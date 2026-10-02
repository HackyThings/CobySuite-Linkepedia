-- Config Window: the addon's settings window, the suite's standard one
-- (CobySuite.UI.CreateSettingsWindow): a sidebar of categories, staged edits
-- that Apply writes through Config.Set, Cancel and Defaults, and a Guide
-- button beside Defaults that opens the feature guide. Opened from
-- /lp settings, the minimap button and the Options > AddOns entry
-- (registered at the bottom). Built at load, so opening it never creates
-- frames in combat; the controls are painted from config on every show.
--
-- Each feature's on/off switch sits on its section header or card, and the
-- rows that tune it are disabled while it is off. The examples
-- (Config/Examples.lua) show what the staged settings do and change
-- nothing; the Item database card's buttons start scans at once and never
-- apply staged settings.

local Config = CobysLinkepedia.Config
local Opt = Config.Options
local Examples = Config.Examples
local Utilities = CobysLinkepedia.Utilities
local UI = CobySuite_CobysLinkepedia.UI

local ICONS = "Interface\\Icons\\"

local function Seconds(value)
  if value == 0 then return "Instant" end
  return ("%.2f s"):format(value)
end

local function Items(value)
  if value == 1 then return "1 item" end
  return ("%d items"):format(value)
end

local function History(value)
  if value == 0 then return "Off" end
  return Items(value)
end

local function PerSecond(value)
  return ("%d a second"):format(value)
end

local function On(key)
  return function(get) return get(key) end
end

local function BindingText(action)
  local key = GetBindingKey(action)
  if key then return GetBindingText(key, 1) end
  return Utilities.WrapColor(Utilities.Colors.DISABLED_GRAY, "Not bound")
end

local window = UI.CreateSettingsWindow({
  name = "CobysLinkepediaConfigWindow",
  title = Utilities.WrapColor(Utilities.Colors.TEXT_TEAL, "Coby's Linkepedia") .. " Settings",
  icon = CobysLinkepedia.ICON,
  config = Config,
  size = "standard",
  persist = {
    svTable = function() return COBYS_LINKEPEDIA_WINDOW_STATE end,
    key = "configWindow",
  },
  watch = { bus = CobysLinkepedia.EventBus, event = CobysLinkepedia.Events.ConfigChanged },
  message = function(text) Utilities.Message.Warn(text) end,
  onApply = function()
    CobysLinkepedia.Debug.Log("CONFIG", "Settings applied")
  end,
  footerButtons = {
    {
      text = "Guide", width = 80,
      tooltip = "Open the feature guide: what each part of Coby's Linkepedia does.",
      onClick = function() if CobysLinkepedia.Guide.Toggle then CobysLinkepedia.Guide.Toggle() end end,
    },
  },
  categories = {
    {
      key = "autocomplete", label = "Autocomplete",
      build = function(panel)
        panel:Section("Chat autocomplete", {
          icon = ICONS .. "UI_Chat",
          subtitle = "Type [ and a few letters in any chat box, then pick an item from the list.",
          switchKey = Opt.AUTOCOMPLETE_ENABLED,
          switchTooltip = "Turn chat autocomplete on or off.",
        })
        panel:Slider{
          key = Opt.AUTOCOMPLETE_DELAY, label = "Wait before suggesting",
          min = 0, max = 2, step = 0.05, format = Seconds, minLabel = "Instant", maxLabel = "2 s",
          description = "How long the list waits after your last key press. Shorter feels quicker; longer skips searches while you type fast.",
          enabledWhen = On(Opt.AUTOCOMPLETE_ENABLED),
        }
        panel:Slider{
          key = Opt.MAX_DROPDOWN_RESULTS, label = "Suggestions shown",
          min = 1, max = Examples.MAX_ROWS, step = 1, format = Items,
          description = "How many matches the list shows at once.",
          enabledWhen = On(Opt.AUTOCOMPLETE_ENABLED),
        }
        panel:Preview{
          caption = "Example",
          height = Examples.AUTOCOMPLETE_HEIGHT,
          build = Examples.BuildAutocomplete,
          refresh = Examples.PaintAutocomplete,
          ticker = 1,   -- follows a build; repaints from the cached search
          dimWhen = function(get) return not get(Opt.AUTOCOMPLETE_ENABLED) end,
          description = "Up and Down move through the list, Tab or a click picks, and Enter still sends your message.",
        }
      end,
    },
    {
      key = "linking", label = "Linking",
      build = function(panel)
        panel:BeginCard{
          title = "Link by name",
          description = "Send an item's exact name in brackets and it goes out as a link.",
          icon = ICONS .. "INV_Misc_Note_02",
          switchKey = Opt.AUTO_LINKIFY_ON_SEND,
          switchTooltip = "Turn linking by name on or off.",
        }
        panel:Preview{
          caption = "Example",
          text = Examples.LinkByNameText,
          dimWhen = function(get) return not get(Opt.AUTO_LINKIFY_ON_SEND) end,
          description = "Links are made only when you send. /run and /script lines are never changed. Add ~R2 or ~270 for a captured variant's rank or item level.",
        }
        panel:EndCard()
        panel:BeginCard{
          title = "Item tokens",
          description = "Write ${i=ID}, ${n=name} or ${v=N} and it sends as a link.",
          icon = ICONS .. "INV_Misc_ScrollUnrolled01",
          switchKey = Opt.EXPAND_ITEM_TOKENS,
          switchTooltip = "Turn item tokens on or off, in chat lines and macros.",
        }
        panel:Preview{
          caption = "Example",
          text = Examples.TokensText,
          dimWhen = function(get) return not get(Opt.EXPAND_ITEM_TOKENS) end,
          description = "Tokens become links in typed chat and macro chat lines. Turn this off to send tokens as typed.",
        }
        panel:EndCard()
      end,
    },
    {
      key = "database", label = "Item database",
      build = function(panel)
        panel:Section("Your item database")
        panel:StatusCard{
          icon = ICONS .. "INV_Misc_Book_09",
          ticker = 0.5,
          state = function() return (Examples.DatabaseState()) end,
          stateText = function() return (select(2, Examples.DatabaseState())) end,
          title = function() return (select(3, Examples.DatabaseState())) end,
          description = function() return (select(4, Examples.DatabaseState())) end,
          actions = Examples.DatabaseActions(),
        }
        panel:Note{ text = Examples.SpeedNote, color = Utilities.Colors.CAUTION_ORANGE }

        panel:Section("Scan speed")
        panel:Radio{
          key = Opt.SCAN_SPEED,
          options = {
            { value = "Slow", label = "Slow", description = "Smoothest play while it runs",
              tooltip = "Asks for up to 50 items at a time, then waits 0.5 s for answers." },
            { value = "Medium", label = "Medium", description = "A good balance for most players",
              tooltip = "Asks for up to 100 items at a time, then waits 0.3 s for answers." },
            { value = "Fast", label = "Fast", description = "Finishes soonest, can cost some frames",
              tooltip = "Asks for up to 200 items at a time, then waits 0.1 s for answers." },
          },
          description = "Hold Shift as you click Build or Expand for one faster scan, or Ctrl+Shift for the fastest. Both can stutter while they run.",
        }

        panel:Section("Idle scan", {
          icon = ICONS .. "INV_Misc_PocketWatch_01",
          subtitle = "While you play, quietly asks again for items a scan could not get. Never in combat or during a scan. The search window's Idle Scan box is the same switch.",
          switchKey = Opt.IDLE_SCAN_ENABLED,
          switchTooltip = "Turn the idle scan on or off.",
        })
        panel:Slider{
          key = Opt.IDLE_SCAN_RATE, label = "Items per second",
          min = 1, max = 20, step = 1, format = PerSecond,
          description = function(w)
            return "Higher catches up sooner; lower asks the server for less. " .. Examples.IdleEstimate(w)
          end,
          enabledWhen = On(Opt.IDLE_SCAN_ENABLED),
        }
      end,
    },
    {
      key = "search", label = "Search window",
      build = function(panel)
        panel:Section("Item lists", { icon = ICONS .. "INV_Misc_Spyglass_03" })
        panel:Checkbox{
          key = Opt.SHIFT_HOVER_COMPARISON, label = "Compare with equipped gear on Shift",
          description = "Hold Shift over an item in any list to see it beside what you wear.",
        }
        panel:Slider{
          key = Opt.MAX_RECENT_HISTORY, label = "History length",
          min = 0, max = 200, step = 1, format = History, minLabel = "Off", maxLabel = "200",
          description = "How many of the items you linked the History tab keeps. At Off, new links are no longer kept and the list empties the next time you link an item; the History tab's Clear History empties it now.",
        }
        panel:Section("Shortcuts", {
          icon = ICONS .. "INV_Misc_Key_05",
          subtitle = "Pick these keys in Options > Keybindings > AddOns, under Coby's Linkepedia.",
        })
        panel:Value{
          label = "Toggle search window",
          value = function() return BindingText("COBYSLINKEPEDIA_TOGGLE_SEARCH") end,
          events = { "UPDATE_BINDINGS" },
        }
        panel:Value{
          label = "Toggle quick search",
          value = function() return BindingText("COBYSLINKEPEDIA_TOGGLE_QUICKSEARCH") end,
          events = { "UPDATE_BINDINGS" },
          description = "Quick search is the fastest way to put a link into chat.",
        }
      end,
    },
    {
      key = "messages", label = "Minimap and chat",
      build = function(panel)
        panel:Section("On screen", { icon = CobysLinkepedia.ICON })
        panel:Checkbox{
          key = Opt.SHOW_MINIMAP_BUTTON, label = "Show minimap button",
          description = "Left-click opens search, right-click opens these settings. The addon compartment entry stays either way.",
        }
        panel:Checkbox{
          key = Opt.CAPTURE_TOAST_ENABLED, label = "Show new variant notices",
          description = "A small notice at the bottom right when the addon saves a new version of an item you came across.",
        }
        panel:Button{
          text = "Show sample notice", width = 160,
          description = "Shows one now, whether or not the box above is ticked.",
          onClick = function() Examples.ShowSampleNotice() end,
        }
        panel:Section("Chat messages")
        panel:Radio{
          key = Opt.CHAT_VERBOSITY,
          options = {
            { value = "Quiet", label = "Quiet", description = "Only answers to your commands, and warnings" },
            { value = "Normal", label = "Normal", description = "Also says when a scan starts and finishes" },
            { value = "Verbose", label = "Detailed", description = "Also reports each step of a scan" },
          },
        }
        panel:Preview{ caption = "Example", text = Examples.MessagesText }
      end,
    },
  },
})

-------------------------------------------------------------------------------
-- Options > AddOns entry: the shared page with a button that opens this
-- window, registered once the addon has loaded (as Public Order Whisper does)
-------------------------------------------------------------------------------
EventUtil.ContinueOnAddOnLoaded("CobysLinkepedia", function()
  UI.RegisterSettingsCategory({
    name        = "Coby's Linkepedia",
    brandColor  = Utilities.Colors.TEXT_TEAL,
    version     = CobysLinkepedia.version,
    description = {
      "Your personal item encyclopedia. Search, autocomplete and link any item in the game from a database the addon builds on your own client, with no addon update needed after a patch.",
      "The settings live in the addon's own settings window.",
    },
    slash       = "/lp settings",
    onOpen      = function() window:Open() end,
  })
end)
