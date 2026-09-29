CobysLinkepedia = {
  Debug = {},
  Config = {},
  Database = {},
  Scanner = {},
  Autocomplete = {},
  Linkify = {},
  Variants = {},
  MacroTokens = {},
  Search = {},
  QuickSearch = {},
  Guide = {},
  Toast = {},
  Minimap = {},
  Utilities = {},
}

-------------------------------------------------------------------------------
-- EventBus event constants
-------------------------------------------------------------------------------
CobysLinkepedia.Events = {
  ScanCancelled      = "cobys_linkepedia_scan_cancelled",
  ScanComplete       = "cobys_linkepedia_scan_complete",
  DatabaseUpdated    = "cobys_linkepedia_database_updated",
  ItemCaptured       = "cobys_linkepedia_item_captured",
  FavoriteChanged    = "cobys_linkepedia_favorite_changed",
  HistoryUpdated     = "cobys_linkepedia_history_updated",
  ConfigChanged      = "cobys_linkepedia_config_changed",
  -- (id, itemID, change): change is "saved", "updated", "deleted" or "favorite"
  SavedVariantsChanged = "cobys_linkepedia_saved_variants_changed",
  RecipeIndexUpdated   = "cobys_linkepedia_recipe_index_updated",
  RecipeScanStarted    = "cobys_linkepedia_recipe_scan_started",
  RecipeScanProgress   = "cobys_linkepedia_recipe_scan_progress",
  RecipeScanComplete   = "cobys_linkepedia_recipe_scan_complete",
  RecipeScanCancelled  = "cobys_linkepedia_recipe_scan_cancelled",
}

-------------------------------------------------------------------------------
-- Addon metadata
-------------------------------------------------------------------------------
local ADDON_NAME = "CobysLinkepedia"
local VERSION = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "2.0.0"

CobysLinkepedia.version = VERSION

-------------------------------------------------------------------------------
-- Key bindings: the labels and the functions the actions call. The actions
-- themselves are declared in Bindings.xml, which the client loads from the
-- addon folder.
-------------------------------------------------------------------------------
BINDING_HEADER_COBYSLINKEPEDIA = "Coby's Linkepedia"
BINDING_NAME_COBYSLINKEPEDIA_TOGGLE_SEARCH = "Toggle Search Window"
BINDING_NAME_COBYSLINKEPEDIA_TOGGLE_QUICKSEARCH = "Toggle Quick Search"

function CobysLinkepedia_ToggleSearch()
  if CobysLinkepedia.Search.ToggleWindow then
    CobysLinkepedia.Search.ToggleWindow()
  end
end

function CobysLinkepedia_ToggleQuickSearch()
  if CobysLinkepedia.QuickSearch.Toggle then
    CobysLinkepedia.QuickSearch.Toggle()
  end
end

-------------------------------------------------------------------------------
-- Addon Compartment global stubs (referenced by TOC)
-------------------------------------------------------------------------------
function CobysLinkepedia_OnAddonCompartmentClick(_, button)
  if CobysLinkepedia.Minimap and CobysLinkepedia.Minimap.OnCompartmentClick then
    CobysLinkepedia.Minimap.OnCompartmentClick(button)
  end
end

function CobysLinkepedia_OnAddonCompartmentEnter(_, menuItem)
  if CobysLinkepedia.Minimap and CobysLinkepedia.Minimap.OnCompartmentEnter then
    CobysLinkepedia.Minimap.OnCompartmentEnter(menuItem)
  end
end

function CobysLinkepedia_OnAddonCompartmentLeave()
  if CobysLinkepedia.Minimap and CobysLinkepedia.Minimap.OnCompartmentLeave then
    CobysLinkepedia.Minimap.OnCompartmentLeave()
  end
end

-------------------------------------------------------------------------------
-- Slash command registration and routing (CobySuite.Slash.Register)
-- "help" (also empty input) and "version" come from the registrar.
-- Core.lua loads before Utilities/Main.lua, so the chat printer is bound late.
-------------------------------------------------------------------------------
local function Msg(text)
  CobysLinkepedia.Utilities.Message(text)
end

CobySuite_CobysLinkepedia.Slash.Register({
  key = "COBYSLINKEPEDIA",
  slashes = { "/lp", "/linkepedia", "/cobyslinkepedia" },
  title = "Coby's Linkepedia",
  version = VERSION,
  message = Msg,
  commands = {
    { name = "build", aliases = { "rebuild" }, help = "Wipe the item database and scan every item ID from scratch (asks first when a database exists)",
      run = function()
        if CobysLinkepedia.Scanner.StartBuild then
          CobysLinkepedia.Scanner.StartBuild()
        end
      end },
    { name = "expand", help = "Scan only the item IDs the database does not have yet; also continues an unfinished scan",
      run = function()
        if CobysLinkepedia.Scanner.StartExpand then
          CobysLinkepedia.Scanner.StartExpand()
        end
      end },
    { name = "pause", help = "Pause the running scan",
      run = function()
        if CobysLinkepedia.Scanner.Pause then
          CobysLinkepedia.Scanner.Pause()
        end
      end },
    { name = "resume", help = "Resume a paused scan",
      run = function()
        if CobysLinkepedia.Scanner.Resume then
          CobysLinkepedia.Scanner.Resume()
        end
      end },
    { name = "stop", aliases = { "cancel" }, help = "Cancel the running scan; the items found so far are kept",
      run = function()
        if CobysLinkepedia.Scanner.Cancel then
          CobysLinkepedia.Scanner.Cancel()
        end
      end },
    { name = "show", help = "Open or close the search window",
      run = function()
        if CobysLinkepedia.Search.ToggleWindow then
          CobysLinkepedia.Search.ToggleWindow()
        end
      end },
    { name = "qs", aliases = { "quicksearch" }, help = "Open or close the quick search bar",
      run = function()
        if CobysLinkepedia.QuickSearch.Toggle then
          CobysLinkepedia.QuickSearch.Toggle()
        end
      end },
    { name = "tutorial", aliases = { "guide" }, help = "Open or close the feature guide: what each part of Coby's Linkepedia does",
      run = function()
        if CobysLinkepedia.Guide.Toggle then
          CobysLinkepedia.Guide.Toggle()
        end
      end },
    { name = "settings", aliases = { "config" }, help = "Open the settings window",
      run = function()
        if CobysLinkepedia.Config.OpenSettings then
          CobysLinkepedia.Config.OpenSettings()
        end
      end },
    { name = "debug", help = "Open or close the debug log window (copy it into a bug report)",
      run = function()
        if CobysLinkepedia.DebugWindow then
          CobysLinkepedia.DebugWindow:Toggle()
        end
      end },
    { name = "status", help = "Open or close the status window: the database, the scans and the idle scan, updated live",
      run = function()
        if CobysLinkepedia.Search.ToggleStatusWindow then
          CobysLinkepedia.Search.ToggleStatusWindow()
        end
      end },
    { name = "stats", help = "Open or close the live stats window: memory, framerate, latency and database counts",
      run = function()
        if CobysLinkepedia.Search.ToggleStatsWindow then
          CobysLinkepedia.Search.ToggleStatsWindow()
        end
      end },
    { name = "set", usage = "set <key> <value>", help = "Change a setting by its key, such as /lp set scanSpeed Fast; /lp set alone lists every key and its value",
      run = function(rest)
        if CobysLinkepedia.Config.HandleSetCommand then
          CobysLinkepedia.Config.HandleSetCommand(rest)
        end
      end },
    { name = "reset", help = "Delete the item database with its captured variants and recipe index (asks first); settings, favorites, history and saved variants are kept",
      run = function()
        if CobysLinkepedia.Database.ShowResetConfirmation then
          CobysLinkepedia.Database.ShowResetConfirmation()
        end
      end },
    { name = "recipes", usage = "recipes [cancel]", help = "Index which recipes craft which gear, for the Variant Builder (runs by itself after a patch); cancel stops it",
      run = function(rest)
        CobysLinkepedia.Scanner.RecipeScanCommand(rest and rest:match("^%s*(%S+)"))
      end },
    { name = "variant", usage = "variant [itemID]", help = "Open the Variant Builder, optionally on an item ID",
      run = function(rest)
        CobysLinkepedia.Search.OpenBuilder(tonumber(rest and rest:match("^%s*(%d+)")))
      end },
    { name = "findmax", usage = "findmax [cancel]", help = "Scan item IDs 0 to 1,000,000 and report the highest one the game knows; cancel stops it",
      run = function(rest)
        if CobysLinkepedia.Scanner.FindMaxItemID then
          CobysLinkepedia.Scanner.FindMaxItemID(rest and rest:match("^%s*(%S+)"))
        end
      end },
    -- Development only: a build without the test files has no such commands
    { name = "perf", help = "Open the test window and run the performance measurement (Run Perf); the report opens for copying",
      available = function() return CobysLinkepedia.Tests ~= nil end,
      run = function()
        local tests = CobysLinkepedia.Tests
        if not tests then
          Msg("Tests are not loaded.")
          return
        end
        tests.RunPerformance()
      end },
    { name = "test", usage = "test [suite]", help = "Open the in-game test window, optionally running one suite",
      available = function() return CobysLinkepedia.Tests ~= nil end,
      run = function(rest)
        local tests = CobysLinkepedia.Tests
        if not tests then
          Msg("Tests are not loaded.")
          return
        end
        tests.Window:Show()
        local suite = rest and rest:match("^%s*(%S+)")
        if suite then
          tests.RunSuite(suite)
        end
      end },
  },
})

-------------------------------------------------------------------------------
-- Chat link lookup command: /link <name>
-------------------------------------------------------------------------------
SLASH_COBYSLINKEPEDIALINK1 = "/link"

SlashCmdList["COBYSLINKEPEDIALINK"] = function(input)
  local query = input:trim()
  if query == "" then
    Msg("Usage: /link <item name>")
    return
  end

  local results = CobysLinkepedia.Database.Search(query, 20)
  if not results or #results == 0 then
    Msg("No matches found for \"" .. query .. "\".")
    return
  end

  -- The database stores names, not links: a link only exists once the
  -- client has the item's data, which it lacks for anything not seen this
  -- session. Every result is requested and the list prints once, in order,
  -- when each has loaded or timed out, so the output is clickable links
  -- rather than plain bracketed names.
  local LINK_LOAD_TIMEOUT = 3
  local links = {}
  local waiting = #results

  local function PrintResults()
    for i, item in ipairs(results) do
      if links[i] then
        print("  " .. links[i])
      else
        print("  [" .. item.name .. "] (ID: " .. item.itemID .. ", data not available yet)")
      end
    end
    -- History records the best match when it produced a link
    if links[1] then
      CobysLinkepedia.Search.AddToHistory(results[1].itemID)
    end
    if #results >= 20 then
      Msg("Showing first 20 results. Narrow your search for fewer matches.")
    else
      Msg(#results .. " match" .. (#results == 1 and "" or "es") .. " found.")
    end
  end

  local function Settled()
    waiting = waiting - 1
    if waiting == 0 then PrintResults() end
  end

  for i, item in ipairs(results) do
    CobysLinkepedia.Utilities.LoadItemThen(item.itemID, {
      timeout = LINK_LOAD_TIMEOUT,
      onReady = function(link)
        links[i] = link
        Settled()
      end,
      onFail = Settled,
    })
  end
end

-------------------------------------------------------------------------------
-- Startup sequence
-------------------------------------------------------------------------------
-- Load and login run once, through Blizzard's EventUtil helpers (the
-- suite's convention); entering the world and logout recur, so they keep a
-- frame
local svCorrupt = false

EventUtil.ContinueOnAddOnLoaded(ADDON_NAME, function()
  local Database = CobysLinkepedia.Database

  -- One protected boundary around everything that reads the item
  -- database: the shape check (Database owns the layout) and the index
  -- build. A failed check, or an error inside either, replaces the
  -- database with an empty valid one, and the login dialog offers a
  -- rebuild. The item database is derived data a scan recreates, so it is
  -- not backed up; favorites and history live in COBYS_LINKEPEDIA_STATE.
  local ok, err = pcall(function()
    local valid, reason = Database.ValidateStorage()
    if not valid then error(reason, 0) end
    Database.Load()
  end)
  if not ok then
    svCorrupt = true
    CobysLinkepedia.Debug.Warn("INIT", "Item database rejected, starting empty: %s", tostring(err))
    COBYS_LINKEPEDIA_DB = {}
    Database.EnsureStorage()
    Database.Load()
  end

  -- Initialize config (fills defaults, validates, creates the state
  -- tables). Guarded as well, so a damaged config cannot stop the rest of
  -- the addon loading; the shared base replaces a config that is not a
  -- table.
  local okConfig, errConfig = pcall(CobysLinkepedia.Config.InitializeData)
  if not okConfig then
    CobysLinkepedia.Debug.Warn("INIT", "Config initialization failed: %s", tostring(errConfig))
  end

  CobysLinkepedia.Debug.Log("INIT", "CobysLinkepedia v%s loaded", VERSION)
end)

EventUtil.ContinueOnPlayerLogin(function()
  -- Show corrupt data dialog if needed
  if svCorrupt and CobysLinkepedia.Database.ShowCorruptDialog then
    CobysLinkepedia.Database.ShowCorruptDialog()
  end

  -- First install check
  if COBYS_LINKEPEDIA_STATE and COBYS_LINKEPEDIA_STATE.firstInstall then
    if CobysLinkepedia.Config.ShowWelcomeWindow then
      CobysLinkepedia.Config.ShowWelcomeWindow()
    end
  else
    -- Version migration check
    local storedVersion = COBYS_LINKEPEDIA_STATE and COBYS_LINKEPEDIA_STATE.version
    if storedVersion and storedVersion ~= VERSION then
      if CobysLinkepedia.Config.RunMigration then
        CobysLinkepedia.Config.RunMigration(storedVersion, VERSION)
      end
      if CobysLinkepedia.Config.ShowUpdateWindow then
        CobysLinkepedia.Config.ShowUpdateWindow(VERSION)
      end
      if COBYS_LINKEPEDIA_STATE then
        COBYS_LINKEPEDIA_STATE.version = VERSION
      end
    end

    -- WoW patch detection: the dialog offers an Expand for the items the
    -- update added. Scans only ever start from the player.
    local currentInterface = select(4, GetBuildInfo())
    local storedInterface = COBYS_LINKEPEDIA_STATE and COBYS_LINKEPEDIA_STATE.interfaceVersion
    if storedInterface and storedInterface ~= currentInterface then
      if CobysLinkepedia.Database.GetCount() > 0 and CobysLinkepedia.Config.ShowPatchDialog then
        CobysLinkepedia.Config.ShowPatchDialog()
      end
      if COBYS_LINKEPEDIA_STATE then
        COBYS_LINKEPEDIA_STATE.interfaceVersion = currentInterface
      end
    end
  end

  -- Linkify's handler for the chat edit box pre-send event, and its hook
  -- on the macro manager's edit box
  CobysLinkepedia.Linkify.InstallHook()
  CobysLinkepedia.Linkify.InstallMacroHook()

  -- Item tokens in the macro window: the side panel, Shift-click tokens and
  -- the preload of the items saved macros name
  CobysLinkepedia.MacroTokens.Initialize()

  -- Hook all existing chat edit boxes (autocomplete)
  CobysLinkepedia.Autocomplete.HookAllEditBoxes()

  -- Build the quick search bar now, so opening it never creates frames in combat
  CobysLinkepedia.QuickSearch.EnsureFrame()

  -- The recipe index the Variant Builder needs, when this client build has
  -- not been indexed yet (it starts a little later and yields to everything)
  CobysLinkepedia.Scanner.ScheduleRecipeScan()

  -- Register minimap button, addon compartment, LDB
  if CobysLinkepedia.Minimap.Initialize then
    CobysLinkepedia.Minimap.Initialize()
  end

  -- Unfinished scan: a Build or Expand started and never reached its end
  -- (cancelled, or cut off by a reload or logout). Expand continues it
  -- without losing what is stored; Build would wipe it. A database that
  -- was never scanned has no flag and gets no notice.
  local scanState = COBYS_LINKEPEDIA_DB and COBYS_LINKEPEDIA_DB.scanState
  if type(scanState) == "table" and scanState.complete == false then
    local Msg = CobysLinkepedia.Utilities.Message
    if Msg then
      Msg("Your last scan did not finish. Use /lp expand to continue it; the items already stored are kept.", "normal")
    end
  end

  CobysLinkepedia.Debug.Log("INIT", "PLAYER_LOGIN complete")
end)

local worldFrame = CreateFrame("Frame")
worldFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
worldFrame:RegisterEvent("PLAYER_LOGOUT")

worldFrame:SetScript("OnEvent", function(_, event, arg1, ...)
  if event == "PLAYER_ENTERING_WORLD" then
    -- isLogin and isReload are the event's first two arguments; arg1 took
    -- the first, so reading both from ... shifted them by one
    local isLogin, isReload = arg1, ...

    -- Start the idle scanner if the SavedVariable exists and the option is
    -- on (the root, not its layout; InitializeData has run by now)
    if COBYS_LINKEPEDIA_DB then
      CobysLinkepedia.Scanner.ReconcileIdle()
    end

    -- Register item encounter event hooks (variant capture)
    if CobysLinkepedia.Database.Capture and CobysLinkepedia.Database.Capture.RegisterEvents then
      CobysLinkepedia.Database.Capture.RegisterEvents()
    end

    CobysLinkepedia.Debug.Log("INIT", "PLAYER_ENTERING_WORLD (login=%s, reload=%s)",
      tostring(isLogin), tostring(isReload))

  elseif event == "PLAYER_LOGOUT" then
    -- Join pending scan writes onto their bucket strings, and write the
    -- dead-ID list, before the SavedVariables are written
    CobysLinkepedia.Database.Flush()
    CobysLinkepedia.Scanner.SaveDead()
  end
end)
