-- persistence.lua — Save/load orchestrator conversation history and agent logs.
--
-- Sessions are stored under .agentflow/sessions/{session_id}/
-- Structure:
--   conversation.json   Full orchestrator message history
--   plan.json           The task plan (if any)
--   meta.json           Timestamp, cost, model info
--   logs/               Per-agent conversation logs

local M = {}

local log  = require("agentflow.util.log")
local json = require("agentflow.util.json")

-- ── Path helpers ──────────────────────────────────────────────────────────────

local function sessions_dir()
  return vim.fn.getcwd() .. "/.agentflow/sessions"
end

local function session_dir(id)
  return sessions_dir() .. "/" .. id
end

local function ensure_dir(path)
  vim.fn.mkdir(path, "p")
end

local function write_json(path, data)
  local encoded, err = json.encode(data, false)
  if not encoded then
    log.warn("persistence: encode failed", { path = path, err = err })
    return false
  end
  local lines = vim.split(encoded, "\n", { plain = true })
  return vim.fn.writefile(lines, path) == 0
end

local function read_json(path)
  if vim.fn.filereadable(path) == 0 then return nil end
  local lines = vim.fn.readfile(path)
  if not lines or #lines == 0 then return nil end
  local data, err = json.decode(table.concat(lines, "\n"))
  if not data then
    log.warn("persistence: decode failed", { path = path, err = err })
  end
  return data
end

-- ── Session ID ────────────────────────────────────────────────────────────────

--- Generate a session ID based on current timestamp.
--- @return string  e.g. "2026-04-05T142301"
local function new_session_id()
  return os.date("%Y-%m-%dT%H%M%S")
end

-- ── Save ─────────────────────────────────────────────────────────────────────

--- Save the current orchestrator state to disk.
--- @param orchestrator table  Orchestrator instance
--- @param session_id string|nil  Uses auto-generated ID if nil
--- @return string  The session ID used
function M.save(orchestrator, session_id)
  session_id = session_id or new_session_id()
  local dir  = session_dir(session_id)
  ensure_dir(dir)
  ensure_dir(dir .. "/logs")

  -- Conversation history
  write_json(dir .. "/conversation.json", orchestrator:get_conversation())

  -- Task plan
  local plan = orchestrator:get_plan()
  if plan then
    write_json(dir .. "/plan.json", {
      tasks           = plan.tasks,
      execution_order = plan.execution_order,
    })
  end

  -- Metadata
  local cost = orchestrator:get_cost()
  write_json(dir .. "/meta.json", {
    session_id  = session_id,
    saved_at    = os.date("%Y-%m-%dT%H:%M:%S"),
    cost        = cost,
    model       = orchestrator.cfg and orchestrator.cfg.orchestrator.model,
  })

  log.info("persistence: session saved", { id = session_id, dir = dir })
  return session_id
end

--- Save an individual agent's conversation log.
--- @param agent table  agents/agent.lua instance
--- @param session_id string
function M.save_agent_log(agent, session_id)
  local dir  = session_dir(session_id) .. "/logs"
  ensure_dir(dir)
  local path = dir .. "/" .. agent.name .. ".json"
  write_json(path, {
    name    = agent.name,
    state   = agent.state,
    depth   = agent.depth,
    metrics = agent.metrics,
    history = agent.history,
  })
end

-- ── Load ─────────────────────────────────────────────────────────────────────

--- Load a saved session into an orchestrator instance.
--- @param orchestrator table  Orchestrator to restore state into
--- @param session_id string
--- @return boolean ok
function M.load(orchestrator, session_id)
  local dir = session_dir(session_id)

  local conversation = read_json(dir .. "/conversation.json")
  if not conversation then
    log.warn("persistence: no conversation found", { id = session_id })
    return false
  end

  orchestrator.conversation = conversation

  local plan_data = read_json(dir .. "/plan.json")
  if plan_data then
    orchestrator.active_plan = plan_data
  end

  local meta = read_json(dir .. "/meta.json")
  if meta and meta.cost then
    orchestrator._cost = meta.cost
  end

  log.info("persistence: session loaded", {
    id    = session_id,
    turns = #conversation,
  })
  return true
end

-- ── List sessions ─────────────────────────────────────────────────────────────

--- Return a list of saved session IDs, most recent first.
--- @return table[]  { id, saved_at, cost, model }
function M.list_sessions()
  local dir = sessions_dir()
  if vim.fn.isdirectory(dir) == 0 then return {} end

  local entries = {}
  local handle  = vim.loop.fs_scandir(dir)
  if not handle then return {} end

  while true do
    local name, kind = vim.loop.fs_scandir_next(handle)
    if not name then break end
    if kind == "directory" then
      local meta = read_json(dir .. "/" .. name .. "/meta.json")
      table.insert(entries, {
        id       = name,
        saved_at = meta and meta.saved_at or "",
        cost     = meta and meta.cost or {},
        model    = meta and meta.model or "?",
      })
    end
  end

  -- Sort most-recent-first
  table.sort(entries, function(a, b) return a.id > b.id end)
  return entries
end

--- Delete a session directory.
--- @param session_id string
function M.delete(session_id)
  local dir = session_dir(session_id)
  if vim.fn.isdirectory(dir) == 1 then
    vim.fn.delete(dir, "rf")
    log.info("persistence: deleted session", { id = session_id })
  end
end

-- ── Auto-save integration ─────────────────────────────────────────────────────

local _current_session_id = nil

--- Start auto-saving after synthesis completes.
--- Call this once from init.lua after setup().
--- @param orchestrator table
function M.setup_autosave(orchestrator)
  local events = require("agentflow.util.events")
  events.on("orchestrator:synthesized", function(_)
    _current_session_id = new_session_id()
    local ok, err = pcall(M.save, orchestrator, _current_session_id)
    if not ok then
      log.warn("persistence: autosave failed", { err = tostring(err) })
    else
      log.info("persistence: autosaved", { id = _current_session_id })
    end
  end)
end

--- Return the session ID of the last auto-save.
function M.last_session_id()
  return _current_session_id
end

return M
