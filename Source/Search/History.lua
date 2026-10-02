-- History: recently linked items, persisted in COBYS_LINKEPEDIA_STATE.history

local Search = CobysLinkepedia.Search
local Config = CobysLinkepedia.Config
local Utilities = CobysLinkepedia.Utilities
local Debug = CobysLinkepedia.Debug

-------------------------------------------------------------------------------
-- Add to history (called whenever a link is produced, from any source)
-------------------------------------------------------------------------------
function Search.AddToHistory(itemID)
  if not COBYS_LINKEPEDIA_STATE or not COBYS_LINKEPEDIA_STATE.history then return end
  if not itemID then return end

  local history = COBYS_LINKEPEDIA_STATE.history
  -- The setter validates this option, but the trim below must end whatever
  -- the saved value is: a negative limit kept it looping forever
  local maxHistory = tonumber(Config.Get(Config.Options.MAX_RECENT_HISTORY))
  if not Utilities.IsFiniteNumber(maxHistory) then maxHistory = 50 end
  local limit = math.max(math.floor(maxHistory), 0)

  local newest = history[1]
  if newest and newest.id == itemID then
    -- Already on top (a macro can link the same item on every press): only
    -- its time moves
    newest.timestamp = time()
  else
    -- Remove duplicate if already in history (will move to top)
    for i = #history, 1, -1 do
      if history[i].id == itemID then
        table.remove(history, i)
        break
      end
    end

    -- Insert at top (most recent first)
    table.insert(history, 1, {
      id = itemID,
      timestamp = time(),
    })
  end

  -- Cap at the limit
  while #history > limit do
    table.remove(history)
  end

  CobysLinkepedia.EventBus:Fire(CobysLinkepedia.Events.HistoryUpdated)
end

-------------------------------------------------------------------------------
-- Clear all history entries
-------------------------------------------------------------------------------
function Search.ClearHistory()
  if not COBYS_LINKEPEDIA_STATE then return end
  COBYS_LINKEPEDIA_STATE.history = {}
  CobysLinkepedia.EventBus:Fire(CobysLinkepedia.Events.HistoryUpdated)
  Debug.Log("UI", "History cleared")
end

-------------------------------------------------------------------------------
-- History tab content: a Clear button over a scrolling item list, left of
-- the detail pane. Rows use the explorer's shared click actions.
-------------------------------------------------------------------------------
do
  -- Deferred init: the window's own OnLoad runs a frame after load
  local function InitHistoryTab()
    if Search._historyFrame then return end
    local window = CobysLinkepediaSearchWindow
    if not window then return end

    local f = CreateFrame("Frame", nil, window)
    f:SetPoint("TOPLEFT", 8, -58)
    f:SetPoint("BOTTOMRIGHT", Search.ContentEdge, "BOTTOMRIGHT", 0, 26)
    f:Hide()

    Utilities.CreateButton(f, {
      text = "Clear History",
      size = { 100, 22 },
      fontSize = 11,
      point = { "TOPRIGHT", -4, -4 },
      tooltip = "Remove every item from History. Favorites are kept.",
      onClick = function()
        Search.ClearHistory()
      end,
    })

    local list = Search.CreateItemList(f, {
      top = -30,
      rightText = function(entry)
        return entry.timestamp and date("%H:%M", entry.timestamp) or ""
      end,
    })

    f.EmptyText = f:CreateFontString(nil, "OVERLAY", Utilities.Fonts.BODY)
    f.EmptyText:SetPoint("CENTER")
    f.EmptyText:SetText("No recent items.\nLink items to add them to history.")
    f.EmptyText:SetTextColor(unpack(Utilities.Colors.DISABLED_GRAY))
    f.EmptyText:SetJustifyH("CENTER")

    function f:RefreshHistory()
      local history = COBYS_LINKEPEDIA_STATE and COBYS_LINKEPEDIA_STATE.history or {}
      list:SetEntries(history)
      self.EmptyText:SetShown(#history == 0)
    end

    f:SetScript("OnShow", function(self) self:RefreshHistory() end)

    CobysLinkepedia.EventBus:Register({ ReceiveEvent = function()
      if f:IsShown() then f:RefreshHistory() end
    end }, { CobysLinkepedia.Events.HistoryUpdated })

    Search._historyFrame = f
  end

  C_Timer.After(0, InitHistoryTab)
end

Debug.Log("INIT", "Search history loaded")
