-- util/log.lua — Structured leveled logger
-- Writes to a scratch buffer ("AgentFlow Log") and optionally to a file.

local M = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local LEVEL_NAMES = { [1] = "DEBUG", [2] = "INFO", [3] = "WARN", [4] = "ERROR" }
local LEVEL_HL = {
  [1] = "Comment",
  [2] = "Normal",
  [3] = "WarningMsg",
  [4] = "ErrorMsg",
}

-- State
local _min_level = LEVELS.info
local _log_file = nil    -- file handle, nil = no file logging
local _buf = nil         -- log scratch buffer number
local _lines = {}        -- in-memory log lines (capped)
local MAX_LINES = 2000

-- ── Internal helpers ────────────────────────────────────────────────────────

local function timestamp()
  return os.date("%H:%M:%S")
end

local function get_or_create_buf()
  if _buf and vim.api.nvim_buf_is_valid(_buf) then
    return _buf
  end
  _buf = vim.api.nvim_create_buf(false, true)  -- unlisted, scratch
  vim.api.nvim_buf_set_name(_buf, "AgentFlow Log")
  vim.api.nvim_set_option_value("filetype", "agentflow-log", { buf = _buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = _buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = _buf })
  return _buf
end

local function append_to_buf(line)
  local buf = get_or_create_buf()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  local count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, count, count, false, { line })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Scroll any window displaying the log buffer to the bottom
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      local new_count = vim.api.nvim_buf_line_count(buf)
      vim.api.nvim_win_set_cursor(win, { new_count, 0 })
    end
  end
end

local function write(level, msg, data)
  if level < _min_level then return end

  local level_name = LEVEL_NAMES[level] or "???"
  local line = string.format("[%s] [%s] %s", timestamp(), level_name, msg)

  if data ~= nil then
    local ok, encoded = pcall(vim.fn.json_encode, data)
    line = line .. " " .. (ok and encoded or tostring(data))
  end

  -- In-memory ring buffer
  table.insert(_lines, line)
  if #_lines > MAX_LINES then
    table.remove(_lines, 1)
  end

  -- Scratch buffer
  append_to_buf(line)

  -- Optional file sink
  if _log_file then
    _log_file:write(line .. "\n")
    _log_file:flush()
  end
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Configure the logger. Called from agentflow.setup().
--- @param opts table { level?: string, file?: string }
function M.setup(opts)
  opts = opts or {}
  if opts.level then
    _min_level = LEVELS[opts.level] or LEVELS.info
  end
  if opts.file then
    local f, err = io.open(opts.file, "a")
    if f then
      _log_file = f
    else
      vim.notify("AgentFlow log: cannot open file: " .. err, vim.log.levels.WARN)
    end
  end
end

function M.debug(msg, data) write(LEVELS.debug, msg, data) end
function M.info(msg, data)  write(LEVELS.info,  msg, data) end
function M.warn(msg, data)  write(LEVELS.warn,  msg, data) end
function M.error(msg, data) write(LEVELS.error, msg, data) end

--- Return all in-memory log lines.
function M.get_lines()
  return vim.list_slice(_lines, 1, #_lines)
end

--- Return the log scratch buffer number (creates it if needed).
function M.get_buf()
  return get_or_create_buf()
end

--- Open the log buffer in a new split.
function M.open()
  local buf = get_or_create_buf()
  vim.cmd("botright 15split")
  vim.api.nvim_win_set_buf(0, buf)
end

return M
