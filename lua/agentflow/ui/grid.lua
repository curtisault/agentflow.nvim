-- ui/grid.lua — High-density heat-map of the entire agent tree.
--
-- Left pane:  every agent as a single coloured character cell, grouped by parent.
-- Right pane: detail sidebar for the selected cell.
-- Scales to 200+ agents. Arrow keys navigate, <CR> opens in dashboard.

local M = {}

local log    = require("agentflow.util.log")
local events = require("agentflow.util.events")

-- ── Highlights ────────────────────────────────────────────────────────────────

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AgentFlowGridIdle",      { fg = "#45475a" })
  vim.api.nvim_set_hl(0, "AgentFlowGridAssigned",  { fg = "#fab387" })
  vim.api.nvim_set_hl(0, "AgentFlowGridRunning",   { fg = "#a6e3a1", bold = true })
  vim.api.nvim_set_hl(0, "AgentFlowGridCompleted", { fg = "#89b4fa" })
  vim.api.nvim_set_hl(0, "AgentFlowGridFailed",    { fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "AgentFlowGridSelected",  { fg = "#cba6f7", bold = true, reverse = true })
  vim.api.nvim_set_hl(0, "AgentFlowGridHeader",    { fg = "#6c7086", italic = true })
  vim.api.nvim_set_hl(0, "AgentFlowGridDetail",    { fg = "#cdd6f4" })
  vim.api.nvim_set_hl(0, "AgentFlowGridDim",       { fg = "#313244" })
end

local STATE_CHAR = {
  idle = "·", assigned = "◐", running = "█", completed = "✓", failed = "✗",
}
local STATE_HL = {
  idle = "AgentFlowGridIdle", assigned = "AgentFlowGridAssigned",
  running = "AgentFlowGridRunning", completed = "AgentFlowGridCompleted",
  failed = "AgentFlowGridFailed",
}

-- ── State ─────────────────────────────────────────────────────────────────────

local _state = {
  buf        = nil,
  win        = nil,
  prev_buf   = nil,  -- buffer to restore on close
  all_agents = {},   -- flat list of all agents in tree order
  selected   = 1,    -- index into all_agents
  search     = nil,  -- search string for /
}

-- ── Flatten tree ──────────────────────────────────────────────────────────────

local function flatten_all(agents, out)
  out = out or {}
  for _, a in ipairs(agents or {}) do
    table.insert(out, a)
    flatten_all(a.children, out)
  end
  return out
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

local GRID_COLS  = 20   -- cells per row in the left pane
local PANE_SPLIT = 24   -- column where the detail pane starts

local function render()
  if not (_state.buf and vim.api.nvim_buf_is_valid(_state.buf)) then return end

  local agents   = _state.all_agents
  local selected = _state.selected
  local sel_agent = agents[selected]

  -- Build the grid cells
  local cell_lines = {}  -- string rows for the left pane
  local cell_hls   = {}  -- { row, col, hl }

  local row_chars = {}
  local row_hls_per = {}
  local row_idx = 0

  for i, agent in ipairs(agents) do
    local state = agent.state or "idle"
    local ch    = (i == selected) and "@" or (STATE_CHAR[state] or "?")
    local hl    = (i == selected) and "AgentFlowGridSelected" or (STATE_HL[state] or "AgentFlowGridDim")

    local col_in_row = ((i - 1) % GRID_COLS)
    if col_in_row == 0 then
      row_idx = row_idx + 1
      row_chars[row_idx]    = {}
      row_hls_per[row_idx]  = {}
    end
    table.insert(row_chars[row_idx], ch)
    table.insert(row_hls_per[row_idx], hl)
  end

  for r = 1, row_idx do
    table.insert(cell_lines, table.concat(row_chars[r], " "))
    table.insert(cell_hls, row_hls_per[r])
  end

  -- Build the detail pane lines
  local detail = {}
  if sel_agent then
    local function da(line) table.insert(detail, line) end
    da("Agent: " .. sel_agent.name)
    da("State: " .. (sel_agent.state or "?"))
    da("Model: " .. (sel_agent.config and sel_agent.config.model or "?"))
    da("Depth: " .. tostring(sel_agent.depth or 0))
    da("Children: " .. #(sel_agent.children or {}))
    if sel_agent.metrics then
      da(string.format("Tok in:  %d", sel_agent.metrics.tokens_in or 0))
      da(string.format("Tok out: %d", sel_agent.metrics.tokens_out or 0))
      da(string.format("Time:    %dms", sel_agent.metrics.duration_ms or 0))
    end
    if sel_agent.current_task then
      da("")
      da("Task:")
      local desc = sel_agent.current_task.description or ""
      for _, chunk in ipairs(vim.split(desc:sub(1, 120), "\n")) do
        da("  " .. chunk)
      end
    end
  else
    table.insert(detail, "(no agent selected)")
  end

  -- Combine left + right panes side by side
  local lines = {}
  local hls   = {}

  -- Header
  table.insert(lines, string.format(" Grid (%d agents)%s Detail",
    #agents, string.rep(" ", PANE_SPLIT - #tostring(#agents) - 10)))
  table.insert(hls, { 0, 0, -1, "AgentFlowGridHeader" })
  table.insert(lines, string.rep("─", PANE_SPLIT) .. "│" .. string.rep("─", 30))
  table.insert(hls, { 1, 0, -1, "AgentFlowGridDim" })

  local max_rows = math.max(#cell_lines, #detail)
  for r = 1, max_rows do
    local left  = cell_lines[r] or ""
    local right = detail[r]     or ""
    -- Pad left to PANE_SPLIT
    local padded = left .. string.rep(" ", math.max(0, PANE_SPLIT - #left))
    local full   = padded .. "│ " .. right
    local line_idx = #lines
    table.insert(lines, full)

    -- Apply per-cell highlights on the left side
    if cell_hls[r] then
      for ci, hl in ipairs(cell_hls[r]) do
        local col = (ci - 1) * 2  -- each cell is "X " (2 chars)
        table.insert(hls, { line_idx, col, col + 1, hl })
      end
    end
    -- Right pane dim
    table.insert(hls, { line_idx, PANE_SPLIT + 2, -1, "AgentFlowGridDetail" })
  end

  table.insert(lines, string.rep("─", PANE_SPLIT) .. "┴" .. string.rep("─", 30))
  table.insert(hls, { #lines - 1, 0, -1, "AgentFlowGridDim" })
  table.insert(lines, " ← → ↑ ↓ navigate  <CR> dashboard  / search  q close  <Tab> hub")
  table.insert(hls, { #lines - 1, 0, -1, "AgentFlowGridDim" })

  vim.api.nvim_set_option_value("modifiable", true, { buf = _state.buf })
  vim.api.nvim_buf_set_lines(_state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(_state.buf, -1, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(_state.buf, -1, h[4], h[1], h[2], h[3])
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })
end

-- ── Keymaps ───────────────────────────────────────────────────────────────────

local function move(delta)
  local n = #_state.all_agents
  if n == 0 then return end
  _state.selected = math.max(1, math.min(n, _state.selected + delta))
  render()
end

local function set_keymaps()
  local buf = _state.buf
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true })
  end

  map("l",      function() move(1) end)
  map("h",      function() move(-1) end)
  map("j",      function() move(GRID_COLS) end)
  map("k",      function() move(-GRID_COLS) end)
  map("<Right>",function() move(1) end)
  map("<Left>", function() move(-1) end)
  map("<Down>", function() move(GRID_COLS) end)
  map("<Up>",   function() move(-GRID_COLS) end)

  map("<CR>", function()
    local agent = _state.all_agents[_state.selected]
    if agent then
      M.close()
      require("agentflow.ui.dashboard").open({ focus = agent })
    end
  end)

  map("/", function()
    vim.ui.input({ prompt = "Search agent name: " }, function(input)
      if not input or input == "" then return end
      for i, a in ipairs(_state.all_agents) do
        if a.name:lower():find(input:lower(), 1, true) then
          _state.selected = i
          break
        end
      end
      render()
    end)
  end)

  map("q",     M.close)
  map("<Esc>", M.close)
  map("<Tab>", function() M.close(); require("agentflow.ui.hub").open() end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.open(opts)
  opts = opts or {}
  setup_highlights()

  -- Collect all agents
  local roots = opts.agents or {}
  if #roots == 0 then
    local ok, init = pcall(require, "agentflow")
    local orc = ok and init._orchestrator
    if orc and orc._root_agent then
      roots = { orc._root_agent }
    else
      local registry = require("agentflow.agents")
      roots = vim.tbl_map(function(ac)
        return { name = ac.name, state = "idle", children = {}, config = ac,
                 depth = 0, metrics = {}, get_subtree = function() return {} end }
      end, registry.list())
    end
  end

  _state.all_agents = flatten_all(roots)
  _state.selected   = 1

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
  vim.api.nvim_set_option_value("filetype",   "agentflow-grid", { buf = _state.buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })
  vim.api.nvim_set_option_value("bufhidden",  "wipe", { buf = _state.buf })

  -- Replace current window's buffer
  vim.api.nvim_win_set_buf(_state.win, _state.buf)
  vim.api.nvim_set_option_value("number",     false, { win = _state.win })
  vim.api.nvim_set_option_value("cursorline", false, { win = _state.win })

  set_keymaps()
  render()

  events.on("agent:state_changed", function(_) vim.schedule(render) end)
  log.debug("Grid opened", { agents = #_state.all_agents })
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
