-- ui/picker.lua — Picker abstraction layer.
--
-- Auto-detects the installed picker and delegates to it.
-- Detection priority (configurable in config.ui.picker):
--   mini.pick → telescope → fzf-lua → vim.ui.select
--
-- Common interface:
--   picker.pick(items, opts, on_select)
--   items:     { text: string, value: any }[]
--   opts:      { prompt?: string, previewer?: fun(item) → string }
--   on_select: fun(item)

local M = {}

local log = require("agentflow.util.log")

-- ── Backend detection ─────────────────────────────────────────────────────────

local function has(mod)
  return pcall(require, mod)
end

local function detect_backend()
  local cfg_backend = nil
  local ok, cfg = pcall(function()
    return require("agentflow.config").get().ui.picker
  end)
  if ok then cfg_backend = cfg end

  if cfg_backend then return cfg_backend end

  if has("mini.pick")   then return "mini.pick"    end
  if has("telescope")   then return "telescope"     end
  if has("fzf-lua")     then return "fzf-lua"       end
  return "vim.ui.select"
end

-- ── Backend adapters ──────────────────────────────────────────────────────────

local function pick_mini(items, opts, on_select)
  local MiniPick = require("mini.pick")

  local mini_items = vim.tbl_map(function(item)
    return { text = item.text, _value = item.value or item }
  end, items)

  local source = {
    items  = mini_items,
    name   = opts.prompt or "AgentFlow",
    choose = function(chosen)
      if chosen then on_select({ text = chosen.text, value = chosen._value }) end
    end,
  }

  if opts.previewer then
    source.preview = function(buf, item)
      if not item then return end
      local preview_text = opts.previewer({ text = item.text, value = item._value })
      if preview_text then
        local lines = vim.split(preview_text, "\n", { plain = true })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      end
    end
  end

  MiniPick.start({ source = source })
end

local function pick_telescope(items, opts, on_select)
  local pickers  = require("telescope.pickers")
  local finders  = require("telescope.finders")
  local conf     = require("telescope.config").values
  local actions  = require("telescope.actions")
  local state    = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = opts.prompt or "AgentFlow",
    finder       = finders.new_table({
      results = items,
      entry_maker = function(item)
        return {
          value   = item,
          display = item.text,
          ordinal = item.text,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local selection = state.get_selected_entry(prompt_bufnr)
        actions.close(prompt_bufnr)
        if selection then on_select(selection.value) end
      end)
      return true
    end,
  }):find()
end

local function pick_fzf(items, opts, on_select)
  local fzf = require("fzf-lua")

  local texts = vim.tbl_map(function(i) return i.text end, items)
  local by_text = {}
  for _, item in ipairs(items) do by_text[item.text] = item end

  fzf.fzf_exec(texts, {
    prompt  = (opts.prompt or "AgentFlow") .. "> ",
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          on_select(by_text[selected[1]] or { text = selected[1] })
        end
      end,
    },
  })
end

local function pick_ui_select(items, opts, on_select)
  local display = vim.tbl_map(function(i) return i.text end, items)
  local by_text = {}
  for _, item in ipairs(items) do by_text[item.text] = item end

  vim.ui.select(display, {
    prompt  = opts.prompt or "AgentFlow",
    format_item = function(t) return t end,
  }, function(choice)
    if choice then
      on_select(by_text[choice] or { text = choice })
    end
  end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Open a picker with the given items.
---
--- @param items table[]  { text: string, value: any }
--- @param opts  table    { prompt?: string, previewer?: fun(item) → string }
--- @param on_select function  Called with the chosen item
function M.pick(items, opts, on_select)
  opts = opts or {}

  if not items or #items == 0 then
    vim.notify("AgentFlow: picker has no items", vim.log.levels.INFO)
    return
  end

  local backend = detect_backend()
  log.debug("picker: using backend", { backend = backend })

  if backend == "mini.pick" then
    pick_mini(items, opts, on_select)
  elseif backend == "telescope" then
    pick_telescope(items, opts, on_select)
  elseif backend == "fzf-lua" then
    pick_fzf(items, opts, on_select)
  else
    pick_ui_select(items, opts, on_select)
  end
end

--- Convenience: pick from a list of agent names.
--- Provides a live previewer showing the agent's conversation log.
--- @param agents table[]  Agent config list or live agent objects
--- @param on_select function  Called with chosen agent
function M.pick_agent(agents, on_select)
  local items = vim.tbl_map(function(a)
    local state = a.state or "idle"
    local dot   = ({ idle = "○", running = "●", completed = "✓", failed = "✗" })[state] or "?"
    return {
      text  = string.format("%s %s  (%s / %s)",
        dot, a.name, a.model or "?", a.backend or "cli"),
      value = a,
    }
  end, agents)

  M.pick(items, {
    prompt = "Select agent",
    -- Live previewer: show conversation log or config details
    previewer = function(item)
      local a = item.value
      local lines = {}
      table.insert(lines, "Name:    " .. (a.name or "?"))
      table.insert(lines, "Model:   " .. (a.model or "?"))
      table.insert(lines, "Backend: " .. (a.backend or "cli"))
      table.insert(lines, "State:   " .. (a.state or "idle"))
      if a.metrics then
        table.insert(lines, string.format(
          "Tokens:  %d in / %d out  (%dms)",
          a.metrics.tokens_in or 0,
          a.metrics.tokens_out or 0,
          a.metrics.duration_ms or 0
        ))
      end
      if a.history and #a.history > 0 then
        table.insert(lines, "")
        table.insert(lines, "--- Last message ---")
        local last = a.history[#a.history]
        for _, l in ipairs(vim.split((last.content or ""):sub(1, 400), "\n")) do
          table.insert(lines, l)
        end
      end
      return table.concat(lines, "\n")
    end,
  }, function(item)
    on_select(item.value)
  end)
end

--- Multi-select picker (falls back to repeated single-select for vim.ui.select).
--- @param items table[]  { text, value }
--- @param opts table  { prompt? }
--- @param on_select function  Called with table[] of chosen items
function M.pick_multi(items, opts, on_select)
  opts = opts or {}
  local backend = detect_backend()

  -- mini.pick and telescope support multi-select natively
  if backend == "telescope" then
    local pickers  = require("telescope.pickers")
    local finders  = require("telescope.finders")
    local conf     = require("telescope.config").values
    local actions  = require("telescope.actions")
    local state    = require("telescope.actions.state")

    pickers.new({}, {
      prompt_title = opts.prompt or "AgentFlow (multi)",
      finder       = finders.new_table({
        results     = items,
        entry_maker = function(item)
          return { value = item, display = item.text, ordinal = item.text }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map_fn)
        actions.select_default:replace(function()
          local picker_state = state.get_current_picker(prompt_bufnr)
          local multi        = picker_state:get_multi_selection()
          actions.close(prompt_bufnr)
          if #multi > 0 then
            on_select(vim.tbl_map(function(e) return e.value end, multi))
          else
            local sel = state.get_selected_entry(prompt_bufnr)
            if sel then on_select({ sel.value }) end
          end
        end)
        map_fn("i", "<Tab>", actions.toggle_selection + actions.move_selection_worse)
        map_fn("n", "<Tab>", actions.toggle_selection + actions.move_selection_worse)
        return true
      end,
    }):find()
  else
    -- Fallback: single pick
    M.pick(items, opts, function(item) on_select({ item }) end)
  end
end

--- Convenience: pick from a list of strings.
--- @param strings string[]
--- @param prompt string
--- @param on_select function  Called with chosen string
function M.pick_string(strings, prompt, on_select)
  local items = vim.tbl_map(function(s) return { text = s, value = s } end, strings)
  M.pick(items, { prompt = prompt }, function(item) on_select(item.value) end)
end

--- Session browser: pick from saved sessions with summary preview.
--- @param on_select function  Called with chosen session { id, saved_at, cost, model }
function M.pick_session(on_select)
  local persistence = require("agentflow.persistence")
  local sessions    = persistence.list_sessions()

  if #sessions == 0 then
    vim.notify("AgentFlow: no saved sessions", vim.log.levels.INFO)
    return
  end

  local items = vim.tbl_map(function(s)
    return {
      text  = string.format("%s  %s  agents:%d  tok:%d",
        s.id, s.model or "?",
        s.cost and s.cost.agent_count or 0,
        s.cost and (s.cost.tokens_in + s.cost.tokens_out) or 0),
      value = s,
    }
  end, sessions)

  M.pick(items, {
    prompt = "Resume session",
    previewer = function(item)
      local s = item.value
      local lines = {
        "Session: " .. s.id,
        "Saved:   " .. (s.saved_at or "?"),
        "Model:   " .. (s.model or "?"),
      }
      if s.cost then
        table.insert(lines, string.format(
          "Agents:  %d  |  Tokens: %d in / %d out",
          s.cost.agent_count or 0, s.cost.tokens_in or 0, s.cost.tokens_out or 0
        ))
      end
      return table.concat(lines, "\n")
    end,
  }, function(item)
    on_select(item.value)
  end)
end

return M
