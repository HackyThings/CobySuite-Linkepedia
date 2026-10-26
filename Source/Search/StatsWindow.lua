-- Stats Window: a movable window of live performance metrics (/lp stats)

local Search = CobysLinkepedia.Search
local Utilities = CobysLinkepedia.Utilities

local ADDON_NAME = "CobysLinkepedia"
local UPDATE_INTERVAL = 0.5
local MEMORY_INTERVAL = 30

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local FormatKB = CobysLinkepedia.Utilities.FormatKB
local FormatUptime = CobysLinkepedia.Utilities.FormatDuration

-- Green while it holds, gray when not: an idle state is no error
local function GreenGray(val, text)
  local colors = Utilities.Colors
  return Utilities.WrapColor(val and colors.TEXT_GREEN or colors.DISABLED_GRAY, text)
end

-- The addon counts are kept between polls until an addon loads. The
-- session clock starts at this login or reload.
local addonCountText
local sessionStart
local DEBUG_BUFFER_SIZE = 5000   -- the shared logger's default; Debug/Logger.lua sets no other

local function AddonCountText()
  if not addonCountText then
    local loaded = 0
    for i = 1, C_AddOns.GetNumAddOns() do
      if C_AddOns.IsAddOnLoaded(i) then loaded = loaded + 1 end
    end
    addonCountText = string.format("%d / %d", loaded, C_AddOns.GetNumAddOns())
  end
  return addonCountText
end

local statsEvents = CreateFrame("Frame")
statsEvents:RegisterEvent("ADDON_LOADED")
statsEvents:RegisterEvent("PLAYER_LOGIN")
statsEvents:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    sessionStart = GetTime()
  end
  addonCountText = nil
end)

-------------------------------------------------------------------------------
-- Metric definitions
-------------------------------------------------------------------------------
local METRICS = {
  {
    label = "Coby's Linkepedia memory",
    getValue = function()
      return FormatKB(GetAddOnMemoryUsage(ADDON_NAME))
    end,
    tooltip = "Memory used by Coby's Linkepedia",
  },
  {
    label = "All addons memory",
    getValue = function()
      local total = 0
      for i = 1, C_AddOns.GetNumAddOns() do
        total = total + GetAddOnMemoryUsage(i)
      end
      return FormatKB(total)
    end,
    tooltip = "Total memory across all loaded addons",
  },
  {
    label = "Framerate",
    getValue = function()
      return string.format("%.1f fps", GetFramerate())
    end,
    tooltip = "Current frames per second",
  },
  {
    label = "Home latency",
    getValue = function()
      local _, _, home = GetNetStats()
      return string.format("%.0f ms", home)
    end,
    tooltip = "How long the game server takes to answer.",
  },
  {
    label = "World latency",
    getValue = function()
      local _, _, _, world = GetNetStats()
      return string.format("%.0f ms", world)
    end,
    tooltip = "How long the world server takes to answer.",
  },
  {
    label = "Database items",
    getValue = function()
      local count = CobysLinkepedia.Database.GetCount()
      return BreakUpLargeNumbers(count)
    end,
    tooltip = "Total items stored in the item database",
  },
  {
    label = "Captured variants",
    getValue = function()
      return BreakUpLargeNumbers(CobysLinkepedia.Database.GetVariantTotal())
    end,
    tooltip = "Distinct item variants captured from gameplay",
  },
  {
    label = "Pending items",
    getValue = function()
      return BreakUpLargeNumbers(CobysLinkepedia.Scanner.GetIdleStatus().queued)
    end,
    tooltip = "Items the server has not sent yet. The idle scan keeps asking for them.",
  },
  {
    label = "Scan active",
    getValue = function()
      local status = CobysLinkepedia.Scanner.GetStatus()
      if status and status.isActive then
        return GreenGray(true, "Yes") .. "  (" .. (status.scanMode or "?") .. ")"
      end
      return GreenGray(false, "No")
    end,
    tooltip = "Whether a scan is currently in progress",
  },
  {
    label = "Debug buffer",
    getValue = function()
      local size = CobysLinkepedia.Debug.GetBufferSize()
      return string.format("%d / %d", size, DEBUG_BUFFER_SIZE)
    end,
    tooltip = "Entries held in the debug log",
  },
  {
    label = "Loaded addons",
    getValue = AddonCountText,
    tooltip = "Loaded / total installed addons",
  },
  {
    label = "Session uptime",
    getValue = function()
      if not sessionStart then return "--" end
      return FormatUptime(GetTime() - sessionStart)
    end,
    tooltip = "Time since this login or reload",
  },
}

-------------------------------------------------------------------------------
-- Window creation: at PLAYER_LOGIN (below), or on first open if login came in
-- combat; never while in combat, since that would create frames
-------------------------------------------------------------------------------
local statsWindow = nil

local function CreateStatsWindow()
  if statsWindow then return statsWindow end

  local ROW_H = 18
  local LABEL_W = 170
  local PAD = 10
  local numMetrics = #METRICS
  local winH = numMetrics * ROW_H + 50

  -- Shell: draggable, its place saved with the other windows' (the screen's
  -- center until it is moved). No solid background: the template art alone.
  local f = CobySuite_CobysLinkepedia.UI.CreateWindow({
    name = "CobysLinkepediaStatsWindow",
    title = Utilities.WrapColor(CobysLinkepedia.BRAND_COLOR, "Coby's Linkepedia") .. " Stats",
    icon = CobysLinkepedia.ICON,
    width = 340,
    height = winH,
    solidBackground = false,
    escapeCloses = true,
    persist = {
      svTable = function() return COBYS_LINKEPEDIA_WINDOW_STATE end,
      key = "statsWindow",
      fixedSize = true,
    },
  })

  f._memTimer = 0

  f._metricList = CobySuite_CobysLinkepedia.UI.CreateMetricList(f, METRICS, {
    labelWidth = LABEL_W, padding = PAD, top = 28, errorText = Utilities.WrapColor(Utilities.Colors.WARNING_RED, "error"),
  })

  -- Refresh logic
  function f:RefreshMetrics()
    self._memTimer = (self._memTimer or 0) + UPDATE_INTERVAL
    if self._memTimer >= MEMORY_INTERVAL then
      UpdateAddOnMemoryUsage()
      self._memTimer = 0
    end
    self._metricList.Refresh()
  end

  -- Every UPDATE_INTERVAL while shown, and on the first frame after a show
  local onUpdate, runSoon = CobySuite_CobysLinkepedia.Utilities.Throttle(UPDATE_INTERVAL, function(self)
    self:RefreshMetrics()
  end)
  f:SetScript("OnUpdate", onUpdate)

  f:SetScript("OnShow", function(self)
    UpdateAddOnMemoryUsage()
    runSoon(self)
  end)

  statsWindow = f
  return f
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------
function Search.ToggleStatsWindow()
  if not statsWindow and InCombatLockdown() then
    Utilities.Message.Warn("The stats window can't open for the first time in combat. Try again after combat.")
    return
  end
  CreateStatsWindow():Toggle()
end

-- The window once it is built (nil before)
function Search.GetStatsWindow()
  return statsWindow
end

EventUtil.ContinueOnPlayerLogin(function()
  if not InCombatLockdown() then CreateStatsWindow() end
end)
