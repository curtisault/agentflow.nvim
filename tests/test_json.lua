-- tests/test_json.lua — Unit tests for util/json.lua

local json = require("agentflow.util.json")

describe("json.encode / json.decode", function()

  it("round-trips a simple table", function()
    local value   = { name = "test", count = 42, flag = true }
    local encoded, enc_err = json.encode(value)
    assert.is_nil(enc_err)
    assert.is_not_nil(encoded)

    local decoded, dec_err = json.decode(encoded)
    assert.is_nil(dec_err)
    assert.are.equal("test", decoded.name)
    assert.are.equal(42, decoded.count)
    assert.are.equal(true, decoded.flag)
  end)

  it("round-trips a nested structure", function()
    local value   = { tasks = { { id = "t1", depends_on = { "t2", "t3" } } } }
    local encoded, _ = json.encode(value)
    local decoded, _ = json.decode(encoded)
    assert.are.equal("t1", decoded.tasks[1].id)
    assert.are.equal("t2", decoded.tasks[1].depends_on[1])
  end)

  it("returns error on invalid JSON", function()
    local result, err = json.decode("{invalid}")
    assert.is_nil(result)
    assert.is_not_nil(err)
  end)

  it("returns error on empty string", function()
    local result, err = json.decode("")
    assert.is_nil(result)
    assert.is_not_nil(err)
  end)

end)

describe("json.extract", function()

  it("extracts JSON from a fenced code block", function()
    local text = 'Here is the plan:\n\n```json\n{"tasks":[]}\n```\n\nDone.'
    local raw, err = json.extract(text)
    assert.is_nil(err)
    assert.are.equal('{"tasks":[]}', raw)
  end)

  it("extracts bare JSON object from prose", function()
    local text = 'Response: {"key":"value"} end.'
    local raw, err = json.extract(text)
    assert.is_nil(err)
    assert.truthy(raw:find('"key"'))
  end)

  it("returns error when no JSON found", function()
    local raw, err = json.extract("no json here")
    assert.is_nil(raw)
    assert.is_not_nil(err)
  end)

end)
