-- tests/test_config.lua — Unit tests for config.lua

local config = require("agentflow.config")

describe("config.validate", function()

  before_each(function()
    -- Reset internal state between tests
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

  it("rejects duplicate agent names", function()
    local _, errors = config.setup({
      agents = {
        { name = "a", model = "m", backend = "cli" },
        { name = "a", model = "m2", backend = "cli" },
      },
    })
    assert.is_true(#errors > 0)
    assert.truthy(errors[1]:find("duplicated"))
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
    -- Other concurrency fields should still have defaults
    assert.are.equal(5, cfg.concurrency.max_depth)
  end)

end)
