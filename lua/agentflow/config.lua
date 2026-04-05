-- config.lua — Single source of truth for all AgentFlow configuration.
-- Handles defaults, user merging, .agentflow.json project override, and validation.

local M = {}

-- ── Defaults ──────────────────────────────────────────────────────────────────

local DEFAULTS = {
  backend = {
    primary = "cli",
    cli_path = "claude",
    cli_flags = { "--output-format", "stream-json", "--verbose" },
    api_key_env = "ANTHROPIC_API_KEY",
  },
  orchestrator = {
    model = "claude-sonnet-4-20250514",
    system_prompt = nil,    -- loaded from prompts/orchestrator.md at runtime
    max_turns = 20,
  },
  agents = {
    {
      name = "sonnet",
      model = "claude-sonnet-4-20250514",
      backend = "cli",
      role = "subagent",
      max_tokens = 8192,
    },
  },
  routing = {
    rules = {
      { match = { fallback = true }, agent = "sonnet", priority = 99 },
    },
  },
  context = {
    max_tokens_per_agent = 12000,
    include_buffers = true,
    include_treesitter = true,
    include_git_diff = "staged",  -- "staged" | "all" | false
    include_lsp_symbols = true,
    include_file_tree = true,
  },
  ui = {
    chat_width = 0.5,
    roster_width = 30,
    review_style = "vertical",    -- "vertical" | "horizontal"
    approve_mode = "manual",      -- "manual" | "auto" | "auto-safe"
    picker = nil,                 -- nil = auto-detect
  },
  concurrency = {
    max_parallel_agents = 4,
    max_depth = 5,
    max_total_agents = 200,
    max_children_per_agent = 20,
    timeout_ms = 30000,
  },
  keymaps = {
    enabled = true,
  },
  log = {
    level = "info",
    file = nil,
  },
}

-- ── Internal state ────────────────────────────────────────────────────────────

local _config = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────

--- Deep merge src into dst. Tables are merged recursively; other values overwrite.
local function deep_merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      deep_merge(dst[k], v)
    else
      dst[k] = v
    end
  end
  return dst
end

--- Deep copy a table.
local function deep_copy(t)
  if type(t) ~= "table" then return t end
  local copy = {}
  for k, v in pairs(t) do
    copy[k] = deep_copy(v)
  end
  return copy
end

--- Union two agents arrays by name. Later entries win on conflict.
local function union_agents(base, override)
  local by_name = {}
  for _, a in ipairs(base)     do by_name[a.name] = a end
  for _, a in ipairs(override) do by_name[a.name] = a end  -- override wins
  local out = {}
  for _, a in pairs(by_name) do table.insert(out, a) end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- Load and merge a .agentflow.json project file if one exists.
local function load_project_file()
  local path = vim.fn.getcwd() .. "/.agentflow.json"
  if vim.fn.filereadable(path) == 0 then return {} end

  local raw = vim.fn.readfile(path)
  if not raw or #raw == 0 then return {} end

  local ok, parsed = pcall(vim.fn.json_decode, table.concat(raw, "\n"))
  if not ok or type(parsed) ~= "table" then
    vim.notify("AgentFlow: invalid .agentflow.json — skipping", vim.log.levels.WARN)
    return {}
  end
  return parsed
end

-- ── Validation ────────────────────────────────────────────────────────────────

local VALID_PRIMARIES = { cli = true, api = true }
local VALID_ROLES = { orchestrator = true, subagent = true }
local VALID_BACKENDS = { cli = true, http = true, ollama = true, lmstudio = true, openai_compat = true }
local VALID_APPROVE_MODES = { manual = true, auto = true, ["auto-safe"] = true }
local VALID_GIT_DIFF = { staged = true, all = true, ["false"] = true }
local VALID_LOG_LEVELS = { debug = true, info = true, warn = true, error = true }

--- Validate the merged config. Returns (config, errors[]).
function M.validate(cfg)
  local errors = {}

  local function err(msg) table.insert(errors, msg) end

  -- backend
  if not VALID_PRIMARIES[cfg.backend.primary] then
    err("backend.primary must be 'cli' or 'api', got: " .. tostring(cfg.backend.primary))
  end
  if type(cfg.backend.cli_path) ~= "string" or cfg.backend.cli_path == "" then
    err("backend.cli_path must be a non-empty string")
  end

  -- orchestrator
  if type(cfg.orchestrator.model) ~= "string" or cfg.orchestrator.model == "" then
    err("orchestrator.model must be a non-empty string")
  end
  if type(cfg.orchestrator.max_turns) ~= "number" or cfg.orchestrator.max_turns < 1 then
    err("orchestrator.max_turns must be a positive number")
  end

  -- agents
  if type(cfg.agents) ~= "table" then
    err("agents must be a table")
  else
    local names = {}
    for i, agent in ipairs(cfg.agents) do
      local prefix = "agents[" .. i .. "]"
      if type(agent.name) ~= "string" or agent.name == "" then
        err(prefix .. ".name must be a non-empty string")
      elseif names[agent.name] then
        err(prefix .. ".name '" .. agent.name .. "' is duplicated")
      else
        names[agent.name] = true
      end
      if type(agent.model) ~= "string" or agent.model == "" then
        err(prefix .. ".model must be a non-empty string")
      end
      if not VALID_BACKENDS[agent.backend or "cli"] then
        err(prefix .. ".backend must be one of: cli, http, ollama, lmstudio, openai_compat")
      end
      if agent.role and not VALID_ROLES[agent.role] then
        err(prefix .. ".role must be 'orchestrator' or 'subagent'")
      end
    end
  end

  -- ui
  if not VALID_APPROVE_MODES[cfg.ui.approve_mode] then
    err("ui.approve_mode must be 'manual', 'auto', or 'auto-safe'")
  end

  -- context
  local gd = cfg.context.include_git_diff
  if gd ~= false and not VALID_GIT_DIFF[tostring(gd)] then
    err("context.include_git_diff must be 'staged', 'all', or false")
  end
  if type(cfg.context.max_tokens_per_agent) ~= "number" or cfg.context.max_tokens_per_agent < 1 then
    err("context.max_tokens_per_agent must be a positive number")
  end

  -- concurrency
  local conc = cfg.concurrency
  if type(conc.max_parallel_agents) ~= "number" or conc.max_parallel_agents < 1 then
    err("concurrency.max_parallel_agents must be >= 1")
  end
  if type(conc.max_depth) ~= "number" or conc.max_depth < 1 then
    err("concurrency.max_depth must be >= 1")
  end

  -- log
  if not VALID_LOG_LEVELS[cfg.log.level] then
    err("log.level must be one of: debug, info, warn, error")
  end

  return cfg, errors
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Initialize config from user opts. Returns (merged_config, errors[]).
function M.setup(user_opts)
  local cfg = deep_copy(DEFAULTS)

  -- Merge project-level .agentflow.json first (lowest priority override)
  local project = load_project_file()
  if next(project) then
    local project_agents = project.agents or {}
    deep_merge(cfg, project)
    -- Restore agents as a union so project entries append rather than overwrite
    if #project_agents > 0 then
      cfg.agents = union_agents(deep_copy(DEFAULTS.agents), project_agents)
    end
  end

  -- Merge user opts (highest priority)
  if user_opts and next(user_opts) then
    local user_agents = user_opts.agents or {}
    deep_merge(cfg, user_opts)
    if #user_agents > 0 then
      cfg.agents = union_agents(cfg.agents, user_agents)
    end
  end

  local _, errors = M.validate(cfg)
  _config = cfg
  return cfg, errors
end

--- Return the current config. Errors if setup() has not been called.
function M.get()
  if not _config then
    error("agentflow: config.get() called before config.setup()")
  end
  return _config
end

--- Return a copy of the defaults (useful for documentation / UI display).
function M.defaults()
  return deep_copy(DEFAULTS)
end

return M
