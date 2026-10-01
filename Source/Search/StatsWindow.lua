-- Stats Window: a movable window of live performance metrics (/lp stats)
-- Adapted from CobySniper's Monitor StatsTab pattern.

local Search = CobysLinkepedia.Search
local Utilities = CobysLinkepedia.Utilities
local Debug = CobysLinkepedia.Debug

local ADDON_NAME = "CobysLinkepedia"
local UPDATE_INTERVAL = 0.5
local MEMORY_INTERVAL = 30

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local FormatKB = CobysLinkepedia.Utilities.FormatKB
local FormatUptime = CobysLinkepedia.Utilities.FormatDuration

local function GreenRed(val, text)
  local colors = Utilities.Colors
  return Utilities.WrapColor(val and colors.TEXT_GREEN or colors.TEXT_RED, text)
end

-- Counts that rarely change are kept between polls: the variant total until
-- the variant generation moves, the addon counts until an addon loads. The
-- session clock starts at this login or reload.
local variantCount, variantCountGeneration
local addonCountText
local sessionStart

local function CapturedVariantCount()
  local generation = CobysLinkepedia.Database.GetVariantGeneration()
  if variantCountGeneration ~= generation then
    local count = 0
    if COBYS_LINKEPEDIA_DB and COBYS_LINKEPEDIA_DB.variants then
      for _, v in pairs(COBYS_LINKEPEDIA_DB.variants) do
        count = count + #v
      end
    end
    variantCount, variantCountGeneration = count, generation
  end
  return variantCount
end

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
    label = "Coby's Linkepedia Memory",
    getValue = function()
      return FormatKB(GetAddOnMemoryUsage(ADDON_NAME))
    end,
    tooltip = "Memory used by Coby's Linkepedia",
  },
  {
    label = "All Addons Memory",
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
    label = "Home Latency",
    getValue = function()
      local _, _, home = GetNetStats()
      return string.format("%.0f ms", home)
    end,
    tooltip = "Latency to home (game) server",
  },
  {
    label = "World Latency",
    getValue = function()
      local _, _, _, world = GetNetStats()
      return string.format("%.0f ms", world)
    end,
    tooltip = "Latency to world server",
  },
  {
    label = "Database Items",
    getValue = function()
      local count = CobysLinkepedia.Database.GetCount and CobysLinkepedia.Database.GetCount() or 0
      return tostring(count)
    end,
    tooltip = "Total items stored in the item database",
  },
  {
    label = "Captured Variants",
    getValue = function()
      return tostring(CapturedVariantCount())
    end,
    tooltip = "Distinct item variants captured from gameplay",
  },
  {
    label = "Pending Items",
    getValue = function()
      if COBYS_LINKEPEDIA_DB and COBYS_LINKEPEDIA_DB.scanState and COBYS_LINKEPEDIA_DB.scanState.pendingIDs then
        return tostring(#COBYS_LINKEPEDIA_DB.scanState.pendingIDs)
      end
      return "0"
    end,
    tooltip = "Items queued for retry in idle scan (not yet resolved from server)",
  },
  {
    label = "Scan Active",
    getValue = function()
      local status = CobysLinkepedia.Scanner.GetStatus and CobysLinkepedia.Scanner.GetStatus()
      if status and status.isActive then
        return GreenRed(true, "Yes") .. "  (" .. (status.scanMode or "?") .. ")"
      end
      return GreenRed(false, "No")
    end,
    tooltip = "Whether a scan is currently in progress",
  },
  {
    label = "Debug Buffer",
    getValue = function()
      local size = CobysLinkepedia.Debug.GetBufferSize and CobysLinkepedia.Debug.GetBufferSize() or 0
      return string.format("%d / 5000", size)
    end,
    tooltip = "Debug log entries in the ring buffer",
  },
  {
    label = "Loaded Addons",
    getValue = AddonCountText,
    tooltip = "Loaded / total installed addons",
  },
  {
    label = "Session Uptime",
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
  local LABEL_W = 140
  local PAD = 10
  local numMetrics = #METRICS
  local winH = numMetrics * ROW_H + 50

  -- Shell: draggable, position not persisted. No solid background: the
  -- window has always shown the template art alone.
  local f = CobySuite_CobysLinkepedia.UI.CreateWindow({
    name = "CobysLinkepediaStatsWindow",
    title = "Coby's Linkepedia Stats",
    width = 340,
    height = winH,
    solidBackground = false,
    escapeCloses = true,
  })

  f._memTimer = 0

  -- the shared metric rows (CobySuite.UI.CreateMetricList)
  f._metricList = CobySuite_CobysLinkepedia.UI.CreateMetricList(f, METRICS, {
    labelWidth = LABEL_W, padding = PAD, top = 28, errorText = "|cFFFF4D4Derror|r",
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

EventUtil.ContinueOnPlayerLogin(function()
  if not InCombatLockdown() then CreateStatsWindow() end
end)

Debug.Log("INIT", "Stats window loaded")
