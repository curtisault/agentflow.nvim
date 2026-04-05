-- health.lua — :checkhealth agentflow
--
-- Run with:  :checkhealth agentflow

local M = {}

-- Neovim 0.10+ uses vim.health; older versions use the health module
local h = vim.health or require("health")

local function ok(msg)    h.ok(msg)    end
local function warn(msg)  h.warn(msg)  end
local function error(msg) h.error(msg) end
local function info(msg)  h.info(msg)  end
local function start(msg) h.start(msg) end

function M.check()

  -- ── Neovim version ───────────────────────────────────────────────────────
  start("Neovim version")
  local nvim_ver = vim.version()
  if nvim_ver.major > 0 or nvim_ver.minor >= 9 then
    ok(string.format("Neovim %d.%d.%d (>= 0.9 required)",
      nvim_ver.major, nvim_ver.minor, nvim_ver.patch))
  else
    error(string.format("Neovim %d.%d.%d — AgentFlow requires >= 0.9",
      nvim_ver.major, nvim_ver.minor, nvim_ver.patch))
  end

  -- ── Claude CLI ───────────────────────────────────────────────────────────
  start("Claude CLI (primary backend)")

  local cli_path = "claude"
  local ok_cfg, cfg = pcall(function()
    return require("agentflow.config").get()
  end)
  if ok_cfg and cfg then
    cli_path = cfg.backend.cli_path or "claude"
  end

  local cli_out  = vim.fn.system({ cli_path, "--version" })
  local cli_code = vim.v.shell_error

  if cli_code == 0 then
    local version = vim.trim(cli_out):match("([%d%.]+)") or vim.trim(cli_out)
    ok("claude CLI found: " .. cli_path .. " (version " .. version .. ")")
    -- Check that `claude api messages` is reachable (just --help to avoid API call)
    local api_out  = vim.fn.system({ cli_path, "api", "--help" })
    local api_code = vim.v.shell_error
    if api_code == 0 or api_out:find("messages") then
      ok("claude api subcommand available")
    else
      warn("claude api subcommand may not be available — check CLI version")
    end
  else
    warn("claude CLI not found at '" .. cli_path .. "' — HTTP adapter will be used as fallback")
    info("Install: https://claude.ai/download or set backend.cli_path in setup()")
  end

  -- ── Anthropic API key ────────────────────────────────────────────────────
  start("Anthropic API key (HTTP fallback backend)")

  local key_env = "ANTHROPIC_API_KEY"
  if ok_cfg and cfg then key_env = cfg.backend.api_key_env or key_env end

  local api_key = vim.fn.getenv(key_env)
  if api_key and api_key ~= vim.NIL and api_key ~= "" then
    ok("$" .. key_env .. " is set (" .. #api_key .. " chars)")
  else
    warn("$" .. key_env .. " is not set — HTTP fallback backend will not work")
    info("Set it in your shell profile or pass api_key in agent config")
  end

  -- ── curl (required for HTTP/Ollama/LMStudio backends) ───────────────────
  start("curl (required for HTTP, Ollama, LM Studio backends)")
  local curl_out  = vim.fn.system({ "curl", "--version" })
  local curl_code = vim.v.shell_error
  if curl_code == 0 then
    local curl_ver = curl_out:match("curl (%S+)")
    ok("curl found: " .. (curl_ver or "unknown version"))
  else
    error("curl not found — HTTP, Ollama, and LM Studio backends will not work")
  end

  -- ── Ollama ───────────────────────────────────────────────────────────────
  start("Ollama (optional local backend)")
  local ollama_endpoint = "http://localhost:11434"
  local ollama_out  = vim.fn.system({ "curl", "--silent", "--max-time", "2", ollama_endpoint })
  local ollama_code = vim.v.shell_error
  if ollama_code == 0 and ollama_out ~= "" then
    ok("Ollama reachable at " .. ollama_endpoint)
  else
    info("Ollama not reachable at " .. ollama_endpoint .. " (optional — skip if not using local models)")
  end

  -- ── LM Studio ────────────────────────────────────────────────────────────
  start("LM Studio (optional local backend)")
  local lms_endpoint = "http://localhost:1234/v1/models"
  local lms_out  = vim.fn.system({ "curl", "--silent", "--max-time", "2", lms_endpoint })
  local lms_code = vim.v.shell_error
  if lms_code == 0 and lms_out:find("data") then
    ok("LM Studio reachable at http://localhost:1234")
  else
    info("LM Studio not reachable (optional — skip if not using LM Studio)")
  end

  -- ── Treesitter parsers ───────────────────────────────────────────────────
  start("Treesitter (context engine)")
  local ts_ok, ts = pcall(require, "nvim-treesitter")
  if ts_ok or vim.treesitter then
    ok("nvim-treesitter / built-in treesitter available")
    -- Check a few common parsers
    local parsers = { "lua", "python", "javascript", "typescript" }
    for _, lang in ipairs(parsers) do
      local has_parser = pcall(vim.treesitter.language.inspect, lang)
      if has_parser then
        ok("  parser: " .. lang)
      else
        info("  parser not installed: " .. lang .. " (run :TSInstall " .. lang .. ")")
      end
    end
  else
    warn("nvim-treesitter not found — treesitter context will be disabled")
  end

  -- ── Optional picker plugins ──────────────────────────────────────────────
  start("Picker plugins (optional — vim.ui.select always available)")
  local pickers = {
    { mod = "mini.pick",   name = "mini.pick"   },
    { mod = "telescope",   name = "telescope"   },
    { mod = "fzf-lua",     name = "fzf-lua"     },
  }
  local found_picker = false
  for _, p in ipairs(pickers) do
    if pcall(require, p.mod) then
      ok(p.name .. " detected")
      found_picker = true
    else
      info(p.name .. " not installed (optional)")
    end
  end
  if not found_picker then
    info("No picker plugin found — using vim.ui.select (always available)")
  end

  -- ── git ──────────────────────────────────────────────────────────────────
  start("git (context engine — git diff / blame)")
  local git_out  = vim.fn.system({ "git", "--version" })
  local git_code = vim.v.shell_error
  if git_code == 0 then
    ok(vim.trim(git_out))
    local is_repo = vim.fn.system("git rev-parse --is-inside-work-tree 2>/dev/null")
    if vim.v.shell_error == 0 and vim.trim(is_repo) == "true" then
      ok("Current directory is a git repository")
    else
      info("Current directory is not a git repository — git context will be empty")
    end
  else
    warn("git not found — git diff/blame context will be disabled")
  end

  -- ── AgentFlow config ─────────────────────────────────────────────────────
  start("AgentFlow configuration")
  if ok_cfg and cfg then
    ok("config loaded successfully")
    info("Primary backend: " .. (cfg.backend.primary or "cli"))
    info("Orchestrator model: " .. (cfg.orchestrator.model or "?"))
    info("Registered agents: " .. #(cfg.agents or {}))
    info("Max parallel: " .. (cfg.concurrency.max_parallel_agents or 4))
    info("Max depth: " .. (cfg.concurrency.max_depth or 5))

    -- Validate
    local _, errors = require("agentflow.config").validate(cfg)
    if #errors == 0 then
      ok("config validation passed")
    else
      for _, e in ipairs(errors) do
        error("config error: " .. e)
      end
    end
  else
    warn("AgentFlow not yet initialized — call require('agentflow').setup() first")
  end
end

return M
