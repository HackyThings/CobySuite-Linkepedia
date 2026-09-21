-- CobySuite.EventBus: shared pub/sub constructor
-- Each addon gets its own independent instance via New()
--
-- Delivery contract:
--   * Listeners hear an event in the order they registered for it.
--   * Fire delivers to the listeners registered when it starts. One that
--     registers during delivery first hears the next Fire; one unregistered
--     during delivery is skipped if it has not been called yet.
--   * Every listener runs inside its own error boundary (xpcall with the
--     client's error handler): the error is reported as usual, and the other
--     listeners and the code that fired carry on.
--   * A listener may Fire other events (nested delivery is fine).

local EventBus = CobySuite_CobysLinkepedia.EventBus

function EventBus.New()
  local bus = {}
  local ordered = {}      -- eventName -> { listener, ... } in registration order
  local registered = {}   -- eventName -> { [listener] = true }

  -- One scratch array per nesting depth holds the listeners a Fire delivers
  -- to, so delivery allocates nothing once the arrays exist
  local scratch = {}
  local depth = 0

  function bus:Register(listener, eventNames)
    for _, eventName in ipairs(eventNames) do
      local set = registered[eventName]
      if not set then
        set = {}
        registered[eventName] = set
        ordered[eventName] = {}
      end
      if not set[listener] then
        set[listener] = true
        local list = ordered[eventName]
        list[#list + 1] = listener
      end
    end
    return self
  end

  function bus:Unregister(listener, eventNames)
    for _, eventName in ipairs(eventNames) do
      local set = registered[eventName]
      if set and set[listener] then
        set[listener] = nil
        local list = ordered[eventName]
        for i = #list, 1, -1 do
          if list[i] == listener then
            table.remove(list, i)
            break
          end
        end
      end
    end
    return self
  end

  function bus:Fire(eventName, ...)
    local list = ordered[eventName]
    local n = list and #list or 0
    if n == 0 then return self end
    local set = registered[eventName]

    depth = depth + 1
    local snapshot = scratch[depth]
    if not snapshot then
      snapshot = {}
      scratch[depth] = snapshot
    end
    for i = 1, n do snapshot[i] = list[i] end

    local handler = geterrorhandler()
    for i = 1, n do
      local listener = snapshot[i]
      if set[listener] then
        xpcall(listener.ReceiveEvent, handler, listener, eventName, ...)
      end
    end

    for i = 1, n do snapshot[i] = nil end
    depth = depth - 1
    return self
  end

  return bus
end
