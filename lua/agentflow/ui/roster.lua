-- ui/roster.lua — Vertical split showing all registered agents and their live status.
--
-- One line per agent: [status dot] name  model  backend  (depth/children)
-- Updates reactively when agent state changes via the event bus.

local M = {}

local log = require("agentflow.util.log")

-- ── Highlight groups ─────────────────────────────────────────────────────────

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AgentFlowRosterIdle",      { fg = "#6c7086" })
  vim.api.nvim_set_hl(0, "AgentFlowRosterRunning",   { fg = "#a6e3a1", bold = true })
  vim.api.nvim_set_hl(0, "AgentFlowRosterCompleted", { fg = "#89b4fa" })
  vim.api.nvim_set_hl(0, "AgentFlowRosterFailed",    { fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "AgentFlowRosterAssigned",  { fg = "#fab387" })
  vim.api.nvim_set_hl(0, "AgentFlowRosterHeader",    { fg = "#cdd6f4", bold = true })
  vim.api.nvim_set_hl(0, "AgentFlowRosterDim",       { fg = "#45475a" })
end

-- ── State ─────────────────────────────────────────────────────────────────────

local _state = {
  buf      = nil,
  win      = nil,
  agents   = {},   -- list of agent objects being tracked
  width    = 35,
}

-- ── Status dot mapping ────────────────────────────────────────────────────────

local STATE_DOT = {
  idle      = { dot = "○", hl = "AgentFlowRosterIdle" },
  assigned  = { dot = "◐", hl = "AgentFlowRosterAssigned" },
  running   = { dot = "●", hl = "AgentFlowRosterRunning" },
  completed = { dot = "✓", hl = "AgentFlowRosterCompleted" },
  failed    = { dot = "✗", hl = "AgentFlowRosterFailed" },
}

local function dot_for(state)
  return STATE_DOT[state] or { dot = "?", hl = "AgentFlowRosterIdle" }
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

local function render()
  if not (_state.buf and vim.api.nvim_buf_is_valid(_state.buf)) then return end

  local lines = {}
  local highlights = {}   -- { line, col_start, col_end, hl_group }

  -- Header
  table.insert(lines, " AgentFlow Roster")
  table.insert(highlights, { #lines - 1, 1, -1, "AgentFlowRosterHeader" })
  table.insert(lines, string.rep("─", _state.width - 2))
  table.insert(highlights, { #lines - 1, 0, -1, "AgentFlowRosterDim" })

  if #_state.agents == 0 then
    table.insert(lines, " (no agents registered)")
    table.insert(highlights, { #lines - 1, 1, -1, "AgentFlowRosterIdle" })
  else
    for _, agent in ipairs(_state.agents) do
      local d      = dot_for(agent.state)
      local indent = string.rep("  ", agent.depth or 0)
      local name   = agent.name or "?"
      local model  = (agent.config and agent.config.model) or ""
      -- Trim model to keep lines short
      model = model:match("([^/]+)$") or model   -- last path component
      if #model > 14 then model = model:sub(1, 13) .. "…" end

      local children_count = agent.children and #agent.children or 0
      local suffix = children_count > 0 and (" [" .. children_count .. "]") or ""

      local line = string.format(" %s%s %s  %s%s",
        indent, d.dot, name, model, suffix)

      -- Pad to width
      if #line < _state.width then
        line = line .. string.rep(" ", _state.width - #line)
      end

      local line_idx = #lines
      table.insert(lines, line)
      -- Highlight just the dot
      local dot_col = #indent + 1  -- 0-indexed, +1 for leading space
      table.insert(highlights, { line_idx, dot_col, dot_col + #d.dot, d.hl })
    end
  end

  table.insert(lines, "")
  table.insert(lines, string.rep("─", _state.width - 2))
  table.insert(highlights, { #lines - 1, 0, -1, "AgentFlowRosterDim" })
  table.insert(lines, " <CR> detail  d kill  q close")
  table.insert(highlights, { #lines - 1, 1, -1, "AgentFlowRosterDim" })

  vim.api.nvim_set_option_value("modifiable", true, { buf = _state.buf })
  vim.api.nvim_buf_set_lines(_state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(_state.buf, -1, 0, -1)
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(_state.buf, -1, h[4], h[1], h[2], h[3])
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })
end

-- ── Keymaps ───────────────────────────────────────────────────────────────────

local function agent_at_cursor()
  if not (_state.win and vim.api.nvim_win_is_valid(_state.win)) then return nil end
  local row = vim.api.nvim_win_get_cursor(_state.win)[1]
  -- Lines 1 and 2 are header; agents start at line 3 (1-indexed)
  local idx = row - 2
  return _state.agents[idx]
end

local function set_keymaps()
  local buf = _state.buf
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true })
  end

  map("<CR>", function()
    local agent = agent_at_cursor()
    if agent then
      vim.notify("AgentFlow: detail view (Phase 5)", vim.log.levels.INFO)
    end
  end)

  map("d", function()
    local agent = agent_at_cursor()
    if agent then
      agent:cancel_subtree()
      render()
    end
  end)

  map("q",     function() M.close() end)
  map("<Esc>", function() M.close() end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Open the roster split. If already open, focus it.
--- @param agents table[]|nil  Agent objects to display (defaults to registry)
function M.open(agents)
  setup_highlights()

  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    vim.api.nvim_set_current_win(_state.win)
    return
  end

  local cfg = require("agentflow.config").get()
  _state.width = cfg.ui.roster_width or 35

  -- Pull from registry if no agents supplied
  if agents then
    _state.agents = agents
  else
    local registry = require("agentflow.agents")
    _state.agents = {}
    for _, ac in ipairs(registry.list()) do
      -- Wrap config entries as minimal agent-like tables for display
      table.insert(_state.agents, {
        name     = ac.name,
        state    = "idle",
        depth    = 0,
        children = {},
        config   = ac,
      })
    end
  end

  -- Create buffer
  _state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype",  "agentflow-roster", { buf = _state.buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = _state.buf })

  -- Open vertical split on the right
  vim.cmd("botright " .. _state.width .. "vsplit")
  _state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(_state.win, _state.buf)
  vim.api.nvim_set_option_value("number",         false, { win = _state.win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = _state.win })
  vim.api.nvim_set_option_value("signcolumn",     "no",  { win = _state.win })
  vim.api.nvim_set_option_value("wrap",           false, { win = _state.win })
  vim.api.nvim_set_option_value("cursorline",     true,  { win = _state.win })

  set_keymaps()
  render()
  log.debug("Roster opened", { agents = #_state.agents })
end

--- Close the roster window.
function M.close()
  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    vim.api.nvim_win_close(_state.win, true)
  end
  _state.win = nil
  _state.buf = nil
end

--- Update the list of tracked agents and re-render.
--- @param agents table[]
function M.update(agents)
  _state.agents = agents
  render()
end

--- Re-render in place (called from event callbacks).
function M.refresh()
  render()
end

--- Subscribe to an event bus so the roster updates automatically.
--- @param events table  util/events.lua instance
function M.subscribe(events)
  local refresh_events = {
    "agent:state_changed",
    "agent:started",
    "agent:completed",
    "agent:failed",
    "plan:created",
  }
  for _, ev in ipairs(refresh_events) do
    events.on(ev, function(_)
      vim.schedule(function() render() end)
    end)
  end
end

return M
