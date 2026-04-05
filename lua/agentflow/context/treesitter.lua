-- context/treesitter.lua — AST-aware context extraction via nvim-treesitter.
--
-- Walks up the treesitter node tree from the cursor to find the enclosing
-- function, class/module, or falls back to the full file.

local M = {}

local log = require("agentflow.util.log")

-- ── Node type sets ────────────────────────────────────────────────────────────

-- Node types that count as a "function" scope across common languages.
local FUNCTION_TYPES = {
  -- Lua
  ["function_definition"]   = true,
  ["function_declaration"]  = true,
  ["local_function"]        = true,
  ["method_definition"]     = true,
  -- Python
  ["function_def"]          = true,
  ["async_function_def"]    = true,
  -- JavaScript / TypeScript
  ["function"]              = true,
  ["arrow_function"]        = true,
  ["method_definition"]     = true,
  ["function_expression"]   = true,
  -- Go
  ["function_declaration"]  = true,
  ["method_declaration"]    = true,
  -- Rust
  ["function_item"]         = true,
  -- Ruby
  ["method"]                = true,
  ["singleton_method"]      = true,
  -- Elixir
  ["function"]              = true,
  ["def"]                   = true,
}

-- Node types that count as a "class" scope.
local CLASS_TYPES = {
  -- General OOP
  ["class_definition"]      = true,
  ["class_declaration"]     = true,
  ["class_body"]            = true,
  -- Python
  ["class_def"]             = true,
  -- JavaScript / TypeScript
  ["class_declaration"]     = true,
  ["class"]                 = true,
  -- Ruby
  ["class"]                 = true,
  ["module"]                = true,
  -- Rust
  ["impl_item"]             = true,
  ["struct_item"]           = true,
  ["enum_item"]             = true,
  -- Go
  ["type_declaration"]      = true,
  -- Elixir
  ["defmodule"]             = true,
  ["module"]                = true,
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function has_treesitter(bufnr)
  -- Check if a parser is available for this buffer's filetype
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  return ok and parser ~= nil
end

local function node_text(node, bufnr)
  if not node then return nil end
  local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
  if not ok then return nil end
  return text
end

local function node_range_info(node)
  local sr, sc, er, ec = node:range()  -- 0-indexed
  return { start_line = sr + 1, start_col = sc, end_line = er + 1, end_col = ec }
end

--- Walk up from `node` until we find a node whose type is in `type_set`.
--- Returns the first matching ancestor (or the node itself).
local function find_ancestor(node, type_set)
  local cur = node
  while cur do
    if type_set[cur:type()] then
      return cur
    end
    cur = cur:parent()
  end
  return nil
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Get the source text of the enclosing scope at the cursor.
---
--- @param scope string  "function" | "class" | "file"
--- @param bufnr number|nil  Buffer to query (defaults to current)
--- @return table|nil {
---   text, scope, node_type, range { start_line, end_line }, filetype
--- }
function M.get_scope(scope, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })

  if scope == "file" then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return {
      text      = table.concat(lines, "\n"),
      scope     = "file",
      node_type = "file",
      range     = { start_line = 1, end_line = #lines },
      filetype  = filetype,
    }
  end

  if not has_treesitter(bufnr) then
    log.debug("context/treesitter: no parser for buffer", { bufnr = bufnr, ft = filetype })
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)  -- {row, col} 1-indexed
  local row    = cursor[1] - 1  -- 0-indexed for treesitter
  local col    = cursor[2]

  local node = vim.treesitter.get_node({ bufnr = bufnr, pos = { row, col } })
  if not node then
    log.debug("context/treesitter: no node at cursor")
    return nil
  end

  local type_set = scope == "class" and CLASS_TYPES or FUNCTION_TYPES
  local target   = find_ancestor(node, type_set)

  if not target then
    log.debug("context/treesitter: no enclosing " .. scope .. " found")
    return nil
  end

  local text = node_text(target, bufnr)
  if not text then return nil end

  local range = node_range_info(target)

  log.debug("context/treesitter: found scope", {
    scope     = scope,
    node_type = target:type(),
    lines     = range.start_line .. "-" .. range.end_line,
  })

  return {
    text      = text,
    scope     = scope,
    node_type = target:type(),
    range     = range,
    filetype  = filetype,
  }
end

--- Format a scope result for prompt injection.
--- @param scope_info table  Result from get_scope()
--- @param label string|nil
--- @return string
function M.format(scope_info, label)
  if not scope_info then return "" end

  label = label or ("Enclosing " .. scope_info.scope)
  local parts = {}

  table.insert(parts, string.format(
    "### %s (lines %d–%d, node: `%s`)",
    label,
    scope_info.range.start_line,
    scope_info.range.end_line,
    scope_info.node_type
  ))
  table.insert(parts, "")
  table.insert(parts, "```" .. (scope_info.filetype or ""))
  table.insert(parts, scope_info.text)
  table.insert(parts, "```")

  return table.concat(parts, "\n")
end

return M
