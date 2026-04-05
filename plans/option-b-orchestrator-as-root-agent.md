# Plan: Orchestrator as Root Agent (Option B)

## Checklist

- [x] **Phase 1** — Add `_root_agent` to `orchestrator.new()`
- [x] **Phase 2** — Wire root agent state through `submit()`, `run_plan()`, `synthesize()`, `run()`
- [x] **Phase 3** — Attach task agents as children of root agent in `run_plan()`
- [x] **Phase 4** — Roll up cost/metrics into `_root_agent.metrics` at end of `run()`
- [x] **Phase 5** — Reset `_root_agent.children` at top of each `run()` call
- [x] **Phase 6** — Verify `tree.lua` renders root agent correctly (no code change expected)
- [x] **Phase 7** — Update `dashboard.lua` default focus to root agent
- [x] **Phase 8** — Verify chat spinner UX is correct (no code change expected)
- [x] **Phase 9** — Project-local agent discovery (`.agentflow/agents/*.json` + array merge fix)

## Goal

Make the orchestrator visible in the tree and dashboard as a root agent node. Its internal
phases (planning → delegating → synthesizing) map to real agent states so the UI reflects
what is actually happening during a run. Child task agents appear as children of the root
in the tree.

## Current State

- `orchestrator.lua` is a standalone object that calls the CLI backend directly
- `agent.lua` is the state machine that the tree/dashboard renders
- `tree.lua` already looks for `orc._root_agent` and falls back to registry stubs —
  just needs `_root_agent` to be populated
- Dashboard shows "sonnet" as idle because the orchestrator's work is invisible to agents
- The events bus (`util/events.lua`) drives all UI updates via `agent:state_changed`

## Architecture After This Change

```
orchestrator._root_agent  (Agent, depth=0, name="orchestrator")
  ├── state:  idle → running (planning) → running (delegating) → running (synthesizing) → completed
  ├── current_task.description: human-readable phase label
  └── children[]
        ├── agent("sonnet")  task: "t1 — Analyse the codebase"
        └── agent("sonnet")  task: "t2 — Write the tests"
```

The tree and dashboard already know how to render this shape — they just need `_root_agent`
to exist and emit `agent:state_changed` events as its state progresses.

---

## Implementation Phases

### Phase 1 — Add `_root_agent` to the orchestrator constructor

**File:** `lua/agentflow/orchestrator.lua`

In `M.new(cfg)`, after building `self`, create the root agent:

```lua
local agent_mod = require("agentflow.agents.agent")
self._root_agent = agent_mod.new(
  {
    name    = "orchestrator",
    model   = cfg.orchestrator.model,
    backend = cfg.backend.primary or "cli",
    role    = "orchestrator",
  },
  { depth = 0, events = events }
)
```

The root agent starts in `idle` state. It is never submitted to the pool — the orchestrator
controls its state directly.

---

### Phase 2 — Drive root agent state through orchestrator phases

**File:** `lua/agentflow/orchestrator.lua`

Add a private helper to set the root agent's phase description and state atomically:

```lua
function M:_set_phase(state, description)
  self._root_agent.current_task = description and { description = description } or nil
  self._root_agent:_set_state(state)
end
```

Wire it into each phase:

#### `M:submit()` — planning phase
```lua
-- at the top of submit(), before the backend call:
self:_set_phase("running", "Planning: " .. user_message:sub(1, 60))

-- at the bottom of submit(), before returning the plan:
self:_set_phase("assigned", "Plan ready — " .. #plan.tasks .. " tasks")
```

#### `M:run_plan()` — delegation phase
```lua
-- at the top of run_plan():
self:_set_phase("running", "Delegating " .. #plan.tasks .. " tasks")
```

#### `M:synthesize()` — synthesis phase
```lua
-- at the top of synthesize():
self:_set_phase("running", "Synthesizing results")
```

#### `M:run()` — completion / failure
```lua
-- after synthesize() returns successfully:
self:_set_phase("completed", nil)

-- in error branches (submit fails, synthesize fails):
self:_set_phase("failed", nil)
```

#### `M:reset()` — between runs
```lua
-- add to M:reset():
self._root_agent:reset()   -- clears state, history, children, metrics
```

---

### Phase 3 — Attach task agents as children of root agent

**File:** `lua/agentflow/orchestrator.lua`, in `M:run_plan()`

After `router.assign()` returns an agent for a task, attach it to the root:

```lua
-- existing code (simplified):
local agent = router.assign(task, cfg, pool)

-- NEW: wire into tree
agent.parent = self._root_agent
agent._events = events
table.insert(self._root_agent.children, agent)
```

Do this before the agent is submitted to the pool, so the tree can show it as "assigned"
before it starts running.

**Note:** `router.assign()` may reuse an agent instance across tasks. Guard against
duplicate insertion:

```lua
local already_child = false
for _, c in ipairs(self._root_agent.children) do
  if c == agent then already_child = true; break end
end
if not already_child then
  agent.parent = self._root_agent
  agent._events = events
  table.insert(self._root_agent.children, agent)
end
```

---

### Phase 4 — Cost and metrics rollup

**File:** `lua/agentflow/orchestrator.lua`

After synthesis, copy accumulated cost into the root agent's metrics so the dashboard
"Tokens" line shows the total across all children:

```lua
-- at the end of M:run(), after _set_phase("completed"):
self._root_agent.metrics.tokens_in  = self._cost.tokens_in
self._root_agent.metrics.tokens_out = self._cost.tokens_out
self._root_agent.metrics.duration_ms =
  vim.loop.now() - (self._root_agent.metrics.started_at or vim.loop.now())
```

Set `started_at` at the top of `M:run()`:

```lua
self._root_agent.metrics.started_at = vim.loop.now()
```

---

### Phase 5 — Reset between runs

**File:** `lua/agentflow/orchestrator.lua`, `M:run()`

At the very top of `M:run()`, before `_set_phase`, reset the root agent so child list and
state are clean for a new request:

```lua
self._root_agent.children = {}
self._root_agent._cancelled = false
self._root_agent.metrics.started_at = vim.loop.now()
```

**Note:** Do NOT call `self._root_agent:reset()` here — that resets state to `idle` and
emits the event, which would briefly flash the UI. Just clear children and cancelled flag.

---

### Phase 6 — Tree view (already wired, verify)

**File:** `lua/agentflow/ui/tree.lua`

`tree.lua` line ~230 already does:

```lua
local orc = ok and init._orchestrator
_state.root_agents = (orc and orc._root_agent) and { orc._root_agent } or {}
```

After Phase 1, `orc._root_agent` will be populated on setup. No code change needed here,
but verify this path is exercised by opening `:AgentTree` mid-run.

---

### Phase 7 — Dashboard initial focus

**File:** `lua/agentflow/ui/dashboard.lua`

`dashboard.lua` currently opens focused on whatever agent is passed in `opts.focus`, or
falls back to showing a stub. Update the fallback in `M.open()` to focus the root agent:

```lua
-- replace the existing fallback focus logic:
if not _state.focus then
  local ok, init = pcall(require, "agentflow")
  local orc = ok and init._orchestrator
  _state.focus = (orc and orc._root_agent) or nil
end
```

This means `:AgentDash` with no arguments opens on the orchestrator root, not a random
stub agent.

---

### Phase 8 — Spinner / chat UX during planning phase

**File:** `lua/agentflow/ui/chat.lua`

The spinner already runs from when `send()` is called until the first `on_token`. Since
`on_token` now only fires during `synthesize()` (Phases 1–3 are silent), the spinner
correctly covers the full planning + delegation period.

No code change needed. This behaviour is already correct after the earlier fix to strip
`on_token` from `submit()` and `run_plan()`.

---

## Files Changed

| File | Change |
|------|--------|
| `lua/agentflow/orchestrator.lua` | Add `_root_agent`; wire state transitions; attach child agents; track metrics |
| `lua/agentflow/ui/dashboard.lua` | Update default focus to root agent |
| `lua/agentflow/ui/tree.lua` | Verify only — no change expected |
| `lua/agentflow/init.lua` | Verify only — `_root_agent` exposed via `_orchestrator._root_agent` |

---

## Key Invariants to Preserve

1. `_root_agent` is created in `M.new()` so it exists before the first `run()` call.
   Tree/dashboard can open and show it as `idle` even before any request is sent.

2. State transitions always go through `_set_state()` so `agent:state_changed` events
   fire and the UI re-renders automatically.

3. Child agents are appended to `_root_agent.children` before being submitted to the pool,
   so they appear in the tree as "assigned" immediately.

4. `router.assign()` may return the same agent instance for multiple tasks across multiple
   runs. The duplicate-child guard in Phase 3 prevents the same agent appearing twice.

5. `M:reset()` (called by `M.cancel()` in init.lua) must reset `_root_agent` cleanly,
   including clearing `children`.

---

## Open Questions / Future Work

- **Phase labels in the tree**: "Planning: …" truncated task description works for now.
  A future enhancement could show the plan's task count badge on the root node.

- **Multi-run history**: Currently each `run()` wipes `_root_agent.children`. A future
  enhancement could keep a history of past runs.

- **Orchestrator's own token streaming**: The planning and synthesis LLM calls in the
  orchestrator are made directly (not through an Agent). Those tokens don't appear in
  `_root_agent.metrics` until the end. A future enhancement could accumulate them
  incrementally via `on_token` callbacks in `submit()` and `synthesize()`.

- **Router reuse of agent instances**: Currently `router.assign()` returns a new or
  reused `Agent`. If the same instance is used for two tasks in the same run, it will
  appear once in the children list (guarded by Phase 3). Child agent metrics will reflect
  only the last task. Consider whether tasks should always get fresh agent instances.

---

### Phase 9 — Project-local agent discovery

**Files:** `lua/agentflow/config.lua`, `lua/agentflow/agents/init.lua`

#### Part A — Fix agents array merging in `config.lua`

`deep_merge` treats the `agents` array like a plain table: project `agents[1]` overwrites
the default `agents[1]` rather than appending. Fix by post-processing the merge so project
agents are unioned with global agents, with project entries winning on name conflict:

```lua
-- After deep_merge in M.setup(), reconcile agents arrays:
local function union_agents(base, override)
  local by_name = {}
  for _, a in ipairs(base) do by_name[a.name] = a end
  for _, a in ipairs(override) do by_name[a.name] = a end  -- project wins
  local out = {}
  for _, a in pairs(by_name) do table.insert(out, a) end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- replace merged cfg.agents with the union:
cfg.agents = union_agents(DEFAULTS.agents, cfg.agents or {})
```

#### Part B — Scan `.agentflow/agents/*.json` in `agents/init.lua`

Add `load_from_project_dir()` which scans `cwd()/.agentflow/agents/` for JSON files and
registers each one. Called at the end of `setup_from_config()`:

```lua
function M.load_from_project_dir()
  local dir = vim.fn.getcwd() .. "/.agentflow/agents"
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
```

Each file describes one agent, e.g. `.agentflow/agents/rust-expert.json`:

```json
{
  "name": "rust-expert",
  "model": "claude-opus-4-6",
  "backend": "cli",
  "role": "subagent",
  "max_tokens": 8192
}
```

#### Precedence order (lowest → highest)

1. Plugin defaults (`DEFAULTS.agents`)
2. `.agentflow.json` project config (`agents` array)
3. `.agentflow/agents/*.json` individual files (registered last, overwrite on name conflict)

#### Files Changed

| File | Change |
|------|--------|
| `lua/agentflow/config.lua` | Add `union_agents()` post-merge step for `agents` array |
| `lua/agentflow/agents/init.lua` | Add `load_from_project_dir()`; call from `setup_from_config()` |
