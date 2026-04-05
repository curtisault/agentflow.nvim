-- backend/init.lua — Backend factory and fallback chain.
--
-- M.get(backend_name, agent_config) returns the correct adapter instance.
-- Fallback chain: cli → http → error

local M = {}

local log    = require("agentflow.util.log")
local config = require("agentflow.config")

-- ── Factory ───────────────────────────────────────────────────────────────────

--- Return an adapter instance for the given backend name.
--- agent_config is the agent's config table (may contain endpoint, api_key_env, etc.)
---
--- @param backend_name string  "cli" | "http" | "ollama" | "lmstudio" | "openai_compat"
--- @param agent_config table|nil
--- @return table  adapter instance
function M.get(backend_name, agent_config)
  agent_config = agent_config or {}
  local cfg = config.get()

  if backend_name == "cli" then
    local cli = require("agentflow.backend.cli")

    -- Build a fallback to HTTP if CLI is unavailable
    local function http_fallback(messages, opts)
      log.warn("CLI unavailable, falling back to HTTP adapter")
      local http = require("agentflow.backend.http").new({
        api_key_env = cfg.backend.api_key_env,
      })
      return http:complete(messages, opts)
    end

    return cli.new({
      cli_path    = agent_config.cli_path or cfg.backend.cli_path,
      cli_flags   = agent_config.cli_flags or cfg.backend.cli_flags,
      fallback_fn = http_fallback,
    })

  elseif backend_name == "http" then
    return require("agentflow.backend.http").new({
      api_key_env = agent_config.api_key_env or cfg.backend.api_key_env,
      api_key     = agent_config.api_key,
      base_url    = agent_config.endpoint,
    })

  elseif backend_name == "ollama" then
    return require("agentflow.backend.ollama").new({
      endpoint = agent_config.endpoint or "http://localhost:11434",
      timeout  = agent_config.timeout,
    })

  elseif backend_name == "lmstudio" then
    return require("agentflow.backend.lmstudio").new({
      base_url = agent_config.endpoint or "http://localhost:1234/v1",
      timeout  = agent_config.timeout,
    })

  elseif backend_name == "openai_compat" then
    return require("agentflow.backend.openai_compat").new({
      base_url      = agent_config.endpoint or error("openai_compat requires endpoint"),
      api_key       = agent_config.api_key,
      api_key_env   = agent_config.api_key_env,
      extra_headers = agent_config.extra_headers,
      timeout       = agent_config.timeout,
    })

  else
    -- Try custom backends registered via extensions
    local ext    = require("agentflow.extensions")
    local custom = ext.get_backend(backend_name, agent_config)
    if custom then return custom end

    error("backend.get: unknown backend '" .. tostring(backend_name) .. "'")
  end
end

--- Validate that each configured agent's backend is reachable.
--- Returns a list of { agent_name, error } for any that fail.
--- Must be called from within a coroutine (some checks are async).
---
--- @return table[]  { name, error }
function M.validate_all()
  local cfg = config.get()
  local failures = {}

  for _, agent_cfg in ipairs(cfg.agents) do
    local backend_name = agent_cfg.backend or "cli"

    if backend_name == "cli" then
      local cli = require("agentflow.backend.cli")
      local ok, err = cli.discover(agent_cfg.cli_path or cfg.backend.cli_path)
      if not ok then
        table.insert(failures, { name = agent_cfg.name, error = err })
      end

    elseif backend_name == "ollama" then
      local ollama = require("agentflow.backend.ollama").new({
        endpoint = agent_cfg.endpoint or "http://localhost:11434",
      })
      local models, err = ollama:list_models()
      if not models then
        table.insert(failures, { name = agent_cfg.name, error = err })
      elseif agent_cfg.model then
        local found = false
        for _, m in ipairs(models) do
          if m.name == agent_cfg.model or m.name == agent_cfg.model .. ":latest" then
            found = true; break
          end
        end
        if not found then
          table.insert(failures, {
            name  = agent_cfg.name,
            error = "model '" .. agent_cfg.model .. "' not found in Ollama",
          })
        end
      end

    elseif backend_name == "lmstudio" then
      local lms = require("agentflow.backend.lmstudio").new({
        base_url = agent_cfg.endpoint or "http://localhost:1234/v1",
      })
      local models, err = lms:list_models()
      if not models then
        table.insert(failures, { name = agent_cfg.name, error = err })
      end

    elseif backend_name == "http" or backend_name == "openai_compat" then
      -- Just check that an API key is present (can't ping without billing)
      local key_env = agent_cfg.api_key_env or cfg.backend.api_key_env
      local key = agent_cfg.api_key or vim.fn.getenv(key_env or "")
      if (not key or key == vim.NIL or key == "") and not agent_cfg.api_key then
        table.insert(failures, {
          name  = agent_cfg.name,
          error = "no API key found (env: " .. (key_env or "?") .. ")",
        })
      end
    end
  end

  if #failures > 0 then
    for _, f in ipairs(failures) do
      log.warn("Backend validation failed", { agent = f.name, error = f.error })
    end
  else
    log.info("All backends validated successfully")
  end

  return failures
end

return M
