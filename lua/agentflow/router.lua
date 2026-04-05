-- router.lua — Rules engine: task → agent assignment.
--
-- Rules are evaluated in priority order (lower number = higher priority).
-- The first matching rule whose agent is available wins.
-- Falls back to the configured fallback agent if no rules match.

local M = {}

local log = require("agentflow.util.log")

-- ── Rule matching ─────────────────────────────────────────────────────────────

--- Check whether a single rule matches a task.
---
--- Supported match conditions (all optional; omitted conditions always match):
---   match.fallback      boolean   Matches everything — use as catch-all
---   match.task_type     string    Exact task_type match
---   match.filetype      string    Matches current buffer filetype
---   match.file_pattern  string    Lua pattern matched against required file paths
---   match.agent_hint    boolean   If true, only matches when task.agent_hint is set
---
--- @param task table   Task object from planner
--- @param rule table   Routing rule { match, agent, priority }
--- @param context table|nil  Extra context { filetype? }
--- @return boolean
function M.match_rule(task, rule, context)
  local match = rule.match
  if not match then return false end

  -- Fallback rule always matches
  if match.fallback then return true end

  -- task_type
  if match.task_type and task.task_type ~= match.task_type then
    return false
  end

  -- filetype: compare against current buffer filetype (passed in context)
  if match.filetype then
    local ft = context and context.filetype or ""
    if ft ~= match.filetype then return false end
  end

  -- file_pattern: check if any required file matches the Lua pattern
  if match.file_pattern then
    local files = (task.context_requirements and task.context_requirements.files) or {}
    local found = false
    for _, f in ipairs(files) do
      if f:match(match.file_pattern) then
        found = true
        break
      end
    end
    if not found then return false end
  end

  -- agent_hint: only match when the orchestrator suggested a specific agent
  if match.agent_hint then
    if not task.agent_hint or task.agent_hint == "" then return false end
  end

  return true
end

-- ── assign() ─────────────────────────────────────────────────────────────────

--- Assign a task to the best available agent.
---
--- Algorithm:
---   1. If task.agent_hint is set and that agent is available → use it
---   2. Collect all rules that match the task
---   3. Sort by priority (ascending)
---   4. Return the first matching rule's agent that is available
---   5. Fall back to the config fallback agent
---
--- @param task table       Task from planner
--- @param agents table[]   List of registered agent configs (from agents.list())
--- @param rules table[]    Routing rules (from config.routing.rules)
--- @param available table|nil  Set of available agent names { name = true }
---                             If nil, all agents are treated as available.
--- @param context table|nil  { filetype? }
--- @return string|nil  Agent name, or nil if no agent found
function M.assign(task, agents, rules, available, context)
  -- Build a quick lookup of agent names
  local agent_names = {}
  for _, a in ipairs(agents) do
    agent_names[a.name] = true
  end

  local function is_available(name)
    if not agent_names[name] then return false end
    if available == nil then return true end
    return available[name] == true
  end

  -- Honour agent_hint if the orchestrator suggested a specific agent
  if task.agent_hint and task.agent_hint ~= "" then
    if is_available(task.agent_hint) then
      log.debug("router: using agent_hint", {
        task  = task.id,
        agent = task.agent_hint,
      })
      return task.agent_hint
    else
      log.debug("router: agent_hint unavailable, falling through to rules", {
        task  = task.id,
        hint  = task.agent_hint,
      })
    end
  end

  -- Collect matching rules
  local matches = {}
  for _, rule in ipairs(rules or {}) do
    if M.match_rule(task, rule, context) then
      table.insert(matches, rule)
    end
  end

  -- Sort by priority (lower = higher priority)
  table.sort(matches, function(a, b)
    return (a.priority or 99) < (b.priority or 99)
  end)

  -- Return first available match
  for _, rule in ipairs(matches) do
    if rule.agent and is_available(rule.agent) then
      log.debug("router: rule matched", {
        task     = task.id,
        agent    = rule.agent,
        priority = rule.priority,
      })
      return rule.agent
    end
  end

  -- Explicit fallback: find a fallback rule even if agent is "busy"
  -- (pool will queue it; we still need to name an agent)
  for _, rule in ipairs(matches) do
    if rule.agent and agent_names[rule.agent] then
      log.debug("router: using busy-but-known agent as fallback", {
        task  = task.id,
        agent = rule.agent,
      })
      return rule.agent
    end
  end

  log.warn("router: no rule matched, no agent assigned", { task = task.id })
  return nil
end

-- ── get_available() ───────────────────────────────────────────────────────────

--- Build an availability set from the pool's current state.
--- @param pool table  agents/pool.lua instance
--- @return table  { agent_name = true } for idle agents
function M.get_available(pool)
  local out = {}
  if pool and pool.get_idle then
    for _, name in ipairs(pool:get_idle()) do
      out[name] = true
    end
  end
  return out
end

return M
