-- Status Window: the database, the scans and the idle scan at a glance,
-- updated live while it shows (/lp status). Built at load, like the search
-- window, so opening it in combat creates nothing.

local Search = CobysLinkepedia.Search
local Database = CobysLinkepedia.Database
local Scanner = CobysLinkepedia.Scanner
local Config = CobysLinkepedia.Config
local Utilities = CobysLinkepedia.Utilities
local Debug = CobysLinkepedia.Debug

local UPDATE_INTERVAL = 0.5
local WIDTH = 540
local PAD = 12
local TOP = 30
local SECTION_H = 26
local ROW_H = 18
local LABEL_W = 150

-------------------------------------------------------------------------------
-- Text helpers
-------------------------------------------------------------------------------
local Colors = Utilities.Colors
local QUIET_GRAY = "999999"   -- no shared color between DISABLED_GRAY and LABEL_GRAY

local function Green(text) return Utilities.WrapColor(Colors.TEXT_GREEN, text) end
local function Gold(text) return Utilities.WrapColor(Colors.TEXT_GOLD, text) end
local function Red(text) return Utilities.WrapColor(Colors.WARNING_RED, text) end
local function Gray(text) return Utilities.WrapColor(QUIET_GRAY, text) end

-- A count with the player's thousands separator
local function Count(n)
  return BreakUpLargeNumbers(n or 0)
end

local function Plural(n, one, many)
  return Count(n) .. " " .. (n == 1 and one or many)
end

local MODE_NAMES = { build = "Build", expand = "Expand" }

-- The scan footer's words for each phase (Search/ScanStatus.lua)
local PHASE_NAMES = {
  DISCOVER = "Finding items",
  SCANNING = "Scanning",
  REFINE_WAIT = "Waiting for item data",
  REFINING = "Retrying",
  PAUSED = "Paused",
}

-------------------------------------------------------------------------------
-- Rows. Each value function gets one snapshot per refresh:
-- { scan = Scanner.GetStatus(), last = Scanner.GetLastScan(), idle = Scanner.GetIdleStatus() }
-------------------------------------------------------------------------------
local function NowText(s)
  local scan = s.scan
  if not scan.isActive then return Gray("Not scanning") end
  local mode = MODE_NAMES[scan.scanMode] or "Scan"
  if scan.intensity then mode = mode .. " (" .. scan.intensity .. ")" end
  local phase = PHASE_NAMES[scan.state] or scan.state
  if scan.state == "PAUSED" then phase = Gold(phase) end
  local pct = math.floor(scan.position / math.max(scan.upperBound, 1) * 100)
  local text = mode .. ": " .. phase .. " " .. pct .. "%, " .. Count(scan.itemsFound) .. " found"
  local eta = Scanner.GetETA()
  if eta then text = text .. ", " .. Utilities.FormatDuration(eta) .. " left in this step" end
  return text
end

local function LastScanText(s)
  local last = s.last
  local finished = last and last.finishedAt and date("%Y-%m-%d %H:%M", last.finishedAt)
  if s.scan.isActive then
    return "Running now" .. (finished and Gray("; the last one finished " .. finished) or "")
  end
  if not last or last.complete == nil then
    return Gold("None yet: /lp build makes your database")
  end
  local mode = MODE_NAMES[last.mode] or "Scan"
  if last.complete == false then
    local upper = last.upperBound or 0
    local pct = upper > 0 and math.floor(math.min((last.position or 0) / upper, 0.99) * 100) or 0
    return Gold(mode .. " stopped at " .. pct .. "%: /lp expand continues it")
  end
  return mode .. ", finished " .. (finished or "?")
end

local function IdleText(s)
  local idle = s.idle
  if not idle.running then
    if Config.Get(Config.Options.IDLE_SCAN_ENABLED) == false then
      return Gray("Off (Settings > Item database)")
    end
    return Gray("Stopped")
  end
  local speed = Plural(idle.rate, "item ID", "item IDs") .. " a second"
  if idle.blocked == "scan" then return Gold("Waiting while a scan runs") end
  if idle.blocked == "combat" then return Gold("Waiting until combat ends") end
  if idle.queued == 0 then return Green("On") .. ", nothing to ask about" end
  return Green("Working") .. ", " .. speed
end

local function PassText(s)
  local idle = s.idle
  if idle.queued == 0 then return Gray("--") end
  local left = math.max(idle.queued - idle.passDone, 0)
  return Count(idle.passDone) .. " of " .. Count(idle.queued) .. ", about "
    .. Utilities.FormatDuration(math.ceil(left / math.max(idle.rate, 1))) .. " to go"
end

local SECTIONS = {
  {
    title = "Database",
    rows = {
      {
        key = "items", label = "Items",
        tooltip = "Items in your database. Search, autocomplete and linking by name use them.",
        value = function() return Count(Database.GetCount()) end,
      },
      {
        key = "variants", label = "Captured variants",
        tooltip = "Crafted ranks, upgrade levels and other versions of items, captured from your bags, gear, loot, trades, mail and the links other players post.",
        value = function() return Count(Database.GetVariantTotal()) end,
      },
      {
        key = "index", label = "Search index",
        tooltip = "The index search and autocomplete read, built from the database at login.",
        value = function()
          if Database.IsIndexComplete() then return Green("Ready") end
          return Red("Incomplete: /reload rebuilds it")
        end,
      },
    },
  },
  {
    title = "Scans",
    rows = {
      {
        key = "now", label = "Now",
        tooltip = "The scan running now, if any: its step, how far it has got and the items it found.",
        value = NowText,
      },
      {
        key = "last", label = "Last scan",
        tooltip = "The last Build or Expand, and whether it ran to its end.",
        value = LastScanText,
      },
      {
        key = "highest", label = "Highest item ID",
        tooltip = "The highest item ID your game client knows, as of the last scan.",
        value = function(s)
          local highest = s.last and s.last.highestID
          return (highest and highest > 0) and Count(highest) or Gray("--")
        end,
      },
      {
        key = "lastItem", label = "Last item stored",
        tooltip = "The newest item a scan or the idle scan stored this session.",
        value = function(s)
          if not s.scan.lastFoundName then return Gray("None this session") end
          return s.scan.lastFoundName .. Gray("  (ID " .. s.scan.lastFoundID .. ")")
        end,
      },
    },
  },
  {
    title = "Idle Scan",
    rows = {
      {
        key = "idle", label = "Idle scan",
        tooltip = "The background scan that asks the server again for the items a scan held back, never in combat.",
        value = IdleText,
      },
      {
        key = "queue", label = "Waiting on the server",
        tooltip = "Item IDs the last scan could not get from the server. The idle scan asks for each again.",
        value = function(s)
          if s.idle.queued == 0 then return Gray("None") end
          return Plural(s.idle.queued, "item ID", "item IDs")
        end,
      },
      {
        key = "pass", label = "This pass",
        tooltip = "How far the idle scan has got through its queue this time round. An ID the server has not answered yet waits for the next pass.",
        value = PassText,
      },
      {
        key = "session", label = "This session",
        tooltip = "What the idle scan did since this login or reload.",
        value = function(s)
          local idle = s.idle
          return Count(idle.asked) .. " asked, " .. Count(idle.stored) .. " stored, "
            .. Count(idle.dead) .. " skipped"
        end,
      },
      {
        key = "unanswered", label = "No answer so far",
        tooltip = "Item IDs the last scan asked the server about twice and heard nothing. If the next Expand hears nothing either, they are skipped from then on.",
        value = function()
          local count = Scanner.GetUnansweredCount()
          if count == 0 then return Gray("None") end
          return Plural(count, "item ID", "item IDs") .. Gray("  (one more silent scan and they are skipped)")
        end,
      },
      {
        key = "dead", label = "Skipped item IDs",
        tooltip = "Item IDs your game client lists that the server refused, or never answered in two scans. They are skipped until the next game patch.",
        value = function()
          local dead = Scanner.GetDeadCount()
          if dead == 0 then return Gray("None found yet") end
          return Plural(dead, "item ID", "item IDs") .. ", skipped until the next game patch"
        end,
      },
    },
  },
}

-------------------------------------------------------------------------------
-- Window
-------------------------------------------------------------------------------
local rowTotal = 0
for _, section in ipairs(SECTIONS) do rowTotal = rowTotal + #section.rows end

local window = CobySuite_CobysLinkepedia.UI.CreateWindow({
  name = "CobysLinkepediaStatusWindow",
  title = Utilities.WrapColor(Utilities.Colors.TEXT_TEAL, "Coby's Linkepedia") .. " Status",
  icon = CobysLinkepedia.ICON,
  width = WIDTH,
  height = TOP + #SECTIONS * SECTION_H + rowTotal * ROW_H + PAD,
  escapeCloses = true,
  persist = {
    svTable = function() return COBYS_LINKEPEDIA_WINDOW_STATE end,
    key = "statusWindow",
    fixedSize = true,
  },
})

window.Rows = {}       -- key -> row frame, with .Value
local lists = {}       -- one shared metric list per section

local function OnRowError(metric, err)
  Debug.Warn("UI", "Status window row %s failed: %s", metric.key, tostring(err))
end

local y = -TOP
for _, section in ipairs(SECTIONS) do
  CobySuite_CobysLinkepedia.UI.CreateSection(window, {
    text = section.title,
    point = { "TOPLEFT", PAD, y - 6 },
    width = WIDTH - PAD * 2,
  })
  y = y - SECTION_H

  local metrics = {}
  for i, def in ipairs(section.rows) do
    metrics[i] = { key = def.key, label = def.label, tooltip = def.tooltip, getValue = def.value }
  end
  local list = CobySuite_CobysLinkepedia.UI.CreateMetricList(window, metrics, {
    rowHeight = ROW_H, labelWidth = LABEL_W, padding = PAD, top = -y,
    errorText = Red("error"), onError = OnRowError,
  })
  for _, row in ipairs(list.rows) do
    -- Inset the label from the shaded row, and keep a long value on its line
    row.Label:SetPoint("LEFT", 4, 0)
    row.Value:SetWordWrap(false)
  end
  for key, row in pairs(list.byKey) do window.Rows[key] = row end
  lists[#lists + 1] = list
  y = y - #section.rows * ROW_H
end

-- Every row reads the same snapshot of the scanner
function window:Refresh()
  local snapshot = {
    scan = Scanner.GetStatus(),
    last = Scanner.GetLastScan(),
    idle = Scanner.GetIdleStatus(),
  }
  for _, list in ipairs(lists) do list.Refresh(snapshot) end
end

-- Every UPDATE_INTERVAL while shown, and at once when it opens
window:SetScript("OnUpdate", (CobySuite_CobysLinkepedia.Utilities.Throttle(UPDATE_INTERVAL, function(self)
  self:Refresh()
end)))
window:SetScript("OnShow", function(self)
  self:Refresh()
end)

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------
function Search.GetStatusWindow()
  return window
end

function Search.ToggleStatusWindow()
  window:Toggle()
end

Debug.Log("INIT", "Status window loaded")
