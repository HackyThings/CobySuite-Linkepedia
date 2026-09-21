-------------------------------------------------------------------------------
-- CobysLinkepedia Debug Window: thin wrapper around CobySuite.Debug.NewWindow
-- Only contains addon-specific wipe logic and window construction call.
-- The frame is kept as CobysLinkepedia.DebugWindow; callers toggle it with :Toggle().
-------------------------------------------------------------------------------

CobysLinkepedia.DebugWindow = CobySuite_CobysLinkepedia.Debug.NewWindow({
  windowName = "CobysLinkepediaDebugWindow",
  title = "Coby's Linkepedia Debug Log",
  logger = CobysLinkepedia.Debug,
  -- Position and size, kept like the other windows' (the table exists by
  -- the first show)
  persist = {
    svTable = function() return COBYS_LINKEPEDIA_WINDOW_STATE end,
    key = "debugWindow",
  },
  extraToolbarButtons = {
    {
      key = "WipeButton",
      text = "Wipe All Data",
      width = 110,
      textColor = {1, 0.3, 0.3},
      side = "left",
      onClick = function(w) w:WipeAllData() end,
    },
  },
})

-------------------------------------------------------------------------------
-- Wipe All Data: nils the SavedVariables and reloads. One named dialog built
-- at load. This file loads before Utilities/Main.lua, so it uses the shared
-- factory and constants directly.
-------------------------------------------------------------------------------
local wipePopup = CobySuite_CobysLinkepedia.UI.CreateDialogPopup({
  name = "CobysLinkepediaWipePopup",
  title = "Wipe All Coby's Linkepedia Data",
  width = 400,
  height = 160,
  body = "This will delete ALL Coby's Linkepedia data:\n" ..
    "database, config, favorites, history, window state, and debug log.\n\n" ..
    "This cannot be undone. Requires /reload.",
  confirmText = "Wipe Everything",
  danger = true,
  hidden = true,
  onConfirm = function()
    -- Empty the logger first: its logout save writes the in-memory buffer back
    -- to the SavedVariable, which would restore the log this wipe deletes
    CobysLinkepedia.Debug.Clear()
    COBYS_LINKEPEDIA_DB = nil
    COBYS_LINKEPEDIA_CONFIG = nil
    COBYS_LINKEPEDIA_STATE = nil
    COBYS_LINKEPEDIA_WINDOW_STATE = nil
    COBYS_LINKEPEDIA_DEBUG_LOG = nil
    ReloadUI()
  end,
})

function CobysLinkepedia.DebugWindow:WipeAllData()
  wipePopup:Show()
end
