-- ui/chat.lua — Minimal floating chat window for Phase 1.
--
-- Displays a conversation between the user and Claude.
-- Streams tokens into the buffer in real time.
-- Input is collected via a prompt buffer at the bottom.

local M = {}

local log    = require("agentflow.util.log")
local async  = require("agentflow.util.async")
local config = require("agentflow.config")

-- ── Highlight groups ─────────────────────────────────────────────────────────

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AgentFlowUser",   { fg = "#89b4fa", bold = true })   -- blue
  vim.api.nvim_set_hl(0, "AgentFlowClaude", { fg = "#a6e3a1" })                -- green
  vim.api.nvim_set_hl(0, "AgentFlowSystem", { fg = "#6c7086", italic = true }) -- muted
  vim.api.nvim_set_hl(0, "AgentFlowBorder", { fg = "#313244" })
  vim.api.nvim_set_hl(0, "AgentFlowSpinner",{ fg = "#fab387" })                -- peach
end

-- forward declaration so spinner functions can reference _state as an upvalue
local _state

-- ── Spinner ───────────────────────────────────────────────────────────────────

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_VERBS  = {
      "Journeying through Arda",
      "Consulting the Palantír",
      "Deciphering ancient Elvish texts",
      "Forging in the fires of Mount Doom",
      "Seeking wisdom in Rivendell",
      "Marching with the armies of the West",
      "Bearing the burden",
      "Inscribing in the Book of Mazarbul",
      "Wandering through Mirkwood",
      "Following the trail of the Uruk-hai",
      "Pondering in the halls of Moria",
      "Calling upon the Eagles",
      "Lighting the beacons of Gondor",
      "Reforging the shards of Narsil",
      "Summoning the Grey Host",
      "Passing through the Mines of Moria",
      "Crossing the Bridge of Khazad-dûm",
      "Taking counsel with the White Council",
      "Searching the archives of Minas Tirith",
      "Walking the paths of the dead",
      "Reckoning as the wisest of wizards",
      "Bearing as a ranger of the North",
      "Weaving the tapestry of fate",
      "Unsealing the gates of Moria",
      "Recording in the Red Book",
      "Sending riders of Rohan",
      "Beginning the quest",
      "Examining in Galadriel's Mirror",
      "Studying the lore of the Elves",
      "👁️ Eye of Sauron'ening",
      "Preserving in the halls of Rivendell",
      "Hunting servants of the Enemy",
      "Uniting the kingdoms of Men and Elves",
      "Facing the trial at Mount Doom",
      "Casting into the Cracks of Doom",
      "Ordering as the Elves would have it"
}

local _sp = { timer = nil, frame = 1, verb = 1, tick = 0, active = false }

local function buf_set_last_line(text)
  if not (_state and _state.buf and vim.api.nvim_buf_is_valid(_state.buf)) then return end
  local count = vim.api.nvim_buf_line_count(_state.buf)
  vim.api.nvim_set_option_value("modifiable", true, { buf = _state.buf })
  vim.api.nvim_buf_set_lines(_state.buf, count - 1, count, false, { text })
  vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })
end

local function spinner_stop()
  if _sp.timer then
    _sp.timer:stop()
    if not _sp.timer:is_closing() then _sp.timer:close() end
    _sp.timer = nil
  end
  _sp.active = false
end

local function spinner_start()
  _sp.frame  = 1
  _sp.tick   = 0
  _sp.verb   = math.random(#SPINNER_VERBS)
  _sp.active = true

  local verb = SPINNER_VERBS[_sp.verb]

  _sp.timer = vim.loop.new_timer()
  _sp.timer:start(0, 120, vim.schedule_wrap(function()
    if not _sp.active then return end
    if not (_state.buf and vim.api.nvim_buf_is_valid(_state.buf)) then
      spinner_stop(); return
    end
    _sp.frame = (_sp.frame % #SPINNER_FRAMES) + 1
    buf_set_last_line(SPINNER_FRAMES[_sp.frame] .. " " .. verb .. "…")
  end))
end

-- ── State ─────────────────────────────────────────────────────────────────────

_state = {
  buf       = nil,   -- chat display buffer
  win       = nil,   -- chat display window
  input_buf = nil,   -- input prompt buffer
  input_win = nil,   -- input prompt window
  history   = {},    -- { role, content } list
  running   = false, -- true while a request is in flight
}

-- ── Buffer helpers ────────────────────────────────────────────────────────────

local function buf_append(lines, hl_group)
  if not (_state.buf and vim.api.nvim_buf_is_valid(_state.buf)) then return end

  vim.api.nvim_set_option_value("modifiable", true, { buf = _state.buf })
  local count = vim.api.nvim_buf_line_count(_state.buf)

  -- Replace trailing empty line if buffer is empty-ish
  if count == 1 and vim.api.nvim_buf_get_lines(_state.buf, 0, 1, false)[1] == "" then
    vim.api.nvim_buf_set_lines(_state.buf, 0, 1, false, lines)
    count = 0
  else
    vim.api.nvim_buf_set_lines(_state.buf, count, count, false, lines)
  end

  if hl_group then
    for i = count, count + #lines - 1 do
      vim.api.nvim_buf_add_highlight(_state.buf, -1, hl_group, i, 0, -1)
    end
  end

  vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })

  -- Scroll to bottom
  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    local new_count = vim.api.nvim_buf_line_count(_state.buf)
    vim.api.nvim_win_set_cursor(_state.win, { new_count, 0 })
  end
end

local function buf_append_token(token)
  -- Append a streamed token to the last line (or start a new one on newline)
  if not (_state.buf and vim.api.nvim_buf_is_valid(_state.buf)) then return end

  vim.api.nvim_set_option_value("modifiable", true, { buf = _state.buf })
  local count = vim.api.nvim_buf_line_count(_state.buf)
  local last   = vim.api.nvim_buf_get_lines(_state.buf, count - 1, count, false)[1] or ""

  -- Split token on newlines
  local parts = vim.split(token, "\n", { plain = true })
  local new_last = last .. parts[1]
  local new_lines = { new_last }
  for i = 2, #parts do
    table.insert(new_lines, parts[i])
  end

  vim.api.nvim_buf_set_lines(_state.buf, count - 1, count, false, new_lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })

  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    local new_count = vim.api.nvim_buf_line_count(_state.buf)
    vim.api.nvim_win_set_cursor(_state.win, { new_count, 0 })
  end
end

-- ── Window layout ─────────────────────────────────────────────────────────────

local function compute_layout()
  local cfg = config.get()
  local width  = math.floor(vim.o.columns * (cfg.ui.chat_width or 0.5))
  local height = math.floor(vim.o.lines * 0.7)
  local row    = math.floor((vim.o.lines - height - 3) / 2)
  local col    = math.floor((vim.o.columns - width) / 2)
  return { width = width, height = height, row = row, col = col }
end

local function open_windows()
  local layout = compute_layout()

  -- Chat display buffer
  _state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "agentflow-chat", { buf = _state.buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = _state.buf })

  _state.win = vim.api.nvim_open_win(_state.buf, true, {
    relative = "editor",
    row      = layout.row,
    col      = layout.col,
    width    = layout.width,
    height   = layout.height,
    style    = "minimal",
    border   = "rounded",
    title    = " AgentFlow ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("wrap", true, { win = _state.win })
  vim.api.nvim_set_option_value("linebreak", true, { win = _state.win })
  vim.api.nvim_set_option_value("cursorline", false, { win = _state.win })

  -- Input buffer (2 rows below the chat window)
  _state.input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = _state.input_buf })

  _state.input_win = vim.api.nvim_open_win(_state.input_buf, true, {
    relative = "editor",
    row      = layout.row + layout.height + 1,
    col      = layout.col,
    width    = layout.width,
    height   = 1,
    style    = "minimal",
    border   = "rounded",
    title    = " Prompt (<CR> send  <C-c> cancel  <C-l> clear) ",
    title_pos = "left",
  })
end

-- ── Keymaps ───────────────────────────────────────────────────────────────────

local function set_keymaps()
  local function map(mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, { buffer = _state.input_buf, silent = true, nowait = true })
  end

  -- Send on <CR>
  map("n", "<CR>", function() M.send() end)
  map("i", "<CR>", function()
    vim.cmd("stopinsert")
    M.send()
  end)

  -- Cancel
  map({ "n", "i" }, "<C-c>", function() M.close() end)

  -- Clear history
  map({ "n", "i" }, "<C-l>", function() M.clear() end)

  -- Close on <Esc> in normal mode
  map("n", "<Esc>", function() M.close() end)
  map("n", "q",     function() M.close() end)

  -- Also close chat window keymaps
  vim.keymap.set("n", "q",     function() M.close() end, { buffer = _state.buf, silent = true })
  vim.keymap.set("n", "<Esc>", function() M.close() end, { buffer = _state.buf, silent = true })
end

-- ── Send / receive ────────────────────────────────────────────────────────────

function M.send()
  if _state.running then
    vim.notify("AgentFlow: request already in flight", vim.log.levels.WARN)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(_state.input_buf, 0, -1, false)
  local prompt = vim.trim(table.concat(lines, "\n"))
  if prompt == "" then return end

  -- Clear input buffer
  vim.api.nvim_buf_set_lines(_state.input_buf, 0, -1, false, { "" })

  -- Add user turn to history and display
  table.insert(_state.history, { role = "user", content = prompt })
  buf_append({ "", "You: " .. prompt, "" }, "AgentFlowUser")

  _state.running = true

  async.run(function()
    local orch = require("agentflow")._get_orchestrator()
    if not orch then
      vim.schedule(function()
        _state.running = false
        buf_append({ "[Error: AgentFlow not initialized — call setup() first]", "" }, "AgentFlowSystem")
      end)
      return
    end

    -- Header line + empty line (spinner/content lands here)
    buf_append({ "Claude:", "" }, "AgentFlowClaude")
    spinner_start()

    local is_first_token = true

    local result, err = orch:run(prompt, {
      on_token = function(token)
        vim.schedule(function()
          if is_first_token then
            is_first_token = false
            spinner_stop()
            buf_set_last_line("")
          end
          buf_append_token(token)
        end)
      end,
    })

    vim.schedule(function()
      spinner_stop()
      _state.running = false

      if err then
        buf_set_last_line("")
        buf_append({ "[Error: " .. err .. "]", "" }, "AgentFlowSystem")
        log.error("Chat request failed", { error = err })
        return
      end

      table.insert(_state.history, { role = "assistant", content = result.content })

      local stats = string.format(
        "[%d in / %d out tokens — %s]",
        result.tokens_in, result.tokens_out, result.model
      )
      buf_append({ "", stats, "" }, "AgentFlowSystem")
    end)
  end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Open the chat window. If already open, focus the input.
function M.open()
  setup_highlights()

  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    vim.api.nvim_set_current_win(_state.input_win)
    vim.cmd("startinsert")
    return
  end

  open_windows()
  set_keymaps()

  -- Show existing history if any
  if #_state.history > 0 then
    for _, msg in ipairs(_state.history) do
      local hl = msg.role == "user" and "AgentFlowUser" or "AgentFlowClaude"
      local label = msg.role == "user" and "You: " or "Claude: "
      local content_lines = vim.split(label .. msg.content, "\n", { plain = true })
      table.insert(content_lines, "")
      buf_append(content_lines, hl)
    end
  else
    buf_append({ "AgentFlow — type a message and press <CR> to send.", "" }, "AgentFlowSystem")
  end

  vim.api.nvim_set_current_win(_state.input_win)
  vim.cmd("startinsert")
  log.debug("Chat window opened")
end

--- Close and destroy the chat windows.
function M.close()
  if _state.input_win and vim.api.nvim_win_is_valid(_state.input_win) then
    vim.api.nvim_win_close(_state.input_win, true)
  end
  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    vim.api.nvim_win_close(_state.win, true)
  end
  _state.win       = nil
  _state.buf       = nil
  _state.input_win = nil
  _state.input_buf = nil
  log.debug("Chat window closed")
end

--- Clear conversation history and the display buffer.
function M.clear()
  _state.history = {}
  if _state.buf and vim.api.nvim_buf_is_valid(_state.buf) then
    vim.api.nvim_set_option_value("modifiable", true, { buf = _state.buf })
    vim.api.nvim_buf_set_lines(_state.buf, 0, -1, false, { "AgentFlow — history cleared.", "" })
    vim.api.nvim_set_option_value("modifiable", false, { buf = _state.buf })
  end
  log.debug("Chat history cleared")
end

--- Pre-populate the input with a prompt and optionally send immediately.
--- @param prompt string
--- @param send boolean|nil  If true, send without waiting for user input
function M.with_prompt(prompt, send)
  M.open()
  if _state.input_buf and vim.api.nvim_buf_is_valid(_state.input_buf) then
    vim.api.nvim_buf_set_lines(_state.input_buf, 0, -1, false, { prompt })
  end
  if send then
    M.send()
  end
end

return M
