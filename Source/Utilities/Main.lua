local Utilities = CobysLinkepedia.Utilities
local Shared = CobySuite_CobysLinkepedia.Utilities
local SharedUI = CobySuite_CobysLinkepedia.UI

---------------------------------------------------------------------------
-- Import all shared constants and functions
---------------------------------------------------------------------------
for k, v in pairs(Shared) do Utilities[k] = v end

-- Import shared UI factories as Utilities methods (backwards compatibility)
Utilities.AddTooltip        = SharedUI.AddTooltip
Utilities.AddItemTooltip    = SharedUI.AddItemTooltip
Utilities.CreateButton      = SharedUI.CreateButton
Utilities.CreateDropDown    = SharedUI.CreateDropDown
Utilities.CreateDialogPopup = SharedUI.CreateDialogPopup

---------------------------------------------------------------------------
-- Colors: copy shared palette + add addon-specific colors
---------------------------------------------------------------------------
Utilities.Colors = {}
for k, v in pairs(Shared.Colors) do Utilities.Colors[k] = v end
Utilities.Colors.BRAND_TEAL     = { 0, 0.81, 0.82 }
Utilities.Colors.TEXT_TEAL      = "00CED1"

---------------------------------------------------------------------------
-- Addon-specific: chat output (branded prefix with verbosity check)
--
-- Message(text, level), level one of:
--   "always"  (default) answers to a command, errors, warnings
--   "normal"  automatic lifecycle notices: scan start, refine, complete
--   "verbose" per-phase and per-batch detail
-- Quiet prints "always" only, Normal adds "normal", Verbose prints all.
---------------------------------------------------------------------------
local LEVEL_RANK = { always = 0, normal = 1, verbose = 2 }
local VERBOSITY_RANK = { Quiet = 0, Normal = 1, Verbose = 2 }

local function ShouldPrintMessage(level)
  local rank = LEVEL_RANK[level or "always"] or 0
  if rank == 0 then return true end
  local Config = CobysLinkepedia.Config
  local verbosity = Config and Config.Get and Config.Options
    and Config.Get(Config.Options.CHAT_VERBOSITY) or "Normal"
  return rank <= (VERBOSITY_RANK[verbosity] or 1)
end

Utilities.Message = CobySuite_CobysLinkepedia.Chat.NewMessenger({
  prefix = "[Coby's Linkepedia]",
  color  = Utilities.Colors.TEXT_TEAL,
  gate   = ShouldPrintMessage,
})
-- Utilities.Message.Success(text, level) and Utilities.Message.Warn(text,
-- level) print the same way in green and gold


---------------------------------------------------------------------------
-- Addon-specific: CobysLinkepedia tooltip content (minimap, LDB, compartment)
---------------------------------------------------------------------------
local BRAND_TOOLTIP_OPTS = {
  brandColor = "00CFD0",
  title      = "Coby's Linkepedia",
  body = function()
    local count = CobysLinkepedia.Database.GetCount and CobysLinkepedia.Database.GetCount() or 0
    return { "Items: " .. count }
  end,
  keys = {
    { key = "Left-click",  desc = "Open search window" },
    { key = "Right-click", desc = "Open settings"      },
  },
}
Utilities.BRAND_TOOLTIP_OPTS = BRAND_TOOLTIP_OPTS
