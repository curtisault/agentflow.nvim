-- util/retry.lua — Exponential backoff retry helper.
--
-- Usage (inside a coroutine):
--   local result, err = retry.run(function()
--     return backend:complete(messages, opts)
--   end, { max_attempts = 3, base_ms = 500 })

local M = {}

local log   = require("agentflow.util.log")
local async = require("agentflow.util.async")

-- Errors that are not worth retrying
local FATAL_PATTERNS = {
  "authentication",
  "invalid api key",
  "permission denied",
  "not found",
  "model not found",
  "context window exceeded",
  "cancelled",
}

local function is_fatal(err)
  if not err then return false end
  local lower = err:lower()
  for _, pat in ipairs(FATAL_PATTERNS) do
    if lower:find(pat, 1, true) then return true end
  end
  return false
end

--- Run fn with automatic retries and exponential backoff.
--- fn must return (result, error) — the standard AgentFlow convention.
--- Must be called from within a coroutine.
---
--- @param fn function  () → result, err
--- @param opts table|nil {
---   max_attempts? number   Default 3
---   base_ms?      number   Initial wait in ms (default 500)
---   max_ms?       number   Cap per wait (default 30000)
---   jitter?       boolean  Add random jitter (default true)
---   on_retry?     function (attempt, err, wait_ms)
--- }
--- @return any|nil result
--- @return string|nil error  (last error if all attempts fail)
function M.run(fn, opts)
  opts = opts or {}
  local max_attempts = opts.max_attempts or 3
  local base_ms      = opts.base_ms      or 500
  local max_ms       = opts.max_ms       or 30000
  local jitter       = opts.jitter ~= false

  local last_err

  for attempt = 1, max_attempts do
    local result, err = fn()

    if not err then
      if attempt > 1 then
        log.info("retry: succeeded", { attempt = attempt })
      end
      return result, nil
    end

    last_err = err

    if is_fatal(err) then
      log.warn("retry: fatal error, not retrying", { err = err })
      return nil, err
    end

    if attempt == max_attempts then break end

    -- Exponential backoff: base * 2^(attempt-1), capped at max_ms
    local wait = math.min(base_ms * (2 ^ (attempt - 1)), max_ms)
    if jitter then
      wait = wait * (0.75 + math.random() * 0.5)  -- ±25% jitter
    end
    wait = math.floor(wait)

    log.warn("retry: attempt failed, waiting", {
      attempt  = attempt,
      err      = err,
      wait_ms  = wait,
    })

    if opts.on_retry then
      pcall(opts.on_retry, attempt, err, wait)
    end

    async.sleep(wait)
  end

  log.error("retry: all attempts exhausted", {
    max_attempts = max_attempts,
    last_err     = last_err,
  })
  return nil, last_err
end

--- Wrap a backend adapter's complete() with retry logic.
--- Returns a new function with the same signature.
---
--- @param adapter table  Backend adapter instance
--- @param opts table|nil  Retry options
--- @return table  Wrapped adapter (same interface)
function M.wrap_backend(adapter, opts)
  local wrapped = setmetatable({}, { __index = adapter })
  function wrapped:complete(messages, call_opts)
    return M.run(function()
      return adapter:complete(messages, call_opts)
    end, opts)
  end
  return wrapped
end

return M
