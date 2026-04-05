-- backend/http.lua — Anthropic HTTP API adapter.
--
-- Uses curl via subprocess.lua to hit the Anthropic /v1/messages endpoint.
-- Handles SSE streaming. Used as fallback when the CLI is unavailable,
-- or as a primary backend when the user provides an API key.

local M = {}

local log        = require("agentflow.util.log")
local json       = require("agentflow.util.json")
local subprocess = require("agentflow.util.subprocess")

local ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"
local ANTHROPIC_VERSION = "2023-06-01"

-- ── Constructor ───────────────────────────────────────────────────────────────

--- @param opts table {
---   api_key_env? string   Env var name holding the API key (default "ANTHROPIC_API_KEY")
---   api_key?     string   Literal API key (overrides env var)
---   base_url?    string   Override the endpoint URL
--- }
function M.new(opts)
  opts = opts or {}
  local self = {
    api_key_env = opts.api_key_env or "ANTHROPIC_API_KEY",
    _api_key    = opts.api_key,
    base_url    = opts.base_url or ANTHROPIC_API_URL,
  }
  return setmetatable(self, { __index = M })
end

function M:_get_api_key()
  if self._api_key then return self._api_key end
  local key = vim.fn.getenv(self.api_key_env)
  if key == vim.NIL or key == "" then return nil end
  return key
end

-- ── SSE parser ────────────────────────────────────────────────────────────────

-- Anthropic SSE lines look like:
--   event: content_block_delta
--   data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}
--
-- We extract just the data lines and parse them as JSON.
local function parse_sse_line(line, state, on_token)
  if line:sub(1, 6) == "data: " then
    local raw = line:sub(7)
    if raw == "[DONE]" then return end

    local event, err = json.decode(raw)
    if not event then
      log.debug("HTTP SSE: could not parse data line", { line = raw, err = err })
      return
    end

    local etype = event.type
    if etype == "content_block_delta" then
      local delta = event.delta
      if delta and delta.type == "text_delta" and delta.text then
        table.insert(state.text_parts, delta.text)
        if on_token then pcall(on_token, delta.text) end
      end
    elseif etype == "message_start" then
      if event.message then
        state.model = event.message.model or state.model
        if event.message.usage then
          state.tokens_in = event.message.usage.input_tokens or state.tokens_in
        end
      end
    elseif etype == "message_delta" then
      if event.usage then
        state.tokens_out = event.usage.output_tokens or state.tokens_out
      end
    elseif etype == "error" then
      log.error("HTTP SSE error event", { event = event })
      state.error = (event.error and event.error.message) or "unknown SSE error"
    end
  end
end

-- ── complete() ────────────────────────────────────────────────────────────────

--- Send messages to the Anthropic API via curl.
--- Must be called from within a coroutine.
---
--- @param messages table[]
--- @param opts table { model, max_tokens, system?, on_token? }
--- @return table|nil  { content, tokens_in, tokens_out, model, raw }
--- @return string|nil error
function M:complete(messages, opts)
  opts = opts or {}

  local api_key = self:_get_api_key()
  if not api_key then
    return nil, "HTTP backend: no API key found in env var " .. self.api_key_env
  end

  local payload_tbl = {
    model      = opts.model or "claude-sonnet-4-20250514",
    max_tokens = opts.max_tokens or 8192,
    messages   = messages,
    stream     = true,
  }
  if opts.system then
    payload_tbl.system = opts.system
  end

  local payload, enc_err = json.encode(payload_tbl)
  if not payload then
    return nil, "HTTP backend: encode error: " .. (enc_err or "?")
  end

  local cmd = {
    "curl", "--silent", "--no-buffer",
    "-X", "POST",
    "-H", "x-api-key: " .. api_key,
    "-H", "anthropic-version: " .. ANTHROPIC_VERSION,
    "-H", "content-type: application/json",
    "-H", "accept: text/event-stream",
    "-d", payload,
    self.base_url,
  }

  log.debug("HTTP request", { model = payload_tbl.model, url = self.base_url })

  local state = {
    text_parts = {},
    tokens_in  = 0,
    tokens_out = 0,
    model      = payload_tbl.model,
    error      = nil,
  }

  local result, run_err = subprocess.run({
    cmd     = cmd,
    timeout = 120000,
    on_stdout = function(line)
      parse_sse_line(line, state, opts.on_token)
    end,
    on_stderr = function(line)
      if line ~= "" then log.debug("HTTP curl stderr", { line = line }) end
    end,
  })

  if run_err then
    return nil, "HTTP backend: subprocess error: " .. run_err
  end

  if result.code ~= 0 then
    return nil, "HTTP backend: curl exited " .. result.code .. ": " .. result.stderr
  end

  if state.error then
    return nil, "HTTP backend: API error: " .. state.error
  end

  -- Non-streaming fallback: parse stdout as a single JSON body
  local content = table.concat(state.text_parts, "")
  if content == "" and result.stdout ~= "" then
    local body, _ = json.decode(result.stdout)
    if body and body.content then
      for _, block in ipairs(body.content) do
        if block.type == "text" then content = content .. (block.text or "") end
      end
      if body.usage then
        state.tokens_in  = body.usage.input_tokens  or state.tokens_in
        state.tokens_out = body.usage.output_tokens or state.tokens_out
      end
      state.model = body.model or state.model
    end
  end

  log.info("HTTP complete", {
    tokens_in  = state.tokens_in,
    tokens_out = state.tokens_out,
    model      = state.model,
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
