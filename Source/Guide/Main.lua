-- Guide: the feature guide, a section for each part of Coby's Linkepedia
-- (CobySuite.UI.CreateGuideWindow, the suite's standard guide). /lp guide
-- (alias tutorial), the search window's "?" and the settings window's Guide
-- button open it, and a fresh install opens it at its first section
-- (Guide/WhatsNew.lua), the item database, whose Build Database button
-- starts the first build (it replaced the old welcome window). Built at
-- load, like the search window, so opening it in combat creates nothing.

local Guide = CobysLinkepedia.Guide
local U = CobySuite_CobysLinkepedia.Utilities
local T = CobySuite_CobysLinkepedia.UI.GuideText

local ICONS = "Interface\\Icons\\"

-- The database section's button: Build on an empty database, Rebuild (which
-- asks first) on a full one, greyed while any scan runs
local function Scanning()
  local ok, status = pcall(CobysLinkepedia.Scanner.GetStatus)
  return ok and type(status) == "table" and status.isActive == true
end

local function BuildLabel()
  if Scanning() then return "Building..." end
  local ok, count = pcall(CobysLinkepedia.Database.GetCount)
  if ok and type(count) == "number" and count > 0 then return "Rebuild Database" end
  return "Build Database"
end

-- The search window's speeds: Shift-click faster, Ctrl+Shift-click fastest
local function Intensity()
  if IsShiftKeyDown() and IsControlKeyDown() then return "Max" end
  if IsShiftKeyDown() then return "Boost" end
  return nil
end

local function HasItems()
  local ok, count = pcall(CobysLinkepedia.Database.GetCount)
  return ok and type(count) == "number" and count > 0
end

-- Expand: only the IDs the database lacks, once there is a database to add to
local EXPAND_BUTTON = {
  text = "Expand Database", width = 150,
  tooltip = "Scan only the item IDs your database doesn't have yet: a new patch's items, or the rest of a scan that was canceled. Much faster than a rebuild.",
  label = function() return Scanning() and "Scanning..." or "Expand Database" end,
  enabled = function() return HasItems() and not Scanning() end,
  onClick = function()
    CobysLinkepedia.Scanner.StartExpand(Intensity())
    CobysLinkepedia.Debug.Log("INIT", "Guide: expand started")
  end,
}

-- Each section: what the part does, then commands and keys to try. Keep the
-- text in step with the README.
Guide.SECTIONS = {
  {
    key = "database",
    title = "Your item database",
    icon = ICONS .. "INV_Misc_Book_09",
    summary = "Build a searchable item list from your game client",
    body = T.Bullets({
      "Click " .. T.Key("Build Database") .. " to start. It runs in the background for a few minutes and pauses in combat.",
      "The search window's footer shows progress and the time left in the current step.",
      "Already have items? " .. T.Key("Expand Database") .. " adds the missing ones without starting over.",
      "Shift-click for a faster scan, Ctrl+Shift-click for the fastest. Both can stutter.",
    }),
    buttons = {
      {
        text = "Build Database", width = 150,
        tooltip = "Build your item database now. It runs in the background for a few minutes and pauses by itself in combat.",
        label = BuildLabel,
        enabled = function() return not Scanning() end,
        onClick = function()
          CobysLinkepedia.Scanner.StartBuild(false, Intensity())
          CobysLinkepedia.Debug.Log("INIT", "Guide: build started from the database section")
        end,
      },
      EXPAND_BUTTON,
    },
    try = {
      { "/lp build", "Build the database from scratch" },
      { "/lp status", "Watch the database, the scans and the idle scan, live" },
      { "/lp pause", "Pause the running scan" },
      { "/lp resume", "Resume a paused scan" },
    },
  },
  {
    key = "current",
    title = "Keeping it current",
    icon = ICONS .. "INV_Misc_PocketWatch_01",
    summary = "Held-back items and variants arrive by themselves; Expand adds new ones",
    body = T.Bullets({
      "The idle scan asks the server again for items a build held back, five a second, never in combat.",
      "Variants, such as crafted ranks, are captured as you play: bags, worn gear, loot, trades, mail and links others post.",
      "After a game patch, a dialog offers " .. T.Key("Expand") .. ", so new items arrive without an addon update.",
      "IDs the server refuses, or never answers in two scans, are skipped until the next patch.",
    }),
    buttons = { EXPAND_BUTTON },
    try = {
      { "/lp expand", "Add a new patch's items, or finish a scan that was canceled" },
    },
  },
  {
    key = "autocomplete",
    title = "Chat autocomplete",
    icon = ICONS .. "UI_Chat",
    summary = "Type [ in chat and pick any item from a list",
    body = T.Bullets({
      "In any chat box, type " .. T.Key("[") .. " and the start of an item's name. A list of matches opens.",
      T.Key("Up") .. " and " .. T.Key("Down") .. " move through it. " .. T.Key("Tab") .. " or a click puts the link where you typed.",
      T.Key("Enter") .. " still sends your message, and " .. T.Key("Escape") .. " closes the list.",
      "It works mid-message too: the text after it stays put.",
    }),
    try = {
      { "[hearth", "Type it in chat, then press Tab" },
    },
  },
  {
    key = "linkify",
    title = "Linking by name",
    icon = ICONS .. "INV_Misc_Note_02",
    summary = "Send [Item Name] and it turns into a link",
    body = T.Bullets({
      "Send an item's exact name in brackets and it goes out as a link. Capitalization doesn't matter.",
      "A name that matches nothing is sent as you typed it.",
      "For an item with captured variants, add a rank or item level: [Item Name~R2] or [Item Name~270].",
      T.Key("/link") .. " lists up to 20 matches in your own chat; Shift-click one into a message.",
    }),
    try = {
      { "[Hearthstone]", "Type it in a message and press Enter" },
      { "/link <name>", "List the items that match a name" },
    },
  },
  {
    key = "tokens",
    title = "Item tokens for macros",
    icon = ICONS .. "INV_Misc_ScrollUnrolled01",
    summary = "Put exact items in macros with ${i=ID}, ${n=name} and ${v=N}",
    body = T.Bullets({
      T.Key("${i=6948}") .. " links item 6948, " .. T.Key("${n=hearth}") .. " the item with that name, and " .. T.Key("${v=5}") .. " your saved variant 5.",
      "Tokens work in any chat line a macro sends, and in typed chat.",
      "A panel on the macro window lists the syntax, shows what each token links, and finds items to add.",
      "Shift-click an item into a macro's chat line and the panel offers its token.",
    }),
    try = {
      { "/s Selling ${i=6948}", "A macro line that links a Hearthstone" },
    },
  },
  {
    key = "search",
    title = "The search window",
    icon = ICONS .. "INV_Misc_Spyglass_03",
    summary = "Search, filter and browse the whole database",
    body = T.Bullets({
      "Open it from the minimap button, the addon compartment, a key binding or " .. T.Key("/lp") .. ".",
      "Type to filter; the dropdowns narrow by quality, type and expansion. Every column sorts and resizes.",
      "Click an item for its ID, link and Wowhead URL. The link and URL have copy icons.",
      "Shift-click links an item, Ctrl-click tries it on, right-click opens a menu.",
      "The tabs hold " .. T.Block("Variants") .. ", " .. T.Block("Favorites") .. ", " .. T.Block("History") .. " and " .. T.Block("Stats") .. ".",
    }),
    try = {
      { "/lp show", "Open or close the search window" },
    },
  },
  {
    key = "variants",
    title = "The Variant Builder",
    icon = ICONS .. "INV_Helmet_08",
    summary = "Build and save crafted and upgrade-track versions of gear",
    body = T.Bullets({
      "Pick a piece of gear and build the exact version you want.",
      "Crafted gear takes a quality and optional reagents. Other gear takes a season, track, rank and quality.",
      "Save a version and it gets a number; " .. T.Key("${v=N}") .. " then links exactly that variant.",
      "Saved variants show in the item's detail pane, and favorites in the " .. T.Block("Favorites") .. " tab.",
    }),
    try = {
      { "/lp variant [itemID]", "Open the Variant Builder, on an item when you give its ID" },
    },
  },
  {
    key = "quicksearch",
    title = "Quick search",
    atlas = "common-search-magnifyingglass",
    summary = "A small search box that drops a link into your chat",
    body = T.Bullets({
      "A small search bar that opens ready to type, with the ten best matches under it.",
      T.Key("Enter") .. " or a click puts the link in your open chat box, or opens chat with it.",
      "Give it a key binding: it's the fastest way to link anything.",
    }),
    try = {
      { "/lp qs", "Open or close the quick search bar" },
    },
  },
  {
    key = "settings",
    title = "Settings and shortcuts",
    icon = ICONS .. "INV_Misc_Key_05",
    summary = "The settings window, key bindings and every command",
    body = T.Bullets({
      "Five pages: Autocomplete, Linking, Item database, Search window, and Minimap and chat.",
      "Examples show what a choice does. Changes wait for " .. T.Key("Apply") .. "; " .. T.Key("Cancel") .. " drops them, " .. T.Key("Defaults") .. " restores every setting.",
      "Right-click the minimap button to open it too.",
      "Set keys under Options > Keybindings > AddOns: Toggle Search Window and Toggle Quick Search.",
    }),
    try = {
      { "/lp settings", "Open the settings window" },
      { "/lp help", "List every command" },
      { "/lp guide", "Open or close this guide" },
      { "/lp changelog", "What changed in each version" },
    },
  },
}

local window = CobySuite_CobysLinkepedia.UI.CreateGuideWindow({
  name = "CobysLinkepediaGuideWindow",
  title = "Coby's Linkepedia Guide",
  icon = CobysLinkepedia.ICON,
  intro = "New here? Start with the first section. Click any heading to open or close it.",
  footer = "Open this guide any time with " .. U.WrapColor(U.Colors.HELP_COMMAND, "/lp guide"),
  sections = Guide.SECTIONS,
  persist = {
    svTable = function() return COBYS_LINKEPEDIA_WINDOW_STATE end,
    key = "guideWindow",
  },
})

function Guide.GetWindow()
  return window
end

-- The Build Database button follows the scanner while the guide is open
local listener = {}
function listener:ReceiveEvent()
  if window:IsShown() then window:RefreshBodies() end
end
CobysLinkepedia.EventBus:Register(listener, {
  CobysLinkepedia.Events.ScanComplete, CobysLinkepedia.Events.ScanCancelled, CobysLinkepedia.Events.DatabaseUpdated,
})

function Guide.Toggle()
  window:Toggle()
end

-- Shows the guide at its first section (a fresh install's first login)
function Guide.Show()
  window:OpenSection(Guide.SECTIONS[1].key)
end

CobysLinkepedia.Debug.Log("INIT", "Guide loaded")
