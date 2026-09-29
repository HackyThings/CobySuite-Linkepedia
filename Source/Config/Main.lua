local Config = CobysLinkepedia.Config

---------------------------------------------------------------------------
-- Shared config base via CobySuite.Config.New
---------------------------------------------------------------------------
local base = CobySuite_CobysLinkepedia.Config.New({
  savedVariable = "COBYS_LINKEPEDIA_CONFIG",
  options = {
    AUTOCOMPLETE_ENABLED   = "autocompleteEnabled",
    AUTOCOMPLETE_DELAY     = "autocompleteDelay",
    MAX_DROPDOWN_RESULTS   = "maxDropdownResults",
    SCAN_SPEED             = "scanSpeed",
    IDLE_SCAN_ENABLED      = "idleScanEnabled",
    IDLE_SCAN_RATE         = "idleScanRate",
    SHOW_MINIMAP_BUTTON    = "showMinimapButton",
    AUTO_LINKIFY_ON_SEND   = "autoLinkifyOnSend",
    EXPAND_ITEM_TOKENS     = "expandItemTokens",
    CHAT_VERBOSITY         = "chatVerbosity",
    CAPTURE_TOAST_ENABLED  = "captureToastEnabled",
    MAX_RECENT_HISTORY     = "maxRecentHistory",
    SHIFT_HOVER_COMPARISON = "shiftHoverComparison",
  },
  defaults = {
    ["autocompleteEnabled"]   = true,
    ["autocompleteDelay"]     = 0.25,
    ["maxDropdownResults"]    = 10,
    ["scanSpeed"]             = "Medium",
    ["idleScanEnabled"]       = true,
    ["idleScanRate"]          = 5,
    ["showMinimapButton"]     = true,
    ["autoLinkifyOnSend"]     = true,
    ["expandItemTokens"]      = true,
    ["chatVerbosity"]         = "Normal",
    ["captureToastEnabled"]   = false,
    ["maxRecentHistory"]      = 50,
    ["shiftHoverComparison"]  = true,
  },
  validate = {
    ["autocompleteEnabled"]   = { type = "boolean" },
    ["autocompleteDelay"]     = { type = "number", min = 0, max = 2 },
    ["maxDropdownResults"]    = { type = "number", min = 1, max = 10, integer = true },
    ["scanSpeed"]             = { type = "string", values = { "Slow", "Medium", "Fast" } },
    ["idleScanEnabled"]       = { type = "boolean" },
    ["idleScanRate"]          = { type = "number", min = 1, max = 20, integer = true },
    ["showMinimapButton"]     = { type = "boolean" },
    ["autoLinkifyOnSend"]     = { type = "boolean" },
    ["expandItemTokens"]      = { type = "boolean" },
    ["chatVerbosity"]         = { type = "string", values = { "Quiet", "Normal", "Verbose" } },
    ["captureToastEnabled"]   = { type = "boolean" },
    ["maxRecentHistory"]      = { type = "number", min = 0, max = 200, integer = true },
    ["shiftHoverComparison"]  = { type = "boolean" },
  },
  debug = CobysLinkepedia.Debug,
  onSet = function(name, old, value)
    CobysLinkepedia.EventBus:Fire(CobysLinkepedia.Events.ConfigChanged, name, value, old)
  end,
  onReset = function()
    CobysLinkepedia.EventBus:Fire(CobysLinkepedia.Events.ConfigChanged)
  end,
})

-- Install onto CobysLinkepedia.Config namespace
Config.Options        = base.Options
Config.Defaults       = base.Defaults
Config.IsValidOption  = base.IsValidOption
Config.CheckValue     = base.CheckValue
Config.Get            = base.Get
Config.Set            = base.Set

---------------------------------------------------------------------------
-- InitializeData: wraps base with addon-specific SavedVariable init
---------------------------------------------------------------------------
function Config.InitializeData()
  -- Initialize config SavedVariable (shared base handles defaults + stale cleanup)
  base.InitializeData()

  -- Initialize COBYS_LINKEPEDIA_STATE
  if type(COBYS_LINKEPEDIA_STATE) ~= "table" then
    COBYS_LINKEPEDIA_STATE = {
      version = CobysLinkepedia.version,
      interfaceVersion = select(4, GetBuildInfo()),
      firstInstall = true,
      favorites = {},
      history = {},
      savedVariants = { nextID = 1, byID = {} },
    }
    CobysLinkepedia.Debug.Log("CONFIG", "InitializeData: first install detected")
  else
    if type(COBYS_LINKEPEDIA_STATE.favorites) ~= "table" then COBYS_LINKEPEDIA_STATE.favorites = {} end
    if type(COBYS_LINKEPEDIA_STATE.history) ~= "table" then COBYS_LINKEPEDIA_STATE.history = {} end
  end
  -- Saved variants repair their own records (Variants/Store.lua)
  CobysLinkepedia.Variants.ValidateSaved()

  -- Initialize COBYS_LINKEPEDIA_WINDOW_STATE
  if type(COBYS_LINKEPEDIA_WINDOW_STATE) ~= "table" then
    COBYS_LINKEPEDIA_WINDOW_STATE = {}
  end

  -- Initialize COBYS_LINKEPEDIA_DB. Its layout belongs to Database, which is
  -- the only file allowed to know what lives inside it.
  CobysLinkepedia.Database.EnsureStorage()
end

---------------------------------------------------------------------------
-- HandleSetCommand: /lp set <key> <value>
---------------------------------------------------------------------------
function Config.HandleSetCommand(input)
  local Msg = CobysLinkepedia.Utilities.Message
  if not input or input:trim() == "" then
    if Msg then Msg("Current settings:") end
    local keys = {}
    for _, key in pairs(Config.Options) do
      table.insert(keys, key)
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
      local val = Config.Get(key)
      if Msg then
        Msg("  " .. key .. " = " .. tostring(val))
      end
    end
    return
  end

  local key, value = input:match("^(%S+)%s+(.*)")
  if not key then
    if Msg then Msg("Usage: /lp set <key> <value>") end
    return
  end

  if not Config.IsValidOption(key) then
    if Msg then Msg(CobysLinkepedia.Utilities.WrapColor("FF4D4D", "Unknown setting: " .. key)) end
    return
  end

  local parsed
  local lower = value:lower()
  if lower == "true" or lower == "on" then
    parsed = true
  elseif lower == "false" or lower == "off" then
    parsed = false
  elseif tonumber(value) then
    parsed = tonumber(value)
  else
    parsed = value
  end

  local ok, reason = Config.Set(key, parsed)
  if not Msg then return end
  if ok then
    Msg(key .. " = " .. tostring(parsed))
  else
    Msg(CobysLinkepedia.Utilities.WrapColor("FF4D4D", "Invalid value for " .. key .. ": " .. tostring(reason)))
  end
end

---------------------------------------------------------------------------
-- OpenSettings / ToggleSettings: the settings window (Config/Window.lua),
-- for /lp settings and the minimap button. The Options > AddOns entry opens
-- the window itself (window:Open).
---------------------------------------------------------------------------
function Config.OpenSettings()
  local f = CobysLinkepediaConfigWindow
  if f and not f:IsShown() then f:Toggle() end
end

function Config.ToggleSettings()
  local f = CobysLinkepediaConfigWindow
  if f then f:Toggle() end
end
