-- backend/openai_compat.lua — Generic OpenAI-compatible adapter.
-- Works with OpenRouter, vLLM, and any endpoint that speaks the OpenAI chat completion API.

local M = {}

local log        = require("agentflow.util.log")
local json       = require("agentflow.util.json")
local subprocess = require("agentflow.util.subprocess")

-- ── Constructor ───────────────────────────────────────────────────────────────

--- @param opts table {
---   base_url   string    e.g. "https://openrouter.ai/api/v1"
---   api_key    string|nil
---   api_key_env string|nil  Env var name (fallback if api_key not set)
---   extra_headers table|nil  Additional headers { ["X-Foo"] = "bar" }
--- }
function M.new(opts)
  opts = opts or {}
  assert(opts.base_url, "openai_compat: base_url is required")
  local self = {
    base_url      = opts.base_url:gsub("/$", ""),  -- strip trailing slash
    _api_key      = opts.api_key,
    api_key_env   = opts.api_key_env,
    extra_headers = opts.extra_headers or {},
    timeout       = opts.timeout or 120000,
  }
  return setmetatable(self, { __index = M })
end

function M:_get_api_key()
  if self._api_key then return self._api_key end
  if self.api_key_env then
    local key = vim.fn.getenv(self.api_key_env)
    if key ~= vim.NIL and key ~= "" then return key end
  end
  return nil
end

-- ── SSE parser (OpenAI format) ────────────────────────────────────────────────

local function parse_sse_line(line, state, on_token)
  if line:sub(1, 6) ~= "data: " then return end
  local raw = line:sub(7)
  if raw == "[DONE]" then return end

  local event, err = json.decode(raw)
  if not event then
    log.debug("openai_compat SSE parse error", { line = raw, err = err })
    return
  end

  -- choices[0].delta.content carries the streamed text
  local choices = event.choices
  if choices and choices[1] then
    local delta = choices[1].delta
    if delta and delta.content then
      table.insert(state.text_parts, delta.content)
      if on_token then pcall(on_token, delta.content) end
    end
  end

  -- usage may appear on the final chunk (some providers)
  if event.usage then
    state.tokens_in  = event.usage.prompt_tokens     or state.tokens_in
    state.tokens_out = event.usage.completion_tokens or state.tokens_out
  end

  state.model = event.model or state.model
end

-- ── complete() ────────────────────────────────────────────────────────────────

--- @param messages table[]
--- @param opts table { model, max_tokens?, system?, on_token? }
--- @return table|nil  { content, tokens_in, tokens_out, model, raw }
--- @return string|nil error
function M:complete(messages, opts)
  opts = opts or {}

  local msg_list = {}
  if opts.system then
    table.insert(msg_list, { role = "system", content = opts.system })
  end
  vim.list_extend(msg_list, messages)

  local payload_tbl = {
    model      = opts.model or "gpt-4o",
    messages   = msg_list,
    max_tokens = opts.max_tokens or 8192,
    stream     = true,
  }

  local payload, enc_err = json.encode(payload_tbl)
  if not payload then
    return nil, "openai_compat: encode error: " .. (enc_err or "?")
  end

  local url = self.base_url .. "/chat/completions"
  local api_key = self:_get_api_key()

  local cmd = { "curl", "--silent", "--no-buffer", "-X", "POST" }

  if api_key then
    vim.list_extend(cmd, { "-H", "Authorization: Bearer " .. api_key })
  end
  vim.list_extend(cmd, { "-H", "content-type: application/json" })
  vim.list_extend(cmd, { "-H", "accept: text/event-stream" })

  for k, v in pairs(self.extra_headers) do
    vim.list_extend(cmd, { "-H", k .. ": " .. v })
  end

  vim.list_extend(cmd, { "-d", payload, url })

  log.debug("openai_compat request", { model = payload_tbl.model, url = url })

  local state = {
    text_parts = {},
    tokens_in  = 0,
    tokens_out = 0,
    model      = payload_tbl.model,
  }

  local result, run_err = subprocess.run({
    cmd     = cmd,
    timeout = self.timeout,
    on_stdout = function(line)
      parse_sse_line(line, state, opts.on_token)
    end,
    on_stderr = function(line)
      if line ~= "" then log.debug("openai_compat stderr", { line = line }) end
    end,
  })

  if run_err then return nil, "openai_compat: subprocess error: " .. run_err end
  if result.code ~= 0 then
    return nil, "openai_compat: curl exited " .. result.code .. ": " .. result.stderr
  end

  local content = table.concat(state.text_parts, "")

  -- Non-streaming fallback
  if content == "" and result.stdout ~= "" then
    local body, _ = json.decode(result.stdout)
    if body and body.choices and body.choices[1] then
      local msg = body.choices[1].message
      if msg then content = msg.content or "" end
    end
    if body and body.usage then
      state.tokens_in  = body.usage.prompt_tokens     or state.tokens_in
      state.tokens_out = body.usage.completion_tokens or state.tokens_out
    end
    if body then state.model = body.model or state.model end
  end

  log.info("openai_compat complete", {
    model      = state.model,
    tokens_in  = state.tokens_in,
    tokens_out = state.tokens_out,
  })

  return {
    content    = content,
    tokens_in  = state.tokens_in,
    tokens_out = state.tokens_out,
    model      = state.model,
    raw        = result.stdout,
  }, nil
end

return M
