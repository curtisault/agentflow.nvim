-- tests/test_config.lua — Unit tests for config.lua

local config

describe("config.validate", function()

  before_each(function()
    package.loaded["agentflow.config"] = nil
    config = require("agentflow.config")
  end)

  it("accepts valid default config", function()
    local cfg, errors = config.setup({})
    assert.are.same({}, errors)
    assert.is_not_nil(cfg)
  end)

  it("rejects invalid backend.primary", function()
    local _, errors = config.setup({ backend = { primary = "ftp" } })
    assert.is_true(#errors > 0)
    assert.truthy(errors[1]:find("primary"))
  end)

  it("rejects an agent with an invalid backend", function()
    local _, errors = config.setup({
      agents = {
        { name = "bad-backend", model = "claude-sonnet-4-6", backend = "ftp" },
      },
    })
    assert.is_true(#errors > 0)
    assert.truthy(errors[1]:find("backend"))
  end)

  it("rejects invalid approve_mode", function()
    local _, errors = config.setup({ ui = { approve_mode = "always" } })
    assert.is_true(#errors > 0)
    assert.truthy(errors[1]:find("approve_mode"))
  end)

  it("deep-merges user opts with defaults", function()
    local cfg, _ = config.setup({
      concurrency = { max_parallel_agents = 8 },
    })
    assert.are.equal(8, cfg.concurrency.max_parallel_agents)
    assert.are.equal(5, cfg.concurrency.max_depth)
  end)

  it("unions user agents with defaults rather than replacing them", function()
    local cfg, errors = config.setup({
      agents = {
        { name = "my-agent", model = "claude-opus-4-6", backend = "cli", role = "subagent" },
      },
    })
    assert.are.same({}, errors)
    local names = {}
    for _, a in ipairs(cfg.agents) do names[a.name] = true end
    assert.is_true(names["sonnet"],   "default 'sonnet' agent should be preserved")
    assert.is_true(names["my-agent"], "user agent should be added")
  end)

  it("user agent with same name as default overrides the default", function()
    local cfg, errors = config.setup({
      agents = {
        { name = "sonnet", model = "claude-opus-4-6", backend = "cli", role = "subagent" },
      },
    })
    assert.are.same({}, errors)
    local sonnet_entries = {}
    for _, a in ipairs(cfg.agents) do
      if a.name == "sonnet" then table.insert(sonnet_entries, a) end
    end
    assert.are.equal(1, #sonnet_entries)
    assert.are.equal("claude-opus-4-6", sonnet_entries[1].model)
  end)

  it("multiple user agents are all merged into the list", function()
    local cfg, errors = config.setup({
      agents = {
        { name = "alpha", model = "claude-haiku-4-5-20251001", backend = "cli" },
        { name = "beta",  model = "claude-haiku-4-5-20251001", backend = "cli" },
      },
    })
    assert.are.same({}, errors)
    local names = {}
    for _, a in ipairs(cfg.agents) do names[a.name] = true end
    assert.is_true(names["alpha"])
    assert.is_true(names["beta"])
    assert.is_true(names["sonnet"])
  end)

end)
