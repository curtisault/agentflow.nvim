-- context/lsp.lua — LSP symbols, diagnostics, and references.
-- Uses vim.lsp.buf_request_sync so it can be called from both sync and async contexts.
-- Gracefully handles: no LSP client, request timeout, multiple clients.

local M = {}

local log = require("agentflow.util.log")

local LSP_TIMEOUT = 3000  -- ms; LSP requests can be slow on large projects

-- ── Helpers ───────────────────────────────────────────────────────────────────

--- Return active LSP clients for a buffer (handles both Neovim 0.9 and 0.10+ APIs).
local function get_clients(bufnr)
  -- Neovim 0.10+ deprecates buf_get_clients in favour of get_clients
  if vim.lsp.get_clients then
    return vim.lsp.get_clients({ bufnr = bufnr })
  else
    return vim.lsp.buf_get_clients(bufnr)
  end
end

local function has_client(bufnr)
  local clients = get_clients(bufnr)
  return clients and #clients > 0
end

--- Send a request to all clients and return the first successful result.
--- @param bufnr number
--- @param method string  LSP method name
--- @param params table
--- @return any|nil  result, string|nil error
local function request(bufnr, method, params)
  if not has_client(bufnr) then
    return nil, "no LSP client attached"
  end

  local ok, results = pcall(
    vim.lsp.buf_request_sync,
    bufnr,
    method,
    params,
    LSP_TIMEOUT
  )

  if not ok then
    return nil, "LSP request failed: " .. tostring(results)
  end

  if not results then
    return nil, "LSP request timed out or returned nil"
  end

  -- Pick the first non-nil result across clients
  for _, res in pairs(results) do
    if res.result ~= nil then
      return res.result, nil
    end
    if res.error then
      log.debug("context/lsp: client error", { err = res.error })
    end
  end

  return nil, "no LSP result"
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Get document symbols for a buffer.
--- @param bufnr number|nil  Defaults to current buffer
--- @return table[]|nil  List of SymbolInformation, or nil on failure
function M.get_symbols(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local result, err = request(bufnr, "textDocument/documentSymbol", params)

  if err then
    log.debug("context/lsp: get_symbols failed", { err = err })
    return nil
  end

  return result
end

--- Get all diagnostics for a buffer.
--- @param bufnr number|nil
--- @param severity string|nil  "error" | "warn" | "info" | "hint" | nil (all)
--- @return table[]  List of diagnostic objects
function M.get_diagnostics(bufnr, severity)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local filter = {}
  if severity then
    local sev_map = {
      error = vim.diagnostic.severity.ERROR,
      warn  = vim.diagnostic.severity.WARN,
      info  = vim.diagnostic.severity.INFO,
      hint  = vim.diagnostic.severity.HINT,
    }
    filter.severity = sev_map[severity]
  end

  local diags = vim.diagnostic.get(bufnr, filter)
  log.debug("context/lsp: diagnostics", { count = #diags, bufnr = bufnr })
  return diags
end

--- Get all references to the symbol under the cursor.
--- @param bufnr number|nil
--- @return table[]|nil  List of Location objects
function M.get_references(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local params = vim.lsp.util.make_position_params(0, nil)
  params.context = { includeDeclaration = true }

  local result, err = request(bufnr, "textDocument/references", params)
  if err then
    log.debug("context/lsp: get_references failed", { err = err })
    return nil
  end

  return result
end

--- Get hover documentation for the symbol under the cursor.
--- @param bufnr number|nil
--- @return string|nil  Markdown hover text
function M.get_hover(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local params = vim.lsp.util.make_position_params(0, nil)
  local result, err = request(bufnr, "textDocument/hover", params)

  if err or not result then
    log.debug("context/lsp: get_hover failed", { err = err })
    return nil
  end

  if type(result.contents) == "string" then
    return result.contents
  elseif type(result.contents) == "table" then
    if result.contents.value then
      return result.contents.value
    elseif result.contents[1] then
      -- MarkedString[]
      local parts = {}
      for _, item in ipairs(result.contents) do
        if type(item) == "string" then
          table.insert(parts, item)
        elseif item.value then
          table.insert(parts, item.value)
        end
      end
      return table.concat(parts, "\n")
    end
  end

  return nil
end

-- ── Formatters ────────────────────────────────────────────────────────────────

local SEVERITY_LABEL = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN]  = "WARN",
  [vim.diagnostic.severity.INFO]  = "INFO",
  [vim.diagnostic.severity.HINT]  = "HINT",
}

--- Format diagnostics for prompt injection.
--- @param diags table[]
--- @param path string|nil  File path label
--- @return string
function M.format_diagnostics(diags, path)
  if not diags or #diags == 0 then return "" end

  local parts = { "### LSP Diagnostics" .. (path and (": `" .. path .. "`") or "") }

  for _, d in ipairs(diags) do
    local sev   = SEVERITY_LABEL[d.severity] or "?"
    local src   = d.source and ("[" .. d.source .. "] ") or ""
    local line  = (d.lnum or 0) + 1  -- convert 0-indexed to 1-indexed
    table.insert(parts, string.format(
      "  %s  line %d: %s%s", sev, line, src, d.message
    ))
  end

  return table.concat(parts, "\n")
end

--- Format document symbols as a compact outline.
--- @param symbols table[]  Nested SymbolInformation / DocumentSymbol list
--- @param indent number|nil
--- @return string
function M.format_symbols(symbols, indent)
  if not symbols or #symbols == 0 then return "" end
  indent = indent or 0

  local KIND_NAME = {
    [1]  = "File",       [2]  = "Module",    [3]  = "Namespace",
    [4]  = "Package",    [5]  = "Class",      [6]  = "Method",
    [7]  = "Property",   [8]  = "Field",      [9]  = "Constructor",
    [10] = "Enum",       [11] = "Interface",  [12] = "Function",
    [13] = "Variable",   [14] = "Constant",   [15] = "String",
    [16] = "Number",     [17] = "Boolean",    [18] = "Array",
    [19] = "Object",     [20] = "Key",        [21] = "Null",
    [22] = "EnumMember", [23] = "Struct",     [24] = "Event",
    [25] = "Operator",   [26] = "TypeParameter",
  }

  local lines = {}
  local pad   = string.rep("  ", indent)

  for _, sym in ipairs(symbols) do
    local kind = KIND_NAME[sym.kind] or "?"
    local range_start = sym.range and (sym.range.start.line + 1) or "?"
    table.insert(lines, string.format(
      "%s[%s] %s  (line %s)", pad, kind, sym.name, range_start
    ))
    -- Recurse into children (DocumentSymbol has .children)
    if sym.children and #sym.children > 0 then
      table.insert(lines, M.format_symbols(sym.children, indent + 1))
    end
  end

  return table.concat(lines, "\n")
end

return M
