-- backend/ollama.lua — Ollama adapter.
-- Hits http://localhost:11434/api/chat with Ollama's newline-delimited streaming JSON.

local M = {}

local log        = require("agentflow.util.log")
local json       = require("agentflow.util.json")
local subprocess = require("agentflow.util.subprocess")

local DEFAULT_ENDPOINT = "http://localhost:11434"

-- ── Constructor ───────────────────────────────────────────────────────────────

--- @param opts table { endpoint? string, timeout? number }
function M.new(opts)
  opts = opts or {}
  local self = {
    endpoint = opts.endpoint or DEFAULT_ENDPOINT,
    timeout  = opts.timeout  or 120000,
  }
  return setmetatable(self, { __index = M })
end

-- ── Model discovery ───────────────────────────────────────────────────────────

--- List models available in this Ollama instance.
--- Must be called from within a coroutine.
--- @return table[]|nil  [{ name, size, modified_at }], error
function M:list_models()
  local result, err = subprocess.run({
    cmd     = { "curl", "--silent", self.endpoint .. "/api/tags" },
    timeout = 10000,
  })
  if err then return nil, err end
  if result.code ~= 0 then
    return nil, "ollama list_models: curl exited " .. result.code
  end
  local body, decode_err = json.decode(result.stdout)
  if not body then return nil, "ollama list_models: " .. (decode_err or "bad JSON") end
  return body.models or {}, nil
end

--- Check whether a specific model is available.
--- @param model string
--- @return boolean, string|nil
function M:has_model(model)
  local models, err = self:list_models()
  if not models then return false, err end
  for _, m in ipairs(models) do
    if m.name == model or m.name == model .. ":latest" then
      return true, nil
    end
  end
  return false, "model not found: " .. model
end

-- ── Message format ────────────────────────────────────────────────────────────

-- Ollama uses the same role/content structure as OpenAI.
-- We pass messages through unchanged.

-- ── complete() ────────────────────────────────────────────────────────────────

--- Send messages to Ollama and stream back the response.
--- Must be called from within a coroutine.
---
--- @param messages table[]
--- @param opts table { model, max_tokens?, system?, on_token? }
--- @return table|nil  { content, tokens_in, tokens_out, model, raw }
--- @return string|nil error
function M:complete(messages, opts)
  opts = opts or {}

  local model = opts.model
  if not model or model == "" then
    return nil, "ollama: model is required"
  end

  -- Prepend system message if provided (Ollama supports it as a role)
  local msg_list = {}
  if opts.system then
    table.insert(msg_list, { role = "system", content = opts.system })
  end
  vim.list_extend(msg_list, messages)

  local payload_tbl = {
    model    = model,
    messages = msg_list,
    stream   = true,
    options  = {},
  }
  if opts.max_tokens then
    payload_tbl.options.num_predict = opts.max_tokens
  end

  local payload, enc_err = json.encode(payload_tbl)
  if not payload then
    return nil, "ollama: encode error: " .. (enc_err or "?")
  end

  local url = self.endpoint .. "/api/chat"
  local cmd = {
    "curl", "--silent", "--no-buffer",
    "-X", "POST",
    "-H", "content-type: application/json",
    "-d", payload,
    url,
  }

  log.debug("Ollama request", { model = model, endpoint = self.endpoint })

  local text_parts = {}
  local tokens_in  = 0
  local tokens_out = 0
  local raw_events = {}

  local result, run_err = subprocess.run({
    cmd     = cmd,
    timeout = self.timeout,
    on_stdout = function(line)
      if line == "" then return end
      local event, err = json.decode(line)
      if not event then
        log.debug("Ollama: non-JSON line", { line = line, err = err })
        return
      end
      table.insert(raw_events, event)

      if event.message and event.message.content then
        local text = event.message.content
        table.insert(text_parts, text)
        if opts.on_token then pcall(opts.on_token, text) end
      end

      -- Final event carries usage stats
      if event.done then
        tokens_in  = event.prompt_eval_count  or tokens_in
        tokens_out = event.eval_count          or tokens_out
      end
    end,
    on_stderr = function(line)
      if line ~= "" then log.debug("Ollama stderr", { line = line }) end
    end,
  })

  if run_err then return nil, "ollama: subprocess error: " .. run_err end
  if result.code ~= 0 then
    return nil, "ollama: curl exited " .. result.code .. ": " .. result.stderr
  end

  local content = table.concat(text_parts, "")
  log.info("Ollama complete", { model = model, tokens_in = tokens_in, tokens_out = tokens_out })

  return {
    content    = content,
    tokens_in  = tokens_in,
    tokens_out = tokens_out,
    model      = model,
    raw        = raw_events,
  }, nil
end

return M
