-- Search Results: TableHeader + ScrollBox with sortable, resizable columns
-- Follows CobySniper's proven column-based row rendering pattern
--
-- Performance notes:
--   - Browsing and text search build the same kind of list: (itemID, handle)
--     pairs from Database.NewBrowseBuilder, across frames, never a result
--     table per match; rows materialise their item only when drawn
--   - Enrichment is lazy: only visible rows (~15-20) call C_Item APIs per render
--   - QuickEnrich (C_Item.GetItemInfoInstant) is client-only, fast
--   - FullEnrich (C_Item.GetItemInfo) may hit server cache, used sparingly
--   - Column sorts read keys from the stored records (Database.EntrySortKey)
--     and run as counting sorts across frames; the name column is a copy of
--     the name order the build recorded
--   - Column resize repositions existing cells, no object recreation

local Search = CobysLinkepedia.Search
local Database = CobysLinkepedia.Database
local Utilities = CobysLinkepedia.Utilities
local Debug = CobysLinkepedia.Debug
local SortDir = CobySuite_CobysLinkepedia.SortDir

local ROW_HEIGHT = 22
local ICON_SIZE = 18

-- State
local dataProvider = nil
local scrollBox = nil
local scrollBar = nil
local scrollView = nil
local tableHeader = nil
local emptyLabel = nil
local resultsTabActive = true
local currentQuery = ""
local currentFilters = {}

-- How the search box's text matches: "exact", "any" or "all" (see
-- Database.NewBrowseBuilder). Kept in COBYS_LINKEPEDIA_WINDOW_STATE.searchMode,
-- read on first use (the saved state loads after this file).
local SEARCH_MODES = { exact = true, any = true, all = true }
local searchMode = nil

local function SearchMode()
  if not searchMode then
    local state = COBYS_LINKEPEDIA_WINDOW_STATE
    local saved = type(state) == "table" and state.searchMode
    searchMode = SEARCH_MODES[saved] and saved or "exact"
  end
  return searchMode
end
local sortColumn = "quality"
local sortDir = SortDir.DESC

-- The list the ScrollBox shows. Elements handed to the row initialiser are
-- integer positions into these arrays, never item tables, so a 176K-item
-- list costs two flat arrays rather than 176K result tables.
local resultCount = 0
local resultIDs = {}        -- position -> itemID
local resultEntries = nil   -- position -> stored entry handle
-- Rows materialise their item on draw and park it here by position. Values
-- are weak: once a row recycles, the GC reclaims items nobody else holds, so
-- scrolling the whole list never accumulates the whole list.
local browseCache = setmetatable({}, { __mode = "v" })

-- Builds: the list for the current filters, and query when one is typed, in
-- default order, built across frames (see Database.NewBrowseBuilder). Two
-- bases are cached, the browse list and the last text search, each until the
-- database, its filters, or its query and search mode change; column sorts reorder a cached
-- base without walking again, and clearing a search puts the browse list
-- back at once.
local BUILD_BUDGET_MS = 6
local buildSerial = 0           -- bumps to stand down a build or deferred sort in flight
local builder = nil
local builderFrame = CreateFrame("Frame")
local buildSig = nil            -- signature (filters, and query with its search mode) of the build in flight
local buildSlot = nil           -- "browse" or "text": the base the build fills
local buildGeneration = nil     -- Database.GetGeneration() when that build started
local buildOwner = nil          -- "user" or "system": who asked for the build in flight
local buildWaitsForCombat = false  -- the build in flight (walk and finish) holds still in combat
local EnsureOverlay             -- assigned with the overlay below; InitResults calls it

local function NewBase()
  return {
    valid = false,
    sig = nil,                                 -- filters, and query with its search mode, it was built for
    generation = nil,                          -- database generation the base was built from
    baseIDs = nil, baseEntries = nil, n = 0,   -- quality descending, then name
    groupBounds = nil,                         -- {from, to} of each quality group in the base
    nameOrder = nil,                           -- base positions in name order over every quality
  }
end
local bases = { browse = NewBase(), text = NewBase() }
-- What the ScrollBox shows: which base, in which sort
local presented = { base = nil, key = nil, dir = nil }

-- Combat policy for result work. A request belongs to the user (a keystroke,
-- a header click, a filter choice) or to the system (a DatabaseUpdated
-- refresh, and a deferred sort a system request started). One policy covers
-- every stage of a list (the walk, the finish that joins it, the column
-- sort): a text search or sort the user asked for runs at once, in combat
-- too; the browse walk and its finish, whoever asked, and all system-owned
-- work hold still while the player is in combat and carry on when the fight
-- ends. A system refresh asked for in combat waits and then runs once with
-- whatever was requested last.
local pendingSystemRefresh = false

-- Test seams for the Browse suite (Search.SetTestOverrides): a combat flag
-- and a slice budget in place of the real ones while set
local testOverrides = nil

local function InCombat()
  local forced = testOverrides and testOverrides.inCombat
  if forced ~= nil then
    if type(forced) == "function" then return forced() and true or false end
    return forced
  end
  return UnitAffectingCombat("player")
end

local function Budget()
  return testOverrides and testOverrides.budgetMs or BUILD_BUDGET_MS
end

local function OnCombatEnded()
  if not pendingSystemRefresh then return end
  pendingSystemRefresh = false
  if CobysLinkepediaSearchWindow and CobysLinkepediaSearchWindow:IsShown() then
    Search.RefreshResults(currentQuery, "system")
  end
end

local regenFrame = CreateFrame("Frame")
regenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
regenFrame:SetScript("OnEvent", function()
  -- A test still holding its simulated fight ends it itself (SetTestOverrides)
  if testOverrides and testOverrides.inCombat ~= nil and InCombat() then return end
  OnCombatEnded()
end)

-- Jobs: work after a build's walk (joining its output, a column sort) runs in
-- a coroutine that yields whenever this frame's slice is spent, so no single
-- frame carries it. One job at a time; a newer build or sort (buildSerial)
-- stands it down.
local jobFrame = CreateFrame("Frame")
local jobActive = false
local jobKind = nil     -- "finish" or "sort" while a job runs
local workSlices = 0    -- walk steps and job slices run, for GetListState
local sliceStart = 0

-- Called by job code every few hundred entries (column sorts) or few
-- thousand (Finish)
local function Pause()
  if debugprofilestop() - sliceStart >= Budget() then
    coroutine.yield()
  end
end

-- Runs fn(Pause) across frames and calls onDone with a table of its return
-- values. waitsForCombat (a boolean, or a function read before every slice):
-- no slice runs while the player is in combat (combatText goes on the
-- overlay meanwhile). kind names the job for GetListState.
local ShowOverlay   -- assigned with the overlay below
local function StopJob()
  jobActive = false
  jobKind = nil
  jobFrame:SetScript("OnUpdate", nil)
end

local function RunJob(fn, onDone, waitsForCombat, combatText, kind)
  StopJob()
  local serial = buildSerial
  local co = coroutine.create(function(pause) return { fn(pause) } end)
  jobActive = true
  jobKind = kind
  local function Resume()
    if serial ~= buildSerial then
      StopJob()
      return
    end
    local waits = waitsForCombat
    if type(waits) == "function" then waits = waits() end
    if waits and InCombat() then
      if combatText then ShowOverlay(combatText) end
      return
    end
    workSlices = workSlices + 1
    sliceStart = debugprofilestop()
    local ok, result = coroutine.resume(co, Pause)
    if not ok then
      StopJob()
      error(result, 0)
    end
    if coroutine.status(co) == "dead" then
      StopJob()
      onDone(result)
    end
  end
  jobFrame:SetScript("OnUpdate", Resume)
  Resume()
end

-------------------------------------------------------------------------------
-- Column definitions
-------------------------------------------------------------------------------
local COLUMNS = {
  { key = "name",      label = "Item Name",  width = 200, sortable = true, justify = "LEFT",   tooltip = "Item name, colored by quality" },
  { key = "itemLevel", label = "iLvl",       width = 45,  sortable = true, justify = "CENTER", tooltip = "Item level" },
  { key = "type",      label = "Type",       width = 90,  sortable = true, justify = "LEFT",   tooltip = "Item class (Weapon, Armor, etc.)" },
  { key = "subType",   label = "Subtype",    width = 90,  sortable = true, justify = "LEFT",   tooltip = "Item subclass (Cloth, Dagger, etc.)" },
  { key = "expansion", label = "Expac",      width = 70,  sortable = true, justify = "CENTER", tooltip = "Expansion the item belongs to" },
  { key = "quality",   label = "Quality",    width = 65,  sortable = true, justify = "CENTER", tooltip = "Item quality (Poor through Legendary)" },
  { key = "itemID",    label = "ID",         width = 55,  sortable = true, justify = "RIGHT",  tooltip = "Numeric item ID" },
  { key = "reqLevel",  label = "Req",        width = 40,  sortable = true, justify = "CENTER", tooltip = "Required player level" },
  -- Trailing spacer that absorbs leftover width, matching CobySniper's tables.
  -- Stretching a real data column instead cost it its divider and its resize
  -- handle, and inverted it whenever the window was narrower than the columns.
  { key = "_pad",      label = "",                        sortable = false,                    stretch = true },
}

-------------------------------------------------------------------------------
-- Two-level enrichment: Quick (client-only) and Full (may hit server cache)
-------------------------------------------------------------------------------
-- Each level is marked done only once the client has actually answered, so
-- an item it had not loaded is asked again on its next draw (and a drawn row
-- requests the data once, RequestRowData below)
local function QuickEnrich(item)
  if item._qe then return end

  -- Stored class first; the icon always comes from the instant API
  local classID = item._classID
  if not classID or classID < 0 or not item._icon then
    local _, _, _, _, ic, cid, scid = C_Item.GetItemInfoInstant(item.itemID)
    item._icon = ic or item._icon
    if cid and (not classID or classID < 0) then
      item._classID = cid
      item._subClassID = scid or item._subClassID or -1
    end
  end

  item.type = Utilities.GetClassName(item._classID) or ""
  item.subType = Utilities.GetSubClassName(item._classID, item._subClassID) or ""
  item._qe = (item._classID or -1) >= 0 and item._icon ~= nil
end

local function FullEnrich(item)
  QuickEnrich(item)
  if item._fe then return end

  -- Stored values first (zero API calls for entries the scan filled in)
  local expID = item._expansionID
  if not expID or expID < 0 then
    local _, _, _, itemLevel, reqLevel, _, _, _, equipLoc, _, _, _, _, _, expansionID = C_Item.GetItemInfo(item.itemID)
    if expansionID then
      item.itemLevel = itemLevel or item.itemLevel or 0
      item.reqLevel = reqLevel or item.reqLevel or 0
      item._expansionID = expansionID
      item._equipLoc = equipLoc or ""
      expID = expansionID
    end
  end

  item.expansion = (expID and expID >= 0 and Utilities.ExpansionNames[expID]) or ""
  item._fe = expID ~= nil and expID >= 0
end

-------------------------------------------------------------------------------
-- Row rendering: structure creation, cell repositioning, data population
-------------------------------------------------------------------------------

-- Create cell objects for a row (only when column count changes)
local function EnsureRowStructure(row, columns)
  if row._colCount == #columns then return end
  row._colCount = #columns

  if row._cells then
    for _, cell in ipairs(row._cells) do
      if cell.text then cell.text:Hide() end
      if cell.icon then cell.icon:Hide() end
    end
  end
  row._cells = {}

  for i, colDef in ipairs(columns) do
    local cell = {}
    if colDef.key == "name" then
      cell.icon = row:CreateTexture(nil, "ARTWORK")
      cell.icon:SetSize(ICON_SIZE, ICON_SIZE)
      cell.text = row:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
      cell.text:SetJustifyH("LEFT")
    else
      cell.text = row:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
      cell.text:SetJustifyH(colDef.justify or "LEFT")
    end
    row._cells[i] = cell
  end
end

-- Reposition all cells based on current column widths (called on resize + render)
local function RepositionCells(row, columns)
  if not row._cells then return end
  local x = 0
  for i, colDef in ipairs(columns) do
    local cell = row._cells[i]
    if not cell then break end
    local w = colDef.width or 0   -- the trailing _pad column carries no width

    if colDef.stretch then
      -- Padding column: no cell content, and it must not advance x.
    elseif colDef.key == "name" then
      if cell.icon then
        cell.icon:ClearAllPoints()
        cell.icon:SetPoint("LEFT", x + 4, 0)
      end
      if cell.text then
        cell.text:ClearAllPoints()
        cell.text:SetPoint("LEFT", x + ICON_SIZE + 8, 0)
        cell.text:SetWidth(math.max(w - ICON_SIZE - 12, 10))
      end
    else
      if cell.text then
        cell.text:ClearAllPoints()
        cell.text:SetPoint("LEFT", x + 4, 0)
        cell.text:SetWidth(math.max(w - 8, 10))
      end
    end
    x = x + w
  end
end

-- Fill cell content with item data (lazy enrichment for visible rows only)
local function PopulateRow(row, data, columns)
  row.itemData = data
  EnsureRowStructure(row, columns)
  RepositionCells(row, columns)
  FullEnrich(data)

  for i, colDef in ipairs(columns) do
    local cell = row._cells[i]
    if not cell then break end
    local key = colDef.key

    if key == "name" then
      cell.icon:SetTexture(data._icon or "Interface\\Icons\\INV_Misc_QuestionMark")
      cell.icon:SetDesaturated(false)
      cell.icon:SetAlpha(1)
      cell.icon:Show()
      cell.text:SetText(data.name)
      local qc = ITEM_QUALITY_COLORS[data.quality or 1]
      if qc then
        cell.text:SetTextColor(qc.r, qc.g, qc.b)
      else
        cell.text:SetTextColor(1, 1, 1)
      end
      cell.text:Show()

    elseif key == "quality" then
      cell.text:SetText(Utilities.QualityNames[data.quality] or "")
      local qc = ITEM_QUALITY_COLORS[data.quality or 1]
      if qc then
        cell.text:SetTextColor(qc.r, qc.g, qc.b)
      else
        cell.text:SetTextColor(unpack(Utilities.Colors.LABEL_GRAY))
      end
      cell.text:Show()

    elseif key == "itemLevel" then
      cell.text:SetText(data.itemLevel and data.itemLevel > 0 and tostring(data.itemLevel) or "")
      local lg = Utilities.Colors.LIGHT_GRAY
      cell.text:SetTextColor(lg[1], lg[2], lg[3])
      cell.text:Show()

    elseif key == "itemID" then
      cell.text:SetText(tostring(data.itemID))
      local lg = Utilities.Colors.LIGHT_GRAY
      cell.text:SetTextColor(lg[1], lg[2], lg[3])
      cell.text:Show()

    elseif key == "reqLevel" then
      cell.text:SetText(data.reqLevel and data.reqLevel > 0 and tostring(data.reqLevel) or "")
      local lg = Utilities.Colors.LIGHT_GRAY
      cell.text:SetTextColor(lg[1], lg[2], lg[3])
      cell.text:Show()

    else
      -- type, subType, expansion: plain text
      cell.text:SetText(data[key] or "")
      local lg = Utilities.Colors.LIGHT_GRAY
      cell.text:SetTextColor(lg[1], lg[2], lg[3])
      cell.text:Show()
    end
  end
end

-------------------------------------------------------------------------------
-- Row init (called by ScrollBox for each visible row)
-------------------------------------------------------------------------------
-- The item table for a list position, materialised on demand into the weak
-- cache, so only rows that have been drawn ever exist as tables
local function ResolveItem(pos)
  local item = browseCache[pos]
  if item then return item end
  local id = resultIDs[pos]
  if not id then return nil end
  item = Database.MaterializeEntry(id, resultEntries[pos])
  browseCache[pos] = item
  return item
end

-- A drawn row whose item the client had not loaded asks for it once and
-- redraws itself when the data arrives, if it still shows that item
local function RequestRowData(row, data)
  if data._loadRequested then return end
  data._loadRequested = true
  Utilities.LoadItemThen(data.itemID, {
    timeout = 10,
    onReady = function()
      if row.itemData == data and row:IsVisible() and tableHeader then
        PopulateRow(row, data, tableHeader:GetColumns())
      end
    end,
  })
end

local function InitRow(row, pos)
  if not row._initialized then
    -- Highlight
    row.Highlight = CobySuite_CobysLinkepedia.UI.AddHoverHighlight(row)

    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- Handlers are installed once per row and read row.itemData at event
    -- time (PopulateRow keeps it current), so a recycled row costs no new
    -- closures per draw. The shared tooltip helper takes an ID resolver for
    -- exactly this.
    row:SetScript("OnClick", function(self, button)
      Search.HandleItemClick(self.itemData, button, self)
    end)

    CobySuite_CobysLinkepedia.UI.AddItemTooltip(row, function(self)
      return self.itemData and self.itemData.itemID
    end, "ANCHOR_RIGHT", Search.ItemTooltipOptions)

    row._initialized = true
  end

  local item = ResolveItem(pos)
  if not item then return end

  -- Populate columns
  PopulateRow(row, item, tableHeader:GetColumns())
  if not item._fe then
    RequestRowData(row, item)
  end

  -- Alternating bg from the list position
  Utilities.AddAlternatingRowBg(row, pos)
end

-------------------------------------------------------------------------------
-- Context menu
-------------------------------------------------------------------------------
local function PutInChat(text)
  Search.PutInChat(text)
end

function Search.ShowContextMenu(anchor, item)
  MenuUtil.CreateContextMenu(anchor, function(_, rootDescription)
    local isFav = Search.IsFavorite and Search.IsFavorite(item.itemID)
    rootDescription:CreateButton(
      isFav and "Remove from Favorites" or "Add to Favorites",
      function()
        if isFav then
          Search.RemoveFavorite(item.itemID)
        else
          Search.AddFavorite(item.itemID)
        end
      end
    )

    rootDescription:CreateDivider()

    -- Each entry puts its text into chat (the open chat box, or a newly
    -- opened one); nothing here claims to copy to the clipboard
    rootDescription:CreateButton("Link item in chat", function()
      Search.LinkItemToChat(item.itemID)
    end)
    rootDescription:CreateButton("Send name to chat", function()
      PutInChat(item.name)
    end)
    rootDescription:CreateButton("Send item ID to chat", function()
      PutInChat(tostring(item.itemID))
    end)
    rootDescription:CreateButton("Send Wowhead link to chat", function()
      PutInChat("https://www.wowhead.com/item=" .. item.itemID)
    end)

    -- The item's ${i=ID} token, to copy from chat (where it also links when
    -- sent). Macros get tokens from the macro window's panel, whose clicks
    -- are the only safe way to change a macro.
    rootDescription:CreateButton("Send item token to chat", function()
      PutInChat(CobysLinkepedia.Linkify.FormatToken(item.itemID))
    end)

    if CobysLinkepedia.Variants.IsGear(item.itemID) then
      rootDescription:CreateDivider()
      rootDescription:CreateButton("Build variant", function()
        Search.OpenBuilder(item.itemID)
      end)
    end
  end)
end

-------------------------------------------------------------------------------
-- Initialize results (called by Window.lua OnLoad)
-------------------------------------------------------------------------------
function Search.InitResults(window)

  -- TableHeader: below the top row (search box, mode picker and filters),
  -- where every tab's content starts, left of the detail pane
  tableHeader = CreateFrame("Frame", nil, window)
  Mixin(tableHeader, CobysLinkepediaTableHeaderMixin)
  tableHeader:SetPoint("TOPLEFT", 8, -58)
  -- The right side follows the detail pane's width (Search.ContentEdge)
  tableHeader:SetPoint("TOPRIGHT", Search.ContentEdge, "TOPRIGHT", 0, -58)

  tableHeader:Init({
    columns = COLUMNS,
    persistenceKey = "results",
    utilities = CobysLinkepedia.Utilities,
    persistence = { savedVariable = "COBYS_LINKEPEDIA_WINDOW_STATE", path = "columnWidths" },
    onSort = function(key, dir)
      Search.ApplySort(key, dir)
    end,
    -- Columns above their minimum shrink to fit the table's width, so a
    -- narrow window or oversized saved widths never push a column out of view
    fitToWidth = true,
    onColumnResize = function()
      if not scrollBox then return end
      -- Reposition cells in visible rows; no object recreation needed
      local cols = tableHeader:GetColumns()
      scrollBox:ForEachFrame(function(row)
        if row._cells and row.itemData then
          RepositionCells(row, cols)
        end
      end)
    end,
  })

  tableHeader:SetSort("quality", SortDir.DESC)

  -- ScrollBox: anchored below header, left of detail pane
  scrollBox = CreateFrame("Frame", nil, window, "WowScrollBoxList")
  scrollBox:SetPoint("TOPLEFT", tableHeader, "BOTTOMLEFT", 0, 0)
  -- Row cells are laid out at the same fixed x offsets as the header columns,
  -- so they need the same clipping or a narrow window spills row text over the
  -- scrollbar and detail pane while the header above it stays clipped.
  scrollBox:SetClipsChildren(true)
  if Search._scanStatusFrame then
    scrollBox:SetPoint("BOTTOMRIGHT", Search._scanStatusFrame, "TOPRIGHT", 0, -4)
  else
    scrollBox:SetPoint("BOTTOMRIGHT", Search.ContentEdge, "BOTTOMRIGHT", 0, 104)
  end

  -- ScrollBar
  scrollBar = CreateFrame("EventFrame", nil, window, "MinimalScrollBar")
  scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 4, 0)
  scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 4, 0)

  -- DataProvider
  dataProvider = CreateDataProvider()

  -- ScrollView
  scrollView = CreateScrollBoxListLinearView()
  scrollView:SetElementExtent(ROW_HEIGHT)
  scrollView:SetElementInitializer("Button", function(row, data)
    InitRow(row, data)
  end)

  ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, scrollView)
  scrollBox:SetDataProvider(dataProvider)

  -- Empty-state label, same treatment as Coby's Currency Searcher: centred
  -- grey text over the list rather than an unexplained black void.
  emptyLabel = window:CreateFontString(nil, "OVERLAY", Utilities.Fonts.BODY)
  emptyLabel:SetPoint("CENTER", scrollBox, "CENTER", 0, 0)
  emptyLabel:SetWidth(320)
  emptyLabel:SetJustifyH("CENTER")
  emptyLabel:SetSpacing(3)
  local gray = Utilities.Colors.LABEL_GRAY
  emptyLabel:SetTextColor(gray[1], gray[2], gray[3])
  emptyLabel:Hide()

  window._scrollBox = scrollBox
  window._dataProvider = dataProvider

  -- Closing the window lets a search's list go (Search.ReleaseSearchList)
  window:HookScript("OnHide", function() Search.ReleaseSearchList() end)
  Search._tableHeader = tableHeader

  EnsureOverlay()
end

-- Picks the empty-state message from current state. Called after every refresh
-- and on every tab change, so the label tracks the list and can never linger
-- over another tab. An empty database and an empty search are different
-- problems and get different wording.
local function UpdateEmptyState()
  if not emptyLabel then return end

  -- While a build is in flight the overlay carries the message instead.
  if not resultsTabActive or builder or resultCount > 0 then
    emptyLabel:Hide()
    return
  end

  if Database.GetCount() == 0 then
    emptyLabel:SetText(
      "Your item database is empty.\n" ..
      "Press |cFF00CED1Build|r below, or use |cFF00CED1/lp build|r, to scan the item cache."
    )
  else
    emptyLabel:SetText("No items match your search.")
  end
  emptyLabel:Show()
end

-------------------------------------------------------------------------------
-- Progress overlay (builds, sorts and combat waits)
-------------------------------------------------------------------------------
-- Over the list: "Loading items... 43%" while the browse list builds,
-- "Searching items... 43%" for a text search, "Sorting items..." for a column
-- sort, and a paused or after-combat line while work waits out a fight. It
-- shows only when work outlasts its first slice.
local sortingOverlay = nil

-- Built once from InitResults rather than on first use, so a first open in
-- combat never reaches CreateFrame under lockdown.
EnsureOverlay = function()
  if sortingOverlay or not scrollBox then return end
  sortingOverlay = CreateFrame("Frame", nil, scrollBox)
  sortingOverlay:SetAllPoints()
  sortingOverlay:SetFrameStrata("DIALOG")

  sortingOverlay.bg = sortingOverlay:CreateTexture(nil, "BACKGROUND")
  sortingOverlay.bg:SetAllPoints()
  sortingOverlay.bg:SetColorTexture(0, 0, 0, 0.6)

  sortingOverlay.text = sortingOverlay:CreateFontString(nil, "OVERLAY", Utilities.Fonts.BODY)
  sortingOverlay.text:SetPoint("CENTER")
  sortingOverlay.text:SetTextColor(unpack(Utilities.Colors.LIGHT_GRAY))
  sortingOverlay:Hide()
end

ShowOverlay = function(text)
  EnsureOverlay()
  if not sortingOverlay then return end
  sortingOverlay.text:SetText(text or "Sorting items...")
  sortingOverlay:Show()
end

local function HideOverlay()
  if sortingOverlay then sortingOverlay:Hide() end
end

-------------------------------------------------------------------------------
-- Presenting a list
-------------------------------------------------------------------------------
-- Hands the current arrays to the ScrollBox. The provider is Blizzard's
-- virtual IndexRangeDataProvider (Blizzard_SharedXML): its elements are the
-- integers 1..n with no backing table, so this is O(1) against the n-element
-- insert the old path paid. The list view branches on IsVirtual() itself, and
-- on a provider reassignment it re-initialises every visible frame instead of
-- matching frames by element data ("we never try and recycle" in
-- ScrollBoxListView.lua, ValidateDataRange), so integer positions cannot
-- carry stale rows across a refresh.
local function Present()
  dataProvider = CreateIndexRangeDataProvider(resultCount)
  if scrollBox then
    scrollBox:SetDataProvider(dataProvider)
  end
  HideOverlay()
  UpdateEmptyState()
  if CobysLinkepediaSearchWindow and CobysLinkepediaSearchWindow.UpdateStatusBar then
    CobysLinkepediaSearchWindow:UpdateStatusBar()
  end
end

local function ShowEmptyList()
  resultCount = 0
  resultIDs, resultEntries = {}, nil
  presented.base, presented.key, presented.dir = nil, nil, nil
  wipe(browseCache)
  if scrollBox then
    scrollBox:SetDataProvider(CreateIndexRangeDataProvider(0))
  end
end

-- Stands down a build or a deferred sort in flight: anything scheduled earlier
-- compares its serial against buildSerial before touching state.
local function CancelBuild()
  buildSerial = buildSerial + 1
  builderFrame:SetScript("OnUpdate", nil)
  StopJob()
  builder = nil
  buildSig = nil
end

-- The search mode counts only for a text search: the browse list ignores it,
-- so switching modes keeps the cached browse list
local function ListSignature(filters, query)
  return tostring(filters.type) .. "|" .. tostring(filters.quality) .. "|" .. tostring(filters.expansion)
    .. "|" .. (query and (SearchMode() .. "|" .. query) or "")
end

-------------------------------------------------------------------------------
-- Browse list: column sorts over the cached base
-------------------------------------------------------------------------------
-- Reorders a cached base by one column without a comparison sort. The name
-- column copies the name order the build recorded (descending is that order
-- reversed). Every other column reads one key per entry from the stored
-- records, turns it into a small integer rank (the key itself for the
-- numeric columns, its place among the column's distinct values for the text
-- columns) and places the entries with a counting sort. That keeps ties in
-- base order (quality descending, then name) in both directions, and it runs
-- in slices: pause, when given, yields the job when the frame's budget is
-- spent. A key that is not a whole number, or a range too wide to count,
-- falls back to one table.sort.
local COUNT_RANGE_MAX = 4194304   -- 2^22 slots at most in the count array
local PAUSE_EVERY = 256           -- entries between budget checks: a text key costs a few microseconds

-- /lp perf sets this to a table while it times the sorts: the sort writes
-- the step it is in (and the key range) there, so the report can say where
-- the longest slice was spent
local sortProbe = nil

local function Phase(name)
  if sortProbe then sortProbe.phase = name end
end

local TEXT_COLUMNS = { type = true, subType = true, expansion = true }

local function SortedFromBase(key, ascending, base, pause)
  local n = base.n
  local ids, entries = base.baseIDs, base.baseEntries
  local NewArray = Database.NewArray
  -- Every array a sort fills is made at its final size up front: growing one
  -- entry by entry doubled it again and again, each time inside one slice
  local outIDs, outEntries = NewArray(n), NewArray(n)

  local function Tick(i)
    if pause and i % PAUSE_EVERY == 0 then pause() end
  end

  if key == "name" and base.nameOrder then
    Phase("copy")
    local order = base.nameOrder
    for i = 1, n do
      local src = ascending and order[i] or order[n + 1 - i]
      outIDs[i], outEntries[i] = ids[src], entries[src]
      Tick(i)
    end
    return outIDs, outEntries
  end

  -- One key per entry
  -- The handles are read without checking each record's id while the
  -- database is at the generation the base was built from (checked again
  -- after every few hundred entries, since a write can land between slices)
  local keys = ids
  if key ~= "itemID" then
    Phase("keys")
    keys = NewArray(n)
    local EntrySortKey, GetGeneration = Database.EntrySortKey, Database.GetGeneration
    local current = base.generation ~= nil and base.generation == GetGeneration()
    for i = 1, n do
      keys[i] = EntrySortKey(ids[i], entries[i], key, current)
      if i % PAUSE_EVERY == 0 then
        if pause then pause() end
        current = base.generation ~= nil and base.generation == GetGeneration()
      end
    end
  end

  -- Ranks: text keys by their place among the distinct values, numbers as they are
  local ranks = keys
  if TEXT_COLUMNS[key] then
    Phase("ranks")
    local distinct, rankOf = {}, {}
    for i = 1, n do
      local k = keys[i]
      if rankOf[k] == nil then
        rankOf[k] = true
        distinct[#distinct + 1] = k
      end
      Tick(i)
    end
    table.sort(distinct)
    for r, k in ipairs(distinct) do rankOf[k] = r end
    ranks = NewArray(n)
    for i = 1, n do
      ranks[i] = rankOf[keys[i]]
      Tick(i)
    end
  end

  Phase("range")
  local minRank, maxRank = math.huge, -math.huge
  local countable = true
  for i = 1, n do
    local r = ranks[i]
    if type(r) ~= "number" or r ~= math.floor(r) then
      countable = false
      break
    end
    if r < minRank then minRank = r end
    if r > maxRank then maxRank = r end
    Tick(i)
  end
  if n == 0 then return outIDs, outEntries end
  if countable and maxRank - minRank + 1 > COUNT_RANGE_MAX then countable = false end

  if sortProbe then sortProbe.range = countable and (maxRank - minRank + 1) or "not countable" end

  if not countable then
    Phase("comparison sort")
    local perm = {}
    for i = 1, n do perm[i] = i end
    table.sort(perm, function(a, b)
      local ka, kb = keys[a], keys[b]
      if ka == kb then return a < b end
      if ascending then return ka < kb end
      return ka > kb
    end)
    for i = 1, n do
      local src = perm[i]
      outIDs[i], outEntries[i] = ids[src], entries[src]
    end
    return outIDs, outEntries
  end

  -- Counting sort: slot = the rank's place in the chosen direction. The
  -- output arrays already have their n slots, so placing entries out of
  -- order writes into the array part (into an empty table those writes grew
  -- the hash part and rehashed it again and again: the long frames the first
  -- measurement of these sorts showed)
  if not table.create then
    for i = 1, n do outIDs[i], outEntries[i] = 0, 0 end
  end
  Phase("count")
  local range = maxRank - minRank + 1
  local count = NewArray(range)
  for r = 1, range do
    count[r] = 0
    Tick(r)
  end
  for i = 1, n do
    local slot = ascending and (ranks[i] - minRank + 1) or (maxRank - ranks[i] + 1)
    count[slot] = count[slot] + 1
    Tick(i)
  end
  Phase("place")
  local nextPos = 1
  for r = 1, range do
    local c = count[r]
    count[r] = nextPos
    nextPos = nextPos + c
    Tick(r)
  end
  for i = 1, n do
    local slot = ascending and (ranks[i] - minRank + 1) or (maxRank - ranks[i] + 1)
    local pos = count[slot]
    count[slot] = pos + 1
    outIDs[pos], outEntries[pos] = ids[i], entries[i]
    Tick(i)
  end
  return outIDs, outEntries
end

-- The Browse suite checks the column sorts against a comparison sort
Search.SortedFromBase = SortedFromBase

-- Puts a cached base on screen in the current sort. Quality descending is
-- the base order and costs nothing; anything else sorts as a job behind the
-- overlay: the first slice runs now, and a sort longer than one slice
-- carries on over the next frames.
local function PresentBase(base, owner)
  local ascending = (sortDir == SortDir.ASC)

  -- Everything that describes what is on screen changes together, here, so no
  -- row initialiser can see the arrays, the cache and the provider out of step.
  local function Apply(ids, entries)
    wipe(browseCache)
    resultIDs, resultEntries, resultCount = ids, entries, base.n
    presented.base, presented.key, presented.dir = base, sortColumn, sortDir
    Present()
  end

  if sortColumn == "quality" and not ascending then
    StopJob()   -- a sort still running for another column must not land on top
    Apply(base.baseIDs, base.baseEntries)
    return
  end

  -- The sort runs as a job across frames, behind the overlay. Until Apply
  -- runs nothing is presented: clearing this keeps RefreshResults from taking
  -- its nothing-to-do shortcut and pinning a stale list if the job is stood
  -- down first. A sort nobody clicked for (owner "system") waits out a fight.
  presented.base, presented.key, presented.dir = nil, nil, nil
  buildSerial = buildSerial + 1
  ShowOverlay("Sorting items...")
  local column = sortColumn
  RunJob(function(pause)
    return SortedFromBase(column, ascending, base, pause)
  end, function(result)
    if not base.valid then return end
    Apply(result[1], result[2])
  end, owner == "system", "Sorting after combat...", "sort")
end

-------------------------------------------------------------------------------
-- Building a list across frames
-------------------------------------------------------------------------------
-- The overlay while a build waits out a fight
local function CombatPauseText(slot)
  return slot == "text" and "Searching items... paused in combat" or "Loading items... paused in combat"
end

local function FinishBuild()
  local finishing, slot = builder, buildSlot
  -- The join runs as a job; the builder stays set until it is done, so a
  -- refresh for the same list keeps this build instead of starting over. It
  -- follows the build's combat policy, read before every slice, since a user
  -- refresh can take over a system build meanwhile.
  RunJob(function(pause)
    return finishing:Finish(true, pause)
  end, function(result)
    if builder ~= finishing then return end
    local base = bases[slot]
    builder = nil
    base.valid = true
    base.baseIDs, base.baseEntries, base.n, base.groupBounds, base.nameOrder =
      result[1], result[2], result[3], result[4], result[5]
    base.sig = buildSig
    buildSig = nil
    -- The generation from when the walk started, not now: a write that landed
    -- mid-walk may or may not be in the list, so the next refresh rebuilds.
    base.generation = buildGeneration
    PresentBase(base, buildOwner)
  end, function() return buildWaitsForCombat end, CombatPauseText(slot), "finish")
end

local function UpdateBuildProgress()
  local pct = math.floor(builder:GetProgress() * 100)
  local verb = buildSlot == "text" and "Searching items" or "Loading items"
  ShowOverlay(string.format("%s... %d%%", verb, math.min(pct, 100)))
end

-- slot "browse" walks every item, "text" only those matching currentQuery
local function StartBuild(slot, sig, owner)
  CancelBuild()
  local serial = buildSerial
  local base = bases[slot]
  base.valid = false
  base.baseIDs, base.baseEntries, base.n, base.groupBounds, base.nameOrder = nil, nil, 0, nil, nil
  buildSig, buildSlot = sig, slot
  buildGeneration = Database.GetGeneration()
  buildOwner = owner
  -- Combat: the browse walk halts by this addon's rules, and so does a list
  -- nobody asked for this moment (a system refresh). A search the player
  -- typed runs at the same per-frame budget. The walk's OnUpdate and the
  -- finish read this flag, so a user refresh that takes the build over
  -- (RefreshResults) lets it run.
  buildWaitsForCombat = slot == "browse" or owner == "system"
  ShowEmptyList()

  builder = Database.NewBrowseBuilder(currentFilters, slot == "text" and currentQuery or nil, SearchMode())

  -- The list is empty and building: retire a stale "no items match" label and
  -- a stale status bar now rather than when the build finishes.
  UpdateEmptyState()
  if CobysLinkepediaSearchWindow and CobysLinkepediaSearchWindow.UpdateStatusBar then
    CobysLinkepediaSearchWindow:UpdateStatusBar()
  end

  -- First slice right now, so a small database or a narrow search appears at
  -- once; a large one yields here and continues from OnUpdate, so the window
  -- paints and stays responsive.
  if not (buildWaitsForCombat and InCombat()) then
    workSlices = workSlices + 1
    if builder:Step(Budget()) then
      FinishBuild()
      return
    end
  end
  UpdateBuildProgress()

  builderFrame:SetScript("OnUpdate", function()
    if serial ~= buildSerial or not builder then
      builderFrame:SetScript("OnUpdate", nil)
      return
    end
    if buildWaitsForCombat and InCombat() then
      ShowOverlay(CombatPauseText(buildSlot))
      return
    end
    workSlices = workSlices + 1
    if builder:Step(Budget()) then
      builderFrame:SetScript("OnUpdate", nil)
      FinishBuild()
    else
      UpdateBuildProgress()
    end
  end)
end

-- Lets a search's list go when the window closes: the browse list is kept,
-- so reopening is instant, and reopening runs the search again
function Search.ReleaseSearchList()
  if buildSlot == "text" and builder then CancelBuild() end
  if presented.base == bases.text then ShowEmptyList() end
  bases.text = NewBase()
end

-- What the list holds right now, for the Browse suite: whether a build is
-- running, the rows presented and the rows the ScrollBox was handed, the
-- presented list's slot and sort, the sort asked for, and the work in
-- flight: its phase ("walk", "finish" or "sort", nil when idle), the walk's
-- progress (0 to 1), a count of walk steps and job slices run so far (it
-- stands still while work waits), who owns the build, whether it waits for
-- combat, and whether a system refresh waits for combat to end
function Search.GetListState()
  local provider = scrollBox and scrollBox:GetDataProvider()
  local slot
  if presented.base == bases.browse then
    slot = "browse"
  elseif presented.base and presented.base == bases.text then
    slot = "text"
  end
  local phase, owner, waits, generation
  if jobActive then
    phase = jobKind
  elseif builder then
    phase = "walk"
  end
  if builder then
    owner, waits, generation = buildOwner, buildWaitsForCombat, buildGeneration
  end
  return {
    building = builder ~= nil or jobActive,
    count = resultCount,
    shown = provider and provider:GetSize() or 0,
    slot = slot,
    presentedColumn = presented.key,
    presentedDir = presented.dir,
    sortColumn = sortColumn,
    sortDir = sortDir,
    phase = phase,
    progress = builder and not jobActive and builder:GetProgress() or nil,
    slices = workSlices,
    owner = owner,
    waitsForCombat = waits,
    pendingSystemRefresh = pendingSystemRefresh,
    generation = generation,
  }
end

-- The item IDs presented, in order (a copy), for the Browse suite
function Search.GetPresentedIDs()
  local out = {}
  for i = 1, resultCount do out[i] = resultIDs[i] end
  return out
end

-- For the Browse suite: overrides = { inCombat = true/false or a function,
-- budgetMs = n } stands in for the player's combat state and the slice
-- budget until it is called again with nil. Leaving a simulated fight runs
-- what waited for it to end, as PLAYER_REGEN_ENABLED does. Returns the
-- previous overrides.
function Search.SetTestOverrides(overrides)
  local previous = testOverrides
  local wasFighting = previous and previous.inCombat ~= nil and InCombat()
  testOverrides = overrides
  if wasFighting and not InCombat() then OnCombatEnded() end
  return previous
end

-------------------------------------------------------------------------------
-- Public entry points
-------------------------------------------------------------------------------
-- owner is "user" (default) or "system"; see the combat policy at the top.
-- The browse walk itself pauses in combat whoever started it.
function Search.RefreshResults(query, owner)
  currentQuery = query or ""
  owner = owner or "user"
  if owner == "system" and InCombat() then
    pendingSystemRefresh = true
    -- Nothing on screen (the update stood down a build or a sort): say why
    if not presented.base and not builder then
      if emptyLabel then emptyLabel:Hide() end
      ShowOverlay("Updating after combat...")
    end
    return
  end
  pendingSystemRefresh = false

  local slot = currentQuery ~= "" and "text" or "browse"
  local sig = ListSignature(currentFilters, slot == "text" and currentQuery or nil)

  -- A build for exactly this list, begun at the database's current
  -- generation, is already running (the window was closed and reopened
  -- mid-build, or a filter clear with nothing set): keep it and its progress
  -- rather than starting over. A build begun before a write is not kept; it
  -- may miss the write. The user taking over a system build lets it run in
  -- combat, as a build of their own would.
  if builder and buildSig == sig and buildGeneration == Database.GetGeneration() then
    if owner == "user" and buildOwner == "system" then
      buildOwner = "user"
      buildWaitsForCombat = buildSlot == "browse"
    end
    UpdateEmptyState()
    return
  end

  CancelBuild()

  -- Reuse the cached base while the database, the filters, the query and its
  -- search mode are unchanged (the signature and generation checks). A
  -- changed sort only reorders it (PresentBase); an unchanged one costs
  -- nothing, so reopening the window or clearing a search never walks again.
  -- The generation check catches writes that fire no event: the idle
  -- scanner's stores and a rebuild's wipe.
  local base = bases[slot]
  if base.valid and base.sig == sig and base.generation == Database.GetGeneration() then
    if presented.base == base and presented.key == sortColumn and presented.dir == sortDir then
      HideOverlay()   -- the ScrollBox already shows exactly this list
      return
    end
    PresentBase(base, owner)
    return
  end

  StartBuild(slot, sig, owner)
end

-- Header click: reorders the cached base (browse list or search) instead of
-- walking the database again
function Search.ApplySort(key, dir)
  sortColumn, sortDir = key, dir
  Search.RefreshResults(currentQuery, "user")
end

function Search.SetFilters(filters)
  currentFilters = filters or {}
  Search.RefreshResults(currentQuery, "user")
end

function Search.GetSearchMode()
  return SearchMode()
end

-- The search box's mode picker. A typed search runs again in the new mode.
function Search.SetSearchMode(mode)
  if not SEARCH_MODES[mode] or mode == SearchMode() then return end
  searchMode = mode
  if type(COBYS_LINKEPEDIA_WINDOW_STATE) == "table" then
    COBYS_LINKEPEDIA_WINDOW_STATE.searchMode = mode
  end
  if currentQuery ~= "" then Search.RefreshResults(currentQuery, "user") end
  if CobysLinkepediaSearchWindow and CobysLinkepediaSearchWindow.UpdateStatusBar then
    CobysLinkepediaSearchWindow:UpdateStatusBar()
  end
end

-------------------------------------------------------------------------------
-- Performance run: the test window's Run Perf button and /lp perf. Times the
-- heaviest work on the player's own database, one measurement per frame, and
-- hands back a plain-text report. A measurement runs its steps or slices back
-- to back, so each number is that step's own cost. Work the addon spreads
-- over frames is judged against a 16 ms frame; work that runs as one call is
-- listed apart. Refused in combat, during a scan and on an empty database;
-- stops when combat or a scan starts. Lines also go to the debug log (UI).
-------------------------------------------------------------------------------
local FRAME_RULE_MS = 16
local perfRunning = false

function Search.IsPerformanceRunning()
  return perfRunning
end

-- onStatus(text, fraction) reports progress; onDone(report) gets the report
-- text, also for a run that stopped early. Returns false, after onStatus
-- with the reason, when the run cannot start.
function Search.RunPerformance(onStatus, onDone)
  local refusal
  if perfRunning then
    refusal = "A performance run is already going."
  elseif UnitAffectingCombat("player") then
    refusal = "The performance run cannot start in combat."
  elseif CobysLinkepedia.Scanner.GetStatus().isActive then
    refusal = "The performance run cannot start while a scan is active."
  elseif Database.GetCount() == 0 then
    refusal = "The item database is empty; build it first (/lp build)."
  end
  if refusal then
    onStatus(refusal)
    return false
  end
  perfRunning = true

  local clock = debugprofilestop
  local spread, once, overRule = {}, {}, {}

  -- Work the addon spreads over frames: worst is its largest frame
  local function Spread(worst, label, fmt, ...)
    local line = label .. ": " .. string.format(fmt, ...)
    spread[#spread + 1] = line
    if worst > FRAME_RULE_MS then
      overRule[#overRule + 1] = string.format("%s: %.1f ms", label, worst)
    end
    Debug.Log("UI", "PERF %s", line)
  end

  -- Work that runs as one call
  local function Once(label, fmt, ...)
    local line = label .. ": " .. string.format(fmt, ...)
    once[#once + 1] = line
    Debug.Log("UI", "PERF %s", line)
  end

  -- A walk at the live budget: total, the largest step (a frame) and steps
  local function Walk(walker)
    local total, worst, steps = 0, 0, 0
    while not walker.done do
      local t = clock()
      walker:Step(BUILD_BUDGET_MS)
      local dt = clock() - t
      total, steps = total + dt, steps + 1
      if dt > worst then worst = dt end
    end
    return total, worst, steps
  end

  -- A job's slices, run back to back: total, the largest slice, slices, the
  -- job's result, and where the largest slice ran (the sort steps it began
  -- and ended in, and the change in Lua memory across it: a large drop means
  -- a garbage collection cycle finished inside it)
  local function TimeJob(fn)
    local co = coroutine.create(fn)
    local total, worst, slices, result = 0, 0, 0, nil
    local where = ""
    while coroutine.status(co) ~= "dead" do
      local phaseBefore = sortProbe and sortProbe.phase
      local memBefore = collectgarbage("count")
      sliceStart = clock()
      local ok, value = coroutine.resume(co, Pause)
      local dt = clock() - sliceStart
      local memAfter = collectgarbage("count")
      if not ok then error(value, 0) end
      result = value
      total, slices = total + dt, slices + 1
      if dt > worst then
        worst = dt
        if sortProbe then
          local phaseAfter = sortProbe.phase
          where = string.format(" (%s, memory %+.1f MB)",
            phaseBefore == phaseAfter and tostring(phaseAfter) or (tostring(phaseBefore) .. " to " .. tostring(phaseAfter)),
            (memAfter - memBefore) / 1024)
        end
      end
    end
    return total, worst, slices, result, where
  end

  local state = {}
  local steps = {}
  local function Add(label, fn)
    steps[#steps + 1] = { label = label, fn = fn }
  end

  Add("browse walk", function()
    state.generation = Database.GetGeneration()
    local builder = Database.NewBrowseBuilder(nil)
    local total, worst, count = Walk(builder)
    state.builder, state.bucketCount = builder, builder.total
    Spread(worst, "Browse walk", "%d buckets, %.1f ms over %d steps, largest step %.1f ms", builder.total, total, count, worst)
  end)

  Add("browse finish", function()
    local total, worst, slices, finished = TimeJob(function(pause) return { state.builder:Finish(true, pause) } end)
    state.builder = nil
    state.base = { baseIDs = finished[1], baseEntries = finished[2], n = finished[3], groupBounds = finished[4],
      nameOrder = finished[5], generation = state.generation }
    Spread(worst, "Browse finish", "%.1f ms over %d slices, largest %.1f ms, %d entries", total, slices, worst, finished[3])
  end)

  -- Each column sort twice: a long slice that comes back in the same step is
  -- the sort's own work; one that moves or goes away is the collector
  for _, col in ipairs(COLUMNS) do
    if col.sortable then
      for run = 1, 2 do
        Add(("sort by %s, run %d"):format(col.key, run), function()
          sortProbe = { phase = "start" }
          local ok, total, worst, slices, _, where = pcall(TimeJob, function(pause)
            return SortedFromBase(col.key, true, state.base, pause)
          end)
          local range = sortProbe.range
          sortProbe = nil
          if not ok then error(total, 0) end
          Spread(worst, ("Column sort %s, run %d"):format(col.key, run), "%.1f ms over %d slices, largest %.1f ms%s, key range %s",
            total, slices, worst, where, tostring(range or "none"))
        end)
      end
    end
  end

  -- The search window's text search: a query build and its finish, in
  -- each search mode
  for _, case in ipairs({ { "s", "exact" }, { "of the", "exact" }, { "of the", "all" }, { "of the", "any" } }) do
    local query, mode = case[1], case[2]
    Add(("window search \"%s\" (%s)"):format(query, mode), function()
      local builder = Database.NewBrowseBuilder(nil, query, mode)
      local walkTotal, walkWorst, walkSteps = Walk(builder)
      local finishTotal, finishWorst, finishSlices, finished = TimeJob(function(pause) return { builder:Finish(true, pause) } end)
      Spread(math.max(walkWorst, finishWorst), ("Window search \"%s\" (%s)"):format(query, mode),
        "walk %.1f ms over %d steps (largest %.1f ms), finish %.1f ms over %d slices (largest %.1f ms), %d results",
        walkTotal, walkSteps, walkWorst, finishTotal, finishSlices, finishWorst, finished[3])
    end)
  end

  -- Autocomplete, quick search, the macro panel and the Variant Builder
  -- picker: capped searches stepped over frames
  for _, query in ipairs({ "s", "sw", "of the", "zzqx" }) do
    Add(("typing search \"%s\""):format(query), function()
      local total, worst, count = Walk(Database.NewSearch(query, 10))
      Spread(worst, ("Typing search \"%s\" (10 results)"):format(query), "%.1f ms over %d steps, largest step %.1f ms", total, count, worst)
    end)
  end

  -- Chat tokens and /link: the same capped searches in one call
  for _, query in ipairs({ "s", "sw", "of the", "zzqx" }) do
    Add(("search \"%s\" in one call"):format(query), function()
      local t = clock()
      Database.Search(query, 10)
      Once(("Search \"%s\", 10 results (chat tokens, /link)"):format(query), "%.1f ms", clock() - t)
    end)
  end
  for _, query in ipairs({ "of the", "s", "zzqx" }) do
    Add(("uncapped search \"%s\""):format(query), function()
      local t = clock()
      local results = Database.Search(query, 0)
      Once(("Search \"%s\", every result (API only)"):format(query), "%.1f ms, %d results", clock() - t, #results)
    end)
  end

  -- The send-time rewrite of a typed message, without sending anything
  Add("chat send", function()
    local Linkify = CobysLinkepedia.Linkify
    local base = state.base
    local item = base and base.n > 0 and Database.MaterializeEntry(base.baseIDs[1], base.baseEntries[1])
    local name = item and item.name ~= "" and item.name or "Hearthstone"
    local filler = string.rep("plain words ", 17)
    local REPEAT = 50
    local function Time(label, fn, text)
      local total, worst = 0, 0
      for _ = 1, REPEAT do
        local t = clock()
        fn(text)
        local dt = clock() - t
        total = total + dt
        if dt > worst then worst = dt end
      end
      Once(label, "%.3f ms average, %.3f ms worst of %d", total / REPEAT, worst, REPEAT)
    end
    Time(("Chat send, %d characters, no brackets"):format(#filler), Linkify.TransformMessage, filler)
    Time("Chat send, the same with one [Item]", Linkify.TransformMessage, filler .. "[" .. name .. "]")
    Time("Chat send, the same with one ${n=Item} token", Linkify.ExpandTokens, filler .. "${n=" .. name .. "}")
  end)

  -- The Stats tab: a recount of every item record (what it pays when the
  -- items changed), then a refresh that reuses those counts because the
  -- item generation has not moved
  Add("stats", function()
    local t = clock()
    local stats = Database.ComputeItemStats()
    Once("Item statistics recount (Stats tab)", "%.1f ms, %d items", clock() - t, stats.totalItems)
    Search.ComputeStats()
    t = clock()
    Search.ComputeStats()
    Once("Stats refresh with cached counts", "%.3f ms", clock() - t)
  end)

  -- The scanner, through its probes (Scanner.Perf): nothing here starts a
  -- scan. The idle tick is one real tick a second early: it asks the server
  -- for up to idleScanRate IDs and may store items or mark IDs dead, as the
  -- ticker would have. The rest leaves what is saved alone. The dead-ID list
  -- goes first, so the known-ID set after it does not pay the list's load.
  local Scanner = CobysLinkepedia.Scanner
  local WALK_BUDGET_MS = Scanner.Perf.WALK_BUDGET_MS

  Add("dead-ID list", function()
    local m = Scanner.Perf.MeasureDeadList()
    Once(("Dead-ID list save, %d IDs (at logout and a scan's end)"):format(m.count),
      "%.1f ms, %.1f KB saved", m.encodeMs, m.bytes / 1024)
    Once(("Dead-ID list load, %d IDs (its first use after login)"):format(m.count), "%.1f ms", m.decodeMs)
  end)

  -- A discover probe's walk, its steps back to back: total, largest, steps
  local function ProbeWalk(probe, budgetMs)
    local total, worst, count = 0, 0, 0
    while not probe.done do
      local t = clock()
      probe:Step(budgetMs)
      local dt = clock() - t
      total, count = total + dt, count + 1
      if dt > worst then worst = dt end
    end
    return total, worst, count
  end

  Add("expand walk", function()
    local probe = Scanner.Perf.NewDiscoverProbe()
    Once(("Known-ID set, %d stored and %d dead (the start of an Expand)"):format(probe.stored, probe.dead),
      "%.1f ms", probe.buildMs)
    local total, worst, count = ProbeWalk(probe, WALK_BUDGET_MS)
    Spread(worst, ("Expand walk, %d ms budget"):format(WALK_BUDGET_MS),
      "%.1f ms over %d steps to ID %d, largest step %.1f ms, %d IDs to ask the server about",
      total, count, probe.pos, worst, probe.listed)
  end)

  Add("build walk", function()
    local probe = Scanner.Perf.NewDiscoverProbe(true)
    local total, worst, count = ProbeWalk(probe, WALK_BUDGET_MS)
    Spread(worst, ("Build walk, %d ms budget"):format(WALK_BUDGET_MS),
      "%.1f ms over %d steps to ID %d, largest step %.1f ms, %d IDs the client lists",
      total, count, probe.pos, worst, probe.listed)
  end)

  Add("idle tick", function()
    local ms, queued, rate = Scanner.Perf.IdleTick()
    if ms then
      Once(("Idle tick, up to %d item IDs from a queue of %d (every second)"):format(rate, queued), "%.3f ms", ms)
    else
      Once("Idle tick", "not measured: the idle scan is off")
    end
  end)

  Add("status window refresh", function()
    local window = Search.GetStatusWindow()
    local REPEAT = 20
    local total, worst = 0, 0
    for _ = 1, REPEAT do
      local t = clock()
      window:Refresh()
      local dt = clock() - t
      total = total + dt
      if dt > worst then worst = dt end
    end
    Once("Status window refresh (twice a second while it shows)", "%.3f ms average, %.3f ms worst of %d",
      total / REPEAT, worst, REPEAT)
  end)

  -- A flush on a scratch database, then the index rebuild the swap back
  -- costs (the same Load a login or /reload runs)
  Add("flush and index rebuild", function()
    state.changed = Database.GetGeneration() ~= state.generation
    state.base = nil
    local previous = Database.ReplaceStorage({})
    local ok, err = pcall(function()
      Database.EnsureStorage()
      for i = 1, 1000 do
        Database.Store(95000000 + i, string.format("Perf Probe %04d", i), 1, 15, 0, 1, 0, 0)
      end
      local t = clock()
      Database.Flush()
      Once("Flush of 1,000 pending records", "%.2f ms", clock() - t)
    end)
    local t = clock()
    Database.ReplaceStorage(previous)
    Once("Index rebuild of the whole database (what login and /reload pay)", "%.1f ms", clock() - t)
    if not ok then error(err, 0) end
  end)

  local startedAt = clock()
  local memoryStart = collectgarbage("count") / 1024
  local itemCount = Database.GetCount()
  local idleQueued = CobysLinkepedia.Scanner.GetIdleStatus().queued
  local deadCount = CobysLinkepedia.Scanner.GetDeadCount()
  local index, completed, stopped = 0, 0, nil

  local function BuildReport()
    local lines = {}
    local function add(text) lines[#lines + 1] = text or "" end
    add("=== COBY'S LINKEPEDIA PERFORMANCE REPORT ===")
    add("")
    add("--- ENVIRONMENT ---")
    add("Addon Version: " .. (C_AddOns.GetAddOnMetadata("CobysLinkepedia", "Version") or "?"))
    add("Shared Library: " .. CobySuite_CobysLinkepedia.LibraryVersionText())
    local version, build = GetBuildInfo()
    add(("WoW Build: %s (build %s)"):format(version or "?", build or "?"))
    add("Date: " .. date("%Y-%m-%d %H:%M:%S"))
    add(("Items: %d in %s buckets"):format(itemCount, tostring(state.bucketCount or "?")))
    add(("Item IDs waiting on the server: %d; not on the server: %d"):format(idleQueued, deadCount))
    add(("Lua memory at start: %.1f MB"):format(memoryStart))
    add(("Slice budget %d ms; a frame over %d ms breaks the rule"):format(BUILD_BUDGET_MS, FRAME_RULE_MS))
    add("")
    add("--- SUMMARY ---")
    if stopped then add("Stopped early: " .. stopped) end
    add(("Measurements: %d of %d in %.1f s"):format(completed, #steps, (clock() - startedAt) / 1000))
    if #overRule == 0 then
      add("Frames over 16 ms in work spread over frames: none")
    else
      add("Frames over 16 ms in work spread over frames: " .. #overRule)
      for _, line in ipairs(overRule) do add("  " .. line) end
    end
    if state.changed then
      add("Note: the database changed during the run, so sorts after the change read each item's id too")
    end
    add("")
    add("--- SPREAD OVER FRAMES ---")
    for _, line in ipairs(spread) do add(line) end
    add("")
    add("--- ONE CALL ---")
    for _, line in ipairs(once) do add(line) end
    add("")
    add("=== END REPORT ===")
    return table.concat(lines, "\n")
  end

  local function Finish()
    perfRunning = false
    sortProbe = nil
    local report = BuildReport()
    state = nil
    Debug.Log("UI", "PERF run %s", stopped and ("stopped: " .. stopped) or "complete")
    onStatus(stopped and ("Performance run stopped: " .. stopped) or
      ("Performance run done in %.1f s. The report is open and selected: press Ctrl+C."):format((clock() - startedAt) / 1000), 1)
    onDone(report)
  end

  -- The next step's label goes up a frame before it runs, so it is on screen
  local function Announce()
    local step = steps[index + 1]
    if step then
      onStatus(("Measuring %d of %d: %s"):format(index + 1, #steps, step.label), index / #steps)
    end
  end

  local function Next()
    if UnitAffectingCombat("player") then
      stopped = "combat started"
      return Finish()
    end
    if CobysLinkepedia.Scanner.GetStatus().isActive then
      stopped = "a scan started"
      return Finish()
    end
    index = index + 1
    local step = steps[index]
    if not step then return Finish() end
    local ok, err = pcall(step.fn)
    if not ok then
      stopped = step.label .. " failed: " .. tostring(err)
      return Finish()
    end
    completed = completed + 1
    Announce()
    C_Timer.After(0, Next)
  end

  Announce()
  C_Timer.After(0, Next)
  return true
end

-------------------------------------------------------------------------------
-- Select an item (show in detail pane; the pane is always visible)
-------------------------------------------------------------------------------
function Search.SelectItem(item)
  if Search.ShowDetail then
    Search.ShowDetail(item)
  end
end

-------------------------------------------------------------------------------
-- Tab switching
-------------------------------------------------------------------------------
function Search.SetActiveTab(tabName)
  local isResults = tabName == "results"
  resultsTabActive = isResults
  UpdateEmptyState()
  if scrollBox then
    scrollBox:SetShown(isResults)
  end
  -- The bar is the window's child, not the list's, so it needs its own SetShown here
  if scrollBar then
    scrollBar:SetShown(isResults)
  end
  if tableHeader then
    tableHeader:SetShown(isResults)
  end
  -- The detail pane serves every item list and the Variant Builder; the
  -- stats tab uses the full width
  if Search._detailFrame then
    Search._detailFrame:SetShown(tabName ~= "stats")
  end
  if Search._variantBuilderFrame then
    Search._variantBuilderFrame:SetShown(tabName == "variants")
  end
  if Search._filterBar then
    Search._filterBar:SetShown(isResults)
  end
  if Search._favoritesFrame then
    Search._favoritesFrame:SetShown(tabName == "favorites")
  end
  if Search._historyFrame then
    Search._historyFrame:SetShown(tabName == "history")
  end
  if Search._statsFrame then
    Search._statsFrame:SetShown(tabName == "stats")
  end
  if Search._scanStatusFrame then
    Search._scanStatusFrame:SetShown(isResults)
  end
end

-------------------------------------------------------------------------------
-- Auto-refresh on database changes
-------------------------------------------------------------------------------
local dbUpdateListener = { ReceiveEvent = function(_, eventName)
  if eventName ~= CobysLinkepedia.Events.DatabaseUpdated then return end
  -- A build or sort in flight works from the database as it was (the walk
  -- holds the item table it began on, and its finish would fill a base
  -- replaced below), so it is stood down first, before the combat check in
  -- RefreshResults can leave it running: it must never present the old
  -- database as the new one. Then the cached lists go. Rebuild now only if
  -- the window is open (in combat: when the fight ends); otherwise drop them
  -- (they are the largest things this file holds) and let the next open
  -- build fresh ones.
  CancelBuild()
  bases.browse, bases.text = NewBase(), NewBase()
  if CobysLinkepediaSearchWindow and CobysLinkepediaSearchWindow:IsShown() then
    Search.RefreshResults(currentQuery, "system")
  else
    ShowEmptyList()
  end
end }
CobysLinkepedia.EventBus:Register(dbUpdateListener, { CobysLinkepedia.Events.DatabaseUpdated })

Debug.Log("INIT", "Search results loaded")
