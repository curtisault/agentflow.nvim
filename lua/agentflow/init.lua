-- agentflow/init.lua — Plugin entry point
-- Usage: require("agentflow").setup(opts)

local M = {}

local log    = require("agentflow.util.log")
local config = require("agentflow.config")
local events = require("agentflow.util.events")

-- Singleton state
local _initialized   = false
local _orchestrator  = nil   -- active Orchestrator instance

-- ── Setup ────────────────────────────────────────────────────────────────────

--- Main setup function. Call once from your Neovim config.
--- @param opts table|nil  User config (merged with defaults)
function M.setup(opts)
  if _initialized then
    log.warn("agentflow.setup() called more than once — ignoring")
    return
  end

  -- Merge and validate config
  local cfg, errors = config.setup(opts or {})
  if errors and #errors > 0 then
    for _, err in ipairs(errors) do
      vim.notify("AgentFlow config error: " .. err, vim.log.levels.ERROR)
    end
    return
  end

  -- Boot logger with user preferences
  log.setup(cfg.log or {})
  log.info("AgentFlow initializing")

  -- Bootstrap agent registry from config
  require("agentflow.agents").setup_from_config()

  -- Create the orchestrator singleton (exposed as M._orchestrator for UI access)
  _orchestrator  = require("agentflow.orchestrator").new(cfg)
  M._orchestrator = _orchestrator

  -- Boot notification / streaming UX system
  require("agentflow.ui.notify").setup()

  -- Set up session auto-save
  require("agentflow.persistence").setup_autosave(_orchestrator)

  -- Register User autocommands for extensibility hooks
  require("agentflow.extensions").setup_autocommands()

  -- Wire UI roster to event bus
  events.on("agent:state_changed", function(_)
    local ok, roster = pcall(require, "agentflow.ui.roster")
    if ok then vim.schedule(function() roster.refresh() end) end
  end)

  -- Register commands
  M._register_commands()

  -- Register keymaps
  M._register_keymaps()

  _initialized = true
  log.info("AgentFlow ready")
end

-- ── Commands ─────────────────────────────────────────────────────────────────

function M._register_commands()
  -- :AgentFlow            → open hub
  -- :AgentFlow {prompt}   → start workflow with prompt
  vim.api.nvim_create_user_command("AgentFlow", function(cmd_opts)
    if cmd_opts.args and cmd_opts.args ~= "" then
      M.start(cmd_opts.args)
    else
      M.hub()
    end
  end, {
    nargs = "?",
    desc = "Open AgentFlow hub or start a workflow with a prompt",
  })

  vim.api.nvim_create_user_command("AgentChat", function()
    M.chat()
  end, { desc = "Open AgentFlow chat pane" })

  vim.api.nvim_create_user_command("AgentTree", function()
    M.tree()
  end, { desc = "Open AgentFlow agent tree view" })

  vim.api.nvim_create_user_command("AgentRoster", function()
    M.roster()
  end, { desc = "Open AgentFlow agent roster" })

  vim.api.nvim_create_user_command("AgentDash", function()
    M.dashboard()
  end, { desc = "Open AgentFlow dashboard view" })

  vim.api.nvim_create_user_command("AgentGrid", function()
    M.grid()
  end, { desc = "Open AgentFlow grid view" })

  vim.api.nvim_create_user_command("AgentConfig", function()
    M.config_panel()
  end, { desc = "Open AgentFlow configuration panel" })

  vim.api.nvim_create_user_command("AgentReview", function()
    M.review()
  end, { desc = "Open AgentFlow review panel" })

  vim.api.nvim_create_user_command("AgentLog", function(cmd_opts)
    if cmd_opts.args and cmd_opts.args ~= "" then
      log.info("Showing log for agent: " .. cmd_opts.args)
    end
    log.open()
  end, {
    nargs = "?",
    desc = "Show AgentFlow log buffer (optionally filter by agent name)",
  })

  vim.api.nvim_create_user_command("AgentKill", function(cmd_opts)
    M.kill(cmd_opts.args)
  end, {
    nargs = 1,
    desc = "Terminate an agent and its subtree",
  })

  vim.api.nvim_create_user_command("AgentAdd", function(cmd_opts)
    -- args: "{name} {model}"
    local parts = vim.split(cmd_opts.args, "%s+", { trimempty = true })
    if #parts < 2 then
      vim.notify("Usage: :AgentAdd {name} {model}", vim.log.levels.ERROR)
      return
    end
    M.add_agent(parts[1], parts[2])
  end, {
    nargs = "+",
    desc = "Register a new agent by name and model",
  })

  vim.api.nvim_create_user_command("AgentPick", function()
    M.pick_agent()
  end, { desc = "Open picker to select an agent" })

  vim.api.nvim_create_user_command("AgentSessions", function()
    M.pick_session()
  end, { desc = "Browse and resume saved AgentFlow sessions" })

  vim.api.nvim_create_user_command("AgentSave", function()
    M.save_session()
  end, { desc = "Save current AgentFlow session to disk" })
end

-- ── Keymaps ──────────────────────────────────────────────────────────────────

function M._register_keymaps()
  local cfg = config.get()
  if not cfg.keymaps or cfg.keymaps.enabled == false then return end

  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { desc = desc, silent = true })
  end

  map("<leader>af", M.hub,         "AgentFlow: open hub")
  map("<leader>ap", function()
    vim.ui.input({ prompt = "AgentFlow prompt: " }, function(input)
      if input and input ~= "" then M.start(input) end
    end)
  end, "AgentFlow: start with prompt")
  map("<leader>as", M.tree,        "AgentFlow: agent tree")
  map("<leader>ac", M.config_panel,"AgentFlow: config panel")
  map("<leader>ar", M.review,      "AgentFlow: review panel")
end

-- ── Public actions ────────────────────────────────────────────────────────────

--- Start a full agentic workflow.
--- Opens the chat pane and runs the orchestrator in the background.
function M.start(prompt)
  if not _orchestrator then
    vim.notify("AgentFlow: not initialized — call setup() first", vim.log.levels.ERROR)
    return
  end

  log.info("Starting workflow", { prompt = prompt })
  vim.notify("AgentFlow: workflow starting…", vim.log.levels.INFO)

  local async = require("agentflow.util.async")
  async.run(function()
    local result, err = _orchestrator:run(prompt, {
      on_token = function(token)
        -- Future: stream to chat UI
        _ = token
      end,
      on_plan = function(plan)
        vim.schedule(function()
          vim.notify(
            string.format("AgentFlow: plan ready — %d tasks in %d groups",
              #plan.tasks, #plan.execution_order),
            vim.log.levels.INFO
          )
          events.emit("plan:created", { plan = plan })
        end)
      end,
      on_complete = function(final)
        vim.schedule(function()
          local cost = _orchestrator:get_cost()
          vim.notify(
            string.format(
              "AgentFlow: workflow complete — %d agents, %d tokens in / %d out",
              cost.agent_count, cost.tokens_in, cost.tokens_out
            ),
            vim.log.levels.INFO
          )
          events.emit("orchestrator:synthesized", { result = final, cost = cost })
        end)
      end,
    })

    if err then
      vim.schedule(function()
        vim.notify("AgentFlow: workflow error — " .. err, vim.log.levels.ERROR)
        log.error("Workflow failed", { error = err })
      end)
    end
  end)
end

function M.hub()
  log.debug("Opening hub")
  require("agentflow.ui.hub").open()
end

function M.chat()
  log.debug("Opening chat")
  local ok, chat_ui = pcall(require, "agentflow.ui.chat")
  if ok then
    chat_ui.open()
  else
    vim.notify("AgentFlow: chat UI not yet built", vim.log.levels.INFO)
  end
end

function M.tree()
  log.debug("Opening tree view")
  require("agentflow.ui.tree").open()
end

function M.roster()
  log.debug("Opening roster")
  require("agentflow.ui.roster").open()
end

function M.dashboard()
  log.debug("Opening dashboard")
  require("agentflow.ui.dashboard").open()
end

function M.grid()
  log.debug("Opening grid view")
  require("agentflow.ui.grid").open()
end

function M.config_panel()
  log.debug("Opening config panel")
  vim.notify("AgentFlow: config panel (Phase 6)", vim.log.levels.INFO)
end

function M.review()
  log.debug("Opening review panel")
  local review_ui = require("agentflow.ui.review")
  local queue     = review_ui.get_queue()
  if #queue > 0 then
    review_ui.open(queue)
  else
    vim.notify("AgentFlow: no results queued for review", vim.log.levels.INFO)
  end
end

--- Expose orchestrator for hub/tree/grid to access live state.
function M._get_orchestrator() return _orchestrator end

function M.status()
  if not _orchestrator then
    vim.notify("AgentFlow: not initialized", vim.log.levels.WARN)
    return
  end
  local cost = _orchestrator:get_cost()
  local plan = _orchestrator:get_plan()
  local msg = string.format(
    "AgentFlow status — agents: %d | tokens in: %d | tokens out: %d | tasks: %s",
    cost.agent_count,
    cost.tokens_in,
    cost.tokens_out,
    plan and (#plan.tasks .. " in plan") or "no active plan"
  )
  vim.notify(msg, vim.log.levels.INFO)
  log.info("Status", { cost = cost })
end

function M.cancel()
  if _orchestrator and _orchestrator._pool then
    _orchestrator._pool:cancel_all()
    _orchestrator:reset()
    vim.notify("AgentFlow: workflow cancelled", vim.log.levels.WARN)
  else
    vim.notify("AgentFlow: nothing to cancel", vim.log.levels.INFO)
  end
end

function M.kill(agent_name)
  log.warn("Kill requested", { agent = agent_name })
  vim.notify("AgentFlow: :AgentKill not yet wired to live agent tree (Phase 5)", vim.log.levels.WARN)
end

function M.add_agent(name, model)
  local registry = require("agentflow.agents")
  registry.register({ name = name, model = model, backend = "cli", role = "subagent" })
  vim.notify("AgentFlow: registered agent '" .. name .. "' (" .. model .. ")", vim.log.levels.INFO)
end

function M.pick_agent()
  log.debug("Pick agent requested")
  local registry = require("agentflow.agents")
  local picker   = require("agentflow.ui.picker")
  picker.pick_agent(registry.list(), function(agent_cfg)
    vim.notify("AgentFlow: selected agent " .. agent_cfg.name, vim.log.levels.INFO)
  end)
end

function M.pick_session()
  local persistence = require("agentflow.persistence")
  local picker      = require("agentflow.ui.picker")
  local sessions    = persistence.list_sessions()
  if #sessions == 0 then
    vim.notify("AgentFlow: no saved sessions found", vim.log.levels.INFO)
    return
  end
  local items = vim.tbl_map(function(s)
    return {
      text  = string.format("%s  %s  agents:%d",
        s.id, s.model, s.cost and s.cost.agent_count or 0),
      value = s.id,
    }
  end, sessions)
  picker.pick(items, { prompt = "Resume session" }, function(item)
    local async = require("agentflow.util.async")
    async.run(function()
      local ok = persistence.load(_orchestrator, item.value)
      vim.schedule(function()
        if ok then
          vim.notify("AgentFlow: session " .. item.value .. " loaded", vim.log.levels.INFO)
        else
          vim.notify("AgentFlow: failed to load session " .. item.value, vim.log.levels.ERROR)
        end
      end)
    end)
  end)
end

function M.save_session()
  local persistence = require("agentflow.persistence")
  local id = persistence.save(_orchestrator)
  vim.notify("AgentFlow: session saved as " .. id, vim.log.levels.INFO)
end

return M
