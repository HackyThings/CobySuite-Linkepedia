-------------------------------------------------------------------------------
-- CobySuite.Utilities.LoadItemThen: an item's link now if the client has its
-- data, otherwise once the data loads, with a timeout and a way to cancel, so
-- no caller piles up callbacks or lets an old request land after a newer one.
--
--   local cancel = CobySuite.Utilities.LoadItemThen(itemID, {
--     timeout = 3,                             -- seconds, default 3
--     onReady = function(link, itemID) end,
--     onFail  = function(reason, itemID) end,  -- optional; "timeout", "nolink" or "noitem"
--   })
--   cancel()   -- neither callback runs afterwards; safe to call more than once
--
-- Unless cancelled, exactly one callback runs, and only once. A cached item calls onReady before
-- LoadItemThen returns. The load is Item:ContinueWithCancelOnItemLoad, whose
-- cancel is called when the request times out or is cancelled.
-------------------------------------------------------------------------------
local U = CobySuite_CobysLinkepedia.Utilities

local DEFAULT_TIMEOUT = 3

local function NoOp() end

function U.LoadItemThen(itemID, opts)
  opts = opts or {}
  local onReady = opts.onReady or NoOp
  local onFail = opts.onFail or NoOp

  itemID = tonumber(itemID)
  if not itemID then
    onFail("noitem", itemID)
    return NoOp
  end

  local _, link = C_Item.GetItemInfo(itemID)
  if link then
    onReady(link, itemID)
    return NoOp
  end

  local settled = false
  local cancelLoad, timer

  local function Settle()
    settled = true
    if cancelLoad then
      cancelLoad()
      cancelLoad = nil
    end
    if timer then
      timer:Cancel()
      timer = nil
    end
  end

  timer = C_Timer.NewTimer(opts.timeout or DEFAULT_TIMEOUT, function()
    timer = nil
    if settled then return end
    Settle()
    onFail("timeout", itemID)
  end)

  local ok, cancelOrErr = pcall(function()
    return Item:CreateFromItemID(itemID):ContinueWithCancelOnItemLoad(function()
      if settled then return end
      cancelLoad = nil
      Settle()
      local _, loadedLink = C_Item.GetItemInfo(itemID)
      if loadedLink then
        onReady(loadedLink, itemID)
      else
        onFail("nolink", itemID)
      end
    end)
  end)
  if not ok then
    if not settled then
      Settle()
      onFail("noitem", itemID)
    end
    return NoOp
  end
  -- A load that completed inside the call has already settled
  if not settled then cancelLoad = cancelOrErr end

  return function()
    if not settled then Settle() end
  end
end
