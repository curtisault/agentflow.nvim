-- ui/dashboard.lua — Drill-down dashboard with breadcrumb navigation.
--
-- Shows stat cards, a focused agent card, and direct children.
-- <CR> drills into a child, <BS> goes up one level.

local M = {}

local log    = require("agentflow.util.log")
local events = require("agentflow.util.events")

-- ── Highlights ────────────────────────────────────────────────────────────────

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AgentFlowDashHeader",  { fg = "#cdd6f4", bold = true })
  vim.api.nvim_set_hl(0, "AgentFlowDashCrumb",   { fg = "#89b4fa" })
  vim.api.nvim_set_hl(0, "AgentFlowDashSep",     { fg = "#45475a" })
  vim.api.nvim_set_hl(0, "AgentFlowDashStatNum", { fg = "#a6e3a1", bold = true })
  vim.api.nvim_set_hl(0, "AgentFlowDashStatLbl", { fg = "#6c7086" })
  vim.api.nvim_set_hl(0, "AgentFlowDashAgent",   { fg = "#cba6f7" })
  vim.api.nvim_set_hl(0, "AgentFlowDashRunning", { fg = "#a6e3a1", bold = true })
  vim.api.nvim_set_hl(0, "AgentFlowDashFailed",  { fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "AgentFlowDashDim",     { fg = "#45475a" })
end

local STATE_DOT = {
  idle = "○", assigned = "◐", running = "●", completed = "✓", failed = "✗",
}
local STATE_HL = {
  idle = "AgentFlowDashDim", assigned = "AgentFlowDashStatLbl",
  running = "AgentFlowDashRunning", completed = "AgentFlowDashStatNum",
  failed = "AgentFlowDashFailed",
}

-- ── State ─────────────────────────────────────────────────────────────────────

local _state = {
  buf         = nil,
  win         = nil,
  prev_buf    = nil,  -- buffer to restore on close
  breadcrumbs = {},   -- stack of agent objects
  focus       = nil,  -- current focused agent
  line_agents = {},   -- line → child agent
}

-- ── Stats for a subtree ───────────────────────────────────────────────────────

local function subtree_stats(agent)
  local counts = { idle = 0, assigned = 0, running = 0, completed = 0, failed = 0 }
  local total  = 1
  counts[agent.state or "idle"] = 1

  local function walk(a)
    for _, child in ipairs(a.children or {}) do
      total = total + 1
      counts[child.state or "idle"] = (counts[child.state or "idle"] or 0) + 1
      walk(child)
    end
  end
  walk(agent)
  return counts, total
end

local function progress_bar(agent, width)
  local counts, total = subtree_stats(agent)
  local done          = (counts.completed or 0)
  local pct        = total > 0 and math.floor(done / total * width) or 0
  return string.rep("█", pct) .. string.rep("░", width - pct)
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

local function render()
  if not (_state.buf and vim.api.nvim_buf_is_valid(_state.buf)) then return end

  local agent = _state.focus
  if not agent then return end

  local lines = {}
  local hls   = {}
  _state.line_agents = {}

  local function add(line, hl, cs, ce)
    table.insert(lines, line)
    if hl then table.insert(hls, { #lines - 1, cs or 0, ce or -1, hl }) end
  end

  -- Breadcrumb bar
  local crumb_parts = {}
  for _, a in ipairs(_state.breadcrumbs) do
    table.insert(crumb_parts, a.name)
  end
  table.insert(crumb_parts, agent.name)
  local crumb_line = " " .. table.concat(crumb_parts, " › ")
  add(crumb_line, "AgentFlowDashCrumb")
  add(string.rep("─", 60), "AgentFlowDashSep")
  add("")

  -- Stat cards
  local counts, total = subtree_stats(agent)
  local stat_line = string.format(
    "  Total: %d  │  ▶ %d  ⏳ %d  ✓ %d  ✗ %d",
    total,
    counts.running   or 0,
    counts.assigned  or 0,
    counts.completed or 0,
    counts.failed    or 0
  )
  add(stat_line, "AgentFlowDashStatNum")
  add("")

  -- Focused agent card
  add("  ┌─ Focused agent " .. string.rep("─", 40), "AgentFlowDashSep")
  add("  │  Name:    " .. agent.name,   "AgentFlowDashAgent")
  add("  │  State:   " .. (agent.state or "?"),
    STATE_HL[agent.state or "idle"])
  add("  │  Model:   " .. (agent.config and agent.config.model or "?"), "AgentFlowDashDim")
  add("  │  Backend: " .. (agent.config and agent.config.backend or "?"), "AgentFlowDashDim")
  add("  │  Depth:   " .. tostring(agent.depth or 0), "AgentFlowDashDim")

  if agent.metrics then
    add(string.format(
      "  │  Tokens:  %d in / %d out  (%dms)",
      agent.metrics.tokens_in or 0,
      agent.metrics.tokens_out or 0,
      agent.metrics.duration_ms or 0
    ), "AgentFlowDashDim")
  end

  if agent.current_task then
    local desc = (agent.current_task.description or ""):sub(1, 50)
    add("  │  Task:    " .. desc, "AgentFlowDashDim")
  end

  -- Progress bar
  local bar = progress_bar(agent, 40)
  add("  │  Progress: " .. bar, "AgentFlowDashStatNum")
  add("  └" .. string.rep("─", 56), "AgentFlowDashSep")
  add("")

  -- Children list
  local children = agent.children or {}
  if #children > 0 then
    add("  Children  (<CR> drill in):", "AgentFlowDashHeader")
    add("")
    for i, child in ipairs(children) do
      local dot   = STATE_DOT[child.state or "idle"] or "?"
      local dot_hl = STATE_HL[child.state or "idle"] or "AgentFlowDashDim"
      local sub   = #(child.children or {})
      local badge = sub > 0 and (" [" .. sub .. "]") or ""
      local model = (child.config and child.config.model or ""):match("([^%-/]+)$") or ""
      local line  = string.format("  %s %s%s  %s", dot, child.name, badge, model)
      local line_idx = #lines
      table.insert(lines, line)
      _state.line_agents[line_idx + 1] = child
      table.insert(hls, { line_idx, 2, 2 + #dot, dot_hl })
      _ = i
    end
  else
    add("  (no children)", "AgentFlowDashDim")
  end

  add("")
  add(string.rep("─", 60), "AgentFlowDashSep")
  add("  <CR> drill in  <BS> up  f filter  <Tab> hub  q close", "AgentFlowDashDim")

  vim.api.nvim_set_option_value("modifiable", true, { buf = _state.buf })
  vim.api.nvim_buf_set_lines(_state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(_state.buf, -1, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(_state.buf, -1, h[4], h[1], h[2], h[3])
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })
end

-- ── Keymaps ───────────────────────────────────────────────────────────────────

local function child_at_cursor()
  if not _state.win or not vim.api.nvim_win_is_valid(_state.win) then return nil end
  local row = vim.api.nvim_win_get_cursor(_state.win)[1]
  return _state.line_agents[row]
end

local function set_keymaps()
  local buf = _state.buf
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true })
  end

  -- Drill into child
  map("<CR>", function()
    local child = child_at_cursor()
    if child then
      table.insert(_state.breadcrumbs, _state.focus)
      _state.focus = child
      render()
    end
  end)

  -- Go up one level
  map("<BS>", function()
    if #_state.breadcrumbs > 0 then
      _state.focus = table.remove(_state.breadcrumbs)
      render()
    end
  end)

  -- Filter children
  map("f", function()
    vim.notify("AgentFlow: status filter (Phase 5.11 picker)", vim.log.levels.INFO)
  end)

  map("q",     M.close)
  map("<Esc>", M.close)
  map("<Tab>", function() M.close(); require("agentflow.ui.hub").open() end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Open the dashboard focused on a specific agent.
--- @param opts table|nil { focus? agent }
function M.open(opts)
  opts  = opts or {}
  setup_highlights()

  local focus = opts.focus
  if not focus then
    -- Default: show orchestrator root or first registered agent
    local ok, init = pcall(require, "agentflow")
    local orc = ok and init._orchestrator
    focus = (orc and orc._root_agent)
    if not focus then
      local registry = require("agentflow.agents")
      local list     = registry.list()
      if #list > 0 then
        focus = { name = list[1].name, state = "idle", children = {},
                  config = list[1], depth = 0, metrics = {},
                  get_subtree = function() return {} end }
      end
    end
  end

  if not focus then
    vim.notify("AgentFlow: no agent to display", vim.log.levels.WARN)
    return
  end

  _state.focus       = focus
  _state.breadcrumbs = {}

  -- If already open in a window, re-render in place
  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    vim.api.nvim_set_current_win(_state.win)
    render()
    return
  end

  -- Save current buffer so we can restore it on close
  _state.prev_buf = vim.api.nvim_get_current_buf()
  _state.win      = vim.api.nvim_get_current_win()

  _state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype",   "agentflow-dash", { buf = _state.buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })
  vim.api.nvim_set_option_value("bufhidden",  "wipe", { buf = _state.buf })

  -- Replace current window's buffer
  vim.api.nvim_win_set_buf(_state.win, _state.buf)
  vim.api.nvim_set_option_value("cursorline", true,  { win = _state.win })
  vim.api.nvim_set_option_value("number",     false, { win = _state.win })

  set_keymaps()
  render()

  events.on("agent:state_changed", function(_) vim.schedule(render) end)
  log.debug("Dashboard opened", { focus = focus.name })
end

function M.close()
  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    -- Restore the previous buffer rather than closing the window
    if _state.prev_buf and vim.api.nvim_buf_is_valid(_state.prev_buf) then
      vim.api.nvim_win_set_buf(_state.win, _state.prev_buf)
    end
  end
  _state.win      = nil
  _state.buf      = nil
  _state.prev_buf = nil
end

function M.refresh() render() end

return M
