-- ui/notify.lua — Streaming UX, spinners, virtual text, and sign column indicators.
--
-- Provides:
--   - Spinner in the statusline / notify for in-flight agents
--   - Virtual text on buffer lines being modified by an active agent
--   - Sign column indicators (running ●, done ✓, failed ✗)

local M = {}

local log    = require("agentflow.util.log")
local events = require("agentflow.util.events")

-- ── Namespace ─────────────────────────────────────────────────────────────────

local NS = vim.api.nvim_create_namespace("agentflow_notify")

-- ── Sign definitions ──────────────────────────────────────────────────────────

local function define_signs()
  vim.fn.sign_define("AgentFlowRunning",   { text = "●", texthl = "AgentFlowRosterRunning" })
  vim.fn.sign_define("AgentFlowDone",      { text = "✓", texthl = "AgentFlowRosterCompleted" })
  vim.fn.sign_define("AgentFlowFailed",    { text = "✗", texthl = "AgentFlowRosterFailed" })
end

-- ── Spinner ───────────────────────────────────────────────────────────────────

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local _spinner = {
  timer    = nil,
  frame    = 1,
  active   = {},   -- agent_name → true
}

local function spinner_tick()
  _spinner.frame = (_spinner.frame % #SPINNER_FRAMES) + 1
  local frame    = SPINNER_FRAMES[_spinner.frame]
  local names    = vim.tbl_keys(_spinner.active)
  table.sort(names)

  if #names == 0 then
    M.spinner_stop()
    return
  end

  -- Update statusline variable (users can reference this in their statusline)
  vim.g.agentflow_spinner = frame .. " AgentFlow: " .. table.concat(names, ", ")
  vim.cmd("redrawstatus")
end

function M.spinner_start(agent_name)
  _spinner.active[agent_name] = true
  if not _spinner.timer then
    _spinner.timer = vim.loop.new_timer()
    _spinner.timer:start(0, 100, vim.schedule_wrap(spinner_tick))
  end
end

function M.spinner_stop(agent_name)
  if agent_name then
    _spinner.active[agent_name] = nil
  else
    _spinner.active = {}
  end

  if vim.tbl_isempty(_spinner.active) and _spinner.timer then
    _spinner.timer:stop()
    if not _spinner.timer:is_closing() then _spinner.timer:close() end
    _spinner.timer         = nil
    vim.g.agentflow_spinner = ""
    vim.cmd("redrawstatus")
  end
end

-- ── Virtual text ──────────────────────────────────────────────────────────────

--- Place virtual text on a buffer line indicating an agent is working on it.
--- @param bufnr number
--- @param line number  0-indexed line
--- @param agent_name string
function M.set_virtual_text(bufnr, line, agent_name)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_set_extmark(bufnr, NS, line, 0, {
    virt_text      = { { " ⟳ " .. agent_name, "AgentFlowRosterRunning" } },
    virt_text_pos  = "eol",
    priority       = 100,
  })
end

--- Clear all AgentFlow virtual text from a buffer.
--- @param bufnr number
function M.clear_virtual_text(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
end

-- ── Signs ─────────────────────────────────────────────────────────────────────

--- Place a status sign in the gutter for a buffer line.
--- @param bufnr number
--- @param line number  1-indexed
--- @param sign string  "AgentFlowRunning" | "AgentFlowDone" | "AgentFlowFailed"
function M.place_sign(bufnr, line, sign)
  pcall(vim.fn.sign_place, 0, "agentflow", sign, bufnr, { lnum = line })
end

--- Remove all AgentFlow signs from a buffer.
--- @param bufnr number
function M.clear_signs(bufnr)
  pcall(vim.fn.sign_unplace, "agentflow", { buffer = bufnr })
end

-- ── Elapsed timer display ─────────────────────────────────────────────────────

local _elapsed = {}   -- agent_name → { started_at, timer }

function M.start_elapsed(agent_name)
  if _elapsed[agent_name] then return end
  local started = vim.loop.now()
  local timer   = vim.loop.new_timer()

  timer:start(0, 1000, vim.schedule_wrap(function()
    local secs = math.floor((vim.loop.now() - started) / 1000)
    -- Update statusline variable per-agent
    vim.g["agentflow_elapsed_" .. agent_name] = secs .. "s"
  end))

  _elapsed[agent_name] = { started_at = started, timer = timer }
end

function M.stop_elapsed(agent_name)
  local entry = _elapsed[agent_name]
  if not entry then return end
  entry.timer:stop()
  if not entry.timer:is_closing() then entry.timer:close() end
  _elapsed[agent_name] = nil
  vim.g["agentflow_elapsed_" .. agent_name] = nil
end

-- ── Event subscriptions ───────────────────────────────────────────────────────

function M.setup()
  define_signs()

  events.on("agent:started", function(data)
    local agent = data and data.agent
    if not agent then return end
    M.spinner_start(agent.name)
    M.start_elapsed(agent.name)
    log.debug("notify: agent started", { name = agent.name })
  end)

  events.on("agent:completed", function(data)
    local agent = data and data.agent
    if not agent then return end
    M.spinner_stop(agent.name)
    M.stop_elapsed(agent.name)
  end)

  events.on("agent:failed", function(data)
    local agent = data and data.agent
    if not agent then return end
    M.spinner_stop(agent.name)
    M.stop_elapsed(agent.name)
    vim.schedule(function()
      vim.notify(
        "AgentFlow: agent failed — " .. agent.name .. ": " .. (data.error or "unknown"),
        vim.log.levels.ERROR
      )
    end)
  end)

  events.on("agent:retrying", function(data)
    local agent = data and data.agent
    if not agent then return end
    vim.schedule(function()
      vim.notify(
        string.format("AgentFlow: %s retrying (attempt %d, wait %dms)",
          agent.name, data.attempt or 0, data.wait_ms or 0),
        vim.log.levels.WARN
      )
    end)
  end)

  events.on("plan:created", function(data)
    local plan = data and data.plan
    if not plan then return end
    vim.schedule(function()
      vim.notify(
        string.format("AgentFlow: plan ready — %d tasks, %d parallel groups",
          #plan.tasks, #plan.execution_order),
        vim.log.levels.INFO
      )
    end)
  end)

  events.on("orchestrator:synthesized", function(data)
    local cost = data and data.cost
    if cost then
      vim.schedule(function()
        vim.notify(
          string.format(
            "AgentFlow: complete — %d agents, %d in / %d out tokens",
            cost.agent_count, cost.tokens_in, cost.tokens_out
          ),
          vim.log.levels.INFO
        )
      end)
    end
  end)
end

--- Return a statusline component string. Add %{v:lua.AgentFlowStatus()} to your statusline.
function M.statusline()
  local spinner = vim.g.agentflow_spinner
  if spinner and spinner ~= "" then
    return spinner
  end
  return ""
end

-- Expose for statusline use
_G.AgentFlowStatus = M.statusline

return M
