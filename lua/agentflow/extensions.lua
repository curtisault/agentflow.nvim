-- extensions.lua — Public API for user extensibility.
--
-- Allows users to register:
--   - Custom backend adapters
--   - Custom context providers
--   - Custom routing rules
--   - Custom result parsers
--
-- Also emits User autocommands so Neovim configs can hook into workflow events.

local M = {}

local log    = require("agentflow.util.log")
local events = require("agentflow.util.events")

-- ── Custom backends ───────────────────────────────────────────────────────────

local _custom_backends = {}

--- Register a custom backend adapter.
--- The adapter must implement: complete(messages, opts) → result, error
---
--- @param name string       Unique backend name (use in agent config as backend = "name")
--- @param adapter_fn function  function(agent_config) → adapter_instance
function M.register_backend(name, adapter_fn)
  assert(type(name) == "string" and name ~= "", "backend name must be a non-empty string")
  assert(type(adapter_fn) == "function", "adapter_fn must be a function")
  _custom_backends[name] = adapter_fn
  log.info("extensions: registered backend", { name = name })
end

--- Called by backend/init.lua to resolve custom backends.
--- @param name string
--- @param agent_config table
--- @return table|nil  adapter instance
function M.get_backend(name, agent_config)
  local fn = _custom_backends[name]
  if not fn then return nil end
  return fn(agent_config)
end

function M.list_backends()
  return vim.tbl_keys(_custom_backends)
end

-- ── Custom context providers ──────────────────────────────────────────────────

local _context_providers = {}

--- Register a custom context provider.
--- The provider is called during context assembly and its output is appended
--- after all built-in sources (within the remaining token budget).
---
--- @param name string
--- @param provider_fn function  function(task, config) → string|nil
function M.register_context_provider(name, provider_fn)
  assert(type(name) == "string" and name ~= "", "provider name required")
  assert(type(provider_fn) == "function", "provider_fn must be a function")
  _context_providers[name] = provider_fn
  log.info("extensions: registered context provider", { name = name })
end

--- Called by context/init.lua to collect custom context sections.
--- @param task table
--- @param config table
--- @return string[]  List of additional context strings
function M.run_context_providers(task, config)
  local out = {}
  for name, fn in pairs(_context_providers) do
    local ok, result = pcall(fn, task, config)
    if ok and result and result ~= "" then
      table.insert(out, result)
    elseif not ok then
      log.warn("extensions: context provider error", { name = name, err = tostring(result) })
    end
  end
  return out
end

-- ── Custom routing rules ──────────────────────────────────────────────────────

--- Append a routing rule at runtime (added with highest priority = 0 by default).
--- This extends config.routing.rules without requiring re-setup.
---
--- @param rule table  { match, agent, priority? }
function M.add_routing_rule(rule)
  assert(type(rule) == "table", "rule must be a table")
  assert(rule.agent, "rule.agent is required")
  local ok, cfg = pcall(function() return require("agentflow.config").get() end)
  if not ok then
    error("extensions.add_routing_rule: plugin not yet initialized")
  end
  rule.priority = rule.priority or 0
  table.insert(cfg.routing.rules, 1, rule)  -- prepend for highest priority
  log.info("extensions: routing rule added", { agent = rule.agent, priority = rule.priority })
end

-- ── Custom result parsers ─────────────────────────────────────────────────────

local _result_parsers = {}

--- Register a custom result parser.
--- Parsers are tried in registration order before the built-in parser.
--- Return nil to pass through to the next parser.
---
--- @param name string
--- @param parser_fn function  function(content, task) → artifacts[]|nil
function M.register_result_parser(name, parser_fn)
  assert(type(name) == "string" and name ~= "", "parser name required")
  assert(type(parser_fn) == "function", "parser_fn must be a function")
  table.insert(_result_parsers, { name = name, fn = parser_fn })
  log.info("extensions: registered result parser", { name = name })
end

--- Try all custom parsers before falling back to the built-in one.
--- Called by results.lua.
--- @param content string
--- @param task table|nil
--- @return table[]|nil  artifacts, or nil to use built-in parser
function M.run_result_parsers(content, task)
  for _, p in ipairs(_result_parsers) do
    local ok, result = pcall(p.fn, content, task)
    if ok and result then
      log.debug("extensions: custom parser matched", { parser = p.name })
      return result
    elseif not ok then
      log.warn("extensions: result parser error", { name = p.name, err = tostring(result) })
    end
  end
  return nil
end

-- ── User autocommands ─────────────────────────────────────────────────────────

--- Emit User autocommands for all AgentFlow events.
--- Called once from init.lua after setup.
function M.setup_autocommands()
  local event_map = {
    ["plan:created"]             = "AgentFlowPlanCreated",
    ["agent:started"]            = "AgentFlowAgentStarted",
    ["agent:completed"]          = "AgentFlowAgentCompleted",
    ["agent:failed"]             = "AgentFlowAgentFailed",
    ["agent:retrying"]           = "AgentFlowAgentRetrying",
    ["orchestrator:synthesized"] = "AgentFlowSynthesized",
    ["review:accepted"]          = "AgentFlowReviewAccepted",
    ["review:rejected"]          = "AgentFlowReviewRejected",
    ["review:retry"]             = "AgentFlowReviewRetry",
  }

  -- Strip functions and other non-serializable values before json_encode.
  local function sanitize(v, depth)
    depth = depth or 0
    if depth > 6 then return nil end
    local t = type(v)
    if t == "function" or t == "userdata" or t == "thread" then
      return nil
    elseif t == "table" then
      local out = {}
      for k, val in pairs(v) do
        if type(k) == "string" or type(k) == "number" then
          local sv = sanitize(val, depth + 1)
          if sv ~= nil then out[k] = sv end
        end
      end
      return out
    else
      return v
    end
  end

  for internal_event, autocmd_name in pairs(event_map) do
    events.on(internal_event, function(data)
      -- Store payload in a global so autocommand handlers can access it
      local ok, encoded = pcall(vim.fn.json_encode, sanitize(data) or {})
      vim.g.agentflow_event_data = ok and encoded or "{}"
      vim.api.nvim_exec_autocmds("User", {
        pattern = autocmd_name,
        data    = data,
      })
    end)
  end

  log.debug("extensions: User autocommands registered")
end

-- ── Public event access ───────────────────────────────────────────────────────

--- Subscribe to an AgentFlow internal event from a user's config.
--- Simpler than using the events module directly.
---
--- Example:
---   require("agentflow.extensions").on("agent:completed", function(data)
---     print("Agent done: " .. data.agent.name)
---   end)
---
--- @param event string
--- @param fn function
--- @return number  subscription id (pass to off() to unsubscribe)
function M.on(event, fn)
  return events.on(event, fn)
end

function M.off(event, id)
  events.off(event, id)
end

return M
