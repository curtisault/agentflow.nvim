-- tests/test_agent_state.lua — Unit tests for agents/agent.lua state machine

local agent_mod
local config

local function ensure_config()
  package.loaded["agentflow.config"] = nil
  config = require("agentflow.config")
  config.setup({})
end

local function make_events()
  local bus = { log = {} }
  function bus.emit(event, data)
    table.insert(bus.log, { event = event, data = data })
  end
  function bus.on() end
  return bus
end

local function make_cfg(overrides)
  local cfg = { name = "test", model = "claude-sonnet-4-6", backend = "cli" }
  for k, v in pairs(overrides or {}) do cfg[k] = v end
  return cfg
end

-- ── Constructor ───────────────────────────────────────────────────────────────

describe("Agent.new()", function()

  before_each(function()
    package.loaded["agentflow.agents.agent"] = nil
    agent_mod = require("agentflow.agents.agent")
  end)

  it("starts in idle state", function()
    local a = agent_mod.new(make_cfg())
    assert.are.equal("idle", a.state)
  end)

  it("stores name and config", function()
    local a = agent_mod.new(make_cfg({ name = "my-agent" }))
    assert.are.equal("my-agent", a.name)
    assert.are.equal("my-agent", a.config.name)
  end)

  it("defaults depth to 0 with no parent", function()
    local a = agent_mod.new(make_cfg())
    assert.are.equal(0, a.depth)
    assert.is_nil(a.parent)
  end)

  it("accepts depth and parent options", function()
    local parent = agent_mod.new(make_cfg({ name = "parent" }))
    local child  = agent_mod.new(make_cfg({ name = "child" }), { parent = parent, depth = 2 })
    assert.are.equal(2,      child.depth)
    assert.are.equal(parent, child.parent)
  end)

  it("starts with empty children list", function()
    local a = agent_mod.new(make_cfg())
    assert.are.same({}, a.children)
  end)

  it("starts with zeroed metrics", function()
    local a = agent_mod.new(make_cfg())
    assert.are.equal(0, a.metrics.tokens_in)
    assert.are.equal(0, a.metrics.tokens_out)
    assert.are.equal(0, a.metrics.duration_ms)
    assert.is_nil(a.metrics.started_at)
  end)

  it("stores system_prompt from config", function()
    local a = agent_mod.new(make_cfg({ system_prompt = "You are a specialist." }))
    assert.are.equal("You are a specialist.", a.config.system_prompt)
  end)

  it("system_prompt is nil when not provided", function()
    local a = agent_mod.new(make_cfg())
    assert.is_nil(a.config.system_prompt)
  end)

end)

-- ── State transitions ─────────────────────────────────────────────────────────

describe("Agent._set_state()", function()

  before_each(function()
    package.loaded["agentflow.agents.agent"] = nil
    agent_mod = require("agentflow.agents.agent")
  end)

  it("changes state and emits agent:state_changed", function()
    local bus = make_events()
    local a   = agent_mod.new(make_cfg(), { events = bus })
    a:_set_state("running")
    assert.are.equal("running", a.state)
    assert.are.equal(1, #bus.log)
    assert.are.equal("agent:state_changed", bus.log[1].event)
    assert.are.equal("idle",    bus.log[1].data.from)
    assert.are.equal("running", bus.log[1].data.to)
    assert.are.equal(a,         bus.log[1].data.agent)
  end)

  it("does not error without an event bus", function()
    local a = agent_mod.new(make_cfg())
    assert.has_no_error(function() a:_set_state("completed") end)
    assert.are.equal("completed", a.state)
  end)

  it("emits on every transition, including repeated state", function()
    local bus = make_events()
    local a   = agent_mod.new(make_cfg(), { events = bus })
    a:_set_state("running")
    a:_set_state("running")
    assert.are.equal(2, #bus.log)
  end)

end)

-- ── reset() ───────────────────────────────────────────────────────────────────

describe("Agent.reset()", function()

  before_each(function()
    package.loaded["agentflow.agents.agent"] = nil
    agent_mod = require("agentflow.agents.agent")
  end)

  it("returns to idle and clears task, history, metrics", function()
    local bus = make_events()
    local a   = agent_mod.new(make_cfg(), { events = bus })
    a:_set_state("completed")
    a.current_task = { description = "do thing" }
    a.history      = { { role = "user", content = "hi" } }
    a.metrics      = { tokens_in = 10, tokens_out = 5, duration_ms = 200, started_at = 1 }

    a:reset()

    assert.are.equal("idle", a.state)
    assert.is_nil(a.current_task)
    assert.are.same({}, a.history)
    assert.are.equal(0, a.metrics.tokens_in)
    assert.are.equal(0, a.metrics.tokens_out)
    assert.are.equal(0, a.metrics.duration_ms)
    assert.is_nil(a.metrics.started_at)
  end)

  it("clears the _cancelled flag", function()
    local a = agent_mod.new(make_cfg())
    a._cancelled = true
    a:reset()
    assert.is_false(a._cancelled)
  end)

end)

-- ── spawn_child() ─────────────────────────────────────────────────────────────

describe("Agent.spawn_child()", function()

  before_each(function()
    ensure_config()
    package.loaded["agentflow.agents.agent"] = nil
    agent_mod = require("agentflow.agents.agent")
  end)

  it("creates a child at depth+1 with correct parent reference", function()
    local parent = agent_mod.new(make_cfg({ name = "parent" }), { depth = 0 })
    local child, err = parent:spawn_child(make_cfg({ name = "child" }))
    assert.is_nil(err)
    assert.is_not_nil(child)
    assert.are.equal(1,      child.depth)
    assert.are.equal(parent, child.parent)
  end)

  it("appends the child to parent.children", function()
    local parent = agent_mod.new(make_cfg({ name = "parent" }))
    parent:spawn_child(make_cfg({ name = "c1" }))
    parent:spawn_child(make_cfg({ name = "c2" }))
    assert.are.equal(2, #parent.children)
  end)

  it("forwards the event bus to the child", function()
    local bus    = make_events()
    local parent = agent_mod.new(make_cfg({ name = "parent" }), { events = bus })
    local child, _ = parent:spawn_child(make_cfg({ name = "child" }))
    assert.are.equal(bus, child._events)
  end)

  it("enforces max_depth from config", function()
    local deep = agent_mod.new(make_cfg({ name = "deep" }), { depth = 5 })
    local child, err = deep:spawn_child(make_cfg({ name = "too-deep" }))
    assert.is_nil(child)
    assert.is_not_nil(err)
    assert.truthy(err:find("depth limit"))
  end)

  it("enforces max_children_per_agent from config", function()
    local parent = agent_mod.new(make_cfg({ name = "parent" }))
    for i = 1, 20 do
      parent:spawn_child(make_cfg({ name = "c" .. i }))
    end
    local child, err = parent:spawn_child(make_cfg({ name = "overflow" }))
    assert.is_nil(child)
    assert.is_not_nil(err)
    assert.truthy(err:find("child limit"))
  end)

end)

-- ── get_subtree() ─────────────────────────────────────────────────────────────

describe("Agent.get_subtree()", function()

  before_each(function()
    ensure_config()
    package.loaded["agentflow.agents.agent"] = nil
    agent_mod = require("agentflow.agents.agent")
  end)

  it("returns empty list for a leaf agent", function()
    local a = agent_mod.new(make_cfg())
    assert.are.same({}, a:get_subtree())
  end)

  it("returns all descendants", function()
    local root = agent_mod.new(make_cfg({ name = "root" }))
    local c1   = root:spawn_child(make_cfg({ name = "c1" }))
    root:spawn_child(make_cfg({ name = "c2" }))
    c1:spawn_child(make_cfg({ name = "c1a" }))

    local subtree = root:get_subtree()
    assert.are.equal(3, #subtree)

    local names = {}
    for _, a in ipairs(subtree) do names[a.name] = true end
    assert.is_true(names["c1"])
    assert.is_true(names["c2"])
    assert.is_true(names["c1a"])
  end)

  it("does not include the root itself", function()
    local root = agent_mod.new(make_cfg({ name = "root" }))
    root:spawn_child(make_cfg({ name = "child" }))

    local subtree = root:get_subtree()
    for _, a in ipairs(subtree) do
      assert.are_not.equal("root", a.name)
    end
  end)

end)

-- ── cancel() / cancel_subtree() ───────────────────────────────────────────────

describe("Agent cancellation", function()

  before_each(function()
    ensure_config()
    package.loaded["agentflow.agents.agent"] = nil
    agent_mod = require("agentflow.agents.agent")
  end)

  it("cancel() sets _cancelled flag only on the agent itself", function()
    local root = agent_mod.new(make_cfg({ name = "root" }))
    root:cancel()
    assert.is_true(root._cancelled)
    -- children unaffected
    local c1 = root:spawn_child(make_cfg({ name = "c1" }))
    assert.is_false(c1._cancelled)
  end)

  it("cancel_subtree() marks root and all descendants cancelled", function()
    local root = agent_mod.new(make_cfg({ name = "root" }))
    local c1   = root:spawn_child(make_cfg({ name = "c1" }))
    local c2   = root:spawn_child(make_cfg({ name = "c2" }))

    root:cancel_subtree()

    assert.is_true(root._cancelled)
    assert.is_true(c1._cancelled)
    assert.is_true(c2._cancelled)
  end)

  it("cancel_subtree() transitions running/assigned agents to failed", function()
    local bus  = make_events()
    local root = agent_mod.new(make_cfg({ name = "root" }), { events = bus })
    local c1   = root:spawn_child(make_cfg({ name = "c1" }))
    c1:_set_state("running")

    root:cancel_subtree()

    assert.are.equal("failed", c1.state)
  end)

  it("cancel_subtree() leaves idle agents in idle state", function()
    local root = agent_mod.new(make_cfg({ name = "root" }))
    local c1   = root:spawn_child(make_cfg({ name = "c1" }))

    root:cancel_subtree()

    assert.are.equal("idle", c1.state)
    assert.is_true(c1._cancelled)
  end)

end)

-- ── total_metrics() ──────────────────────────────────────────────────────────

describe("Agent.total_metrics()", function()

  before_each(function()
    ensure_config()
    package.loaded["agentflow.agents.agent"] = nil
    agent_mod = require("agentflow.agents.agent")
  end)

  it("returns own metrics for a leaf agent", function()
    local a = agent_mod.new(make_cfg())
    a.metrics.tokens_in  = 10
    a.metrics.tokens_out = 5
    local totals = a:total_metrics()
    assert.are.equal(10, totals.tokens_in)
    assert.are.equal(5,  totals.tokens_out)
    assert.are.equal(1,  totals.agent_count)
  end)

  it("sums tokens across root and all descendants", function()
    local root = agent_mod.new(make_cfg({ name = "root" }))
    root.metrics.tokens_in  = 100
    root.metrics.tokens_out = 50

    local c1 = root:spawn_child(make_cfg({ name = "c1" }))
    c1.metrics.tokens_in  = 30
    c1.metrics.tokens_out = 15

    local c2 = root:spawn_child(make_cfg({ name = "c2" }))
    c2.metrics.tokens_in  = 20
    c2.metrics.tokens_out = 10

    local totals = root:total_metrics()
    assert.are.equal(150, totals.tokens_in)
    assert.are.equal(75,  totals.tokens_out)
    assert.are.equal(3,   totals.agent_count)
  end)

  it("counts deeply nested agents", function()
    local root = agent_mod.new(make_cfg({ name = "root" }))
    local c1   = root:spawn_child(make_cfg({ name = "c1" }))
    c1:spawn_child(make_cfg({ name = "c1a" }))

    local totals = root:total_metrics()
    assert.are.equal(3, totals.agent_count)
  end)

end)
