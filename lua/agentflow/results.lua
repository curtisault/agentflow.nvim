-- results.lua — Extract structured artifacts from agent responses.
--
-- Detects and parses:
--   - Fenced code blocks with optional file path annotations
--   - Unified diff format (--- a/  +++ b/  @@ hunks)
--   - Inline edit instructions (REPLACE/INSERT/DELETE markers)
--
-- Maps each artifact to a target buffer/file path.

local M = {}

local log = require("agentflow.util.log")

-- ── Types ─────────────────────────────────────────────────────────────────────
--
-- Artifact = {
--   kind:     string        "code" | "diff" | "instruction"
--   path:     string|nil    Target file path (relative or absolute)
--   language: string|nil    Fenced code language tag
--   content:  string        The extracted content
--   hunks:    Hunk[]|nil    Parsed diff hunks (for kind="diff")
-- }
--
-- Hunk = {
--   old_start: number, old_count: number,
--   new_start: number, new_count: number,
--   lines:     string[]   Lines prefixed with " ", "+", or "-"
-- }

-- ── Code block extraction ─────────────────────────────────────────────────────

-- Match fenced blocks.  We look for an optional file path on the same line as
-- the opening fence, e.g.:
--   ```lua path/to/file.lua
--   ...
--   ```
-- or just:
--   ```lua
--   ...
--   ```

local FENCE_PATTERN = "```([^\n]*)\n(.-)\n```"

--- Extract all fenced code blocks from text.
--- @param text string
--- @return table[]  List of { language, path, content }
local function extract_code_blocks(text)
  local blocks = {}
  for header, content in text:gmatch(FENCE_PATTERN) do
    -- header might be: "lua", "lua path/to/file.lua", "diff", ""
    local lang, path = header:match("^(%S*) *(.-)%s*$")
    lang = lang ~= "" and lang or nil
    path = path ~= "" and path or nil

    -- Also try to detect a file path in the first comment line of the block
    if not path then
      local first_line = content:match("^([^\n]+)")
      if first_line then
        -- Look for patterns like:  -- path/to/file.lua   or  // file.lua   or  # file.lua
        local candidate = first_line:match("^%s*[%-/#]+%s*(.+%.%w+)%s*$")
        if candidate and not candidate:match("%s") and #candidate < 100 then
          path = candidate
        end
      end
    end

    table.insert(blocks, {
      language = lang,
      path     = path,
      content  = content,
    })
  end
  return blocks
end

-- ── Diff parsing ──────────────────────────────────────────────────────────────

--- Check whether a string looks like a unified diff.
local function is_unified_diff(text)
  return text:match("^%-%-%-") ~= nil
      or text:match("^%+%+%+") ~= nil
      or text:match("\n@@") ~= nil
end

--- Parse a unified diff string into structured hunks.
--- @param diff_text string
--- @return table  { old_path, new_path, hunks[] }
local function parse_unified_diff(diff_text)
  local old_path = diff_text:match("^%-%-%- a?/?([^\n]+)") or
                   diff_text:match("^%-%-%- ([^\n]+)")
  local new_path = diff_text:match("\n%+%+%+ b?/?([^\n]+)") or
                   diff_text:match("\n%+%+%+ ([^\n]+)")

  -- Strip timestamps from paths (e.g. "file.lua\t2024-01-01 ...")
  if old_path then old_path = old_path:match("^([^\t]+)") end
  if new_path then new_path = new_path:match("^([^\t]+)") end

  local hunks = {}
  local current_hunk = nil

  for line in (diff_text .. "\n"):gmatch("([^\n]*)\n") do
    local old_s, old_c, new_s, new_c = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if old_s then
      if current_hunk then table.insert(hunks, current_hunk) end
      current_hunk = {
        old_start = tonumber(old_s),
        old_count = tonumber(old_c ~= "" and old_c or "1"),
        new_start = tonumber(new_s),
        new_count = tonumber(new_c ~= "" and new_c or "1"),
        lines     = {},
      }
    elseif current_hunk then
      local prefix = line:sub(1, 1)
      if prefix == "+" or prefix == "-" or prefix == " " then
        table.insert(current_hunk.lines, line)
      end
    end
  end
  if current_hunk then table.insert(hunks, current_hunk) end

  return {
    old_path = old_path,
    new_path = new_path,
    hunks    = hunks,
  }
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Extract all structured artifacts from an agent's response content.
--- @param content string  Raw agent response text
--- @param task table|nil  Task object (used to infer target files)
--- @return table[]  List of Artifact objects
function M.extract(content, task)
  if not content or content == "" then return {} end

  local artifacts = {}

  -- Gather code blocks
  local blocks = extract_code_blocks(content)

  -- Use task's required files as fallback path hints
  local task_files = (task and task.context_requirements and task.context_requirements.files) or {}

  for i, block in ipairs(blocks) do
    local path = block.path

    -- Inherit from task files if exactly one file and no explicit path
    if not path and #task_files == 1 then
      path = task_files[1]
    end

    local kind = "code"
    local hunks = nil

    -- If the block's language is "diff" or content looks like a unified diff → parse it
    if block.language == "diff" or is_unified_diff(block.content) then
      kind = "diff"
      local parsed = parse_unified_diff(block.content)
      hunks = parsed.hunks
      -- Prefer path from the diff header
      if not path then
        path = parsed.new_path or parsed.old_path
      end
    end

    table.insert(artifacts, {
      kind     = kind,
      path     = path,
      language = block.language,
      content  = block.content,
      hunks    = hunks,
      index    = i,
    })
  end

  -- If there are no code blocks, treat the entire response as a plain instruction
  if #artifacts == 0 and content ~= "" then
    table.insert(artifacts, {
      kind     = "instruction",
      path     = nil,
      language = nil,
      content  = content,
      hunks    = nil,
      index    = 1,
    })
  end

  log.debug("results.extract", {
    artifacts = #artifacts,
    kinds     = vim.tbl_map(function(a) return a.kind end, artifacts),
  })

  return artifacts
end

--- Find the target buffer number for an artifact's path.
--- Returns nil if the file is not currently open in any buffer.
--- @param path string
--- @return number|nil bufnr
function M.find_buf(path)
  if not path or path == "" then return nil end

  -- Try exact match first
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 then return bufnr end

  -- Try relative to cwd
  local abs = vim.fn.fnamemodify(path, ":p")
  bufnr = vim.fn.bufnr(abs)
  if bufnr ~= -1 then return bufnr end

  return nil
end

return M
