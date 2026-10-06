-------------------------------------------------------------------------------
-- WhatsNew: the changelog window and what its login shows, on the shared
-- CobySuite.UI.CreateWhatsNewWindow (the suite's standard, as Recollect's):
-- one collapsible section per version of Data/Changelog.lua, /lp changelog
-- any time. At login COBYS_LINKEPEDIA_WINDOW_STATE.lastVersion says what the
-- player last ran: none (a fresh install) opens the feature guide, an older
-- version this window with every version since then open, else nothing;
-- either waits for combat to end. Core.lua's PLAYER_LOGIN calls OnLogin
-- (after starting lastVersion from the version a player of an older release
-- last ran).
-------------------------------------------------------------------------------
local U = CobySuite_CobysLinkepedia.Utilities

local WhatsNew = {}
CobysLinkepedia.WhatsNew = WhatsNew

local changelog = CobySuite_CobysLinkepedia.UI.CreateWhatsNewWindow({
  name = "CobysLinkepediaChangelogWindow",
  title = CobysLinkepedia.Utilities.WrapColor(CobysLinkepedia.Utilities.Colors.TEXT_TEAL, "Coby's Linkepedia") .. ": What's New",
  icon = CobysLinkepedia.ICON,
  intro = "What changed in each version of Coby's Linkepedia, newest first. Click a version to open or close it.",
  footer = "Open this window any time with " .. U.WrapColor(U.Colors.HELP_COMMAND, "/lp changelog"),
  entries = CobysLinkepedia.Data.Changelog,
  version = CobysLinkepedia.version,
  state = function() return COBYS_LINKEPEDIA_WINDOW_STATE end,
  onFirstRun = function() if CobysLinkepedia.Guide.Show then CobysLinkepedia.Guide.Show() end end,
  combatMessage = function(text) CobysLinkepedia.Utilities.Message(text) end,
  onShow = function(what) CobysLinkepedia.Debug.Log("INIT", "Login shows the %s", what) end,
})

-- The window's instance, for the suites
WhatsNew._test = { instance = changelog }

function WhatsNew.Toggle() changelog:Toggle() end
function WhatsNew.OnLogin() changelog:OnLogin() end
