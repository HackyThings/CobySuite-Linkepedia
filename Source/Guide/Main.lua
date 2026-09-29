-- Guide: the feature guide, a section for each part of Coby's Linkepedia
-- (CobySuite.UI.CreateGuideWindow). /lp tutorial and the search window's
-- "?" button open it. Built at load, like the search window, so opening it
-- in combat creates nothing.

local Guide = CobysLinkepedia.Guide

local ICONS = "Interface\\Icons\\"

-- Each section: what the part does, then commands and keys to try. Keep the
-- text in step with the README.
Guide.SECTIONS = {
  {
    key = "database",
    title = "Your item database",
    icon = ICONS .. "INV_Misc_Book_09",
    summary = "Every item your game client knows, built on your own computer",
    body = {
      "Coby's Linkepedia does not ship a list of items. It builds one from your game client, about 175,000 items, so it is never out of date and covers anything the game knows.",
      "A build runs in the background for a few minutes and pauses by itself in combat. You can pause, resume or cancel it, and the search window's footer shows the progress, the rate and the time left. Shift-click Build or Expand for a faster scan, or Ctrl+Shift-click for the fastest; both stutter while they run.",
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
    body = {
      "The idle scan quietly asks the server again for any item it held back during a build, five a second by default and never in combat. It never starts a scan by itself.",
      "Item variants, such as crafted ranks and other versions of an item, are captured as you play: from your bags, the gear you wear, loot, trades, mail and the links other players post in chat.",
      "Expand scans only the item IDs your database does not have yet, and after a game patch a dialog offers to run it, so new items arrive without a rebuild and without waiting for an addon update. IDs the server does not have are skipped until the next game patch.",
    },
    try = {
      { "/lp expand", "Add a new patch's items, or finish a scan that was cancelled" },
    },
  },
  {
    key = "autocomplete",
    title = "Chat autocomplete",
    icon = ICONS .. "UI_Chat",
    summary = "Type [ in chat and pick any item from a list",
    body = {
      "In any tab of the chat window or a pop-out whisper window, type [ and the start of an item's name. A list opens beside the chat box with the best matches, each with its icon and its name in its quality color.",
      "Up and Down move through the list, and Tab or a click puts the item's link where you typed. Enter still sends your message and Escape closes the list. It works in the middle of a message too, and the text after it stays put.",
    },
    try = {
      { "[hearth", "Type it in chat, then press Tab" },
    },
  },
  {
    key = "linkify",
    title = "Linking by name",
    icon = ICONS .. "INV_Misc_Note_02",
    summary = "Send [Item Name] and it turns into a link",
    body = {
      "Type an item's exact name in brackets and send the message: it becomes a real item link as it goes out. Capitalization does not matter, and a name that matches nothing is sent as you typed it.",
      "For an item with captured variants, add a rank or an item level: [Item Name~R2], [Item Name~270], or both.",
      "/link prints up to 20 matching items in your own chat frame. Only you see them, and you can Shift-click any of them into a message.",
    },
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
    body = {
      "A macro names its item exactly with a token: ${i=6948} links item 6948, ${n=hearth} links the item named that, and ${v=5} links your saved variant 5. Tokens work in any chat line a macro sends, and in typed chat too.",
      "The macro window gets a panel on its right edge. It lists the token syntax, shows what each token in the selected macro links right now, and finds items to add at your cursor. Shift-click an item into a macro's chat line and the panel offers its token.",
    },
    try = {
      { "/s Selling ${i=6948}", "A macro line that links a Hearthstone" },
    },
  },
  {
    key = "search",
    title = "The search window",
    icon = ICONS .. "INV_Misc_Spyglass_03",
    summary = "Search, filter and browse the whole database",
    body = {
      "Open it from the minimap button, the addon compartment, a key binding or the command below. The search box filters as you type and the dropdowns beside it narrow by quality, type and expansion. The picker next to the box sets how words match: Exact as typed, All words in any order, or Any word. Every column sorts and resizes.",
      "Click an item to see its details: the item ID, and the link and its Wowhead address, each ready to copy. Shift-click links the item in chat, Ctrl-click tries it on in the dressing room, and right-click opens a menu.",
      "The tabs along the bottom hold the Variant Builder, your Favorites, the History of items you linked, and Stats about your database.",
    },
    try = {
      { "/lp show", "Open or close the search window" },
    },
  },
  {
    key = "variants",
    title = "The Variant Builder",
    icon = ICONS .. "INV_Helmet_08",
    summary = "Build and save any crafted or upgrade-track version of gear",
    body = {
      "Pick a piece of gear and build the exact version you want. Crafted gear takes a quality and any optional reagent, such as embellishments and missives. Other gear takes an upgrade track: a season, a track, a rank and a quality.",
      "Save a version and it gets a number, and ${v=N} then links exactly that variant in chat or a macro. Saved and captured variants show in the item's detail pane, and the ones you favorite show in the Favorites tab.",
    },
    try = {
      { "/lp variant [itemID]", "Open the Variant Builder, on an item when you give its ID" },
    },
  },
  {
    key = "quicksearch",
    title = "Quick search",
    atlas = "common-search-magnifyingglass",
    summary = "A small search box that drops a link into your chat",
    body = {
      "The quick search bar opens ready to type, with the ten best matches under it. Up and Down move the highlight, and Enter or a click picks an item: its link goes into the chat box you had open, or chat opens with it typed in.",
      "Give it a key binding and it is the fastest way to link anything.",
    },
    try = {
      { "/lp qs", "Open or close the quick search bar" },
    },
  },
  {
    key = "settings",
    title = "Settings and shortcuts",
    icon = ICONS .. "INV_Misc_Key_05",
    summary = "The settings window, key bindings and every command",
    body = {
      "The settings window groups everything into Autocomplete, Scanning, Chat & Linking and Display, and changes wait until you click Apply. A right-click on the minimap button opens it too.",
      "Options > Keybindings > AddOns has two entries under Coby's Linkepedia, Toggle Search Window and Toggle Quick Search. Both are unbound until you pick keys.",
    },
    try = {
      { "/lp settings", "Open the settings window" },
      { "/lp help", "List every command" },
      { "/lp tutorial", "Open or close this guide" },
    },
  },
}

local window = CobySuite_CobysLinkepedia.UI.CreateGuideWindow({
  name = "CobysLinkepediaGuideWindow",
  title = "Coby's Linkepedia Guide",
  intro = "Everything Coby's Linkepedia can do, one part at a time. Click a heading to open or close it.",
  sections = Guide.SECTIONS,
  persist = {
    svTable = function() return COBYS_LINKEPEDIA_WINDOW_STATE end,
    key = "guideWindow",
  },
})

function Guide.GetWindow()
  return window
end

function Guide.Toggle()
  window:Toggle()
end

CobysLinkepedia.Debug.Log("INIT", "Guide loaded")
