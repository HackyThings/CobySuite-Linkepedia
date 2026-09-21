-------------------------------------------------------------------------------
-- CobysLinkepedia Debug Logger: thin wrapper around CobySuite.Debug.NewLogger
-------------------------------------------------------------------------------

CobysLinkepedia.Debug = CobySuite_CobysLinkepedia.Debug.NewLogger({
  addonName = "CobysLinkepedia",
  categories = {
    "INIT", "CONFIG", "SCAN", "DATABASE",
    "AUTOCOMPLETE", "LINKIFY", "CAPTURE", "UI",
    "DIAG",
  },
  savedVariable = "COBYS_LINKEPEDIA_DEBUG_LOG",
  sessionHeader = function(lines)
    CobySuite_CobysLinkepedia.Debug.AppendConfigSnapshot(lines, "COBYS_LINKEPEDIA_CONFIG")

    -- Database stats (through the Database API; this file loads before it,
    -- but the header is built at runtime)
    local Database = CobysLinkepedia.Database
    if Database and Database.GetCount then
      table.insert(lines, "Database: " .. Database.GetCount() .. " items")
    end
  end,
})
