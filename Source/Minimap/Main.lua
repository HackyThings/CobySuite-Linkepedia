-- Minimap: minimap button (polar-coordinate drag), LDB data object, Addon Compartment
-- All three come from the shared launcher (CobySuite.UI.CreateLauncher); this
-- file supplies the actions, the saved angle, the show setting and the tooltip.

local Minimap_Module = CobysLinkepedia.Minimap
local Config = CobysLinkepedia.Config
local Search = CobysLinkepedia.Search
local Utilities = CobysLinkepedia.Utilities
local Debug = CobysLinkepedia.Debug

local ICON_TEXTURE = "Interface\\Icons\\INV_Misc_Book_09"

local launcher = CobySuite_CobysLinkepedia.UI.CreateLauncher({
  name          = "CobysLinkepedia",
  label         = "Coby's Linkepedia",
  icon          = ICON_TEXTURE,
  buttonName    = "CobysLinkepediaMinimapButton",
  -- Utilities.BRAND_TOOLTIP_OPTS: the branded title, item count and click hints
  tooltip       = function() return Utilities.BRAND_TOOLTIP_OPTS end,
  onLeftClick   = function() Search.ToggleWindow() end,
  onRightClick  = function() Config.ToggleSettings() end,
  persist       = {
    svTable      = function() return COBYS_LINKEPEDIA_WINDOW_STATE end,
    key          = "minimapAngle",
    defaultAngle = 220,
  },
  isShown       = function() return Config.Get(Config.Options.SHOW_MINIMAP_BUTTON) ~= false end,
  buttonTooltipAnchor      = "ANCHOR_LEFT",
  compartmentTooltipAnchor = "ANCHOR_RIGHT",
})

-------------------------------------------------------------------------------
-- Addon Compartment handlers (the TOC globals in Core.lua call these)
-------------------------------------------------------------------------------
function Minimap_Module.OnCompartmentClick(button)
  launcher:OnCompartmentClick(button)
end

function Minimap_Module.OnCompartmentEnter(menuItem)
  launcher:OnCompartmentEnter(menuItem)
end

function Minimap_Module.OnCompartmentLeave()
  launcher:OnCompartmentLeave()
end

-------------------------------------------------------------------------------
-- Initialize (called from Core.lua PLAYER_LOGIN): the button at the saved
-- angle (default 220), shown per the setting, and the LDB object when a
-- broker library exists
-------------------------------------------------------------------------------
function Minimap_Module.Initialize()
  launcher:Initialize()
  if launcher.DataObject then
    Debug.Log("INIT", "LDB data object registered")
  end
  Debug.Log("INIT", "Minimap module initialized (angle: %d)", launcher:GetAngle())
end

-- Listen for config changes to show/hide button. A nil key (Defaults, a
-- restored snapshot) means any option may have changed, so re-read it.
local configListener = { ReceiveEvent = function(_, eventName, key)
  if key == nil or key == Config.Options.SHOW_MINIMAP_BUTTON then
    launcher:RefreshShown()
  end
end }

CobysLinkepedia.EventBus:Register(configListener, { CobysLinkepedia.Events.ConfigChanged })

Debug.Log("INIT", "Minimap module loaded")
