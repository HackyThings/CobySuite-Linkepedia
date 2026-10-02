-- CobySuite: Shared library for all CobySuite addons
-- All shared utilities, UI factories, and infrastructure live here.
-- Individual addons (Recollect, CobysLinkepedia, etc.) depend on this.

CobySuite_CobysLinkepedia = CobySuite_CobysLinkepedia or {}

-- Sub-namespace declarations (populated by individual modules)
CobySuite_CobysLinkepedia.Utilities = CobySuite_CobysLinkepedia.Utilities or {}
CobySuite_CobysLinkepedia.UI        = CobySuite_CobysLinkepedia.UI or {}
CobySuite_CobysLinkepedia.Debug     = CobySuite_CobysLinkepedia.Debug or {}
CobySuite_CobysLinkepedia.Config    = CobySuite_CobysLinkepedia.Config or {}
CobySuite_CobysLinkepedia.EventBus  = CobySuite_CobysLinkepedia.EventBus or {}
CobySuite_CobysLinkepedia.Chat      = CobySuite_CobysLinkepedia.Chat or {}
CobySuite_CobysLinkepedia.Slash     = CobySuite_CobysLinkepedia.Slash or {}
CobySuite_CobysLinkepedia.Tests     = CobySuite_CobysLinkepedia.Tests or {}

CobySuite_CobysLinkepedia.SortDir = { ASC = "asc", DESC = "desc" }

-- Where this copy of the library comes from. The monorepo's CobySuite addon
-- leaves it as is; a standalone build embeds the library under its own name
-- and replaces it from its Build.lua with { embedded = true, host = "<addon>",
-- commit = "<short sha>", dirty = <bool> }.
CobySuite_CobysLinkepedia.BuildInfo = CobySuite_CobysLinkepedia.BuildInfo or { embedded = false }

-- The library version for reports: "embedded in <host> at <commit>" in a
-- standalone build, else the CobySuite addon's TOC version. The addon name
-- below is the only string literal in shipped shared code that is exactly
-- the library's name (the standalone build checks this; Source/Tests/ is
-- stripped).
function CobySuite_CobysLinkepedia.LibraryVersionText()
  local info = CobySuite_CobysLinkepedia.BuildInfo
  if info and info.embedded then
    return ("embedded in %s at %s"):format(tostring(info.host or "?"), tostring(info.commit or "?"))
  end
  return C_AddOns.GetAddOnMetadata("CobySuite", "Version") or "?"
end
