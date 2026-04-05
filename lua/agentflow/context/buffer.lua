-- context/buffer.lua — Current buffer and alternate buffer extraction.

local M = {}

local log = require("agentflow.util.log")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function is_usable(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  if not vim.api.nvim_buf_is_loaded(bufnr) then return false end
  local bt = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
  -- Skip terminal, quickfix, nofile buffers
  if bt ~= "" then return false end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return false end
  return true
end

local function read_buf(bufnr, max_lines)
  max_lines = max_lines or 2000
  local total = vim.api.nvim_buf_line_count(bufnr)
  local truncated = false
  local limit = total
  if total > max_lines then
    limit = max_lines
    truncated = true
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, limit, false)
  return table.concat(lines, "\n"), truncated, total
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Return information about the current buffer.
--- @param opts table|nil { max_lines? number }
--- @return table|nil {
---   bufnr, path, filetype, cursor_pos, content, truncated, total_lines
--- }
function M.get_current(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()

  if not is_usable(bufnr) then
    log.debug("context/buffer: current buffer is not usable", { bufnr = bufnr })
    return nil
  end

  local path     = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  local cursor   = vim.api.nvim_win_get_cursor(0)  -- {row, col}, 1-indexed row
  local content, truncated, total = read_buf(bufnr, opts.max_lines)

  return {
    bufnr       = bufnr,
    path        = path,
    filetype    = filetype,
    cursor_pos  = { line = cursor[1], col = cursor[2] },
    content     = content,
    truncated   = truncated,
    total_lines = total,
  }
end

--- Return the N most recently used alternate buffers.
--- @param n number|nil  Max number of alternates (default 3)
--- @param opts table|nil { max_lines? number }
--- @return table[]  List of buffer info tables (same shape as get_current)
function M.get_alternates(n, opts)
  n    = n    or 3
  opts = opts or {}

  local current = vim.api.nvim_get_current_buf()
  local out     = {}

  -- vim.fn.getbufinfo returns buffers sorted by last used time (most recent last)
  local all = vim.fn.getbufinfo({ buflisted = 1 })
  -- Reverse to get most-recent-first
  local sorted = {}
  for i = #all, 1, -1 do
    table.insert(sorted, all[i])
  end

  for _, info in ipairs(sorted) do
    if #out >= n then break end
    local bufnr = info.bufnr
    if bufnr ~= current and is_usable(bufnr) then
      local path     = vim.api.nvim_buf_get_name(bufnr)
      local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
      local content, truncated, total = read_buf(bufnr, opts.max_lines or 500)
      table.insert(out, {
        bufnr       = bufnr,
        path        = path,
        filetype    = filetype,
        cursor_pos  = nil,  -- no meaningful cursor for alternates
        content     = content,
        truncated   = truncated,
        total_lines = total,
      })
    end
  end

  log.debug("context/buffer: alternates", { count = #out })
  return out
end

--- Format a buffer info table as a string for injection into a prompt.
--- @param buf_info table
--- @param label string|nil  e.g. "Current buffer" or "Alternate buffer"
--- @return string
function M.format(buf_info, label)
  label = label or "Buffer"
  local parts = {}

  table.insert(parts, string.format("### %s: `%s`", label, buf_info.path))

  if buf_info.filetype and buf_info.filetype ~= "" then
    table.insert(parts, string.format("Filetype: %s", buf_info.filetype))
  end

  if buf_info.cursor_pos then
    table.insert(parts, string.format(
      "Cursor: line %d, col %d",
      buf_info.cursor_pos.line,
      buf_info.cursor_pos.col
    ))
  end

  if buf_info.truncated then
    table.insert(parts, string.format(
      "*(showing first %d of %d lines)*",
      #vim.split(buf_info.content, "\n"),
      buf_info.total_lines
    ))
  end

  table.insert(parts, "")
  table.insert(parts, "```" .. (buf_info.filetype or ""))
  table.insert(parts, buf_info.content)
  table.insert(parts, "```")

  return table.concat(parts, "\n")
end

return M
