-- backend/cli.lua — Claude CLI adapter (primary backend).
--
-- Uses the user's existing Claude subscription via the `claude` CLI binary.
-- No API key required for this path.
--
-- Invocation:
--   claude api messages [flags...]
-- Stdin:  JSON payload  { model, messages, max_tokens, stream: true }
-- Stdout: newline-delimited streaming JSON events

local M = {}

local log        = require("agentflow.util.log")
local json       = require("agentflow.util.json")
local subprocess = require("agentflow.util.subprocess")

-- ── Discovery ────────────────────────────────────────────────────────────────

local _discovery_cache = nil   -- nil = unchecked, true/false after first check

--- Check whether the Claude CLI binary is available and working.
--- Result is cached after the first call.
--- @param cli_path string  Path to the binary (default "claude")
--- @return boolean, string|nil  available, version_or_error
function M.discover(cli_path)
  cli_path = cli_path or "claude"

  if _discovery_cache ~= nil then
    return _discovery_cache
  end

  local out = vim.fn.system({ cli_path, "--version" })
  local code = vim.v.shell_error

  if code ~= 0 then
    log.warn("CLI discovery failed", { cli_path = cli_path, code = code })
    _discovery_cache = false
    return false, "claude CLI not found or returned non-zero: " .. tostring(out):gsub("\n", "")
  end

  local version = out:match("([%d%.]+)")
  log.info("CLI discovered", { cli_path = cli_path, version = version or out:gsub("\n", "") })
  _discovery_cache = true
  return true, version
end

--- Reset discovery cache (useful in tests or after install).
function M.reset_discovery()
  _discovery_cache = nil
end

-- ── Adapter ──────────────────────────────────────────────────────────────────

--- Create a new CLI adapter instance.
--- @param opts table  { cli_path?, cli_flags?, fallback_fn? }
---   cli_path    string      Path to the claude binary (default "claude")
---   cli_flags   string[]    Extra flags passed after "api messages"
---   fallback_fn function    Called with (messages, opts) if CLI unavailable
function M.new(opts)
  opts = opts or {}
  local self = {
    cli_path    = opts.cli_path or "claude",
    cli_flags   = opts.cli_flags or { "--output-format", "stream-json", "--verbose" },
    fallback_fn = opts.fallback_fn,
  }
  return setmetatable(self, { __index = M })
end

--- Send a list of messages to Claude via the CLI and return the response.
--- Must be called from within a coroutine (uses subprocess.run internally).
---
--- @param messages table[]  Array of { role: "user"|"assistant", content: string }
--- @param opts table {
---   model      string    Model ID (e.g. "claude-sonnet-4-20250514")
---   max_tokens number    Max tokens in the response
---   system     string|nil  Optional system prompt
---   on_token   fun(text:string)|nil  Called for each streamed text delta
--- }
--- @return table|nil  { content, tokens_in, tokens_out, model, raw }
--- @return string|nil  error message
function M:complete(messages, opts)
  opts = opts or {}

  -- Discovery check
  local available, disc_err = M.discover(self.cli_path)
  if not available then
    if self.fallback_fn then
      log.warn("CLI unavailable, routing to fallback", { reason = disc_err })
      return self.fallback_fn(messages, opts)
    end
    return nil, "CLI backend unavailable: " .. (disc_err or "unknown")
  end

  -- Build the JSON payload
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
    return nil, "CLI backend: failed to encode payload: " .. (enc_err or "?")
  end

  -- Build command
  local cmd = { self.cli_path, "api", "messages" }
  vim.list_extend(cmd, self.cli_flags)

  log.info("CLI request", { cmd = cmd, model = payload_tbl.model, messages = #messages })

  -- Accumulate streamed response
  local text_parts   = {}
  local tokens_in    = 0
  local tokens_out   = 0
  local model_used   = payload_tbl.model
  local raw_events   = {}
  local agent_mode   = false   -- true when tool-use blocks detected (agent session)

  local function on_stdout(line)
    if line == "" then return end
    log.info("CLI stdout", { line = line })

    local event, parse_err = json.decode(line)
    if not event then
      log.warn("CLI: non-JSON stdout line", { line = line, err = parse_err })
      return
    end

    table.insert(raw_events, event)

    local etype = event.type

    -- Claude Code agent session format (stream-json --verbose)
    -- Text and tool_use arrive in separate assistant events, so we cannot
    -- distinguish intermediate turns from final turns during streaming.
    -- Collect text silently; on_token fires once from the result event.
    if etype == "assistant" then
      local msg = event.message
      if msg then
        if msg.model then model_used = msg.model end
        if msg.content then
          for _, block in ipairs(msg.content) do
            if block.type == "tool_use" then agent_mode = true end
            if block.type == "text" and block.text then
              table.insert(text_parts, block.text)
            end
          end
        end
      end
    elseif etype == "result" then
      if event.usage then
        tokens_in  = (event.usage.input_tokens or 0)
                   + (event.usage.cache_read_input_tokens or 0)
        tokens_out = event.usage.output_tokens or 0
      end
      if type(event.result) == "string" and event.result ~= "" then
        -- event.result is always the canonical final answer; use it
        text_parts = { event.result }
        if opts.on_token then pcall(opts.on_token, event.result) end
      elseif #text_parts > 0 and opts.on_token then
        -- No result field (unusual); emit accumulated text as one chunk
        pcall(opts.on_token, table.concat(text_parts, ""))
      end
    elseif etype == "system" then
      if event.model then model_used = event.model end

    -- Raw Anthropic Messages API streaming format (fallback / future use)
    elseif etype == "content_block_delta" then
      local delta = event.delta
      if delta and delta.type == "text_delta" and delta.text then
        table.insert(text_parts, delta.text)
        if opts.on_token then pcall(opts.on_token, delta.text) end
      end
    elseif etype == "message_delta" then
      if event.usage then
        tokens_out = event.usage.output_tokens or tokens_out
      end
    elseif etype == "message_start" then
      if event.message then
        model_used = event.message.model or model_used
        if event.message.usage then
          tokens_in = event.message.usage.input_tokens or tokens_in
        end
      end
    elseif etype == "error" then
      log.error("CLI stream error event", { event = event })
    end
  end

  local result, run_err = subprocess.run({
    cmd       = cmd,
    stdin     = payload,
    timeout   = 120000,   -- 2 min hard limit for a single completion
    on_stdout = on_stdout,
    on_stderr = function(line)
      if line ~= "" then
        log.info("CLI stderr", { line = line })
      end
    end,
  })

  if run_err then
    return nil, "CLI backend: subprocess error: " .. run_err
  end

  log.info("CLI exited", { code = result.code, raw_events = #raw_events, stdout_bytes = #result.stdout, stderr_bytes = #result.stderr })

  if result.code ~= 0 then
    local stderr_msg = result.stderr ~= "" and result.stderr or "(no stderr)"
    log.error("CLI exited with error", { code = result.code, stderr = stderr_msg })
    return nil, "CLI backend: process exited " .. result.code .. ": " .. stderr_msg
  end

  local content = table.concat(text_parts, "")

  if content == "" and #raw_events == 0 then
    -- No streaming events received; try batch JSON fallback
    -- (only safe when output is a single JSON object, not concatenated NDJSON)
    local body, body_err = json.decode(result.stdout)
    if body and body.content then
      for _, block in ipairs(body.content) do
        if block.type == "text" then
          content = content .. (block.text or "")
        end
      end
      if body.usage then
        tokens_in  = body.usage.input_tokens  or tokens_in
        tokens_out = body.usage.output_tokens or tokens_out
      end
      model_used = body.model or model_used
    elseif body_err then
      log.warn("CLI: could not parse stdout as JSON", { err = body_err })
    end
  end

  log.info("CLI complete", {
    tokens_in  = tokens_in,
    tokens_out = tokens_out,
    model      = model_used,
    chars      = #content,
  })

  return {
    content    = content,
    tokens_in  = tokens_in,
    tokens_out = tokens_out,
    model      = model_used,
    raw        = raw_events,
  }, nil
end

return M
