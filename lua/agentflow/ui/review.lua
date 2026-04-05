-- ui/review.lua — Diff review panel.
--
-- Opens a floating window per agent result showing:
--   Tab 1: Diff      — syntax-highlighted unified diff
--   Tab 2: Raw       — agent's raw response
--   Tab 3: Agent log — conversation history
--   Tab 4: Context   — what context was sent
--
-- Actions: <CR> accept, x reject, e edit, r retry, ]r next, [r prev

local M = {}

local log     = require("agentflow.util.log")
local results = require("agentflow.results")
local diff    = require("agentflow.diff")
local events  = require("agentflow.util.events")

-- ── Highlights ────────────────────────────────────────────────────────────────

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AgentFlowReviewAdd",    { fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "AgentFlowReviewDel",    { fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "AgentFlowReviewHunk",   { fg = "#89dceb", bold = true })
  vim.api.nvim_set_hl(0, "AgentFlowReviewMeta",   { fg = "#6c7086", italic = true })
  vim.api.nvim_set_hl(0, "AgentFlowReviewHeader", { fg = "#cdd6f4", bold = true })
  vim.api.nvim_set_hl(0, "AgentFlowReviewTab",    { fg = "#45475a" })
  vim.api.nvim_set_hl(0, "AgentFlowReviewTabSel", { fg = "#cba6f7", bold = true })
  vim.api.nvim_set_hl(0, "AgentFlowReviewBorder", { fg = "#313244" })
end

-- ── State ─────────────────────────────────────────────────────────────────────

local _state = {
  queue        = {},   -- list of review items { agent, task, result, artifacts }
  current      = 1,   -- index into queue
  win          = nil,
  buf          = nil,
  active_tab   = 1,   -- 1=diff, 2=raw, 3=log, 4=context
  on_complete  = nil, -- called when all items reviewed
}

local TABS = { "Diff", "Raw", "Agent log", "Context" }

-- ── Layout ────────────────────────────────────────────────────────────────────

local function win_size()
  local w = math.floor(vim.o.columns * 0.8)
  local h = math.floor(vim.o.lines   * 0.8)
  local r = math.floor((vim.o.lines   - h) / 2)
  local c = math.floor((vim.o.columns - w) / 2)
  return { width = w, height = h, row = r, col = c }
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

local function render_diff_lines(diff_text)
  local lines = vim.split(diff_text, "\n", { plain = true })
  local hls   = {}
  for i, line in ipairs(lines) do
    local prefix = line:sub(1, 1)
    local hl
    if prefix == "+" then
      hl = "AgentFlowReviewAdd"
    elseif prefix == "-" then
      hl = "AgentFlowReviewDel"
    elseif prefix == "@" then
      hl = "AgentFlowReviewHunk"
    elseif line:match("^%-%-%-") or line:match("^%+%+%+") then
      hl = "AgentFlowReviewMeta"
    end
    if hl then table.insert(hls, { i - 1, 0, -1, hl }) end
  end
  return lines, hls
end

local function render()
  if not (_state.buf and vim.api.nvim_buf_is_valid(_state.buf)) then return end

  local item = _state.queue[_state.current]
  if not item then return end

  local lines = {}
  local hls   = {}

  -- ── Header bar ─────────────────────────────────────────────────────────────
  local agent_name = item.agent and item.agent.name or "?"
  local task_desc  = item.task  and item.task.description:sub(1, 60) or "?"
  local progress   = string.format("(%d/%d)", _state.current, #_state.queue)
  local header     = string.format(" %s  %s  %s", progress, agent_name, task_desc)
  table.insert(lines, header)
  table.insert(hls, { 0, 0, -1, "AgentFlowReviewHeader" })

  -- Metrics
  if item.result then
    local meta = string.format(
      " %s | %d in / %d out tokens",
      item.result.model or "?",
      item.result.tokens_in  or 0,
      item.result.tokens_out or 0
    )
    table.insert(lines, meta)
    table.insert(hls, { 1, 0, -1, "AgentFlowReviewMeta" })
  end

  -- ── Tab bar ────────────────────────────────────────────────────────────────
  local tab_parts = {}
  for i, tab in ipairs(TABS) do
    local label = string.format(" [%d] %s ", i, tab)
    table.insert(tab_parts, label)
  end
  local tab_line = table.concat(tab_parts, " │ ")
  table.insert(lines, "")
  table.insert(lines, tab_line)
  -- Highlight active tab
  local active_label = string.format("[%d] %s", _state.active_tab, TABS[_state.active_tab])
  local tab_col      = tab_line:find(active_label, 1, true)
  if tab_col then
    table.insert(hls, { #lines - 1, tab_col - 1, tab_col - 1 + #active_label, "AgentFlowReviewTabSel" })
  end
  table.insert(lines, string.rep("─", vim.o.columns))

  local content_start = #lines  -- first content line (0-indexed)

  -- ── Tab content ────────────────────────────────────────────────────────────
  if _state.active_tab == 1 then
    -- Diff tab
    local diff_text = item.diff_text or "(no diff generated)"
    local dl, dh    = render_diff_lines(diff_text)
    for _, l in ipairs(dl) do table.insert(lines, l) end
    for _, h in ipairs(dh) do
      table.insert(hls, { content_start + h[1], h[2], h[3], h[4] })
    end

  elseif _state.active_tab == 2 then
    -- Raw output
    local raw = (item.result and item.result.content) or "(no raw output)"
    for _, l in ipairs(vim.split(raw, "\n", { plain = true })) do
      table.insert(lines, l)
    end

  elseif _state.active_tab == 3 then
    -- Agent log / conversation history
    if item.agent and item.agent.history then
      for _, msg in ipairs(item.agent.history) do
        local role_label = msg.role == "user" and "▶ User" or "◀ Agent"
        table.insert(lines, role_label)
        table.insert(hls, { #lines - 1, 0, -1, "AgentFlowReviewMeta" })
        for _, l in ipairs(vim.split(msg.content or "", "\n", { plain = true })) do
          table.insert(lines, "  " .. l)
        end
        table.insert(lines, "")
      end
    else
      table.insert(lines, "(no conversation log)")
    end

  elseif _state.active_tab == 4 then
    -- Context sent
    local ctx = item.context or "(context not captured)"
    for _, l in ipairs(vim.split(ctx, "\n", { plain = true })) do
      table.insert(lines, l)
    end
  end

  -- ── Footer (keybindings) ──────────────────────────────────────────────────
  table.insert(lines, "")
  table.insert(lines, string.rep("─", vim.o.columns))
  local footer = " <CR> accept  x reject  e edit  r retry  ]r next  [r prev  1-4 tabs  q close"
  table.insert(lines, footer)
  table.insert(hls, { #lines - 1, 0, -1, "AgentFlowReviewMeta" })

  -- Write to buffer
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

-- ── Action handlers ───────────────────────────────────────────────────────────

local function current_item() return _state.queue[_state.current] end

local function accept()
  local item = current_item()
  if not item then return end

  local ok_count = 0
  local err_msgs = {}

  for _, artifact in ipairs(item.artifacts or {}) do
    local bufnr = results.find_buf(artifact.path)

    if bufnr then
      local ok, err = diff.apply_artifact(artifact, bufnr)
      if ok then
        ok_count = ok_count + 1
        vim.notify(
          string.format("AgentFlow: applied changes to %s", artifact.path or "buffer"),
          vim.log.levels.INFO
        )
      else
        table.insert(err_msgs, err)
      end
    elseif artifact.path then
      -- File not open — write to disk
      local ok, err = diff.write_to_disk(artifact)
      if ok then
        ok_count = ok_count + 1
        vim.notify("AgentFlow: wrote new file " .. artifact.path, vim.log.levels.INFO)
      else
        table.insert(err_msgs, err)
      end
    else
      vim.notify("AgentFlow: no target path — open the file and retry", vim.log.levels.WARN)
    end
  end

  if #err_msgs > 0 then
    vim.notify("AgentFlow: accept errors: " .. table.concat(err_msgs, "; "), vim.log.levels.ERROR)
  end

  item.decision = "accepted"
  events.emit("review:accepted", { item = item })
  log.info("Review: accepted", { agent = item.agent and item.agent.name })
  M.next()
end

local function reject()
  local item = current_item()
  if not item then return end
  item.decision = "rejected"
  events.emit("review:rejected", { item = item })
  log.info("Review: rejected", { agent = item.agent and item.agent.name })
  vim.notify("AgentFlow: result rejected", vim.log.levels.INFO)
  M.next()
end

local function edit()
  local item = current_item()
  if not item then return end
  -- Open the first artifact's content in a normal buffer for manual editing
  local artifact = item.artifacts and item.artifacts[1]
  local content  = artifact and artifact.content or (item.result and item.result.content) or ""

  local edit_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, vim.split(content, "\n", { plain = true }))
  local ft = artifact and artifact.language or "text"
  vim.api.nvim_set_option_value("filetype", ft, { buf = edit_buf })

  M.close()
  vim.api.nvim_set_current_buf(edit_buf)
  vim.notify("AgentFlow: edit the content, then :AgentReview to re-open", vim.log.levels.INFO)
end

local function retry()
  local item = current_item()
  if not item then return end

  vim.ui.input({ prompt = "Feedback for retry: " }, function(feedback)
    if not feedback or feedback == "" then return end

    item.decision = "retried"
    events.emit("review:retry", { item = item, feedback = feedback })
    vim.notify("AgentFlow: retry requested (Phase 6 full wiring)", vim.log.levels.INFO)
    log.info("Review: retry", { agent = item.agent and item.agent.name, feedback = feedback })
  end)
end

-- ── Navigation ────────────────────────────────────────────────────────────────

function M.next()
  if _state.current >= #_state.queue then
    -- All reviewed
    vim.notify(
      string.format("AgentFlow: review complete (%d items)", #_state.queue),
      vim.log.levels.INFO
    )
    if _state.on_complete then pcall(_state.on_complete, _state.queue) end
    M.close()
    return
  end
  _state.current    = _state.current + 1
  _state.active_tab = 1
  render()
end

function M.prev()
  if _state.current > 1 then
    _state.current    = _state.current - 1
    _state.active_tab = 1
    render()
  end
end

-- ── Keymaps ───────────────────────────────────────────────────────────────────

local function set_keymaps()
  local buf = _state.buf
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true })
  end

  map("<CR>", accept)
  map("x",    reject)
  map("e",    edit)
  map("r",    retry)
  map("]r",   M.next)
  map("[r",   M.prev)
  map("q",    M.close)
  map("<Esc>",M.close)
  map("<Tab>",function()
    local ok, hub = pcall(require, "agentflow.ui.hub")
    if ok then M.close(); hub.open() end
  end)

  -- Tab switching
  for i = 1, #TABS do
    map(tostring(i), function()
      _state.active_tab = i
      render()
    end)
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Open the review panel with a list of agent results.
--- @param items table[]  List of {
---   agent  table     agents/agent.lua instance
---   task   table     Task object
---   result table     Backend result { content, tokens_in, tokens_out, model }
---   context string|nil  Context that was sent
--- }
--- @param opts table|nil { on_complete? function }
function M.open(items, opts)
  opts = opts or {}

  if not items or #items == 0 then
    vim.notify("AgentFlow: no results to review", vim.log.levels.INFO)
    return
  end

  setup_highlights()

  -- Pre-generate diffs for all items
  for _, item in ipairs(items) do
    item.artifacts = results.extract(
      item.result and item.result.content or "",
      item.task
    )

    -- Build diff text for the first artifact
    if #item.artifacts > 0 then
      local artifact = item.artifacts[1]
      local bufnr    = artifact.path and results.find_buf(artifact.path)
      local diff_text, _ = diff.generate_for_artifact(artifact, bufnr)
      item.diff_text = diff_text ~= "" and diff_text or artifact.content
    else
      item.diff_text = item.result and item.result.content or ""
    end
  end

  _state.queue       = items
  _state.current     = 1
  _state.active_tab  = 1
  _state.on_complete = opts.on_complete

  -- Close existing window if open
  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    vim.api.nvim_win_close(_state.win, true)
  end

  local sz = win_size()

  _state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype",  "agentflow-review", { buf = _state.buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe",  { buf = _state.buf })

  _state.win = vim.api.nvim_open_win(_state.buf, true, {
    relative  = "editor",
    row       = sz.row,
    col       = sz.col,
    width     = sz.width,
    height    = sz.height,
    style     = "minimal",
    border    = "rounded",
    title     = " AgentFlow Review ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("wrap",       true,  { win = _state.win })
  vim.api.nvim_set_option_value("cursorline", false, { win = _state.win })

  set_keymaps()
  render()
  log.debug("Review panel opened", { items = #items })
end

--- Close the review panel.
function M.close()
  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    vim.api.nvim_win_close(_state.win, true)
  end
  _state.win = nil
  _state.buf = nil
end

--- Add a single result to the queue (called as agents complete).
--- @param item table
function M.enqueue(item)
  table.insert(_state.queue, item)
  -- If review is already open, refresh the tab bar
  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    render()
  end
end

--- Return the current review queue.
function M.get_queue() return _state.queue end

return M
