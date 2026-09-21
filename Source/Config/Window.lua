-- Config Window: the addon's settings window, the suite's standard one
-- (CobySuite.UI.CreateSettingsWindow): a sidebar of categories, staged edits
-- that Apply writes through Config.Set, Cancel and Defaults. Opened from
-- /lp settings, the minimap button and the Options > AddOns entry
-- (registered at the bottom). Built at load, so opening it never creates
-- frames in combat; the controls are painted from config on every show.

local Config = CobysLinkepedia.Config
local Opt = Config.Options
local Utilities = CobysLinkepedia.Utilities
local UI = CobySuite_CobysLinkepedia.UI

local function Seconds(decimals)
  return function(value) return ("%." .. decimals .. "f s"):format(value) end
end

local function PerSecond(value)
  return ("%d/s"):format(value)
end

local window = UI.CreateSettingsWindow({
  name = "CobysLinkepediaConfigWindow",
  title = "Coby's Linkepedia - Settings",
  config = Config,
  width = 620,
  height = 420,
  persist = {
    svTable = function() return COBYS_LINKEPEDIA_WINDOW_STATE end,
    key = "configWindow",
  },
  watch = { bus = CobysLinkepedia.EventBus, event = CobysLinkepedia.Events.ConfigChanged },
  message = function(text) Utilities.Message.Warn(text) end,
  onApply = function()
    CobysLinkepedia.Debug.Log("CONFIG", "Settings applied")
  end,
  categories = {
    {
      key = "autocomplete", label = "Autocomplete",
      build = function(panel)
        panel:Section("Chat Autocomplete")
        panel:Checkbox{
          key = Opt.AUTOCOMPLETE_ENABLED, label = "Enable autocomplete",
          tooltip = "Type [ and a letter in chat to get a list of matching items.",
        }
        panel:Slider{
          key = Opt.AUTOCOMPLETE_DELAY, label = "Autocomplete delay",
          tooltip = "How long after your last keystroke the list updates. Default: 0.25 s",
          min = 0, max = 2, step = 0.05, format = Seconds(2),
          enabledWhen = function(get) return get(Opt.AUTOCOMPLETE_ENABLED) end,
        }
        panel:Slider{
          key = Opt.MAX_DROPDOWN_RESULTS, label = "Max dropdown results",
          tooltip = "How many matches the list shows at once. Default: 10",
          min = 1, max = 10, step = 1,
          enabledWhen = function(get) return get(Opt.AUTOCOMPLETE_ENABLED) end,
        }
      end,
    },
    {
      key = "scanning", label = "Scanning",
      build = function(panel)
        panel:Section("Item Scan")
        panel:Dropdown{
          key = Opt.SCAN_SPEED, label = "Scan speed",
          tooltip = "How many items each frame of a scan handles. Slow leaves more frame time for the game; Fast finishes sooner. Default: Medium",
          labels = { "Slow", "Medium", "Fast" }, values = { "Slow", "Medium", "Fast" },
        }
        panel:Section("Idle Scan")
        panel:Checkbox{
          key = Opt.IDLE_SCAN_ENABLED, label = "Enable idle background scan",
          tooltip = "Asks the server again, in the background and never in combat, for the items a scan held back.",
        }
        panel:Slider{
          key = Opt.IDLE_SCAN_RATE, label = "Idle scan speed",
          tooltip = "Item IDs the idle scan checks each second. Default: 5",
          min = 1, max = 20, step = 1, format = PerSecond,
          enabledWhen = function(get) return get(Opt.IDLE_SCAN_ENABLED) end,
        }
      end,
    },
    {
      key = "chat", label = "Chat & Linking",
      build = function(panel)
        panel:Section("On Send")
        panel:Checkbox{
          key = Opt.AUTO_LINKIFY_ON_SEND, label = "Auto-linkify [Item Name] on send",
          tooltip = "When a chat message is sent, [Item Name] becomes that item's link. /run and /script lines are never changed.",
        }
        panel:Checkbox{
          key = Opt.EXPAND_ITEM_TOKENS, label = "Item tokens ${i=ID} and ${n=name} in chat and macros",
          tooltip = "Tokens become item links when a chat line or a macro line is sent.",
        }
        panel:Section("Messages")
        panel:Dropdown{
          key = Opt.CHAT_VERBOSITY, label = "Chat message verbosity",
          tooltip = "Quiet shows only answers and warnings, Normal adds scan notices, Verbose adds per-phase detail.",
          labels = { "Quiet", "Normal", "Verbose" }, values = { "Quiet", "Normal", "Verbose" },
        }
      end,
    },
    {
      key = "display", label = "Display",
      build = function(panel)
        panel:Section("Buttons and Notices")
        panel:Checkbox{
          key = Opt.SHOW_MINIMAP_BUTTON, label = "Show minimap button",
          tooltip = "The book icon at the minimap. The addon compartment entry stays either way.",
        }
        panel:Checkbox{
          key = Opt.CAPTURE_TOAST_ENABLED, label = "Capture toast notifications",
          tooltip = "A small notice at the bottom right each time a new item variant is captured. Default: off",
        }
        panel:Section("Search Window")
        panel:Checkbox{
          key = Opt.SHIFT_HOVER_COMPARISON, label = "Shift-hover item comparison",
          tooltip = "Hold Shift over an item to compare it with what you have equipped.",
        }
        panel:Slider{
          key = Opt.MAX_RECENT_HISTORY, label = "Max recent history entries",
          tooltip = "How many recently linked items the History tab keeps. Default: 50",
          min = 0, max = 200, step = 1,
        }
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
      "Your personal item encyclopedia. Search, autocomplete and link any item in the game from a database the addon builds on your own client.",
      "The settings live in the addon's own window.",
    },
    slash       = "/lp settings",
    onOpen      = function() window:Open() end,
  })
end)
