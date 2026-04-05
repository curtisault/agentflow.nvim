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

--- Scan .agentflow/agents/*.json in the current working directory and register
--- any valid agent definitions found. Called after setup_from_config() so that
--- project-local agents can override config-defined ones by name.
function M.load_from_project_dir()
  local dir   = vim.fn.getcwd() .. "/.agentflow/agents"
  local files = vim.fn.glob(dir .. "/*.json", false, true)
  local count = 0
  for _, path in ipairs(files) do
    local raw = vim.fn.readfile(path)
    if raw and #raw > 0 then
      local ok, parsed = pcall(vim.fn.json_decode, table.concat(raw, "\n"))
      if ok and type(parsed) == "table" and parsed.name and parsed.model then
        M.register(parsed)
        count = count + 1
      else
        log.warn("agents: skipping invalid project agent file", { path = path })
      end
    end
  end
  if count > 0 then
    log.info("agents: loaded project-local agents", { count = count, dir = dir })
  end
end

--- Bootstrap the registry from the user config.
--- Called automatically by agentflow.setup().
function M.setup_from_config()
  local config = require("agentflow.config")
  local cfg = config.get()
  for _, agent_cfg in ipairs(cfg.agents or {}) do
    M.register(agent_cfg)
  end
  M.load_from_project_dir()
  log.info("Agent registry initialized", { count = #M.list() })
end

return M
