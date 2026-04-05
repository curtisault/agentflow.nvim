-- backend/lmstudio.lua — LM Studio adapter.
--
-- Distinct from openai_compat because it manages LM Studio's model lifecycle:
-- checking what's loaded, requesting a load before inference, and reporting status.
-- Uses LM Studio's OpenAI-compatible API (default port 1234).

local M = {}

local log           = require("agentflow.util.log")
local json          = require("agentflow.util.json")
local subprocess    = require("agentflow.util.subprocess")
local openai_compat = require("agentflow.backend.openai_compat")

local DEFAULT_BASE_URL = "http://localhost:1234/v1"

-- ── Constructor ───────────────────────────────────────────────────────────────

--- @param opts table { base_url? string, timeout? number }
function M.new(opts)
  opts = opts or {}
  local self = {
    base_url = (opts.base_url or DEFAULT_BASE_URL):gsub("/$", ""),
    timeout  = opts.timeout or 120000,
    -- Delegate inference to the openai_compat adapter
    _compat  = openai_compat.new({
      base_url = opts.base_url or DEFAULT_BASE_URL,
      timeout  = opts.timeout or 120000,
      -- LM Studio typically needs no auth key on localhost
    }),
  }
  return setmetatable(self, { __index = M })
end

-- ── Model management ──────────────────────────────────────────────────────────

--- List currently loaded models via /v1/models.
--- Must be called from within a coroutine.
--- @return table[]|nil  [{ id, ... }], error
function M:list_models()
  local result, err = subprocess.run({
    cmd     = { "curl", "--silent", self.base_url .. "/models" },
    timeout = 8000,
  })
  if err then return nil, "lmstudio list_models: " .. err end
  if result.code ~= 0 then
    return nil, "lmstudio list_models: curl exited " .. result.code
  end

  local body, decode_err = json.decode(result.stdout)
  if not body then
    return nil, "lmstudio list_models: bad JSON: " .. (decode_err or "?")
  end

  return body.data or {}, nil
end

--- Check whether a model is currently loaded.
--- @param model string
--- @return boolean, string|nil
function M:is_loaded(model)
  local models, err = self:list_models()
  if not models then return false, err end
  for _, m in ipairs(models) do
    if m.id == model then return true, nil end
  end
  return false, nil
end

--- Request LM Studio to load a model.
--- LM Studio loads models automatically on first inference request; this is
--- a best-effort pre-warm. Returns immediately — loading happens async in LM Studio.
--- @param model string
function M:request_load(model)
  log.info("lmstudio: requesting model load", { model = model })
  -- LM Studio doesn't expose a dedicated load endpoint; sending a minimal
  -- completion request will trigger the load. We do it fire-and-forget.
  subprocess.run({
    cmd = {
      "curl", "--silent", "--max-time", "5",
      "-X", "POST",
      "-H", "content-type: application/json",
      "-d", json.encode({
        model      = model,
        messages   = { { role = "user", content = "ping" } },
        max_tokens = 1,
        stream     = false,
      }),
      self.base_url .. "/chat/completions",
    },
    timeout = 6000,
  })
end

-- ── complete() ────────────────────────────────────────────────────────────────

--- Send messages to LM Studio.
--- Checks that the model is loaded first; if not, attempts to trigger a load
--- and falls back to an error so the router can reassign.
---
--- @param messages table[]
--- @param opts table { model, max_tokens?, system?, on_token? }
--- @return table|nil  { content, tokens_in, tokens_out, model, raw }
--- @return string|nil error
function M:complete(messages, opts)
  opts = opts or {}
  local model = opts.model
  if not model or model == "" then
    return nil, "lmstudio: model is required"
  end

  local loaded, check_err = self:is_loaded(model)
  if check_err then
    log.warn("lmstudio: could not check model status", { err = check_err })
    -- Proceed anyway — LM Studio may load on demand
  elseif not loaded then
    log.warn("lmstudio: model not loaded, attempting warm-up", { model = model })
    self:request_load(model)
    -- Give it a moment — but don't block; inference will queue in LM Studio
  end

  log.debug("lmstudio request", { model = model, base_url = self.base_url })

  -- Delegate actual inference to the openai_compat adapter
  return self._compat:complete(messages, opts)
end

return M
