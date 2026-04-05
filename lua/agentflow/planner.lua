-- planner.lua — Parses the orchestrator's JSON task plan into executable units.
--
-- Responsibilities:
--   parse()         Extract and validate the JSON plan from Claude's response
--   resolve_order() Topological sort into parallel execution groups
--   validate()      Structural validation with error reporting

local M = {}

local log  = require("agentflow.util.log")
local json = require("agentflow.util.json")

-- ── Types (documentation only — Lua is untyped) ───────────────────────────────
--
-- Task = {
--   id:                   string
--   description:          string
--   task_type:            string   "analysis"|"scaffold"|"search"|"edit"|"test"|"review"
--   context_requirements: {
--     files:        string[]
--     scope:        string     "function"|"file"|"project"
--     include_git:  boolean
--   }
--   depends_on:   string[]
--   agent_hint:   string|nil
--   status:       string     "pending"|"running"|"done"|"failed"
--   result:       any
-- }
--
-- Plan = {
--   tasks:           Task[]
--   execution_order: string[][]   -- groups of parallel task IDs
-- }

local VALID_TASK_TYPES = {
  analysis = true, scaffold = true, search = true,
  edit     = true, test     = true, review = true,
}

local VALID_SCOPES = { ["function"] = true, file = true, project = true }

-- ── parse() ───────────────────────────────────────────────────────────────────

--- Extract and deserialize the JSON plan from Claude's response text.
--- Tries to repair obvious JSON issues before giving up.
---
--- @param response_text string  Raw text from the orchestrator's completion
--- @return table|nil  Plan object, or nil on failure
--- @return string|nil error message
function M.parse(response_text)
  if not response_text or response_text == "" then
    return nil, "planner.parse: empty response"
  end

  -- Extract JSON from the response (handles fenced code blocks and bare JSON)
  local raw, extract_err = json.extract(response_text)
  if not raw then
    return nil, "planner.parse: no JSON found in response — " .. (extract_err or "?")
  end

  local data, decode_err = json.decode(raw)
  if not data then
    -- Attempt a simple repair: strip trailing commas
    local repaired = raw:gsub(",(%s*[%]%}])", "%1")
    data, decode_err = json.decode(repaired)
    if not data then
      return nil, "planner.parse: JSON decode failed — " .. (decode_err or "?")
    end
    log.debug("planner.parse: used repaired JSON")
  end

  -- Normalise: accept both { tasks: [...] } and a bare array [...]
  local raw_tasks
  if data.tasks then
    raw_tasks = data.tasks
  elseif vim.islist(data) then
    raw_tasks = data
  else
    return nil, "planner.parse: expected { tasks: [...] } or a bare array"
  end

  -- Hydrate tasks with default values and status field
  local tasks = {}
  for i, t in ipairs(raw_tasks) do
    local task = {
      id          = t.id or ("t" .. i),
      description = t.description or "",
      task_type   = t.task_type   or "analysis",
      context_requirements = {
        files       = (t.context_requirements and t.context_requirements.files) or {},
        scope       = (t.context_requirements and t.context_requirements.scope) or "function",
        include_git = (t.context_requirements and t.context_requirements.include_git) or false,
      },
      depends_on  = t.depends_on  or {},
      agent_hint  = t.agent_hint  or nil,
      status      = "pending",
      result      = nil,
    }
    table.insert(tasks, task)
  end

  local plan = { tasks = tasks }

  -- Resolve execution order
  local order, order_err = M.resolve_order(tasks)
  if not order then
    return nil, "planner.parse: dependency resolution failed — " .. (order_err or "?")
  end
  plan.execution_order = order

  log.info("planner.parse: plan parsed", {
    tasks  = #tasks,
    groups = #order,
  })

  return plan, nil
end

-- ── resolve_order() ───────────────────────────────────────────────────────────

--- Topological sort of tasks into parallel execution groups.
--- Tasks in the same group have no dependency on each other and can run concurrently.
---
--- @param tasks table[]  Task objects (must have .id and .depends_on)
--- @return string[][]|nil  Groups of task IDs in execution order
--- @return string|nil      Error message (e.g. cycle detected)
function M.resolve_order(tasks)
  -- Build id → task and id → set of dependents maps
  local by_id    = {}
  local in_degree = {}   -- id → number of unsatisfied deps
  local dependents = {}  -- id → list of task ids that depend on this one

  for _, t in ipairs(tasks) do
    by_id[t.id]      = t
    in_degree[t.id]  = 0
    dependents[t.id] = {}
  end

  for _, t in ipairs(tasks) do
    for _, dep_id in ipairs(t.depends_on or {}) do
      if not by_id[dep_id] then
        return nil, "task '" .. t.id .. "' depends on unknown task '" .. dep_id .. "'"
      end
      in_degree[t.id] = in_degree[t.id] + 1
      table.insert(dependents[dep_id], t.id)
    end
  end

  -- Kahn's algorithm
  local groups = {}
  local remaining = #tasks

  while remaining > 0 do
    -- Collect all tasks with in_degree 0
    local group = {}
    for id, deg in pairs(in_degree) do
      if deg == 0 then
        table.insert(group, id)
      end
    end

    if #group == 0 then
      -- No progress — cycle detected
      local cycle_ids = {}
      for id, deg in pairs(in_degree) do
        if deg > 0 then table.insert(cycle_ids, id) end
      end
      return nil, "dependency cycle detected among tasks: " .. table.concat(cycle_ids, ", ")
    end

    table.sort(group)  -- deterministic ordering within a group
    table.insert(groups, group)

    -- Remove these tasks from the graph
    for _, id in ipairs(group) do
      in_degree[id] = nil
      for _, dep_id in ipairs(dependents[id]) do
        in_degree[dep_id] = in_degree[dep_id] - 1
      end
      remaining = remaining - 1
    end
  end

  return groups, nil
end

-- ── validate() ────────────────────────────────────────────────────────────────

--- Validate a parsed plan. Returns (true, {}) on success or (false, errors[]).
---
--- @param plan table  Plan object from parse()
--- @return boolean, string[]
function M.validate(plan)
  local errors = {}

  if not plan or type(plan.tasks) ~= "table" then
    return false, { "plan must have a tasks array" }
  end

  local ids = {}
  for i, t in ipairs(plan.tasks) do
    local prefix = "task[" .. i .. "] (" .. (t.id or "?") .. ")"

    if not t.id or t.id == "" then
      table.insert(errors, prefix .. ": id is required")
    elseif ids[t.id] then
      table.insert(errors, prefix .. ": duplicate id '" .. t.id .. "'")
    else
      ids[t.id] = true
    end

    if not t.description or t.description == "" then
      table.insert(errors, prefix .. ": description is required")
    end

    if t.task_type and not VALID_TASK_TYPES[t.task_type] then
      table.insert(errors, prefix .. ": invalid task_type '" .. t.task_type .. "'")
    end

    local scope = t.context_requirements and t.context_requirements.scope
    if scope and not VALID_SCOPES[scope] then
      table.insert(errors, prefix .. ": invalid scope '" .. scope .. "'")
    end

    if t.depends_on and type(t.depends_on) ~= "table" then
      table.insert(errors, prefix .. ": depends_on must be an array")
    end
  end

  -- Cross-validate dependency IDs (only if no id errors yet)
  if #errors == 0 then
    for _, t in ipairs(plan.tasks) do
      for _, dep_id in ipairs(t.depends_on or {}) do
        if not ids[dep_id] then
          table.insert(errors, "task '" .. t.id .. "' depends on unknown id '" .. dep_id .. "'")
        end
      end
    end
  end

  -- Check for cycles
  if #errors == 0 then
    local _, cycle_err = M.resolve_order(plan.tasks)
    if cycle_err then
      table.insert(errors, cycle_err)
    end
  end

  return #errors == 0, errors
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

--- Find a task by ID within a plan.
--- @param plan table
--- @param id string
--- @return table|nil
function M.get_task(plan, id)
  for _, t in ipairs(plan.tasks) do
    if t.id == id then return t end
  end
  return nil
end

--- Return all tasks with a given status.
--- @param plan table
--- @param status string
--- @return table[]
function M.tasks_by_status(plan, status)
  local out = {}
  for _, t in ipairs(plan.tasks) do
    if t.status == status then table.insert(out, t) end
  end
  return out
end

--- Check whether all dependencies of a task are done.
--- @param plan table
--- @param task table
--- @return boolean
function M.deps_satisfied(plan, task)
  for _, dep_id in ipairs(task.depends_on or {}) do
    local dep = M.get_task(plan, dep_id)
    if not dep or dep.status ~= "done" then return false end
  end
  return true
end

return M
