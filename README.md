# AgentFlow

A Neovim plugin for orchestrating multi-agent AI workflows. Claude acts as a coordinator — decomposing tasks into a dependency graph, routing subtasks to specialized agents, running them in parallel, and synthesizing results back into your editor.

## Requirements

- Neovim 0.9+
- [Claude CLI](https://claude.ai/code) (`claude` binary in PATH) — or an `ANTHROPIC_API_KEY` for HTTP fallback
- Optional: [Ollama](https://ollama.com), [LM Studio](https://lmstudio.ai), or any OpenAI-compatible endpoint for local models
- Optional (for pickers): [mini.pick](https://github.com/echasnovski/mini.pick), [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim), or [fzf-lua](https://github.com/ibhagwan/fzf-lua)

## Installation

### vimpack (native Neovim 0.12+)

Add to your `vimpack.lua` (or wherever you call `vim.pack.add`):

```lua
vim.pack.add({
  "https://github.com/curtisault/agentflow.nvim",
})
```

Then call setup in your config (e.g. `lua/curtis/init.lua`):

```lua
require("agentflow").setup()
```

### lazy.nvim

```lua
{
  "curtisault/agentflow.nvim",
  config = function()
    require("agentflow").setup()
  end,
}
```

## Quick Start

```
:AgentFlow refactor the selected function to use early returns
```

Or via keymap: `<leader>ap` → type your prompt → `<Enter>`

---

## Configuration

```lua
require("agentflow").setup({
  backend = {
    primary     = "cli",              -- "cli" | "http"
    cli_path    = "claude",           -- path to claude binary
    api_key_env = "ANTHROPIC_API_KEY",
  },

  orchestrator = {
    model     = "claude-sonnet-4-20250514",
    max_turns = 20,
  },

  agents = {
    { name = "sonnet", model = "claude-sonnet-4-20250514", backend = "cli", role = "subagent" },
    -- Add more agents for routing, e.g. a local model for simple tasks:
    -- { name = "local", model = "qwen2.5-coder:7b", backend = "ollama" },
  },

  routing = {
    rules = {
      -- Route analysis tasks to a cheaper/faster agent:
      -- { match = { task_type = "analysis" }, agent = "local", priority = 1 },
      { match = { fallback = true }, agent = "sonnet", priority = 99 },
    },
  },

  context = {
    max_tokens_per_agent = 12000,
    include_buffers      = true,
    include_treesitter   = true,
    include_git_diff     = "staged", -- "staged" | "all" | false
    include_lsp_symbols  = true,
    include_file_tree    = true,
  },

  ui = {
    approve_mode = "manual", -- "manual" | "auto" | "auto-safe"
    picker       = nil,      -- nil = auto-detect (mini.pick > telescope > fzf-lua > vim.ui.select)
  },

  concurrency = {
    max_parallel_agents    = 4,
    max_depth              = 5,
    max_total_agents       = 200,
    max_children_per_agent = 20,
    timeout_ms             = 30000,
  },

  keymaps = { enabled = true },
  log     = { level = "info", file = nil },
})
```

### Project-level override

Place a `.agentflow.json` file in your project root to override any settings for that project:

```json
{
  "concurrency": { "max_parallel_agents": 2 },
  "context": { "include_git_diff": "all" }
}
```

---

## Commands

| Command | Description |
|---------|-------------|
| `:AgentFlow [prompt]` | Open hub (no args) or start a workflow |
| `:AgentChat` | Open chat pane |
| `:AgentTree` | Open agent tree view |
| `:AgentRoster` | Open agent roster |
| `:AgentDash` | Open dashboard view |
| `:AgentGrid` | Open grid (heat-map) view |
| `:AgentReview` | Open review panel |
| `:AgentLog [name]` | Show log buffer (optionally filter by agent name) |
| `:AgentKill {name}` | Terminate an agent and its subtree |
| `:AgentAdd {name} {model}` | Register a new agent at runtime |
| `:AgentPick` | Picker to select and inspect an agent |
| `:AgentSessions` | Browse and resume saved sessions |
| `:AgentSave` | Save current session to disk |

---

## Keybindings

### Global (normal mode)

| Key | Action |
|-----|--------|
| `<leader>af` | Open hub |
| `<leader>ap` | Prompt → start workflow |
| `<leader>as` | Open agent tree |
| `<leader>ac` | Open config panel |
| `<leader>ar` | Open review panel |

Disable with `keymaps = { enabled = false }` in setup.

---

### Hub

| Key | Action |
|-----|--------|
| `t` | Tree view |
| `d` | Dashboard |
| `g` | Grid view |
| `r` | Roster |
| `s` | Sessions browser |
| `l` | Log buffer |
| `?` | Help |
| `p` | Prompt → start workflow |
| `q` / `<Esc>` | Close |

---

### Review Panel

| Key | Action |
|-----|--------|
| `<CR>` | Accept artifact (apply diff / write file) |
| `x` | Reject |
| `e` | Edit artifact in buffer |
| `r` | Retry with agent |
| `]r` | Next artifact |
| `[r` | Previous artifact |
| `1` | Diff tab |
| `2` | Raw output tab |
| `3` | Agent log tab |
| `4` | Context tab |
| `<Tab>` | Cycle tabs |
| `q` / `<Esc>` | Close |

---

### Tree View

| Key | Action |
|-----|--------|
| `zo` | Expand node |
| `zc` | Collapse node |
| `zR` | Expand all |
| `zM` | Collapse all |
| `<CR>` | Open dashboard for agent |
| `f` | Filter (picker) |
| `d` | Set depth limit |
| `<C-k>` | Kill agent + subtree |
| `<Tab>` | Go to hub |
| `q` / `<Esc>` | Close |

---

### Dashboard

| Key | Action |
|-----|--------|
| `<CR>` | Drill into child agent |
| `<BS>` | Go up to parent |
| `f` | Pick agent (jump) |
| `<Tab>` | Go to hub |
| `q` / `<Esc>` | Close |

---

### Grid View

| Key | Action |
|-----|--------|
| `h/j/k/l` or arrows | Navigate cells |
| `<CR>` | Open dashboard for selected agent |
| `/` | Search / filter agents |
| `<Tab>` | Go to hub |
| `q` / `<Esc>` | Close |

---

### Roster

| Key | Action |
|-----|--------|
| `<CR>` | Show agent details |
| `d` | Deregister agent |
| `q` / `<Esc>` | Close |

---

### Chat Pane

| Key | Mode | Action |
|-----|------|--------|
| `<CR>` | normal / insert | Send message |
| `<C-c>` | normal / insert | Close |
| `<C-l>` | normal / insert | Clear chat |
| `q` / `<Esc>` | normal | Close |

---

## Backends

| Backend | Config value | Notes |
|---------|-------------|-------|
| Claude CLI | `"cli"` | Requires `claude` binary. Falls back to HTTP if unavailable. |
| Anthropic HTTP | `"http"` | Requires `ANTHROPIC_API_KEY` (or `api_key_env`). |
| Ollama | `"ollama"` | Local. Default endpoint: `http://localhost:11434`. |
| LM Studio | `"lmstudio"` | Local. Default endpoint: `http://localhost:1234/v1`. |
| OpenAI-compat | `"openai_compat"` | Any OpenAI-compatible API. Requires `endpoint`. |

### Custom backend

```lua
require("agentflow.extensions").register_backend("my-backend", function(agent_config)
  return {
    complete = function(self, messages, opts)
      -- return result_string, nil   (or nil, error_string)
    end,
  }
end)
```

---

## Extensibility

```lua
local ext = require("agentflow.extensions")

-- Custom context source (appended to every agent's context)
ext.register_context_provider("jira", function(task, config)
  return "Current Jira ticket: " .. get_current_ticket()
end)

-- Custom result parser (tried before built-in parser)
ext.register_result_parser("my-format", function(content, task)
  -- return artifacts[] or nil to fall through
end)

-- Inject a routing rule at runtime
ext.add_routing_rule({ match = { task_type = "test" }, agent = "local", priority = 1 })

-- Subscribe to events
ext.on("agent:completed", function(data)
  print("Agent done: " .. data.agent.name)
end)
```

### Neovim autocommands

AgentFlow fires `User` autocommands for all major events:

```vim
autocmd User AgentFlowAgentCompleted lua print(vim.g.agentflow_event_data)
```

| Autocommand | Fired when |
|-------------|-----------|
| `AgentFlowPlanCreated` | Orchestrator produces a task plan |
| `AgentFlowAgentStarted` | An agent begins execution |
| `AgentFlowAgentCompleted` | An agent finishes successfully |
| `AgentFlowAgentFailed` | An agent errors out |
| `AgentFlowAgentRetrying` | An agent is retrying after failure |
| `AgentFlowSynthesized` | Orchestrator synthesizes final result |
| `AgentFlowReviewAccepted` | User accepts an artifact |
| `AgentFlowReviewRejected` | User rejects an artifact |
| `AgentFlowReviewRetry` | User requests a retry from review |

---

## Statusline

Add the current agent status to your statusline:

```lua
-- lualine example
require("lualine").setup({
  sections = {
    lualine_x = { _G.AgentFlowStatus },
  },
})
```

`AgentFlowStatus()` returns a spinner + elapsed time while agents are running, empty string otherwise.

---

## Sessions

Workflows are auto-saved to `.agentflow/sessions/` in your project root after synthesis. Each session stores:

- `conversation.json` — full orchestrator message history
- `plan.json` — task plan and execution state
- `meta.json` — model, cost, timestamps
- `logs/` — per-agent log files

Browse and resume sessions with `:AgentSessions` or `s` in the hub.

---

## Health Check

```
:checkhealth agentflow
```

Checks: Neovim version, Claude CLI, API key, curl, Ollama, LM Studio, treesitter parsers, picker plugins, git, and config validation.

---

## Running Tests

Requires [plenary.nvim](https://github.com/nvim-lua/plenary.nvim).

```sh
# All tests
make -C lua/agentflow test

# Single file
make -C lua/agentflow test-file FILE=tests/test_planner.lua
```
