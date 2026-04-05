-- context/init.lua — Context builder.
--
-- Assembles a single context string from all sources (buffer, treesitter, git,
-- LSP, file tree) respecting a token budget.
--
-- Priority order (highest to lowest):
--   1. Task-required files (explicit paths in task.context_requirements.files)
--   2. Current buffer + treesitter scope
--   3. LSP diagnostics
--   4. Git diff
--   5. LSP document symbols
--   6. Alternate buffers
--   7. Project file tree

local M = {}

local log = require("agentflow.util.log")

-- ── Token estimation ──────────────────────────────────────────────────────────

--- Rough token estimate: ~4 chars per token (industry rule of thumb).
--- @param text string
--- @return number
local function estimate_tokens(text)
  return math.ceil(#text / 4)
end

-- ── Section builder ───────────────────────────────────────────────────────────

--- A section is { heading, content, tokens }.
--- We collect sections in priority order then fit as many as possible
--- within the token budget.

local function make_section(heading, content)
  if not content or content == "" then return nil end
  local text   = heading ~= "" and (heading .. "\n\n" .. content) or content
  local tokens = estimate_tokens(text)
  return { heading = heading, content = content, text = text, tokens = tokens }
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Build a context string for the given task.
--- Must be called from within a coroutine (git, file tree paths are async).
---
--- @param task table  Task object from planner.lua
--- @param cfg table   agentflow config (from config.get())
--- @return string     Assembled context (may be empty if nothing available)
function M.build(task, cfg)
  local ctx_cfg    = cfg.context or {}
  local max_tokens = ctx_cfg.max_tokens_per_agent or 12000

  local buf_mod   = require("agentflow.context.buffer")
  local ts_mod    = require("agentflow.context.treesitter")
  local git_mod   = require("agentflow.context.git")
  local lsp_mod   = require("agentflow.context.lsp")
  local files_mod = require("agentflow.context.files")

  local requirements = task.context_requirements or {}
  local sections     = {}

  -- ── 1. Task-required files ──────────────────────────────────────────────────
  if requirements.files and #requirements.files > 0 then
    for _, fpath in ipairs(requirements.files) do
      local info = files_mod.read_file(fpath)
      if info then
        local s = make_section("", files_mod.format_file(info))
        if s then table.insert(sections, s) end
      end
    end
  end

  -- ── 2. Current buffer ────────────────────────────────────────────────────────
  if ctx_cfg.include_buffers ~= false then
    local buf = buf_mod.get_current({ max_lines = 1500 })
    if buf then
      -- Use treesitter scope if available and task is function-scoped
      local scope_text = nil
      if ctx_cfg.include_treesitter ~= false then
        local scope = requirements.scope or "function"
        if scope ~= "file" then
          local ts_result = ts_mod.get_scope(scope)
          if ts_result then
            scope_text = ts_mod.format(ts_result, "Cursor scope (" .. scope .. ")")
          end
        end
      end

      if scope_text then
        local s = make_section("## Current scope", scope_text)
        if s then table.insert(sections, s) end
      else
        -- Fall back to full buffer
        local s = make_section("", buf_mod.format(buf, "Current buffer"))
        if s then table.insert(sections, s) end
      end
    end
  end

  -- ── 3. LSP diagnostics ────────────────────────────────────────────────────
  if ctx_cfg.include_lsp_symbols ~= false then
    local bufnr = vim.api.nvim_get_current_buf()
    local diags = lsp_mod.get_diagnostics(bufnr)
    if diags and #diags > 0 then
      local path = vim.api.nvim_buf_get_name(bufnr)
      local s = make_section(
        "",
        lsp_mod.format_diagnostics(diags, vim.fn.fnamemodify(path, ":."))
      )
      if s then table.insert(sections, s) end
    end
  end

  -- ── 4. Git diff ───────────────────────────────────────────────────────────
  local git_mode = ctx_cfg.include_git_diff
  if git_mode and git_mode ~= false then
    local diff = git_mod.get_diff(git_mode, { max_lines = 300 })
    if diff and (diff.diff ~= "" or diff.stat ~= "") then
      local s = make_section("", git_mod.format(diff))
      if s then table.insert(sections, s) end
    end
  end

  -- ── 5. LSP document symbols ──────────────────────────────────────────────
  if ctx_cfg.include_lsp_symbols ~= false then
    local bufnr  = vim.api.nvim_get_current_buf()
    local symbols = lsp_mod.get_symbols(bufnr)
    if symbols and #symbols > 0 then
      local outline = lsp_mod.format_symbols(symbols)
      if outline ~= "" then
        local s = make_section("### LSP symbol outline", outline)
        if s then table.insert(sections, s) end
      end
    end
  end

  -- ── 6. Alternate buffers ────────────────────────────────────────────────
  if ctx_cfg.include_buffers ~= false then
    local alts = buf_mod.get_alternates(2, { max_lines = 300 })
    for _, alt in ipairs(alts) do
      local s = make_section("", buf_mod.format(alt, "Related buffer"))
      if s then table.insert(sections, s) end
    end
  end

  -- ── 7. Project file tree ────────────────────────────────────────────────
  if ctx_cfg.include_file_tree ~= false then
    local tree = files_mod.get_tree(nil, 3)
    if tree then
      local s = make_section("", files_mod.format_tree(tree))
      if s then table.insert(sections, s) end
    end
  end

  -- ── 8. Custom context providers (extensions) ──────────────────────────────
  local ext_providers = require("agentflow.extensions").run_context_providers(task, cfg)
  for _, extra in ipairs(ext_providers) do
    local s = make_section("", extra)
    if s then table.insert(sections, s) end
  end

  -- ── Assemble within token budget ──────────────────────────────────────────

  local chosen      = {}
  local used_tokens = 0

  for _, section in ipairs(sections) do
    if used_tokens + section.tokens <= max_tokens then
      table.insert(chosen, section.text)
      used_tokens = used_tokens + section.tokens
    else
      -- Try to fit a truncated version
      local remaining_chars = (max_tokens - used_tokens) * 4
      if remaining_chars > 200 then
        local truncated = section.text:sub(1, remaining_chars) .. "\n\n*(context truncated)*"
        table.insert(chosen, truncated)
      end
      break
    end
  end

  log.debug("context/build: assembled", {
    sections     = #chosen,
    est_tokens   = used_tokens,
    max_tokens   = max_tokens,
  })

  return table.concat(chosen, "\n\n---\n\n")
end

--- Build context for a simple prompt (no task object).
--- Convenience wrapper for the chat pane.
--- @param cfg table
--- @return string
function M.build_simple(cfg)
  local dummy_task = {
    description          = "",
    context_requirements = { scope = "function" },
  }
  return M.build(dummy_task, cfg)
end

return M
