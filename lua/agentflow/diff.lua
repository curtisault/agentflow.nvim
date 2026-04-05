-- diff.lua — Diff generation and hunk application.
--
-- Generates unified diffs by comparing agent output against current buffer content.
-- Applies accepted hunks to live buffers, preserving undo history.

local M = {}

local log = require("agentflow.util.log")

-- ── Generation ────────────────────────────────────────────────────────────────

--- Generate a unified diff between old_text and new_text.
--- Uses vim.diff() (Neovim 0.9+) if available, otherwise shells out to diff(1).
---
--- @param old_text string
--- @param new_text string
--- @param opts table|nil { old_label? string, new_label? string, context? number }
--- @return string  Unified diff text (empty string if no changes)
function M.generate(old_text, new_text, opts)
  opts = opts or {}

  if old_text == new_text then return "" end

  local old_label = opts.old_label or "original"
  local new_label = opts.new_label or "modified"
  local context   = opts.context   or 3

  -- Prefer vim.diff (no subprocess needed)
  if vim.diff then
    local ok, result = pcall(vim.diff, old_text, new_text, {
      result_type   = "unified",
      ctxlen        = context,
      ignore_cr_at_eol = true,
    })
    if ok and result then
      -- vim.diff doesn't add --- / +++ headers; prepend them
      local header = string.format(
        "--- %s\n+++ %s\n",
        old_label, new_label
      )
      return header .. result
    end
  end

  -- Fallback: shell out to diff(1)
  local old_file = vim.fn.tempname()
  local new_file = vim.fn.tempname()

  vim.fn.writefile(vim.split(old_text, "\n"), old_file)
  vim.fn.writefile(vim.split(new_text, "\n"), new_file)

  local cmd = string.format(
    "diff -u --label '%s' --label '%s' '%s' '%s'",
    old_label, new_label, old_file, new_file
  )
  local result = vim.fn.system(cmd)

  vim.fn.delete(old_file)
  vim.fn.delete(new_file)

  -- diff exits 1 when files differ (not an error)
  return result or ""
end

--- Generate a diff between an artifact's content and a buffer's current content.
--- @param artifact table  Result from results.extract() — must have .content and .path
--- @param bufnr number|nil  Target buffer (auto-detected from artifact.path if nil)
--- @return string  Diff text
--- @return string|nil  Error
function M.generate_for_artifact(artifact, bufnr)
  local new_content = artifact.content
  if not new_content then
    return "", "artifact has no content"
  end

  -- Find or read the original
  local old_text
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    old_text = table.concat(lines, "\n")
  elseif artifact.path then
    local abs = vim.fn.fnamemodify(artifact.path, ":p")
    if vim.fn.filereadable(abs) == 1 then
      old_text = table.concat(vim.fn.readfile(abs), "\n")
    end
  end

  if not old_text then
    -- New file — diff against empty
    old_text = ""
  end

  local path_label = artifact.path or "buffer"
  return M.generate(old_text, new_content, {
    old_label = "a/" .. path_label,
    new_label = "b/" .. path_label,
  }), nil
end

-- ── Hunk application ──────────────────────────────────────────────────────────

--- Apply a single diff hunk to a buffer, preserving undo history.
--- @param bufnr number
--- @param hunk table  { old_start, old_count, new_start, new_count, lines[] }
--- @return boolean ok, string|nil error
function M.apply_hunk(bufnr, hunk)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "buffer is not valid"
  end

  local old_start = hunk.old_start - 1  -- convert to 0-indexed
  local old_end   = old_start + hunk.old_count

  -- Build the replacement lines (lines prefixed with " " or "+", strip prefix)
  local new_lines = {}
  for _, line in ipairs(hunk.lines) do
    local prefix = line:sub(1, 1)
    if prefix == "+" or prefix == " " then
      table.insert(new_lines, line:sub(2))
    end
    -- "-" lines are deleted (not included)
  end

  -- Wrap in undojoin so all hunks in one accept are a single undo step
  local ok, err = pcall(function()
    vim.api.nvim_buf_set_lines(bufnr, old_start, old_end, false, new_lines)
  end)

  if not ok then
    return false, "apply_hunk: nvim_buf_set_lines failed: " .. tostring(err)
  end

  return true, nil
end

--- Apply all hunks from an artifact's diff to the target buffer.
--- Hunks are applied in reverse order (bottom-up) so earlier line numbers stay valid.
---
--- @param artifact table  Must have .hunks (list of Hunk)
--- @param bufnr number
--- @return boolean ok, string|nil error
function M.apply_artifact(artifact, bufnr)
  if not artifact.hunks or #artifact.hunks == 0 then
    -- No diff hunks — replace the whole buffer with artifact.content
    if artifact.content then
      local lines = vim.split(artifact.content, "\n", { plain = true })
      local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
      if not ok then return false, tostring(err) end
      log.info("diff.apply_artifact: replaced entire buffer", { bufnr = bufnr })
      return true, nil
    end
    return false, "artifact has no hunks and no content"
  end

  -- Apply hunks bottom-up to preserve line numbers
  local sorted = vim.list_slice(artifact.hunks, 1, #artifact.hunks)
  table.sort(sorted, function(a, b) return a.old_start > b.old_start end)

  -- Use undojoin to batch all hunk applications into one undo step
  -- (undojoin requires normal mode; we use a pcall so it doesn't crash if unavailable)
  pcall(vim.cmd, "undojoin")

  for _, hunk in ipairs(sorted) do
    local ok, err = M.apply_hunk(bufnr, hunk)
    if not ok then
      log.error("diff.apply_artifact: hunk failed", { err = err, hunk = hunk.old_start })
      return false, err
    end
  end

  log.info("diff.apply_artifact: applied hunks", {
    bufnr = bufnr,
    hunks = #sorted,
  })
  return true, nil
end

--- Write an artifact's content to disk (for new files or explicit save).
--- @param artifact table
--- @return boolean ok, string|nil error
function M.write_to_disk(artifact)
  if not artifact.path then
    return false, "artifact has no path"
  end
  if not artifact.content then
    return false, "artifact has no content"
  end

  local abs  = vim.fn.fnamemodify(artifact.path, ":p")
  local dir  = vim.fn.fnamemodify(abs, ":h")
  vim.fn.mkdir(dir, "p")

  local lines = vim.split(artifact.content, "\n", { plain = true })
  local ok    = vim.fn.writefile(lines, abs) == 0
  if not ok then
    return false, "writefile failed for " .. abs
  end

  log.info("diff.write_to_disk", { path = abs })
  return true, nil
end

return M
