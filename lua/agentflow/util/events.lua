-- util/events.lua — Simple pub/sub event bus.
--
-- Decouples the core (orchestrator, agents, pool) from the UI.
-- All callbacks are scheduled via vim.schedule so they never fire
-- inside a coroutine yield point.
--
-- Usage:
--   local events = require("agentflow.util.events").new()
--   events.on("agent:completed", function(data) ... end)
--   events.emit("agent:completed", { agent = agent, result = result })

local M = {}

--- Create a new event bus instance.
--- @return table  Event bus with on(), off(), emit(), clear()
function M.new()
  local bus = {
    _listeners = {},  -- event_name → { id → fn }
    _next_id   = 1,
  }

  --- Subscribe to an event. Returns a subscription ID for later removal.
  --- @param event string
  --- @param fn function  Called with (data) when the event fires
  --- @return number  subscription id
  function bus.on(event, fn)
    if not bus._listeners[event] then
      bus._listeners[event] = {}
    end
    local id = bus._next_id
    bus._next_id = bus._next_id + 1
    bus._listeners[event][id] = fn
    return id
  end

  --- Unsubscribe by subscription ID.
  --- @param event string
  --- @param id number
  function bus.off(event, id)
    if bus._listeners[event] then
      bus._listeners[event][id] = nil
    end
  end

  --- Emit an event, calling all registered listeners.
  --- Callbacks are always run via vim.schedule (safe from coroutines).
  --- @param event string
  --- @param data any
  function bus.emit(event, data)
    local listeners = bus._listeners[event]
    if not listeners then return end

    -- Snapshot keys to avoid mutation during iteration
    local fns = {}
    for _, fn in pairs(listeners) do
      table.insert(fns, fn)
    end

    vim.schedule(function()
      for _, fn in ipairs(fns) do
        local ok, err = pcall(fn, data)
        if not ok then
          -- Avoid requiring log here to prevent circular deps
          vim.notify(
            "AgentFlow event error [" .. event .. "]: " .. tostring(err),
            vim.log.levels.ERROR
          )
        end
      end
    end)
  end

  --- Remove all listeners for an event, or all listeners if event is nil.
  --- @param event string|nil
  function bus.clear(event)
    if event then
      bus._listeners[event] = {}
    else
      bus._listeners = {}
    end
  end

  --- Return the list of events that have at least one listener.
  --- @return string[]
  function bus.active_events()
    local out = {}
    for ev, listeners in pairs(bus._listeners) do
      if next(listeners) then
        table.insert(out, ev)
      end
    end
    table.sort(out)
    return out
  end

  return bus
end

-- ── Global singleton ──────────────────────────────────────────────────────────
-- Most of the plugin uses a single shared bus. Individual tests can create
-- isolated instances via M.new().

local _global = M.new()

function M.on(event, fn)        return _global.on(event, fn)   end
function M.off(event, id)       return _global.off(event, id)  end
function M.emit(event, data)    return _global.emit(event, data) end
function M.clear(event)         return _global.clear(event)    end
function M.active_events()      return _global.active_events() end

--- Replace the global bus (useful in tests).
function M.reset()
  _global = M.new()
end

return M
