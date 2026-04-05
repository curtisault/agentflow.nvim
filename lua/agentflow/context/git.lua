-- context/git.lua — Git diff and blame context.
-- All git commands run async via util/subprocess.lua.
-- Returns empty context (no errors) when not in a git repo.

local M = {}

local log        = require("agentflow.util.log")
local subprocess = require("agentflow.util.subprocess")

-- ── Helpers ───────────────────────────────────────────────────────────────────

--- Check whether cwd is inside a git repo (sync, cached per session).
local _is_git_repo = nil

local function check_git_repo()
  if _is_git_repo ~= nil then return _is_git_repo end
  local result = vim.fn.system("git rev-parse --is-inside-work-tree 2>/dev/null")
  _is_git_repo = vim.v.shell_error == 0 and vim.trim(result) == "true"
  return _is_git_repo
end

--- Run a git command async and return its stdout.
--- Must be called from within a coroutine.
--- @param args string[]  Arguments after "git"
--- @param timeout number|nil
--- @return string|nil stdout, string|nil error
local function git(args, timeout)
  local cmd = vim.list_extend({ "git" }, args)
  local result, err = subprocess.run({
    cmd     = cmd,
    timeout = timeout or 15000,
  })
  if err then return nil, err end
  if result.code ~= 0 then
    -- Many git commands return non-zero for "nothing to show" — treat as empty
    return "", nil
  end
  return result.stdout, nil
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Get the current git diff.
--- Must be called from within a coroutine.
---
--- @param mode string  "staged" | "all" | "unstaged"
--- @param opts table|nil { max_lines? number, stat_only? boolean }
--- @return table|nil {
---   mode, diff, stat, truncated, line_count
--- }
function M.get_diff(mode, opts)
  opts = opts or {}

  if not check_git_repo() then
    log.debug("context/git: not a git repo, skipping diff")
    return nil
  end

  local args
  if mode == "staged" then
    args = { "diff", "--cached" }
  elseif mode == "unstaged" then
    args = { "diff" }
  else  -- "all"
    args = { "diff", "HEAD" }
  end

  -- Get the stat summary first (always small)
  local stat_args = vim.list_extend(vim.list_slice(args, 1, #args), { "--stat" })
  local stat, stat_err = git(stat_args)
  if stat_err then
    log.warn("context/git: stat failed", { err = stat_err })
    stat = ""
  end

  if opts.stat_only then
    return { mode = mode, diff = "", stat = stat or "", truncated = false, line_count = 0 }
  end

  local diff, diff_err = git(args)
  if diff_err then
    log.warn("context/git: diff failed", { err = diff_err, mode = mode })
    return nil
  end

  local lines      = vim.split(diff or "", "\n")
  local max_lines  = opts.max_lines or 500
  local truncated  = false

  if #lines > max_lines then
    lines     = vim.list_slice(lines, 1, max_lines)
    truncated = true
  end

  log.debug("context/git: diff", { mode = mode, lines = #lines, truncated = truncated })

  return {
    mode       = mode,
    diff       = table.concat(lines, "\n"),
    stat       = stat or "",
    truncated  = truncated,
    line_count = #lines,
  }
end

--- Get git blame for a range of lines in a file.
--- Must be called from within a coroutine.
---
--- @param file string   Absolute path to the file
--- @param start_line number  1-indexed
--- @param end_line number    1-indexed
--- @return table|nil { blame_lines: string[], file, range }
function M.get_blame(file, start_line, end_line)
  if not check_git_repo() then return nil end
  if not file or file == "" then return nil end

  -- Make path relative to git root
  local rel = vim.fn.fnamemodify(file, ":.")

  local args = {
    "blame",
    string.format("-L%d,%d", start_line, end_line),
    "--porcelain",
    rel,
  }

  local out, err = git(args, 10000)
  if err or not out or out == "" then
    log.debug("context/git: blame returned nothing", { file = rel, err = err })
    return nil
  end

  -- Parse porcelain blame into readable lines
  local parsed = {}
  local lines  = vim.split(out, "\n")
  local i      = 1
  while i <= #lines do
    local line = lines[i]
    -- Porcelain format: 40-char hash + metadata lines + "\t<source line>"
    if line:match("^\t") then
      table.insert(parsed, line:sub(2))  -- strip the leading tab
    end
    i = i + 1
  end

  return {
    blame_lines = parsed,
    file        = file,
    range       = { start_line = start_line, end_line = end_line },
  }
end

--- Get the current branch name.
--- Sync (uses vim.fn.system — safe to call outside coroutines).
--- @return string|nil
function M.branch()
  if not check_git_repo() then return nil end
  local out = vim.fn.system("git rev-parse --abbrev-ref HEAD 2>/dev/null")
  if vim.v.shell_error ~= 0 then return nil end
  return vim.trim(out)
end

--- Get recent commit log (one line per commit).
--- Must be called from within a coroutine.
--- @param n number|nil  Number of commits (default 10)
--- @return string|nil
function M.recent_log(n)
  if not check_git_repo() then return nil end
  local out, err = git({ "log", "--oneline", "-" .. (n or 10) })
  if err then return nil end
  return out
end

--- Reset the git repo detection cache (useful in tests).
function M.reset_cache()
  _is_git_repo = nil
end

--- Format a diff result for prompt injection.
--- @param diff_info table  Result from get_diff()
--- @return string
function M.format(diff_info)
  if not diff_info then return "" end

  local parts = {}
  local mode_label = ({
    staged   = "Staged changes",
    unstaged = "Unstaged changes",
    all      = "All changes (diff HEAD)",
  })[diff_info.mode] or diff_info.mode

  table.insert(parts, "### Git: " .. mode_label)

  if diff_info.stat and diff_info.stat ~= "" then
    table.insert(parts, "")
    table.insert(parts, "**Summary:**")
    table.insert(parts, "```")
    table.insert(parts, diff_info.stat)
    table.insert(parts, "```")
  end

  if diff_info.diff and diff_info.diff ~= "" then
    if diff_info.truncated then
      table.insert(parts, string.format(
        "*(diff truncated to %d lines)*", diff_info.line_count
      ))
    end
    table.insert(parts, "")
    table.insert(parts, "```diff")
    table.insert(parts, diff_info.diff)
    table.insert(parts, "```")
  elseif diff_info.stat == "" then
    table.insert(parts, "*(no changes)*")
  end

  return table.concat(parts, "\n")
end

return M
