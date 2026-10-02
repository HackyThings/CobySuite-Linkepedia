-- Version change and WoW patch handling: the migration stub Core.lua calls
-- when the addon version changes, and the WoW patch dialog, which offers an
-- Expand. What changed in a version shows in the changelog window
-- (Guide/WhatsNew.lua).

local Config = CobysLinkepedia.Config
local Utilities = CobysLinkepedia.Utilities

-------------------------------------------------------------------------------
-- Migration stub: called from Core.lua on version change
-------------------------------------------------------------------------------
function Config.RunMigration(oldVersion, newVersion)
  CobysLinkepedia.Debug.Log("CONFIG", "Migration: %s -> %s", oldVersion, newVersion)
  -- Add version-specific migration logic here as needed
end

-------------------------------------------------------------------------------
-- WoW patch dialog: offers an Expand after a WoW update (Core.lua shows it
-- when the interface version changed and a database exists)
-------------------------------------------------------------------------------
function Config.ShowPatchDialog()
  if Config._patchDialog then
    Config._patchDialog:Show()
    return
  end

  -- Named, so Escape closes it through UISpecialFrames; Config._patchDialog
  -- keeps it a singleton
  local popup = Utilities.CreateDialogPopup({
    name = "CobysLinkepediaPatchDialog",
    icon = CobysLinkepedia.ICON,
    title = "WoW Updated",
    width = 380,
    body = "WoW has been updated. Check for the items it added?\n" ..
      "Your database is kept; only new item IDs are scanned.",
    confirmText = "Check Now",
    cancelText = "Dismiss",
    onConfirm = function()
      if CobysLinkepedia.Scanner.StartExpand then
        CobysLinkepedia.Scanner.StartExpand()
      end
      CobysLinkepedia.Debug.Log("INIT", "WoW patch dialog: user chose to check for new items")
    end,
  })

  Config._patchDialog = popup
end
