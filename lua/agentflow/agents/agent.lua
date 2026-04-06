-- agents/agent.lua — Single agent state machine.
--
-- States: idle → assigned → running → completed | failed → idle
--
-- An agent wraps a backend adapter and manages one task at a time.
-- It knows its parent, children, and depth in the recursive tree.

local M = {}

local log     = require("agentflow.util.log")
local backend = require("agentflow.backend")

-- ── Valid states ──────────────────────────────────────────────────────────────

local STATES = {
  idle      = "idle",
  assigned  = "assigned",
  running   = "running",
  completed = "completed",
  failed    = "failed",
}
M.STATES = STATES

-- ── Constructor ───────────────────────────────────────────────────────────────

--- Create a new agent instance.
--- @param agent_config table  Entry from the agent registry (name, model, backend, ...)
--- @param opts table|nil {
---   parent?   Agent   Parent agent (nil for root/orchestrator)
---   depth?    number  Tree depth (0 = orchestrator)
---   events?   table   Event bus (util/events.lua)
--- }
function M.new(agent_config, opts)
  opts = opts or {}
  local self = {
    -- Identity
    name   = agent_config.name,
    config = agent_config,

    -- Tree position
    parent   = opts.parent or nil,
    children = {},
    depth    = opts.depth  or 0,

    -- State machine
    state        = STATES.idle,
    current_task = nil,

    -- Conversation history with this agent
    history = {},

    -- Performance metrics
    metrics = {
      tokens_in    = 0,
      tokens_out   = 0,
      duration_ms  = 0,
      started_at   = nil,
    },

    -- Event bus (set externally)
    _events = opts.events or nil,

    -- Cancellation flag
    _cancelled = false,

    -- Backend adapter (created lazily)
    _backend = nil,
  }
  return setmetatable(self, { __index = M })
end

-- ── State helpers ─────────────────────────────────────────────────────────────

function M:_set_state(new_state)
  local old = self.state
  self.state = new_state
  log.debug("Agent state change", { name = self.name, from = old, to = new_state })
  self:_emit("agent:state_changed", { agent = self, from = old, to = new_state })
end

function M:_emit(event, data)
  if self._events then
    self._events.emit(event, data)
  end
end

function M:_get_backend()
  if not self._backend then
    self._backend = backend.get(self.config.backend or "cli", self.config)
  end
  return self._backend
end

-- ── Run ───────────────────────────────────────────────────────────────────────

--- Execute a task. Must be called from within a coroutine.
---
--- @param task table    Task object from planner.lua { description, task_type, ... }
--- @param context string  Pre-built context string from context/init.lua
--- @param opts table|nil {
---   system?    string    Override system prompt
---   on_token?  function  Streaming token callback
--- }
--- @return table|nil  { content, tokens_in, tokens_out, model }
--- @return string|nil error
function M:run(task, context, opts)
  opts = opts or {}

  if self._cancelled then
    return nil, "agent cancelled before start"
  end

  self.current_task = task
  self:_set_state(STATES.assigned)
  self:_emit("agent:started", { agent = self, task = task })

  self.metrics.started_at = vim.loop.now()
  self:_set_state(STATES.running)

  -- Build the messages array for this turn
  -- The context is injected as the first user message, followed by the task instruction.
  local messages = vim.list_slice(self.history, 1, #self.history)  -- copy history

  local user_content = ""
  if context and context ~= "" then
    user_content = "## Context\n\n" .. context .. "\n\n"
  end
  user_content = user_content .. "## Task\n\n" .. (task.description or "")

  table.insert(messages, { role = "user", content = user_content })

  local adapter = self:_get_backend()
  local retry   = require("agentflow.util.retry")

  -- Wrap with retry + timeout from config
  local cfg        = require("agentflow.config").get()
  local timeout_ms = cfg.concurrency.timeout_ms or 30000

  local result, err = retry.run(function()
    return adapter:complete(messages, {
      model      = self.config.model,
      max_tokens = self.config.max_tokens or 8192,
      system     = opts.system or self.config.system_prompt,
      on_token   = opts.on_token,
      timeout    = timeout_ms,
    })
  end, {
    max_attempts = 3,
    base_ms      = 1000,
    on_retry     = function(attempt, retry_err, wait_ms)
      self:_emit("agent:retrying", {
        agent   = self,
        attempt = attempt,
        error   = retry_err,
        wait_ms = wait_ms,
      })
      vim.schedule(function()
        vim.notify(
          string.format("AgentFlow: %s retry %d (wait %dms): %s",
            self.name, attempt, wait_ms, retry_err),
          vim.log.levels.WARN
        )
      end)
    end,
  })

  self.metrics.duration_ms = vim.loop.now() - (self.metrics.started_at or 0)

  if self._cancelled then
    self.error = "cancelled"
    self:_set_state(STATES.failed)
    self:_emit("agent:failed", { agent = self, error = "cancelled" })
    return nil, "agent cancelled"
  end

  if err then
    self.error = err
    self:_set_state(STATES.failed)
    self.metrics.tokens_in  = 0
    self.metrics.tokens_out = 0
    self:_emit("agent:failed", { agent = self, error = err })
    log.error("Agent failed", { name = self.name, error = err })
    return nil, err
  end

  -- Record metrics
  self.metrics.tokens_in  = self.metrics.tokens_in  + (result.tokens_in  or 0)
  self.metrics.tokens_out = self.metrics.tokens_out + (result.tokens_out or 0)

  -- Append assistant turn to history
  table.insert(self.history, { role = "user",      content = user_content })
  table.insert(self.history, { role = "assistant", content = result.content })

  self.result = result

  self:_set_state(STATES.completed)
  self:_emit("agent:completed", { agent = self, result = result })
  log.info("Agent completed", {
    name       = self.name,
    tokens_in  = self.metrics.tokens_in,
    tokens_out = self.metrics.tokens_out,
    duration_ms = self.metrics.duration_ms,
  })

  return result, nil
end

-- ── Child management ──────────────────────────────────────────────────────────

--- Spawn a child agent. Enforces max_depth from config.
--- @param child_agent_config table  Agent config for the child
--- @param opts table|nil  Forwarded to M.new
--- @return table|nil  child Agent, or nil if depth limit hit
--- @return string|nil error
function M:spawn_child(child_agent_config, opts)
  local cfg = require("agentflow.config").get()
  local max_depth = cfg.concurrency.max_depth or 5
  local max_children = cfg.concurrency.max_children_per_agent or 20

  if self.depth >= max_depth then
    local msg = "depth limit reached (" .. max_depth .. "), cannot spawn child"
    log.warn("Agent spawn blocked by depth limit", { name = self.name, depth = self.depth })
    return nil, msg
  end

  if #self.children >= max_children then
    local msg = "child limit reached (" .. max_children .. ") for agent " .. self.name
    log.warn("Agent spawn blocked by child limit", { name = self.name })
    return nil, msg
  end

  opts = opts or {}
  opts.parent = self
  opts.depth  = self.depth + 1
  opts.events = self._events

  local child = M.new(child_agent_config, opts)
  table.insert(self.children, child)
  log.debug("Spawned child agent", {
    parent = self.name,
    child  = child.name,
    depth  = child.depth,
  })
  return child, nil
end

--- Return a flat list of all descendants (recursive).
--- @return table[]  Agent list
function M:get_subtree()
  local out = {}
  local function walk(agent)
    for _, child in ipairs(agent.children) do
      table.insert(out, child)
      walk(child)
    end
  end
  walk(self)
  return out
end

--- Cancel this agent and all its descendants.
function M:cancel_subtree()
  self._cancelled = true
  if self.state == STATES.running or self.state == STATES.assigned then
    self:_set_state(STATES.failed)
    self:_emit("agent:failed", { agent = self, error = "cancelled" })
  end
  for _, child in ipairs(self:get_subtree()) do
    child._cancelled = true
    if child.state == STATES.running or child.state == STATES.assigned then
      child:_set_state(STATES.failed)
      child:_emit("agent:failed", { agent = child, error = "cancelled" })
    end
  end
  log.info("Cancelled agent subtree", { root = self.name })
end

--- Cancel only this agent (not children).
function M:cancel()
  self._cancelled = true
  log.info("Agent cancelled", { name = self.name })
end

--- Reset the agent back to idle so it can be reused.
function M:reset()
  self._cancelled  = false
  self.current_task = nil
  self.result      = nil
  self.error       = nil
  self.history     = {}
  self.metrics     = { tokens_in = 0, tokens_out = 0, duration_ms = 0, started_at = nil }
  self:_set_state(STATES.idle)
end

-- ── Aggregated metrics ────────────────────────────────────────────────────────

--- Sum tokens across this agent and all descendants.
--- @return table { tokens_in, tokens_out, agent_count }
function M:total_metrics()
  local totals = {
    tokens_in   = self.metrics.tokens_in,
    tokens_out  = self.metrics.tokens_out,
    agent_count = 1,
  }
  for _, child in ipairs(self:get_subtree()) do
    totals.tokens_in   = totals.tokens_in   + child.metrics.tokens_in
    totals.tokens_out  = totals.tokens_out  + child.metrics.tokens_out
    totals.agent_count = totals.agent_count + 1
  end
  return totals
end

return M
