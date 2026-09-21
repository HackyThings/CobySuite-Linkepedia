-- Update Window: shown when the addon version changes (not on first
-- install), with "What's New" text from a version-keyed table. Also here: the
-- migration stub and the WoW patch dialog, which offers an Expand.

local Config = CobysLinkepedia.Config
local Utilities = CobysLinkepedia.Utilities

-------------------------------------------------------------------------------
-- Version notes: add entries here for each release
-------------------------------------------------------------------------------
local VERSION_NOTES = {
  ["2.0.0"] = {
    "Complete ground-up rewrite for WoW Midnight 12.1",
    "New item database with prefix-indexed storage",
    "Visual autocomplete dropdown with item icons and quality colors",
    "Auto-linkify with tilde qualifier support ([Item~R2~270])",
    "Full search/explorer window with filters, favorites, and history",
    "Quick search bar (spotlight-style floating search)",
    "Capture toast notifications for new item variants",
    "Minimap button, Addon Compartment, and LDB support",
    "Per-frame micro-batch scanning for smooth performance",
    "Ranked variant capture from gameplay encounters",
  },
}

-------------------------------------------------------------------------------
-- Show the update window
-------------------------------------------------------------------------------
function Config.ShowUpdateWindow(newVersion)
  local notes = VERSION_NOTES[newVersion]
  if not notes then return end

  if Config._updateWindow then
    Config._updateWindow:Show()
    return
  end

  local noteLines = {}
  for _, line in ipairs(notes) do
    table.insert(noteLines, "|cFFFFD100•|r " .. line)
  end

  -- Named, so Escape closes it through UISpecialFrames; Config._updateWindow
  -- keeps it a singleton. Only "Got it": it just dismisses.
  local popup = Utilities.CreateDialogPopup({
    name = "CobysLinkepediaUpdateWindow",
    title = "Coby's Linkepedia Updated: v" .. newVersion,
    width = 420,
    height = 320,
    body = "|cFFFFFFFFWhat's New:|r\n\n" .. table.concat(noteLines, "\n"),
    confirmText = "Got it",
    hideCancel = true,
    onConfirm = function()
      CobysLinkepedia.Debug.Log("INIT", "Update window dismissed for v%s", newVersion)
    end,
  })
  popup.Body:SetJustifyH("LEFT")
  popup.Body:SetSpacing(3)

  Config._updateWindow = popup
end

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
    title = "WoW Updated",
    width = 380,
    height = 160,
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
