-- context/files.lua — Project file tree and individual file reading.
-- Uses vim.loop.fs_scandir for async directory walking.
-- Respects .gitignore via git ls-files when available.

local M = {}

local log        = require("agentflow.util.log")
local subprocess = require("agentflow.util.subprocess")

local MAX_FILE_SIZE = 100 * 1024  -- 100 KB hard limit per file read

-- ── .gitignore-aware file listing ────────────────────────────────────────────

--- List tracked/unignored files under root using `git ls-files`.
--- Falls back to raw fs_scandir if not in a git repo.
--- Must be called from within a coroutine.
---
--- @param root string   Absolute directory path
--- @param opts table|nil { max_files? number }
--- @return string[]|nil  Sorted relative file paths, or nil on error
local function git_ls_files(root, opts)
  opts = opts or {}
  local max = opts.max_files or 500

  local result, err = subprocess.run({
    cmd     = { "git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard" },
    timeout = 10000,
  })

  if err or result.code ~= 0 then
    return nil  -- not a git repo or git unavailable
  end

  local files = {}
  for _, line in ipairs(vim.split(result.stdout, "\n")) do
    if line ~= "" then
      table.insert(files, line)
      if #files >= max then break end
    end
  end

  table.sort(files)
  return files
end

-- ── Async directory walker ────────────────────────────────────────────────────

local IGNORE_DIRS = {
  [".git"]          = true, ["node_modules"] = true,
  [".venv"]         = true, ["venv"]         = true,
  ["__pycache__"]   = true, [".mypy_cache"]  = true,
  [".pytest_cache"] = true, ["target"]       = true,   -- Rust/Java
  ["_build"]        = true, ["deps"]         = true,   -- Elixir
  [".elixir_ls"]    = true, ["dist"]         = true,
  ["build"]         = true, [".cache"]       = true,
}

--- Recursively walk `dir` up to `max_depth` levels deep.
--- Returns a tree string (like `tree` output).
--- This is a synchronous walk using vim.loop; it should be fast for typical projects.
---
--- @param dir string     Absolute path
--- @param max_depth number
--- @param current_depth number|nil
--- @param prefix string|nil
--- @return string  Tree text
local function walk_tree(dir, max_depth, current_depth, prefix)
  current_depth = current_depth or 0
  prefix        = prefix        or ""

  if current_depth > max_depth then return "" end

  local handle = vim.loop.fs_scandir(dir)
  if not handle then return "" end

  local entries = {}
  while true do
    local name, kind = vim.loop.fs_scandir_next(handle)
    if not name then break end
    table.insert(entries, { name = name, kind = kind })
  end

  table.sort(entries, function(a, b)
    -- Directories first, then files
    if a.kind ~= b.kind then
      return a.kind == "directory"
    end
    return a.name < b.name
  end)

  local lines = {}
  for i, entry in ipairs(entries) do
    local is_last     = i == #entries
    local connector   = is_last and "└── " or "├── "
    local child_prefix = is_last and "    " or "│   "

    if entry.kind == "directory" then
      if IGNORE_DIRS[entry.name] then
        table.insert(lines, prefix .. connector .. entry.name .. "/  (skipped)")
      else
        table.insert(lines, prefix .. connector .. entry.name .. "/")
        if current_depth < max_depth then
          local subtree = walk_tree(
            dir .. "/" .. entry.name,
            max_depth,
            current_depth + 1,
            prefix .. child_prefix
          )
          if subtree ~= "" then
            table.insert(lines, subtree)
          end
        end
      end
    else
      table.insert(lines, prefix .. connector .. entry.name)
    end
  end

  return table.concat(lines, "\n")
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Build an indented file tree for the project.
--- Prefers git ls-files for accuracy; falls back to fs_scandir walk.
--- Must be called from within a coroutine (git ls-files path).
---
--- @param root string|nil  Root directory (defaults to cwd)
--- @param max_depth number|nil  Max tree depth for the fallback walker (default 4)
--- @return table|nil {
---   tree: string,   -- Formatted tree text
---   method: string, -- "git" | "fs"
---   root: string,
--- }
function M.get_tree(root, max_depth)
  root      = root      or vim.fn.getcwd()
  max_depth = max_depth or 4

  -- Try git ls-files first
  local git_files = git_ls_files(root, { max_files = 500 })
  if git_files then
    -- Format as a flat list (git ls-files doesn't give us a tree naturally)
    local lines = {}
    for _, f in ipairs(git_files) do
      table.insert(lines, f)
    end
    local tree = table.concat(lines, "\n")
    log.debug("context/files: tree via git ls-files", { count = #git_files, root = root })
    return { tree = tree, method = "git", root = root }
  end

  -- Fallback: synchronous fs_scandir walk
  local tree = walk_tree(root, max_depth)
  log.debug("context/files: tree via fs_scandir", { root = root, max_depth = max_depth })
  return { tree = tree, method = "fs", root = root }
end

--- Read a single file with size limits.
--- @param path string  Absolute or relative file path
--- @param opts table|nil { max_bytes? number, max_lines? number }
--- @return table|nil {
---   path, content, size_bytes, truncated, filetype
--- }
function M.read_file(path, opts)
  opts = opts or {}
  local max_bytes = opts.max_bytes or MAX_FILE_SIZE
  local max_lines = opts.max_lines

  -- Stat the file before reading
  local stat = vim.loop.fs_stat(path)
  if not stat then
    log.debug("context/files: file not found", { path = path })
    return nil
  end

  if stat.size > max_bytes then
    log.debug("context/files: file too large", { path = path, size = stat.size })
    return {
      path       = path,
      content    = string.format("*(file too large to include: %d bytes)*", stat.size),
      size_bytes = stat.size,
      truncated  = true,
      filetype   = vim.filetype.match({ filename = path }) or "",
    }
  end

  local fd = vim.loop.fs_open(path, "r", 438)  -- 438 = 0o666
  if not fd then return nil end

  local data = vim.loop.fs_read(fd, stat.size, 0)
  vim.loop.fs_close(fd)

  if not data then return nil end

  local content   = data
  local truncated = false

  if max_lines then
    local lines = vim.split(data, "\n")
    if #lines > max_lines then
      content   = table.concat(vim.list_slice(lines, 1, max_lines), "\n")
      truncated = true
    end
  end

  return {
    path       = path,
    content    = content,
    size_bytes = stat.size,
    truncated  = truncated,
    filetype   = vim.filetype.match({ filename = path }) or "",
  }
end

--- Format a file tree result for prompt injection.
--- @param tree_info table  Result from get_tree()
--- @return string
function M.format_tree(tree_info)
  if not tree_info then return "" end

  local method_label = tree_info.method == "git"
    and "git ls-files"
    or  "directory scan (depth " .. "4" .. ")"

  local parts = {
    "### Project file tree (`" .. tree_info.root .. "`, via " .. method_label .. ")",
    "",
    "```",
    tree_info.tree,
    "```",
  }
  return table.concat(parts, "\n")
end

--- Format a file read result for prompt injection.
--- @param file_info table  Result from read_file()
--- @return string
function M.format_file(file_info)
  if not file_info then return "" end

  local parts = { "### File: `" .. file_info.path .. "`" }

  if file_info.truncated then
    table.insert(parts, "*(content truncated)*")
  end

  table.insert(parts, "")
  table.insert(parts, "```" .. (file_info.filetype or ""))
  table.insert(parts, file_info.content)
  table.insert(parts, "```")

  return table.concat(parts, "\n")
end

return M
