-- util/async.lua — Coroutine-based async helpers.
--
-- All I/O in AgentFlow runs through these primitives so Neovim never blocks.
--
-- Patterns:
--   async.run(fn)         -- Run fn in a new coroutine, scheduled via vim.schedule
--   async.wrap(fn)        -- Turn a callback-based fn into a coroutine-yieldable one
--   async.await(wrapped)  -- Yield until a wrapped fn resolves
--   async.sleep(ms)       -- Non-blocking sleep inside a coroutine

local M = {}

local log = require("agentflow.util.log")

--- Run an async function in a new managed coroutine.
--- Errors inside the coroutine are caught and logged rather than crashing Neovim.
---
--- @param fn function  The async function to run (may call coroutine.yield internally)
--- @param ...          Arguments forwarded to fn
--- @return number      Coroutine handle (for cancel, if needed)
function M.run(fn, ...)
  local args = { ... }
  local co = coroutine.create(function()
    local ok, err = pcall(fn, unpack(args))
    if not ok then
      log.error("async.run: unhandled error in coroutine", { error = tostring(err) })
    end
  end)

  vim.schedule(function()
    local ok, err = coroutine.resume(co)
    if not ok then
      log.error("async.run: coroutine failed to start", { error = tostring(err) })
    end
  end)

  return co
end

--- Wrap a callback-based function so it can be yielded on from within a coroutine.
---
--- The wrapped function must call its last argument (the callback) when done.
--- Callback receives (result, error) — the same pattern used by subprocess.run.
---
--- Example:
---   local wrapped = async.wrap(function(a, b, callback)
---     do_async_thing(a, b, callback)
---   end)
---   -- Inside a coroutine:
---   local result, err = async.await(wrapped(a, b))
---
--- @param fn function  A function that accepts (...args, callback)
--- @return function     A wrapper that, when called, returns a "future" table
function M.wrap(fn)
  return function(...)
    local args = { ... }
    return function()
      local co = coroutine.running()
      assert(co, "async.await must be called from within a coroutine")

      table.insert(args, function(result, err)
        vim.schedule(function()
          coroutine.resume(co, result, err)
        end)
      end)

      fn(unpack(args))
      return coroutine.yield()
    end
  end
end

--- Await a "future" returned by async.wrap(fn)(...).
--- Must be called from within a coroutine.
---
--- @param future function  The callable future from async.wrap
--- @return any, string|nil  result, error
function M.await(future)
  assert(type(future) == "function", "async.await expects a future (function)")
  return future()
end

--- Non-blocking sleep. Must be called from within a coroutine.
--- @param ms number  Milliseconds to wait
function M.sleep(ms)
  local co = coroutine.running()
  assert(co, "async.sleep must be called from within a coroutine")

  local timer = vim.loop.new_timer()
  timer:start(ms, 0, vim.schedule_wrap(function()
    timer:stop()
    if not timer:is_closing() then timer:close() end
    coroutine.resume(co)
  end))

  coroutine.yield()
end

--- Run multiple async functions concurrently and wait for all to finish.
--- Returns a list of {result, error} pairs in the same order as fns.
---
--- @param fns function[]  List of zero-argument async functions (each runs in its own coroutine)
--- @return table[]        List of { result, err } tables
function M.all(fns)
  local co = coroutine.running()
  assert(co, "async.all must be called from within a coroutine")

  local n = #fns
  if n == 0 then return {} end

  local results = {}
  local done = 0

  for i, fn in ipairs(fns) do
    M.run(function()
      local ok, val = pcall(fn)
      results[i] = ok and { result = val, err = nil } or { result = nil, err = tostring(val) }
      done = done + 1
      if done == n then
        vim.schedule(function()
          coroutine.resume(co, results)
        end)
      end
    end)
  end

  return coroutine.yield()
end

return M
