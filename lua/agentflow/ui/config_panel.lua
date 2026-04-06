-- ui/config_panel.lua — Read-only config inspector.
--
-- Opens a floating window showing the active AgentFlow configuration and all
-- registered agents.  Sections can be navigated with j/k; q/<Esc> closes.

local M = {}

local log = require("agentflow.util.log")

-- ── Highlights ────────────────────────────────────────────────────────────────

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AgentFlowCfgHeader",  { fg = "#cba6f7", bold = true })
  vim.api.nvim_set_hl(0, "AgentFlowCfgSection", { fg = "#89b4fa", bold = true })
  vim.api.nvim_set_hl(0, "AgentFlowCfgKey",     { fg = "#cdd6f4" })
  vim.api.nvim_set_hl(0, "AgentFlowCfgValue",   { fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "AgentFlowCfgDim",     { fg = "#45475a" })
  vim.api.nvim_set_hl(0, "AgentFlowCfgAgent",   { fg = "#fab387" })
end

-- ── State ─────────────────────────────────────────────────────────────────────

local _state = { buf = nil, win = nil }

-- ── Layout ────────────────────────────────────────────────────────────────────

local function win_size()
  local w = math.min(math.floor(vim.o.columns * 0.7), 100)
  local h = math.floor(vim.o.lines * 0.75)
  local r = math.floor((vim.o.lines   - h) / 2)
  local c = math.floor((vim.o.columns - w) / 2)
  return { width = w, height = h, row = r, col = c }
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

local function add(lines, hls, text, hl)
  table.insert(lines, text)
  if hl then
    table.insert(hls, { #lines - 1, 0, -1, hl })
  end
end

local function render_value(v)
  local t = type(v)
  if t == "boolean" then return tostring(v)
  elseif t == "number" then return tostring(v)
  elseif t == "string" then return v == "" and '""' or v
  elseif v == nil then return "(nil)"
  else return tostring(v)
  end
end

local function render_section(lines, hls, title, kvs)
  add(lines, hls, "", nil)
  add(lines, hls, "  " .. title, "AgentFlowCfgSection")
  add(lines, hls, "  " .. string.rep("─", #title + 2), "AgentFlowCfgDim")
  for _, pair in ipairs(kvs) do
    local key, val = pair[1], pair[2]
    local line = string.format("  %-30s %s", key, render_value(val))
    table.insert(lines, line)
    -- Colour the value portion
    local val_col = 2 + 30 + 1
    table.insert(hls, { #lines - 1, 0, val_col, "AgentFlowCfgKey" })
    table.insert(hls, { #lines - 1, val_col, -1, "AgentFlowCfgValue" })
  end
end

local function build_lines()
  local lines = {}
  local hls   = {}

  add(lines, hls, "  AgentFlow — Active Configuration", "AgentFlowCfgHeader")
  add(lines, hls, "  " .. string.rep("═", 40), "AgentFlowCfgDim")

  local ok_cfg, cfg = pcall(require("agentflow.config").get)
  if not ok_cfg then
    add(lines, hls, "", nil)
    add(lines, hls, "  (config not yet initialised)", "AgentFlowCfgDim")
    return lines, hls
  end

  -- Backend
  render_section(lines, hls, "Backend", {
    { "primary",      cfg.backend.primary },
    { "cli_path",     cfg.backend.cli_path },
    { "cli_flags",    table.concat(cfg.backend.cli_flags or {}, " ") },
    { "api_key_env",  cfg.backend.api_key_env },
  })

  -- Orchestrator
  render_section(lines, hls, "Orchestrator", {
    { "model",        cfg.orchestrator.model },
    { "max_turns",    cfg.orchestrator.max_turns },
    { "system_prompt", cfg.orchestrator.system_prompt and "(loaded)" or "(none)" },
  })

  -- Agents from registry
  add(lines, hls, "", nil)
  add(lines, hls, "  Agents (registry)", "AgentFlowCfgSection")
  add(lines, hls, "  " .. string.rep("─", 20), "AgentFlowCfgDim")

  local ok_reg, registry = pcall(require, "agentflow.agents")
  local agent_list = (ok_reg and registry.list()) or {}

  if #agent_list == 0 then
    add(lines, hls, "  (none registered)", "AgentFlowCfgDim")
  else
    for _, a in ipairs(agent_list) do
      local has_prompt = a.system_prompt and " [prompt]" or ""
      local line = string.format("  %-18s %-14s %s%s",
        a.name,
        (a.backend or "cli"),
        a.model or "?",
        has_prompt)
      table.insert(lines, line)
      table.insert(hls, { #lines - 1, 0, 20, "AgentFlowCfgAgent" })
      table.insert(hls, { #lines - 1, 20, -1, "AgentFlowCfgValue" })
    end
  end

  -- Context
  render_section(lines, hls, "Context", {
    { "max_tokens_per_agent",  cfg.context.max_tokens_per_agent },
    { "include_buffers",       cfg.context.include_buffers },
    { "include_treesitter",    cfg.context.include_treesitter },
    { "include_git_diff",      cfg.context.include_git_diff },
    { "include_lsp_symbols",   cfg.context.include_lsp_symbols },
    { "include_file_tree",     cfg.context.include_file_tree },
  })

  -- UI
  render_section(lines, hls, "UI", {
    { "chat_width",    cfg.ui.chat_width },
    { "roster_width",  cfg.ui.roster_width },
    { "review_style",  cfg.ui.review_style },
    { "approve_mode",  cfg.ui.approve_mode },
    { "picker",        cfg.ui.picker },
  })

  -- Concurrency
  render_section(lines, hls, "Concurrency", {
    { "max_parallel_agents",    cfg.concurrency.max_parallel_agents },
    { "max_depth",              cfg.concurrency.max_depth },
    { "max_total_agents",       cfg.concurrency.max_total_agents },
    { "max_children_per_agent", cfg.concurrency.max_children_per_agent },
    { "timeout_ms",             cfg.concurrency.timeout_ms },
  })

  -- Routing rules
  add(lines, hls, "", nil)
  add(lines, hls, "  Routing rules", "AgentFlowCfgSection")
  add(lines, hls, "  " .. string.rep("─", 16), "AgentFlowCfgDim")
  local rules = (cfg.routing and cfg.routing.rules) or {}
  if #rules == 0 then
    add(lines, hls, "  (none)", "AgentFlowCfgDim")
  else
    for _, rule in ipairs(rules) do
      local match_parts = {}
      if rule.match then
        for k, v in pairs(rule.match) do
          table.insert(match_parts, k .. "=" .. tostring(v))
        end
      end
      local match_str = #match_parts > 0 and table.concat(match_parts, ", ") or "(always)"
      local line = string.format("  p%-3s %-20s → %s",
        tostring(rule.priority or "?"), match_str, rule.agent or "?")
      table.insert(lines, line)
      table.insert(hls, { #lines - 1, 0, -1, "AgentFlowCfgKey" })
    end
  end

  -- Log
  render_section(lines, hls, "Logging", {
    { "level", cfg.log.level },
    { "file",  cfg.log.file },
  })

  add(lines, hls, "", nil)
  add(lines, hls, "  " .. string.rep("─", 40), "AgentFlowCfgDim")
  add(lines, hls, "  q / <Esc>  close    <Tab>  back to hub", "AgentFlowCfgDim")

  return lines, hls
end

local function render()
  if not (_state.buf and vim.api.nvim_buf_is_valid(_state.buf)) then return end

  local lines, hls = build_lines()

  vim.api.nvim_set_option_value("modifiable", true, { buf = _state.buf })
  vim.api.nvim_buf_set_lines(_state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(_state.buf, -1, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(_state.buf, -1, h[4], h[1], h[2], h[3])
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })

  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    vim.api.nvim_win_set_cursor(_state.win, { 1, 0 })
  end
end

-- ── Keymaps ───────────────────────────────────────────────────────────────────

local function set_keymaps()
  local buf = _state.buf
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true })
  end

  map("q",     M.close)
  map("<Esc>", M.close)
  map("<Tab>", function()
    local ok, hub = pcall(require, "agentflow.ui.hub")
    if ok then M.close(); hub.open() end
  end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.open()
  setup_highlights()

  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    vim.api.nvim_set_current_win(_state.win)
    return
  end

  local sz = win_size()

  _state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype",   "agentflow-config", { buf = _state.buf })
  vim.api.nvim_set_option_value("modifiable", false,              { buf = _state.buf })
  vim.api.nvim_set_option_value("bufhidden",  "wipe",             { buf = _state.buf })

  _state.win = vim.api.nvim_open_win(_state.buf, true, {
    relative  = "editor",
    row       = sz.row,
    col       = sz.col,
    width     = sz.width,
    height    = sz.height,
    style     = "minimal",
    border    = "rounded",
    title     = " AgentFlow Config ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("wrap",        false, { win = _state.win })
  vim.api.nvim_set_option_value("cursorline",  true,  { win = _state.win })
  vim.api.nvim_set_option_value("number",      false, { win = _state.win })
  vim.api.nvim_set_option_value("signcolumn",  "no",  { win = _state.win })

  set_keymaps()
  render()
  log.debug("Config panel opened")
end

function M.close()
  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    vim.api.nvim_win_close(_state.win, true)
  end
  _state.win = nil
  _state.buf = nil
end

return M
