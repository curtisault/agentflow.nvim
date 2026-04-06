-- tests/test_agents_registry.lua — Unit tests for agents/init.lua

local agents

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(content, "\n"), path)
end

local function with_cwd(dir, fn)
  local orig = vim.fn.getcwd()
  vim.fn.chdir(dir)
  local ok, err = pcall(fn)
  vim.fn.chdir(orig)
  if not ok then error(err, 2) end
end

local function temp_project()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

-- ── Registry CRUD ─────────────────────────────────────────────────────────────

describe("agents registry", function()

  before_each(function()
    package.loaded["agentflow.agents"] = nil
    agents = require("agentflow.agents")
  end)

  it("registers and retrieves an agent by name", function()
    agents.register({ name = "alpha", model = "claude-sonnet-4-6", backend = "cli" })
    local a = agents.get("alpha")
    assert.is_not_nil(a)
    assert.are.equal("alpha", a.name)
    assert.are.equal("claude-sonnet-4-6", a.model)
  end)

  it("get() returns nil for an unknown name", function()
    assert.is_nil(agents.get("does-not-exist"))
  end)

  it("list() returns all agents sorted by name", function()
    agents.register({ name = "charlie", model = "m", backend = "cli" })
    agents.register({ name = "alpha",   model = "m", backend = "cli" })
    agents.register({ name = "bravo",   model = "m", backend = "cli" })
    local list = agents.list()
    assert.are.equal(3, #list)
    assert.are.equal("alpha",   list[1].name)
    assert.are.equal("bravo",   list[2].name)
    assert.are.equal("charlie", list[3].name)
  end)

  it("remove() unregisters an agent", function()
    agents.register({ name = "gone", model = "m", backend = "cli" })
    agents.remove("gone")
    assert.is_nil(agents.get("gone"))
  end)

  it("remove() on unknown name is a no-op", function()
    assert.has_no_error(function() agents.remove("ghost") end)
  end)

  it("clear() empties the registry", function()
    agents.register({ name = "a1", model = "m", backend = "cli" })
    agents.register({ name = "a2", model = "m", backend = "cli" })
    agents.clear()
    assert.are.equal(0, #agents.list())
  end)

  it("re-registering same name overwrites previous entry", function()
    agents.register({ name = "dup", model = "model-a", backend = "cli" })
    agents.register({ name = "dup", model = "model-b", backend = "cli" })
    assert.are.equal("model-b", agents.get("dup").model)
    assert.are.equal(1, #agents.list())
  end)

  it("register() deep-copies config so later mutations don't affect registry", function()
    local cfg = { name = "isolated", model = "original", backend = "cli" }
    agents.register(cfg)
    cfg.model = "mutated"
    assert.are.equal("original", agents.get("isolated").model)
  end)

end)

-- ── load_from_project_dir — markdown ─────────────────────────────────────────

describe("agents.load_from_project_dir (markdown)", function()

  before_each(function()
    package.loaded["agentflow.agents"] = nil
    agents = require("agentflow.agents")
  end)

  it("loads a valid .md file with frontmatter and system prompt", function()
    local project = temp_project()
    write_file(project .. "/.agentflow/agents/rust-expert.md", table.concat({
      "---",
      "name: rust-expert",
      "model: claude-opus-4-6",
      "backend: cli",
      "role: subagent",
      "---",
      "",
      "You are a Rust expert.",
    }, "\n"))

    with_cwd(project, function() agents.load_from_project_dir() end)

    local a = agents.get("rust-expert")
    assert.is_not_nil(a)
    assert.are.equal("rust-expert",    a.name)
    assert.are.equal("claude-opus-4-6", a.model)
    assert.are.equal("subagent",        a.role)
    assert.are.equal("You are a Rust expert.", a.system_prompt)
  end)

  it("parses numeric frontmatter values as numbers", function()
    local project = temp_project()
    write_file(project .. "/.agentflow/agents/typed.md", table.concat({
      "---",
      "name: typed",
      "model: claude-sonnet-4-6",
      "backend: cli",
      "max_tokens: 4096",
      "---",
    }, "\n"))

    with_cwd(project, function() agents.load_from_project_dir() end)

    assert.are.equal(4096, agents.get("typed").max_tokens)
  end)

  it("agent without a body has no system_prompt", function()
    local project = temp_project()
    write_file(project .. "/.agentflow/agents/no-body.md", table.concat({
      "---",
      "name: no-body",
      "model: claude-sonnet-4-6",
      "backend: cli",
      "---",
    }, "\n"))

    with_cwd(project, function() agents.load_from_project_dir() end)

    local a = agents.get("no-body")
    assert.is_not_nil(a)
    assert.is_nil(a.system_prompt)
  end)

  it("skips .md file missing 'name'", function()
    local project = temp_project()
    write_file(project .. "/.agentflow/agents/bad.md", table.concat({
      "---",
      "model: claude-sonnet-4-6",
      "---",
    }, "\n"))

    with_cwd(project, function() agents.load_from_project_dir() end)
    assert.are.equal(0, #agents.list())
  end)

  it("skips .md file missing 'model'", function()
    local project = temp_project()
    write_file(project .. "/.agentflow/agents/bad.md", table.concat({
      "---",
      "name: no-model",
      "---",
    }, "\n"))

    with_cwd(project, function() agents.load_from_project_dir() end)
    assert.is_nil(agents.get("no-model"))
  end)

  it("skips .md file without opening ---", function()
    local project = temp_project()
    write_file(project .. "/.agentflow/agents/bad.md",
      "name: no-frontmatter\nmodel: claude-sonnet-4-6\n")

    with_cwd(project, function() agents.load_from_project_dir() end)
    assert.are.equal(0, #agents.list())
  end)

  it("loads multiple .md files in one pass", function()
    local project = temp_project()
    write_file(project .. "/.agentflow/agents/a.md",
      "---\nname: agent-a\nmodel: claude-sonnet-4-6\nbackend: cli\n---\n")
    write_file(project .. "/.agentflow/agents/b.md",
      "---\nname: agent-b\nmodel: claude-opus-4-6\nbackend: cli\n---\n")

    with_cwd(project, function() agents.load_from_project_dir() end)

    assert.is_not_nil(agents.get("agent-a"))
    assert.is_not_nil(agents.get("agent-b"))
    assert.are.equal(2, #agents.list())
  end)

end)

-- ── load_from_project_dir — JSON (legacy) ────────────────────────────────────

describe("agents.load_from_project_dir (json legacy)", function()

  before_each(function()
    package.loaded["agentflow.agents"] = nil
    agents = require("agentflow.agents")
  end)

  it("loads a valid .json agent file", function()
    local project = temp_project()
    write_file(project .. "/.agentflow/agents/go.json",
      vim.fn.json_encode({ name = "go-expert", model = "claude-sonnet-4-6", backend = "cli" }))

    with_cwd(project, function() agents.load_from_project_dir() end)

    local a = agents.get("go-expert")
    assert.is_not_nil(a)
    assert.are.equal("go-expert", a.name)
  end)

  it("skips malformed .json files", function()
    local project = temp_project()
    write_file(project .. "/.agentflow/agents/bad.json", "{not valid json")

    with_cwd(project, function() agents.load_from_project_dir() end)
    assert.are.equal(0, #agents.list())
  end)

  it("skips .json file missing required fields", function()
    local project = temp_project()
    write_file(project .. "/.agentflow/agents/incomplete.json",
      vim.fn.json_encode({ name = "no-model" }))

    with_cwd(project, function() agents.load_from_project_dir() end)
    assert.is_nil(agents.get("no-model"))
  end)

  it("does nothing when .agentflow/agents/ directory does not exist", function()
    local project = temp_project()
    with_cwd(project, function() agents.load_from_project_dir() end)
    assert.are.equal(0, #agents.list())
  end)

end)
