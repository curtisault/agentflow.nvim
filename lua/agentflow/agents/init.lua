-- agents/init.lua — Agent registry and lifecycle manager.
--
-- Holds all configured agents. Agents are registered at setup() time from config
-- and can be added dynamically at runtime.

local M = {}

local log = require("agentflow.util.log")

-- ── Registry ──────────────────────────────────────────────────────────────────

local _registry = {}   -- name → agent_config table

--- Register an agent from a config entry.
--- @param agent_config table { name, model, backend, role?, max_tokens?, endpoint?, ... }
function M.register(agent_config)
  assert(type(agent_config.name) == "string" and agent_config.name ~= "",
    "agents.register: name is required")
  assert(type(agent_config.model) == "string" and agent_config.model ~= "",
    "agents.register: model is required")

  if _registry[agent_config.name] then
    log.warn("agents.register: overwriting existing agent", { name = agent_config.name })
  end

  _registry[agent_config.name] = vim.deepcopy(agent_config)
  log.debug("Agent registered", { name = agent_config.name, model = agent_config.model })
end

--- Retrieve a registered agent config by name.
--- @param name string
--- @return table|nil
function M.get(name)
  return _registry[name]
end

--- Return all registered agent configs as a list.
--- @return table[]
function M.list()
  local out = {}
  for _, cfg in pairs(_registry) do
    table.insert(out, cfg)
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- Unregister an agent.
--- @param name string
function M.remove(name)
  if _registry[name] then
    _registry[name] = nil
    log.debug("Agent unregistered", { name = name })
  end
end

--- Clear all registered agents (used in tests / re-setup).
function M.clear()
  _registry = {}
end

--- Bootstrap the registry from the user config.
--- Called automatically by agentflow.setup().
function M.setup_from_config()
  local config = require("agentflow.config")
  local cfg = config.get()
  for _, agent_cfg in ipairs(cfg.agents or {}) do
    M.register(agent_cfg)
  end
  log.info("Agent registry initialized", { count = #M.list() })
end

return M
