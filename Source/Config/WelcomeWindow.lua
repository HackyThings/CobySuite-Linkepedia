-- Welcome Window: shown on first install
-- Explains the addon, shows key commands, and offers a "Build Database" button

local Config = CobysLinkepedia.Config
local Utilities = CobysLinkepedia.Utilities

function Config.ShowWelcomeWindow()
  if Config._welcomeWindow then
    Config._welcomeWindow:Show()
    return
  end

  -- Named: a singleton that Escape closes through UISpecialFrames
  local popup = Utilities.CreateDialogPopup({
    name = "CobysLinkepediaWelcomeWindow",
    title = "Welcome to Coby's Linkepedia!",
    width = 420,
    height = 280,
    body = "Coby's Linkepedia is your personal item encyclopedia. It scans the WoW " ..
      "item cache to build a searchable database of every item in the game.\n\n" ..
      "|cFFFFD100Key Commands:|r\n" ..
      "  |cFF00CED1/lp build|r: build the item database\n" ..
      "  |cFF00CED1/lp show|r: open the search window\n" ..
      "  |cFF00CED1[|r: type in chat to autocomplete item links\n" ..
      "  Key bindings for the search window and quick search: Options > Keybindings > AddOns\n\n" ..
      "To get started, build your item database. This takes a few minutes " ..
      "and runs in the background.",
    confirmText = "Build Database",
    onConfirm = function()
      if CobysLinkepedia.Scanner.StartBuild then
        CobysLinkepedia.Scanner.StartBuild(true)
      end
      CobysLinkepedia.Debug.Log("INIT", "Welcome window: user chose to build database")
    end,
    cancelText = "Later",
  })
  popup.Body:SetJustifyH("LEFT")
  popup.Body:SetSpacing(3)

  -- The popup is named, so Escape closes it through UISpecialFrames without
  -- running either button handler. Clearing the flag on hide covers every
  -- close path: any way this window goes away, the user has seen it. Leaving
  -- it set froze Core.lua on the first-install branch, so the window reopened
  -- every login and the version / interface-version migration never ran.
  popup:HookScript("OnHide", function()
    if COBYS_LINKEPEDIA_STATE then
      COBYS_LINKEPEDIA_STATE.firstInstall = false
    end
  end)

  -- Later dismisses without building, with a reminder
  popup.CancelButton:SetScript("OnClick", function()
    popup:Hide()
    Utilities.Message("Use |cFF00CED1/lp build|r when you're ready to build your database.")
    CobysLinkepedia.Debug.Log("INIT", "Welcome window: user dismissed")
  end)

  Config._welcomeWindow = popup
end
