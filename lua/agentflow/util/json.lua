-- util/json.lua — JSON encode/decode wrapper with error handling and pretty-print.

local M = {}

--- Encode a Lua value to a JSON string.
--- @param value any
--- @param pretty boolean|nil  If true, indent with 2 spaces (uses vim.fn.json_encode + post-process)
--- @return string|nil, string|nil  encoded, error_message
function M.encode(value, pretty)
  local ok, result = pcall(vim.fn.json_encode, value)
  if not ok then
    return nil, "json.encode failed: " .. tostring(result)
  end
  if pretty then
    -- Neovim's json_encode produces compact output; run through a prettifier
    local ok2, decoded = pcall(vim.fn.json_decode, result)
    if ok2 then
      -- Re-encode via a simple indenter (no external deps)
      result = M._pretty(decoded, 0)
    end
  end
  return result, nil
end

--- Decode a JSON string into a Lua value.
--- @param str string
--- @return any|nil, string|nil  value, error_message
function M.decode(str)
  if type(str) ~= "string" or str == "" then
    return nil, "json.decode: input must be a non-empty string"
  end
  local ok, result = pcall(vim.fn.json_decode, str)
  if not ok then
    return nil, "json.decode failed: " .. tostring(result)
  end
  return result, nil
end

--- Extract the first JSON object or array from a string that may contain
--- surrounding text (e.g. a code fence or prose). Returns the raw JSON string.
--- @param str string
--- @return string|nil, string|nil  raw_json, error_message
function M.extract(str)
  -- Try fenced code block first: ```json ... ``` or ``` ... ```
  local fenced = str:match("```[a-z]*\n(.-)\n```")
  if fenced then
    -- Validate it looks like JSON
    local trimmed = fenced:match("^%s*(.-)%s*$")
    if trimmed:sub(1, 1) == "{" or trimmed:sub(1, 1) == "[" then
      return trimmed, nil
    end
  end

  -- Fallback: find the first { or [ and extract a balanced block
  local start_brace = str:find("{")
  local start_bracket = str:find("%[")
  local start = nil
  local open_char, close_char

  if start_brace and (not start_bracket or start_brace < start_bracket) then
    start = start_brace
    open_char, close_char = "{", "}"
  elseif start_bracket then
    start = start_bracket
    open_char, close_char = "[", "]"
  end

  if not start then
    return nil, "json.extract: no JSON object or array found"
  end

  local depth = 0
  local in_string = false
  local escape_next = false

  for i = start, #str do
    local ch = str:sub(i, i)
    if escape_next then
      escape_next = false
    elseif ch == "\\" and in_string then
      escape_next = true
    elseif ch == '"' then
      in_string = not in_string
    elseif not in_string then
      if ch == open_char then
        depth = depth + 1
      elseif ch == close_char then
        depth = depth - 1
        if depth == 0 then
          return str:sub(start, i), nil
        end
      end
    end
  end

  return nil, "json.extract: unbalanced JSON structure"
end

--- Simple recursive pretty-printer (no external deps).
--- @param value any
--- @param depth number
--- @return string
function M._pretty(value, depth)
  local indent = string.rep("  ", depth)
  local inner  = string.rep("  ", depth + 1)
  local t = type(value)

  if t == "table" then
    -- Detect array vs object
    local is_array = #value > 0
    if is_array then
      local parts = {}
      for _, v in ipairs(value) do
        table.insert(parts, inner .. M._pretty(v, depth + 1))
      end
      if #parts == 0 then return "[]" end
      return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
    else
      local parts = {}
      for k, v in pairs(value) do
        local key = M._pretty(tostring(k), 0)
        table.insert(parts, inner .. key .. ": " .. M._pretty(v, depth + 1))
      end
      if #parts == 0 then return "{}" end
      return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
  elseif t == "string" then
    -- Escape and quote
    local escaped = value:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\t', '\\t')
    return '"' .. escaped .. '"'
  elseif t == "number" or t == "boolean" then
    return tostring(value)
  elseif value == nil then
    return "null"
  else
    return '"' .. tostring(value) .. '"'
  end
end

return M
