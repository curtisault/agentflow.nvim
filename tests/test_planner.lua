-- tests/test_planner.lua — Unit tests for planner.lua

local planner = require("agentflow.planner")

describe("planner.parse", function()

  it("parses a valid JSON plan from a fenced block", function()
    local response = [[
Some prose before.

```json
{
  "tasks": [
    {
      "id": "t1",
      "description": "Analyse the code",
      "task_type": "analysis",
      "context_requirements": { "files": [], "scope": "function", "include_git": false },
      "depends_on": [],
      "agent_hint": null
    }
  ]
}
```

Some prose after.
]]
    local plan, err = planner.parse(response)
    assert.is_nil(err)
    assert.is_not_nil(plan)
    assert.are.equal(1, #plan.tasks)
    assert.are.equal("t1", plan.tasks[1].id)
    assert.are.equal("analysis", plan.tasks[1].task_type)
    assert.are.equal("pending", plan.tasks[1].status)
  end)

  it("returns error on completely invalid response", function()
    local plan, err = planner.parse("no json here at all")
    assert.is_nil(plan)
    assert.is_not_nil(err)
  end)

  it("repairs trailing commas", function()
    local response = [[```json
{"tasks":[{"id":"t1","description":"test","task_type":"analysis","context_requirements":{"files":[],"scope":"function","include_git":false},"depends_on":[],"agent_hint":null,}]}
```]]
    local plan, err = planner.parse(response)
    assert.is_nil(err)
    assert.is_not_nil(plan)
  end)

end)

describe("planner.resolve_order", function()

  it("returns single group for independent tasks", function()
    local tasks = {
      { id = "t1", depends_on = {} },
      { id = "t2", depends_on = {} },
      { id = "t3", depends_on = {} },
    }
    local groups, err = planner.resolve_order(tasks)
    assert.is_nil(err)
    assert.are.equal(1, #groups)
    assert.are.equal(3, #groups[1])
  end)

  it("orders sequential tasks correctly", function()
    local tasks = {
      { id = "t1", depends_on = {} },
      { id = "t2", depends_on = { "t1" } },
      { id = "t3", depends_on = { "t2" } },
    }
    local groups, err = planner.resolve_order(tasks)
    assert.is_nil(err)
    assert.are.equal(3, #groups)
    assert.are.same({ "t1" }, groups[1])
    assert.are.same({ "t2" }, groups[2])
    assert.are.same({ "t3" }, groups[3])
  end)

  it("detects dependency cycles", function()
    local tasks = {
      { id = "t1", depends_on = { "t2" } },
      { id = "t2", depends_on = { "t1" } },
    }
    local groups, err = planner.resolve_order(tasks)
    assert.is_nil(groups)
    assert.is_not_nil(err)
    assert.truthy(err:find("cycle"))
  end)

  it("handles diamond dependency", function()
    -- t1 → t2, t3 → t4
    local tasks = {
      { id = "t1", depends_on = {} },
      { id = "t2", depends_on = { "t1" } },
      { id = "t3", depends_on = { "t1" } },
      { id = "t4", depends_on = { "t2", "t3" } },
    }
    local groups, err = planner.resolve_order(tasks)
    assert.is_nil(err)
    assert.are.equal(3, #groups)
    assert.are.same({ "t1" }, groups[1])
    -- t2 and t3 in same group (parallel)
    table.sort(groups[2])
    assert.are.same({ "t2", "t3" }, groups[2])
    assert.are.same({ "t4" }, groups[3])
  end)

end)

describe("planner.validate", function()

  it("passes a valid plan", function()
    local plan = {
      tasks = {
        { id = "t1", description = "do thing", task_type = "analysis",
          context_requirements = { files = {}, scope = "function", include_git = false },
          depends_on = {}, status = "pending" },
      },
    }
    local ok, errors = planner.validate(plan)
    assert.is_true(ok)
    assert.are.same({}, errors)
  end)

  it("catches missing description", function()
    local plan = {
      tasks = {
        { id = "t1", description = "", task_type = "analysis",
          context_requirements = {}, depends_on = {}, status = "pending" },
      },
    }
    local ok, errors = planner.validate(plan)
    assert.is_false(ok)
    assert.truthy(errors[1]:find("description"))
  end)

end)
