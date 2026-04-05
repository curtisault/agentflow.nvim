-- ui/tree.lua — Indented agent tree view with fold mechanics.
--
-- One line per agent:  [fold] [dot] name  task (truncated)  [N children]  model
-- Scales to hundreds of agents — collapsed branches are a single line.

local M = {}

local log    = require("agentflow.util.log")
local events = require("agentflow.util.events")

-- ── Highlights ────────────────────────────────────────────────────────────────

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AgentFlowTreeIdle",      { fg = "#6c7086" })
  vim.api.nvim_set_hl(0, "AgentFlowTreeRunning",   { fg = "#a6e3a1", bold = true })
  vim.api.nvim_set_hl(0, "AgentFlowTreeCompleted", { fg = "#89b4fa" })
  vim.api.nvim_set_hl(0, "AgentFlowTreeFailed",    { fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "AgentFlowTreeAssigned",  { fg = "#fab387" })
  vim.api.nvim_set_hl(0, "AgentFlowTreeDim",       { fg = "#45475a" })
  vim.api.nvim_set_hl(0, "AgentFlowTreeHeader",    { fg = "#cdd6f4", bold = true })
  vim.api.nvim_set_hl(0, "AgentFlowTreeModel",     { fg = "#6c7086", italic = true })
end

local STATE_HL = {
  idle      = "AgentFlowTreeIdle",
  assigned  = "AgentFlowTreeAssigned",
  running   = "AgentFlowTreeRunning",
  completed = "AgentFlowTreeCompleted",
  failed    = "AgentFlowTreeFailed",
}
local STATE_DOT = {
  idle = "○", assigned = "◐", running = "●", completed = "✓", failed = "✗",
}

-- ── State ─────────────────────────────────────────────────────────────────────

local _state = {
  buf          = nil,
  win          = nil,
  root_agents  = {},   -- top-level agent objects
  collapsed    = {},   -- agent.name → true if folded
  status_filter = nil, -- nil = show all; table of allowed states
  depth_limit  = nil,  -- nil = unlimited
  -- Map from buffer line (1-indexed) → agent object
  line_agents  = {},
}

-- ── Tree flattening ───────────────────────────────────────────────────────────

--- Recursively flatten the agent tree into a list of display rows.
--- @param agents table[]  Top-level agents
--- @param depth number
--- @param filter table|nil  set of allowed states
--- @param depth_limit number|nil
--- @return table[]  { agent, depth, is_last, has_children, collapsed, subtree_count }
local function flatten(agents, depth, filter, depth_limit)
  depth       = depth       or 0
  depth_limit = depth_limit or math.huge

  local rows = {}
  for i, agent in ipairs(agents) do
    -- Status filter
    if filter and not filter[agent.state or "idle"] then
      goto continue
    end

    local children       = agent.children or {}
    local has_children   = #children > 0
    local is_collapsed   = _state.collapsed[agent.name]
    local subtree_count  = #(agent.get_subtree and agent:get_subtree() or {})

    table.insert(rows, {
      agent         = agent,
      depth         = depth,
      is_last       = i == #agents,
      has_children  = has_children,
      collapsed     = is_collapsed,
      subtree_count = subtree_count,
    })

    if has_children and not is_collapsed and depth < depth_limit then
      local sub = flatten(children, depth + 1, filter, depth_limit)
      for _, r in ipairs(sub) do
        table.insert(rows, r)
      end
    end

    ::continue::
  end
  return rows
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

local function render()
  if not (_state.buf and vim.api.nvim_buf_is_valid(_state.buf)) then return end

  local rows = flatten(
    _state.root_agents,
    0,
    _state.status_filter,
    _state.depth_limit
  )

  local lines      = {}
  local hls        = {}
  _state.line_agents = {}

  -- Header
  table.insert(lines, " AgentFlow — Agent Tree")
  table.insert(hls, { 0, 1, -1, "AgentFlowTreeHeader" })
  table.insert(lines, string.rep("─", 60))
  table.insert(hls, { 1, 0, -1, "AgentFlowTreeDim" })

  for _, row in ipairs(rows) do
    local agent   = row.agent
    local state   = agent.state or "idle"
    local dot     = STATE_DOT[state]  or "?"
    local dot_hl  = STATE_HL[state]   or "AgentFlowTreeDim"

    -- Indentation guides
    local indent  = string.rep("│   ", row.depth)
    local connector = row.is_last and "└── " or "├── "

    -- Fold arrow
    local fold_arrow = ""
    if row.has_children then
      fold_arrow = row.collapsed and "▶ " or "▼ "
    else
      fold_arrow = "  "
    end

    -- Task description (truncated)
    local task_desc = ""
    if agent.current_task then
      task_desc = " " .. (agent.current_task.description or ""):sub(1, 40)
      if #(agent.current_task.description or "") > 40 then task_desc = task_desc .. "…" end
    end

    -- Child count badge
    local badge = row.has_children
      and (" [" .. (row.collapsed and row.subtree_count or #(agent.children or {})) .. "]")
      or  ""

    -- Model tag
    local model = (agent.config and agent.config.model) or ""
    model = model:match("([^%-/]+)$") or model  -- last segment
    if #model > 12 then model = model:sub(1, 11) .. "…" end
    model = model ~= "" and ("  " .. model) or ""

    local line = indent .. connector .. fold_arrow .. dot .. " " ..
                 agent.name .. task_desc .. badge .. model

    local line_idx = #lines
    table.insert(lines, line)
    _state.line_agents[line_idx + 1] = agent  -- 1-indexed

    -- Apply dot highlight
    local dot_col = #indent + #connector + #fold_arrow
    table.insert(hls, { line_idx, dot_col, dot_col + #dot, dot_hl })
    -- Dim the model tag
    if model ~= "" then
      local model_col = #line - #model
      table.insert(hls, { line_idx, model_col, -1, "AgentFlowTreeModel" })
    end
  end

  if #rows == 0 then
    table.insert(lines, "  (no agents)")
    table.insert(hls, { #lines - 1, 0, -1, "AgentFlowTreeDim" })
  end

  table.insert(lines, "")
  table.insert(lines, string.rep("─", 60))
  table.insert(hls, { #lines - 1, 0, -1, "AgentFlowTreeDim" })
  table.insert(lines, " zo/zc fold  <CR> dash  f filter  d depth  <C-k> kill  q close")
  table.insert(hls, { #lines - 1, 0, -1, "AgentFlowTreeDim" })

  vim.api.nvim_set_option_value("modifiable", true, { buf = _state.buf })
  vim.api.nvim_buf_set_lines(_state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(_state.buf, -1, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(_state.buf, -1, h[4], h[1], h[2], h[3])
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })
end

-- ── Agent at cursor ───────────────────────────────────────────────────────────

local function agent_at_cursor()
  if not (_state.win and vim.api.nvim_win_is_valid(_state.win)) then return nil end
  local row = vim.api.nvim_win_get_cursor(_state.win)[1]
  return _state.line_agents[row]
end

-- ── Keymaps ───────────────────────────────────────────────────────────────────

local function set_keymaps()
  local buf = _state.buf
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true })
  end

  -- Fold toggle
  map("zo", function()
    local a = agent_at_cursor()
    if a then _state.collapsed[a.name] = false; render() end
  end)
  map("zc", function()
    local a = agent_at_cursor()
    if a then _state.collapsed[a.name] = true; render() end
  end)
  map("zR", function()
    _state.collapsed = {}; render()
  end)
  map("zM", function()
    for _, a in ipairs(_state.root_agents) do
      for _, d in ipairs(a.get_subtree and a:get_subtree() or {}) do
        _state.collapsed[d.name] = true
      end
      _state.collapsed[a.name] = true
    end
    render()
  end)

  -- Open in dashboard
  map("<CR>", function()
    local a = agent_at_cursor()
    if a then
      M.close()
      require("agentflow.ui.dashboard").open({ focus = a })
    end
  end)

  -- Filter by status
  map("f", function()
    local picker = require("agentflow.ui.picker")
    local status_opts = {
      { text = "All",       value = nil },
      { text = "Running",   value = { running = true } },
      { text = "Pending",   value = { pending = true, assigned = true } },
      { text = "Completed", value = { completed = true } },
      { text = "Failed",    value = { failed = true } },
    }
    picker.pick(status_opts, { prompt = "Filter by status" }, function(item)
      _state.status_filter = item.value
      render()
    end)
  end)

  -- Depth limit
  map("d", function()
    vim.ui.input({ prompt = "Max depth (empty = unlimited): " }, function(input)
      if input == "" or input == nil then
        _state.depth_limit = nil
      else
        _state.depth_limit = tonumber(input)
      end
      render()
    end)
  end)

  -- Kill subtree
  map("<C-k>", function()
    local a = agent_at_cursor()
    if a then
      a:cancel_subtree()
      render()
      vim.notify("AgentFlow: killed " .. a.name .. " and subtree", vim.log.levels.WARN)
    end
  end)

  -- Close / return to hub
  map("q",     M.close)
  map("<Esc>", M.close)
  map("<Tab>", function()
    M.close()
    require("agentflow.ui.hub").open()
  end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Open the tree view.
--- @param opts table|nil { agents? table[]  root agent list }
function M.open(opts)
  opts = opts or {}
  setup_highlights()

  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    vim.api.nvim_set_current_win(_state.win)
    return
  end

  -- Source agents from orchestrator if not provided
  if opts.agents then
    _state.root_agents = opts.agents
  else
    local ok, init = pcall(require, "agentflow")
    local orc = ok and init._orchestrator
    _state.root_agents = (orc and orc._root_agent) and { orc._root_agent } or {}
    -- Fallback: show registered agent configs as stubs
    if #_state.root_agents == 0 then
      local registry = require("agentflow.agents")
      _state.root_agents = vim.tbl_map(function(ac)
        return { name = ac.name, state = "idle", children = {}, config = ac,
                 get_subtree = function() return {} end }
      end, registry.list())
    end
  end

  _state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype",   "agentflow-tree", { buf = _state.buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })
  vim.api.nvim_set_option_value("bufhidden",  "wipe",  { buf = _state.buf })

  local width  = math.floor(vim.o.columns * 0.5)
  local height = math.floor(vim.o.lines   * 0.75)
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width)  / 2)

  _state.win = vim.api.nvim_open_win(_state.buf, true, {
    relative  = "editor",
    row = row, col = col, width = width, height = height,
    style     = "minimal",
    border    = "rounded",
    title     = " Agent Tree ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("cursorline", true,  { win = _state.win })
  vim.api.nvim_set_option_value("number",     false, { win = _state.win })
  vim.api.nvim_set_option_value("wrap",       false, { win = _state.win })

  set_keymaps()
  render()

  -- Reactive updates
  events.on("agent:state_changed", function(_) vim.schedule(render) end)

  log.debug("Tree view opened")
end

function M.close()
  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    vim.api.nvim_win_close(_state.win, true)
  end
  _state.win = nil
  _state.buf = nil
end

function M.refresh() render() end

return M
