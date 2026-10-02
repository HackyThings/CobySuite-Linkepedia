-- Config Examples: the examples in the settings window (Config/Window.lua)
-- and what its Item database card reads. Every example shows what a setting
-- does with the window's staged values and changes nothing.
--
-- One sample item drives the chat examples: the Hearthstone, which every
-- character carries, by the name the player's own database holds for it (so
-- in the player's language), else the newest History item the database has.
-- Its first four characters, cut on UTF-8 boundaries, are both the
-- autocomplete draft and the ${n=} token.
--
-- This file loads before the modules it reads (Database, Scanner, Linkify,
-- Variants, Toast), so it reaches them only inside functions, which run
-- once the window is shown.

local Config = CobysLinkepedia.Config
local Opt = Config.Options
local Utilities = CobysLinkepedia.Utilities
local U = CobySuite_CobysLinkepedia.Utilities

local Examples = {}
Config.Examples = Examples

local SAMPLE_ITEM_ID = 6948        -- the Hearthstone
local PREFIX_CHARS = 4
Examples.MAX_ROWS = 10             -- the autocomplete example's rows, the slider's maximum
local ROW_H = 16
local DRAFT_H = 22
Examples.AUTOCOMPLETE_HEIGHT = DRAFT_H + Examples.MAX_ROWS * ROW_H + 8
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

local function Hex(color)
  return ("%02x%02x%02x"):format(color[1] * 255, color[2] * 255, color[3] * 255)
end

local function Grey(text)
  return "|cff" .. Hex(Utilities.Colors.LABEL_GRAY) .. text .. "|r"
end

local function Scanning()
  local ok, status = pcall(CobysLinkepedia.Scanner.GetStatus)
  return ok and type(status) == "table" and status.isActive == true
end

-- An empty-database view for the settings examples and card alone, so a
-- development check can show their empty states without touching the
-- player's database (Examples._test.SetEmptyView)
local emptyView = false

local function ItemCount()
  if emptyView then return 0 end
  local ok, count = pcall(CobysLinkepedia.Database.GetCount)
  return ok and type(count) == "number" and count or 0
end

-- The sample item record and its first characters, or nil when the
-- database holds neither the Hearthstone nor anything in History
function Examples.Sample()
  if emptyView then return nil end
  local Database = CobysLinkepedia.Database
  local item = Database.GetItem(SAMPLE_ITEM_ID)
  if not item then
    local history = COBYS_LINKEPEDIA_STATE and COBYS_LINKEPEDIA_STATE.history
    if type(history) == "table" then
      for _, entry in ipairs(history) do
        item = type(entry) == "table" and Database.GetItem(entry.id) or nil
        if item then break end
      end
    end
  end
  if not item or type(item.name) ~= "string" or item.name == "" then return nil end
  return item, U.Truncate(item.name, PREFIX_CHARS, "")
end

-------------------------------------------------------------------------------
-- Autocomplete: a chat line and the list it would open
-------------------------------------------------------------------------------
-- The search runs once for MAX_ROWS results per sample, when the example
-- shows or the sample changes (never because the database generation moved:
-- the idle scan moves it every second); the Suggestions shown slider only
-- shows or hides cached rows. The settings window repaints the example every
-- second while it shows, so an empty database's card follows a build. A
-- callback whose request is not the newest, or that arrives with the example
-- hidden, is dropped.

local function SetRows(box, results, shown)
  for i, row in ipairs(box.Rows) do
    local item = results and i <= shown and results[i]
    row:SetShown(item and true or false)
    if item then
      local icon = select(5, C_Item.GetItemInfoInstant(item.itemID))
      row.Icon:SetTexture(icon or QUESTION_MARK)
      row.Name:SetText(item.name or "")
      local color = ITEM_QUALITY_COLORS[item.quality or 1]
      if color then row.Name:SetTextColor(color.r, color.g, color.b) end
    end
  end
end

local function ShowMessage(box, text, withButton)
  SetRows(box, nil, 0)
  box.Message:SetText(text or "")
  box.Message:SetShown(text ~= nil)
  box.BuildButton:SetShown(withButton and true or false)
  if withButton then box.BuildButton:SetEnabled(not Scanning()) end
end

local function StopSearch(box)
  box.request = (box.request or 0) + 1
  if box.cancelSearch then
    box.cancelSearch()
    box.cancelSearch = nil
  end
end

local function StartSearch(box, window, prefix)
  StopSearch(box)
  local request = box.request
  local finished = false
  local cancel = CobysLinkepedia.Database.SearchAsync(prefix, Examples.MAX_ROWS, nil, function(results)
    finished = true
    if request ~= box.request then return end
    box.cancelSearch = nil
    box.cache = { prefix = prefix, results = results or {} }
    if box:IsVisible() then Examples.PaintAutocomplete(box, window) end
  end)
  if not finished then box.cancelSearch = cancel end
end

function Examples.PaintAutocomplete(box, window)
  if not window:Get(Opt.AUTOCOMPLETE_ENABLED) then
    box.Draft:SetText(Grey("Off: typing [ in chat does nothing special."))
    ShowMessage(box, nil)
    return
  end
  if ItemCount() == 0 then
    box.Draft:SetText("")
    if Scanning() then
      ShowMessage(box, "Your database is being built. Suggestions appear as items are stored.")
    else
      ShowMessage(box, "No item database yet. Autocomplete suggests items from it, so build it first.", true)
    end
    return
  end
  local item, prefix = Examples.Sample()
  if not item then
    box.Draft:SetText("")
    ShowMessage(box, "No example item in your database yet. Expand fills in what a scan missed.")
    return
  end

  box.Draft:SetText(Grey("Say:") .. " Anyone have [" .. prefix .. Utilities.WrapColor(Utilities.Colors.HIGHLIGHT_WHITE, "||"))
  local cache = box.cache
  if not cache or cache.prefix ~= prefix then
    ShowMessage(box, nil)
    if box:IsVisible() then StartSearch(box, window, prefix) end
    return
  end
  if #cache.results == 0 then
    ShowMessage(box, "Nothing in your database starts with [" .. prefix .. ".")
    return
  end
  box.Message:Hide()
  box.BuildButton:Hide()
  local shown = tonumber(window:Get(Opt.MAX_DROPDOWN_RESULTS)) or Examples.MAX_ROWS
  SetRows(box, cache.results, shown)
end

function Examples.BuildAutocomplete(box, window)
  box.Draft = box:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
  box.Draft:SetPoint("TOPLEFT", 8, -5)
  box.Draft:SetPoint("RIGHT", -8, 0)
  box.Draft:SetJustifyH("LEFT")
  box.Draft:SetWordWrap(false)

  box.Rows = {}
  for i = 1, Examples.MAX_ROWS do
    local row = CreateFrame("Frame", nil, box)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", box, "TOPLEFT", 14, -(DRAFT_H + (i - 1) * ROW_H))
    row:SetPoint("RIGHT", box, "RIGHT", -8, 0)
    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetSize(ROW_H - 2, ROW_H - 2)
    row.Icon:SetPoint("LEFT", 0, 0)
    row.Name = row:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
    row.Name:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)
    row.Name:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.Name:SetJustifyH("LEFT")
    row.Name:SetWordWrap(false)
    row:Hide()
    box.Rows[i] = row
  end

  box.Message = box:CreateFontString(nil, "OVERLAY", Utilities.Fonts.BODY)
  box.Message:SetPoint("TOPLEFT", box, "TOPLEFT", 14, -(DRAFT_H + 8))
  box.Message:SetPoint("RIGHT", box, "RIGHT", -14, 0)
  box.Message:SetJustifyH("LEFT")
  box.Message:SetWordWrap(true)
  box.Message:Hide()

  box.BuildButton = Utilities.CreateButton(box, {
    text = "Build database", size = { 150, 22 },
    point = { "TOPLEFT", box.Message, "BOTTOMLEFT", 0, -10 },
    tooltip = "Build your item database now. It runs in the background for a few minutes and pauses by itself in combat. Shift-click for a faster scan, Ctrl+Shift-click for the fastest.",
    onClick = function()
      Examples.StartBuild()
      Examples.PaintAutocomplete(box, window)   -- the building message at once
    end,
  })
  box.BuildButton:Hide()

  -- A fresh search each time the example shows; none runs while it is hidden
  box:HookScript("OnShow", function()
    box.cache = nil
    Examples.PaintAutocomplete(box, window)
  end)
  box:HookScript("OnHide", function() StopSearch(box) end)
end

-------------------------------------------------------------------------------
-- Linking and tokens: what a line really sends, through Linkify's own lookups
-------------------------------------------------------------------------------
local SENDS = "  " .. Grey("sends") .. "  "

function Examples.LinkByNameText(window)
  local item = Examples.Sample()
  if not item then
    return Grey("Build your item database to see a name turn into a link.")
  end
  local typed = "Anyone have [" .. item.name .. "]?"
  local sent = typed
  if window:Get(Opt.AUTO_LINKIFY_ON_SEND) then
    -- The client links an item it has loaded; ask, so the next repaint can
    C_Item.RequestLoadItemDataByID(item.itemID)
    sent = CobysLinkepedia.Linkify.TransformMessage(typed)
  end
  return Grey("You type:") .. "  " .. typed .. "\n" .. Grey("Others see:") .. "  " .. sent
end

function Examples.TokensText(window)
  local enabled = window:Get(Opt.EXPAND_ITEM_TOKENS)
  local item, prefix = Examples.Sample()
  local variantID = CobysLinkepedia.Variants.LowestID()
  local tokens = { "${i=" .. (item and item.itemID or SAMPLE_ITEM_ID) .. "}" }
  if prefix then tokens[#tokens + 1] = "${n=" .. prefix .. "}" end
  tokens[#tokens + 1] = "${v=" .. (variantID or 1) .. "}"

  local lines = {}
  for i, token in ipairs(tokens) do
    local sent = enabled and CobysLinkepedia.Linkify.ExpandTokens(token) or token
    if sent == token then
      lines[i] = token .. SENDS .. Grey("as typed")
    else
      lines[i] = token .. SENDS .. sent
    end
  end
  if enabled and not variantID then
    lines[#lines + 1] = Grey("Save a variant in the Variant Builder to give it a number.")
  end
  return table.concat(lines, "\n")
end

-------------------------------------------------------------------------------
-- Chat messages: a line of each level, the ones the staged level would not
-- print greyed and marked
-------------------------------------------------------------------------------
local LEVEL_RANK = { Quiet = 0, Normal = 1, Verbose = 2 }
local SAMPLE_LINES = {
  { rank = 0, color = Utilities.Colors.TEXT_GOLD, text = "A scan is already in progress." },
  { rank = 1, color = Utilities.Colors.TEXT_GREEN, text = "Scan complete! Found 1204 items in 3m 12s." },
  { rank = 2, text = "Found 9870 valid item IDs (max ID: 260000). Querying..." },
}

function Examples.MessagesText(window)
  local level = LEVEL_RANK[window:Get(Opt.CHAT_VERBOSITY)] or 1
  local prefix = "[Coby's Linkepedia]"
  local lines = {}
  for i, line in ipairs(SAMPLE_LINES) do
    if line.rank <= level then
      local body = line.color and ("|cff" .. line.color .. line.text .. "|r") or line.text
      lines[i] = "|cff" .. Utilities.Colors.TEXT_TEAL .. prefix .. "|r " .. body
    else
      lines[i] = Grey(prefix .. " " .. line.text .. " (hidden)")
    end
  end
  return table.concat(lines, "\n")
end

-------------------------------------------------------------------------------
-- Item database card
-------------------------------------------------------------------------------
-- The search window's speeds: Shift-click faster, Ctrl+Shift-click fastest
local function Intensity()
  if IsShiftKeyDown() and IsControlKeyDown() then return "Max" end
  if IsShiftKeyDown() then return "Boost" end
  return nil
end

-- The card's actions start scans the way the guide's buttons do, and never
-- apply the window's staged settings: a scan runs at the saved speed
function Examples.StartBuild() CobysLinkepedia.Scanner.StartBuild(false, Intensity()) end
function Examples.StartExpand() CobysLinkepedia.Scanner.StartExpand(Intensity()) end
function Examples.Scanning() return Scanning() end
function Examples.ItemCount() return ItemCount() end

local SPEEDS = "Runs at your saved scan speed; Shift-click for a faster scan, Ctrl+Shift-click for the fastest."

-- The database card's buttons, for the settings window's card and the
-- search window's Stats tab alike: the first builds or expands (its text
-- and tooltip say which, read again at each hover), Rebuild asks first, and
-- the last opens the status window. Each acts at once and stages nothing.
function Examples.DatabaseActions()
  return {
    {
      text = function()
        if Scanning() then return "Scanning..." end
        return ItemCount() > 0 and "Expand database" or "Build database"
      end,
      enabled = function() return not Scanning() end,
      tooltip = function()
        if Scanning() then return "A scan is running. The status window shows how far it has got." end
        if ItemCount() > 0 then
          return "Add only the items your database lacks, such as a new patch's. Much quicker than a rebuild. " .. SPEEDS
        end
        return "Build your item database. It runs in the background for a few minutes and pauses by itself in combat. " .. SPEEDS
      end,
      onClick = function()
        if ItemCount() > 0 then Examples.StartExpand() else Examples.StartBuild() end
      end,
    },
    {
      text = "Rebuild...",
      enabled = function() return ItemCount() > 0 and not Scanning() end,
      tooltip = "Start over and build your item database from scratch. Asks first.",
      onClick = function() Examples.StartBuild() end,
    },
    {
      text = "Status window",
      tooltip = "Watch the database, the scans and the idle scan, live (/lp status).",
      onClick = function() CobysLinkepedia.Search.ToggleStatusWindow() end,
    },
  }
end

local function TimeAgo(when)
  if type(when) ~= "number" then return nil end
  local seconds = math.max(0, time() - when)
  if seconds < 3600 then return "less than an hour ago" end
  local hours = math.floor(seconds / 3600)
  if hours < 48 then return hours == 1 and "an hour ago" or (hours .. " hours ago") end
  return math.floor(hours / 24) .. " days ago"
end

local function IdleText()
  if Config.Get(Opt.IDLE_SCAN_ENABLED) == false then return "Idle scan is off." end
  local ok, idle = pcall(CobysLinkepedia.Scanner.GetIdleStatus)
  if not ok or type(idle) ~= "table" then return "" end
  return ("Idle scan: %s items waiting, %s found this session."):format(
    BreakUpLargeNumbers(idle.queued or 0), BreakUpLargeNumbers(idle.stored or 0))
end

-- The card's state (a StatusCard state: "ok", "warn" or "unknown"), its
-- word, a title and a line about it, then the idle scan's line. Reads only
-- kept counters and fields, so the card can ask every half second.
function Examples.DatabaseState()
  local Scanner = CobysLinkepedia.Scanner
  local count = ItemCount()
  local ok, status = pcall(Scanner.GetStatus)
  if ok and type(status) == "table" and status.isActive then
    local word = status.state == "PAUSED" and "Paused"
      or (status.scanMode == "expand" and "Expanding" or "Building")
    local pct = (status.upperBound or 0) > 0 and math.floor(100 * (status.position or 0) / status.upperBound) or 0
    return "unknown", word, ("%d%% done"):format(pct),
      ("%s items found so far. Scans pause by themselves in combat."):format(BreakUpLargeNumbers(status.itemsFound or 0))
  end
  if count == 0 then
    return "warn", "Empty", "No items yet",
      "Build it once and autocomplete, linking and search start working."
  end
  local items = ("%s items"):format(BreakUpLargeNumbers(count))
  local last = Scanner.GetLastScan()
  if last and last.complete == false then
    return "warn", "Incomplete", items,
      "Your last scan stopped part way. Expand picks it up where it left off.\n" .. IdleText()
  end
  local ago = last and TimeAgo(last.finishedAt)
  local kind = last and last.mode == "expand" and "expand" or "build"
  local line = ago and ("Your last %s finished %s. Expand adds a new patch's items without starting over."):format(kind, ago)
    or "Expand adds a new patch's items without starting over."
  return "ok", "Ready", items, line .. "\n" .. IdleText()
end

-- How long one pass through the idle queue takes at the staged rate
function Examples.IdleEstimate(window)
  local ok, idle = pcall(CobysLinkepedia.Scanner.GetIdleStatus)
  local queued = ok and type(idle) == "table" and idle.queued or 0
  if queued == 0 then return "Nothing is waiting right now." end
  local rate = tonumber(window:Get(Opt.IDLE_SCAN_RATE)) or 5
  local minutes = math.ceil(queued / math.max(rate, 1) / 60)
  local span = minutes <= 1 and "About a minute" or ("About " .. minutes .. " minutes")
  return ("%s for one pass through the %s items waiting, while the idle scan can run."):format(
    span, BreakUpLargeNumbers(queued))
end

-- A note when the staged scan speed is not the one a scan would use
function Examples.SpeedNote(window)
  local staged, saved = window:Get(Opt.SCAN_SPEED), Config.Get(Opt.SCAN_SPEED)
  if staged == saved then return "" end
  return ("Scans run at your saved speed (%s). Apply to scan at %s."):format(tostring(saved), tostring(staged))
end

-------------------------------------------------------------------------------
-- The sample notice: one toast now, whatever the notices setting says
-------------------------------------------------------------------------------
function Examples.ShowSampleNotice()
  local item = Examples.Sample()
  local itemID = item and item.itemID or SAMPLE_ITEM_ID
  local name = item and item.name or C_Item.GetItemNameByID(itemID) or "Hearthstone"
  local icon = select(5, C_Item.GetItemInfoInstant(itemID))
  return CobysLinkepedia.Toast.ShowSample("Variant Captured", name, icon)
end

Examples._test = {
  SetEmptyView = function(on) emptyView = on and true or false end,
}
