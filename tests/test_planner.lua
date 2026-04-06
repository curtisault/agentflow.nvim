-- tests/test_planner.lua — Unit tests for planner.lua

local planner = require("agentflow.planner")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function make_task(overrides)
  local t = {
    id          = "t1",
    description = "do a thing",
    task_type   = "analysis",
    context_requirements = { files = {}, scope = "function", include_git = false },
    depends_on  = {},
    status      = "pending",
  }
  for k, v in pairs(overrides or {}) do t[k] = v end
  return t
end

-- ── planner.parse() ───────────────────────────────────────────────────────────

describe("planner.parse()", function()

  it("parses a valid JSON plan from a fenced code block", function()
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
    assert.are.equal("t1",       plan.tasks[1].id)
    assert.are.equal("analysis", plan.tasks[1].task_type)
    assert.are.equal("pending",  plan.tasks[1].status)
  end)

  it("accepts a bare JSON array (no wrapper object)", function()
    local response = [[```json
[{"id":"t1","description":"do thing","task_type":"edit","context_requirements":{"files":[],"scope":"file","include_git":false},"depends_on":[]}]
```]]
    local plan, err = planner.parse(response)
    assert.is_nil(err)
    assert.is_not_nil(plan)
    assert.are.equal(1, #plan.tasks)
    assert.are.equal("t1", plan.tasks[1].id)
  end)

  it("defaults missing task fields to safe values", function()
    local response = '{"tasks":[{"id":"t1","description":"do thing"}]}'
    local plan, err = planner.parse(response)
    assert.is_nil(err)
    assert.are.equal("analysis",  plan.tasks[1].task_type)
    assert.are.equal("function",  plan.tasks[1].context_requirements.scope)
    assert.are.same({},           plan.tasks[1].depends_on)
    assert.are.equal("pending",   plan.tasks[1].status)
  end)

  it("auto-assigns id when missing", function()
    local response = '{"tasks":[{"description":"no id given"}]}'
    local plan, err = planner.parse(response)
    assert.is_nil(err)
    assert.are.equal("t1", plan.tasks[1].id)
  end)

  it("repairs trailing commas in JSON", function()
    local response = [[```json
{"tasks":[{"id":"t1","description":"test","task_type":"analysis","context_requirements":{"files":[],"scope":"function","include_git":false},"depends_on":[],"agent_hint":null,}]}
```]]
    local plan, err = planner.parse(response)
    assert.is_nil(err)
    assert.is_not_nil(plan)
  end)

  it("returns error on empty response", function()
    local plan, err = planner.parse("")
    assert.is_nil(plan)
    assert.is_not_nil(err)
  end)

  it("returns error when no JSON is found", function()
    local plan, err = planner.parse("no json here at all")
    assert.is_nil(plan)
    assert.is_not_nil(err)
  end)

  it("populates execution_order", function()
    local response = '{"tasks":[{"id":"t1","description":"first"},{"id":"t2","description":"second","depends_on":["t1"]}]}'
    local plan, err = planner.parse(response)
    assert.is_nil(err)
    assert.is_not_nil(plan.execution_order)
    assert.are.equal(2, #plan.execution_order)
    assert.are.same({ "t1" }, plan.execution_order[1])
    assert.are.same({ "t2" }, plan.execution_order[2])
  end)

end)

-- ── planner.resolve_order() ───────────────────────────────────────────────────

describe("planner.resolve_order()", function()

  it("returns a single group for independent tasks", function()
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

  it("handles a diamond dependency (fan-out then fan-in)", function()
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
    table.sort(groups[2])
    assert.are.same({ "t2", "t3" }, groups[2])
    assert.are.same({ "t4" }, groups[3])
  end)

  it("detects a simple two-task cycle", function()
    local tasks = {
      { id = "t1", depends_on = { "t2" } },
      { id = "t2", depends_on = { "t1" } },
    }
    local groups, err = planner.resolve_order(tasks)
    assert.is_nil(groups)
    assert.is_not_nil(err)
    assert.truthy(err:find("cycle"))
  end)

  it("detects a self-dependency cycle", function()
    local tasks = {
      { id = "t1", depends_on = { "t1" } },
    }
    local groups, err = planner.resolve_order(tasks)
    assert.is_nil(groups)
    assert.is_not_nil(err)
  end)

  it("returns error for a dependency on an unknown task id", function()
    local tasks = {
      { id = "t1", depends_on = { "ghost" } },
    }
    local groups, err = planner.resolve_order(tasks)
    assert.is_nil(groups)
    assert.is_not_nil(err)
    assert.truthy(err:find("ghost"))
  end)

  it("groups within a group are sorted deterministically", function()
    local tasks = {
      { id = "c", depends_on = {} },
      { id = "a", depends_on = {} },
      { id = "b", depends_on = {} },
    }
    local groups, _ = planner.resolve_order(tasks)
    assert.are.same({ "a", "b", "c" }, groups[1])
  end)

  it("handles an empty task list", function()
    local groups, err = planner.resolve_order({})
    assert.is_nil(err)
    assert.are.same({}, groups)
  end)

end)

-- ── planner.validate() ────────────────────────────────────────────────────────

describe("planner.validate()", function()

  it("passes a valid single-task plan", function()
    local plan = { tasks = { make_task() } }
    local ok, errors = planner.validate(plan)
    assert.is_true(ok)
    assert.are.same({}, errors)
  end)

  it("passes a valid multi-task plan with dependencies", function()
    local plan = {
      tasks = {
        make_task({ id = "t1" }),
        make_task({ id = "t2", depends_on = { "t1" } }),
      },
    }
    local ok, errors = planner.validate(plan)
    assert.is_true(ok)
    assert.are.same({}, errors)
  end)

  it("rejects a plan with nil tasks", function()
    local ok, errors = planner.validate(nil)
    assert.is_false(ok)
    assert.is_true(#errors > 0)
  end)

  it("rejects a task with an empty description", function()
    local plan = { tasks = { make_task({ description = "" }) } }
    local ok, errors = planner.validate(plan)
    assert.is_false(ok)
    assert.truthy(errors[1]:find("description"))
  end)

  it("rejects an invalid task_type", function()
    local plan = { tasks = { make_task({ task_type = "dance" }) } }
    local ok, errors = planner.validate(plan)
    assert.is_false(ok)
    assert.truthy(errors[1]:find("task_type"))
  end)

  it("rejects an invalid context scope", function()
    local plan = { tasks = { make_task({
      context_requirements = { files = {}, scope = "galaxy", include_git = false }
    }) } }
    local ok, errors = planner.validate(plan)
    assert.is_false(ok)
    assert.truthy(errors[1]:find("scope"))
  end)

  it("rejects a dependency on an unknown task id", function()
    local plan = {
      tasks = {
        make_task({ id = "t1", depends_on = { "missing" } }),
      },
    }
    local ok, errors = planner.validate(plan)
    assert.is_false(ok)
    assert.truthy(errors[1]:find("missing"))
  end)

  it("rejects duplicate task ids", function()
    local plan = {
      tasks = {
        make_task({ id = "dup" }),
        make_task({ id = "dup" }),
      },
    }
    local ok, errors = planner.validate(plan)
    assert.is_false(ok)
    assert.truthy(errors[1]:find("dup"))
  end)

  it("rejects a cyclic dependency", function()
    local plan = {
      tasks = {
        make_task({ id = "t1", depends_on = { "t2" } }),
        make_task({ id = "t2", depends_on = { "t1" } }),
      },
    }
    local ok, errors = planner.validate(plan)
    assert.is_false(ok)
    assert.truthy(errors[1]:find("cycle"))
  end)

end)

-- ── planner helpers ───────────────────────────────────────────────────────────

describe("planner helpers", function()

  local plan

  before_each(function()
    plan = {
      tasks = {
        make_task({ id = "t1", status = "done"    }),
        make_task({ id = "t2", status = "running" }),
        make_task({ id = "t3", status = "pending" }),
        make_task({ id = "t4", status = "pending", depends_on = { "t1" } }),
      },
    }
  end)

  it("get_task() finds a task by id", function()
    local t = planner.get_task(plan, "t2")
    assert.is_not_nil(t)
    assert.are.equal("t2", t.id)
  end)

  it("get_task() returns nil for an unknown id", function()
    assert.is_nil(planner.get_task(plan, "ghost"))
  end)

  it("tasks_by_status() returns matching tasks", function()
    local pending = planner.tasks_by_status(plan, "pending")
    assert.are.equal(2, #pending)
    for _, t in ipairs(pending) do
      assert.are.equal("pending", t.status)
    end
  end)

  it("tasks_by_status() returns empty list when none match", function()
    local failed = planner.tasks_by_status(plan, "failed")
    assert.are.same({}, failed)
  end)

  it("deps_satisfied() returns true when all deps are done", function()
    assert.is_true(planner.deps_satisfied(plan, plan.tasks[4]))
  end)

  it("deps_satisfied() returns false when a dep is not done", function()
    plan.tasks[1].status = "running"
    assert.is_false(planner.deps_satisfied(plan, plan.tasks[4]))
  end)

  it("deps_satisfied() returns true for a task with no deps", function()
    assert.is_true(planner.deps_satisfied(plan, plan.tasks[3]))
  end)

end)
