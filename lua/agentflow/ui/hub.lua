-- ui/hub.lua — Centered floating launcher window.
--
-- Opened by :AgentFlow (no args) or <leader>af.
-- Shows workflow summary and single-key navigation to all views.
-- <Tab> from any view returns here.

local M = {}

local log    = require("agentflow.util.log")
local events = require("agentflow.util.events")

-- ── Highlights ────────────────────────────────────────────────────────────────

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AgentFlowHubTitle",  { fg = "#cba6f7", bold = true })
  vim.api.nvim_set_hl(0, "AgentFlowHubKey",    { fg = "#89b4fa", bold = true })
  vim.api.nvim_set_hl(0, "AgentFlowHubLabel",  { fg = "#cdd6f4" })
  vim.api.nvim_set_hl(0, "AgentFlowHubDim",    { fg = "#45475a" })
  vim.api.nvim_set_hl(0, "AgentFlowHubStat",   { fg = "#a6e3a1", bold = true })
  vim.api.nvim_set_hl(0, "AgentFlowHubStatLb", { fg = "#6c7086" })
  vim.api.nvim_set_hl(0, "AgentFlowHubWarn",   { fg = "#fab387" })
end

-- ── State ─────────────────────────────────────────────────────────────────────

local _state = { buf = nil, win = nil }

-- ── Nav items ─────────────────────────────────────────────────────────────────

local NAV = {
  { key = "c", label = "Chat",          fn = function() require("agentflow.ui.chat").open() end },
  { key = "t", label = "Tree view",     fn = function() require("agentflow.ui.tree").open() end },
  { key = "d", label = "Dashboard",     fn = function() require("agentflow.ui.dashboard").open() end },
  { key = "g", label = "Grid view",     fn = function() require("agentflow.ui.grid").open() end },
  { key = "r", label = "Review panel",  fn = function() require("agentflow.ui.review").open({}) end },
  { key = "s", label = "Config",        fn = function() require("agentflow.ui.config_panel").open() end },
  { key = "l", label = "Logs",          fn = function() require("agentflow.util.log").open() end },
  { key = "?", label = "Help",          fn = function() M._show_help() end },
}

-- ── Stats from orchestrator ───────────────────────────────────────────────────

local function get_stats()
  local ok, init = pcall(require, "agentflow")
  if not ok then return {} end

  -- Access the orchestrator singleton via init module internals
  -- (orchestrator exposes get_plan / get_cost)
  local orc = init._orchestrator
  if not orc then return {} end

  local cost = orc:get_cost()
  local plan = orc:get_plan()

  local running = 0
  local pending = 0
  local done    = 0
  local failed  = 0

  if plan then
    for _, t in ipairs(plan.tasks) do
      if     t.status == "running" then running = running + 1
      elseif t.status == "pending" then pending = pending + 1
      elseif t.status == "done"    then done    = done    + 1
      elseif t.status == "failed"  then failed  = failed  + 1
      end
    end
  end

  return {
    agents     = cost.agent_count,
    tokens_in  = cost.tokens_in,
    tokens_out = cost.tokens_out,
    running    = running,
    pending    = pending,
    done       = done,
    failed     = failed,
    has_plan   = plan ~= nil,
  }
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

local HUB_WIDTH  = 50
local HUB_HEIGHT = 22

local function center_text(text, width)
  local pad = math.floor((width - #text) / 2)
  return string.rep(" ", math.max(0, pad)) .. text
end

local function render()
  if not (_state.buf and vim.api.nvim_buf_is_valid(_state.buf)) then return end

  local lines = {}
  local hls   = {}
  local function add(line, hl, col_s, col_e)
    table.insert(lines, line)
    if hl then
      table.insert(hls, { #lines - 1, col_s or 0, col_e or -1, hl })
    end
  end

  add("")
  add(center_text("⚡ AgentFlow", HUB_WIDTH), "AgentFlowHubTitle")
  add(center_text("Neovim Agentic Workflow", HUB_WIDTH), "AgentFlowHubDim")
  add("")
  add(string.rep("─", HUB_WIDTH), "AgentFlowHubDim")
  add("")

  -- Stats
  local s = get_stats()
  if s.has_plan then
    local stat_line = string.format(
      "  Agents: %d  │  ▶ %d  ⏳ %d  ✓ %d  ✗ %d",
      s.agents, s.running, s.pending, s.done, s.failed
    )
    add(stat_line, "AgentFlowHubStat")
    local tok_line = string.format(
      "  Tokens: %d in / %d out",
      s.tokens_in, s.tokens_out
    )
    add(tok_line, "AgentFlowHubStatLb")
  else
    add("  No active workflow", "AgentFlowHubDim")
  end

  add("")
  add(string.rep("─", HUB_WIDTH), "AgentFlowHubDim")
  add("")

  -- Navigation
  for _, nav in ipairs(NAV) do
    local line = string.format("   %s  %s", nav.key, nav.label)
    add(line)
    -- Highlight just the key
    table.insert(hls, { #lines - 1, 3, 4, "AgentFlowHubKey" })
    table.insert(hls, { #lines - 1, 6, -1, "AgentFlowHubLabel" })
  end

  add("")
  add(string.rep("─", HUB_WIDTH), "AgentFlowHubDim")
  add("")
  add("   p  New prompt  │  q  Close", "AgentFlowHubDim")

  -- Write
  vim.api.nvim_set_option_value("modifiable", true, { buf = _state.buf })
  vim.api.nvim_buf_set_lines(_state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(_state.buf, -1, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(_state.buf, -1, h[4], h[1], h[2], h[3])
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })
end

-- ── Keymaps ───────────────────────────────────────────────────────────────────

local function set_keymaps()
  local buf = _state.buf
  local function map(key, fn)
    vim.keymap.set("n", key, function()
      M.close()
      fn()
    end, { buffer = buf, silent = true, nowait = true })
  end

  for _, nav in ipairs(NAV) do
    map(nav.key, nav.fn)
  end

  -- New prompt
  map("p", function()
    vim.ui.input({ prompt = "AgentFlow prompt: " }, function(input)
      if input and input ~= "" then
        require("agentflow").start(input)
      end
    end)
  end)

  -- Close
  vim.keymap.set("n", "q",     M.close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", M.close, { buffer = buf, silent = true })
end

-- ── Help overlay ──────────────────────────────────────────────────────────────

function M._show_help()
  local help = {
    "AgentFlow keybindings",
    "",
    "Global:",
    "  <leader>af  Open hub",
    "  <leader>ap  Start workflow with prompt",
    "  <leader>as  Agent tree",
    "  <leader>ac  Config panel",
    "  <leader>ar  Review panel",
    "",
    "Hub:",
    "  c  Chat    t  Tree    d  Dashboard",
    "  g  Grid    r  Review  s  Config",
    "  l  Logs    ?  Help    p  Prompt",
    "",
    "Review:",
    "  <CR> accept   x reject   e edit   r retry",
    "  ]r next  [r prev  1-4 switch tabs",
    "",
    "Tree:",
    "  zo/zc fold   zR/zM all   <CR> dashboard",
    "  f filter   d depth   <C-k> kill",
    "",
    "Any view:  <Tab> → hub    q / <Esc> → close",
  }
  vim.notify(table.concat(help, "\n"), vim.log.levels.INFO)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.open()
  setup_highlights()

  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    vim.api.nvim_set_current_win(_state.win)
    render()
    return
  end

  local row = math.floor((vim.o.lines   - HUB_HEIGHT) / 2)
  local col = math.floor((vim.o.columns - HUB_WIDTH)  / 2)

  _state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })
  vim.api.nvim_set_option_value("bufhidden",  "wipe",  { buf = _state.buf })

  _state.win = vim.api.nvim_open_win(_state.buf, true, {
    relative  = "editor",
    row       = row,
    col       = col,
    width     = HUB_WIDTH,
    height    = HUB_HEIGHT,
    style     = "minimal",
    border    = "rounded",
    title     = " AgentFlow ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("cursorline", false, { win = _state.win })
  vim.api.nvim_set_option_value("number",     false, { win = _state.win })

  set_keymaps()
  render()

  -- Refresh stats when workflow events fire
  events.on("plan:created",            function(_) vim.schedule(render) end)
  events.on("agent:state_changed",     function(_) vim.schedule(render) end)
  events.on("orchestrator:synthesized",function(_) vim.schedule(render) end)

  log.debug("Hub opened")
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
