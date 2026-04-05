-- agents/pool.lua — Concurrency pool for the entire agent tree.
--
-- Enforces a global limit on simultaneously running agents.
-- Each submission runs in its own coroutine, using libuv for I/O.
-- Tracks agent depth and parent relationships for tree-aware scheduling.
--
-- Usage:
--   local pool = require("agentflow.agents.pool").new(4)
--   local future = pool:submit(agent, task, context, opts)
--   local results = pool:wait_all()

local M = {}

local log    = require("agentflow.util.log")
local async  = require("agentflow.util.async")
local events = require("agentflow.util.events")

-- ── Constructor ───────────────────────────────────────────────────────────────

--- Create a new concurrency pool.
--- @param max_parallel number   Maximum agents running simultaneously (default 4)
--- @param max_total    number   Hard cap on total agents ever spawned (default 200)
--- @return table Pool instance
function M.new(max_parallel, max_total)
  local pool = {
    max_parallel  = max_parallel or 4,
    max_total     = max_total    or 200,

    _running      = 0,       -- currently executing agents
    _total        = 0,       -- total agents ever submitted to this pool
    _queue        = {},      -- { agent, task, context, opts, resolve_fn }
    _futures      = {},      -- list of pending futures (for wait_all)
    _cancelled    = false,
  }
  return setmetatable(pool, { __index = M })
end

-- ── Internal scheduling ───────────────────────────────────────────────────────

--- Try to dequeue and start the next waiting submission.
--- Called after each agent finishes.
function M:_drain()
  while self._running < self.max_parallel and #self._queue > 0 do
    -- Prefer shallower agents (tree-aware: breadth-first)
    table.sort(self._queue, function(a, b)
      local da = a.agent.depth or 0
      local db = b.agent.depth or 0
      return da < db
    end)

    local item = table.remove(self._queue, 1)
    self:_start(item)
  end
end

--- Start a queued item in a new coroutine.
--- @param item table  { agent, task, context, opts, resolve_fn }
function M:_start(item)
  self._running = self._running + 1

  async.run(function()
    local agent   = item.agent
    local task    = item.task
    local context = item.context
    local opts    = item.opts or {}

    local result, err = agent:run(task, context, opts)

    -- Update task status in the plan (if accessible via opts)
    if item.on_complete then
      pcall(item.on_complete, result, err)
    end

    vim.schedule(function()
      self._running = self._running - 1

      if result then
        item.resolve_fn({ ok = true,  result = result, agent = agent, task = task })
      else
        item.resolve_fn({ ok = false, error  = err,    agent = agent, task = task })
      end

      -- Process next item in queue
      self:_drain()
    end)
  end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Submit an agent to run a task. Returns a future table.
---
--- The future is resolved when the agent completes (or fails).
--- Collect futures and pass them to wait_all() to block until done.
---
--- @param agent   table   agents/agent.lua instance
--- @param task    table   Task object from planner
--- @param context string  Pre-built context string
--- @param opts    table|nil { system?, on_token?, on_complete? }
--- @return table  future { wait: function }  Call future.wait() inside a coroutine to block
function M:submit(agent, task, context, opts)
  if self._cancelled then
    local future = { wait = function() return { ok = false, error = "pool cancelled" } end }
    return future
  end

  if self._total >= self.max_total then
    log.warn("pool: max_total reached, rejecting submission", {
      max   = self.max_total,
      agent = agent.name,
    })
    local future = {
      wait = function()
        return {
          ok    = false,
          error = "pool max_total (" .. self.max_total .. ") reached",
          agent = agent,
          task  = task,
        }
      end,
    }
    return future
  end

  self._total = self._total + 1

  -- Create a coroutine-yieldable future
  local resolved = false
  local resolved_value = nil
  local waiting_co = nil  -- coroutine blocked on future.wait()

  local function resolve_fn(value)
    resolved       = true
    resolved_value = value
    if waiting_co then
      local co = waiting_co
      waiting_co = nil
      vim.schedule(function()
        coroutine.resume(co, value)
      end)
    end
  end

  local item = {
    agent       = agent,
    task        = task,
    context     = context,
    opts        = opts,
    resolve_fn  = resolve_fn,
    on_complete = opts and opts.on_complete,
  }

  local future = {
    --- Block (yield) inside a coroutine until this agent finishes.
    --- @return table  { ok, result|error, agent, task }
    wait = function()
      if resolved then return resolved_value end
      local co = coroutine.running()
      assert(co, "future.wait() must be called from within a coroutine")
      waiting_co = co
      return coroutine.yield()
    end,
    agent = agent,
    task  = task,
  }

  table.insert(self._futures, future)

  log.debug("pool: submitted", {
    agent    = agent.name,
    task     = task.id,
    running  = self._running,
    queued   = #self._queue,
    depth    = agent.depth,
  })

  if self._running < self.max_parallel then
    self:_start(item)
  else
    table.insert(self._queue, item)
    log.debug("pool: queued (at capacity)", { agent = agent.name, queue_len = #self._queue })
  end

  return future
end

--- Submit a group of (agent, task, context) triples in parallel and wait for all.
--- Must be called from within a coroutine.
---
--- @param submissions table[]  { agent, task, context, opts? }
--- @return table[]  List of { ok, result|error, agent, task }
function M:submit_group(submissions)
  local futures = {}
  for _, s in ipairs(submissions) do
    table.insert(futures, self:submit(s.agent, s.task, s.context, s.opts))
  end
  return self:wait_futures(futures)
end

--- Wait for a specific list of futures. Must be called from within a coroutine.
--- @param futures table[]
--- @return table[]  Results in the same order as futures
function M:wait_futures(futures)
  local results = {}
  for _, future in ipairs(futures) do
    table.insert(results, future.wait())
  end
  return results
end

--- Wait for ALL submitted futures. Must be called from within a coroutine.
--- @return table[]  All results
function M:wait_all()
  return self:wait_futures(self._futures)
end

--- Cancel all running and queued work.
function M:cancel_all()
  self._cancelled = true
  self._queue = {}

  -- Cancel all agents whose futures we hold
  for _, future in ipairs(self._futures) do
    if future.agent then
      future.agent:cancel_subtree()
    end
  end

  log.info("pool: cancelled all work", { total = self._total })
end

--- Cancel a specific agent's subtree without affecting other branches.
--- @param root_agent table  Agent whose subtree to cancel
function M:cancel_subtree(root_agent)
  root_agent:cancel_subtree()

  -- Remove queued items belonging to this subtree
  local subtree = { [root_agent] = true }
  for _, child in ipairs(root_agent:get_subtree()) do
    subtree[child] = true
  end

  local remaining = {}
  for _, item in ipairs(self._queue) do
    if not subtree[item.agent] then
      table.insert(remaining, item)
    end
  end
  self._queue = remaining

  log.info("pool: cancelled subtree", { root = root_agent.name })
end

--- Return the names of agents that are currently idle (not running or queued).
--- Used by router.get_available().
--- @return string[]
function M:get_idle()
  local busy = {}
  for _, item in ipairs(self._queue) do
    busy[item.agent.name] = true
  end
  -- We don't track which specific agent instances are running (pool is task-oriented),
  -- so we return an empty list — the router will fall through to any-available logic.
  return {}
end

--- Return pool stats.
--- @return table { running, queued, total, max_parallel, max_total }
function M:stats()
  return {
    running      = self._running,
    queued       = #self._queue,
    total        = self._total,
    max_parallel = self.max_parallel,
    max_total    = self.max_total,
  }
end

return M
