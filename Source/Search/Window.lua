-- Search Window: main hub for browsing, searching, and exploring items

local Search = CobysLinkepedia.Search
local Utilities = CobysLinkepedia.Utilities
local Debug = CobysLinkepedia.Debug

-- The results table is 653px of columns plus the spacer's 25px minimum, and
-- the detail pane side costs another 324px at the pane's default width (the
-- pane plus its margins), so the 1005 minimum fits them unshrunk. The old 800
-- default was 86px too narrow for its own column defaults, which is why ID
-- and Req drew over the scrollbar.
local DETAIL_LEFT_MARGIN = 8     -- the window's edge to the content
local DETAIL_GAP = 20            -- the content's right edge to the pane
local DETAIL_RIGHT_MARGIN = 8    -- the pane to the window's edge
local DEFAULT_WIDTH = 1040
local DEFAULT_HEIGHT = 500
local MIN_WIDTH = 1005
-- The Variant Builder's options, preview and actions need about 350px of tab
local MIN_HEIGHT = 440

-------------------------------------------------------------------------------
-- Mixin
-- Position and size persist under COBYS_LINKEPEDIA_WINDOW_STATE.searchWindow through
-- the CobySuite.UI.CreateWindow shell (SaveState / RestoreState).
-------------------------------------------------------------------------------
CobysLinkepediaSearchWindowMixin = {}

function CobysLinkepediaSearchWindowMixin:OnLoad()
  self:RestoreState()
  -- A size saved under an older, smaller minimum
  if self:GetWidth() < MIN_WIDTH then self:SetWidth(MIN_WIDTH) end
  if self:GetHeight() < MIN_HEIGHT then self:SetHeight(MIN_HEIGHT) end

  self.activeTab = "results"

  self:BuildSearchBox()
  self:BuildTabs()
  self:BuildStatusBar()
  self:BuildContentEdge()

  -- The "?" beside the close button opens the feature guide (Guide/Main.lua)
  self.HelpButton = CobySuite_CobysLinkepedia.UI.CreateHelpButton(self, {
    name = "CobysLinkepediaSearchWindowHelpButton",
    tooltip = "What Coby's Linkepedia can do",
    onClick = function() CobysLinkepedia.Guide.Toggle() end,
  })

  -- Initialize sub-components (they anchor to this frame). BuildContentEdge
  -- above made the right column they anchor to; DetailPane reads its width.
  -- ScanStatus before Results (the ScrollBox anchors to it); FilterBar after
  -- the search box (it re-anchors the box).
  if Search.InitDetailPane then Search.InitDetailPane(self) end
  if Search.InitScanStatus then Search.InitScanStatus(self) end
  if Search.InitResults then Search.InitResults(self) end
  if Search.InitFilterBar then Search.InitFilterBar(self) end
  if Search.InitFavorites then Search.InitFavorites(self) end
end

function CobysLinkepediaSearchWindowMixin:OnSizeChanged()
  self:SaveState()
  -- A narrower window may no longer fit the pane's chosen width
  if self.ContentEdge then self:ApplyDetailWidth(self.detailWidthChosen or self.detailWidth) end
end

-------------------------------------------------------------------------------
-- The detail pane's width
--
-- Every tab's content left of the detail pane anchors its right side to
-- ContentEdge, an invisible frame the full height of the window at the
-- content's right edge (Search.ContentEdge). The pane's width moves the edge,
-- so the table, scan footer, Favorites, History and the Variant Builder all
-- follow. The top row (search box, mode picker and filters) spans the whole
-- window and does not. The player drags the grip on the pane's left edge
-- (DetailPane.lua); the width is saved in
-- COBYS_LINKEPEDIA_WINDOW_STATE.detailPaneWidth and clamped to the window.
-------------------------------------------------------------------------------
local function SavedDetailWidth()
  local state = COBYS_LINKEPEDIA_WINDOW_STATE
  local width = type(state) == "table" and tonumber(state.detailPaneWidth)
  if not Utilities.IsFiniteNumber(width) then return Search.DETAIL_PANE_WIDTH end
  return width
end

function CobysLinkepediaSearchWindowMixin:BuildContentEdge()
  local edge = CreateFrame("Frame", nil, self)
  edge:SetWidth(1)
  self.ContentEdge = edge
  Search.ContentEdge = edge
  self:ApplyDetailWidth(SavedDetailWidth(), true)
end

function CobysLinkepediaSearchWindowMixin:ClampDetailWidth(width)
  local room = self:GetWidth() - DETAIL_LEFT_MARGIN - DETAIL_GAP - DETAIL_RIGHT_MARGIN - Search.CONTENT_MIN_WIDTH
  return math.floor(math.max(Search.DETAIL_PANE_MIN_WIDTH, math.min(room, width)) + 0.5)
end

-- Sets the pane's width (clamped) and moves the content edge with it.
-- chosen keeps the requested width, so a window grown back gets it again.
function CobysLinkepediaSearchWindowMixin:ApplyDetailWidth(width, chosen)
  if chosen then self.detailWidthChosen = width end
  width = self:ClampDetailWidth(width)
  self.detailWidth = width
  local column = width + DETAIL_RIGHT_MARGIN + DETAIL_GAP
  self.ContentEdge:ClearAllPoints()
  self.ContentEdge:SetPoint("TOPRIGHT", self, "TOPRIGHT", -column, 0)
  self.ContentEdge:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -column, 0)
  if Search._detailFrame then Search._detailFrame:SetWidth(width) end
end

function CobysLinkepediaSearchWindowMixin:SaveDetailWidth()
  if type(COBYS_LINKEPEDIA_WINDOW_STATE) ~= "table" then return end
  COBYS_LINKEPEDIA_WINDOW_STATE.detailPaneWidth = self.detailWidthChosen or self.detailWidth
end

-------------------------------------------------------------------------------
-- Search box
-------------------------------------------------------------------------------
function CobysLinkepediaSearchWindowMixin:BuildSearchBox()
  -- Blizzard's SearchBoxTemplate through the shared factory, the same box Coby's
  -- Currency Searcher uses: magnifier, placeholder, built-in clear button,
  -- debounce, and Escape-clears all come with it. The
  -- hand-rolled InputBoxTemplate this replaces needed a separate "Search:"
  -- label, its own clear button and its own debounce, and looked nothing like
  -- the other addons.
  local searchBox = CobySuite_CobysLinkepedia.UI.CreateSearchBox(self, {
    maxLetters  = 100,
    debounce    = 0.5,
    placeholder = "Search items",
    onSearch    = function(text) self:DoSearch(text) end,
    -- Typing a search from another tab goes to the results
    onTextChanged = function(_, userInput)
      if userInput and self.activeTab ~= "results" then
        self:SetTab("results")
      end
    end,
  })

  -- The left of the top row. Until InitFilterBar runs, its right edge is the
  -- window's (the -12 below); FilterBar.lua then ends it at the mode picker,
  -- so the box takes the room the row has left and grows with the window.
  searchBox:ClearAllPoints()
  searchBox:SetPoint("TOPLEFT", 12, -32)
  searchBox:SetPoint("RIGHT", -12, 0)
  searchBox:SetHeight(Utilities.EditBoxHeight.SEARCH)

  self.SearchBox = searchBox
end

function CobysLinkepediaSearchWindowMixin:DoSearch(query)
  self.currentQuery = query
  if Search.RefreshResults then
    Search.RefreshResults(query, "user")
  end
end

-------------------------------------------------------------------------------
-- Shared by the item lists on every tab
-------------------------------------------------------------------------------
-- The detail pane: its default and smallest width, and the least room the
-- content left of it keeps (the Variant Builder's track fields need about
-- 520). Between the content and the pane: the list's scrollbar gap (20) and
-- the grip; right of the pane, an 8px margin.
Search.DETAIL_PANE_WIDTH = 288
Search.DETAIL_PANE_MIN_WIDTH = 240
Search.CONTENT_MIN_WIDTH = 560

-- Item tooltips on every list: Shift shows the comparison when the option is on
Search.ItemTooltipOptions = {
  compareOnShift = function()
    return CobysLinkepedia.Config.Get(CobysLinkepedia.Config.Options.SHIFT_HOVER_COMPARISON)
  end,
  cleanShopping = true,
}

-- One set of row actions for Results, Favorites and History: click shows the
-- item in the detail pane, Ctrl-click opens the dressing room, Shift-click
-- links it in chat, right-click opens the item menu
function Search.HandleItemClick(item, button, anchor)
  if not item then return end
  if button == "LeftButton" then
    if IsControlKeyDown() then
      DressUpItemLink("item:" .. item.itemID)
    elseif IsShiftKeyDown() then
      Search.LinkItemToChat(item.itemID)
    elseif Search.SelectItem then
      Search.SelectItem(item)
    end
  elseif button == "RightButton" and Search.ShowContextMenu then
    Search.ShowContextMenu(anchor, item)
  end
end

-------------------------------------------------------------------------------
-- PutInChat: text into the open chat box, or a newly opened one. Never into
-- the macro editor, which Blizzard's InsertLink types into while it has focus:
-- text an addon types into a macro taints the macro window's saves (see
-- MacroTokens/Editor.lua), so there chat opens instead.
-------------------------------------------------------------------------------
function Search.PutInChat(text)
  CobySuite_CobysLinkepedia.Chat.PutInChat(text)
end

-------------------------------------------------------------------------------
-- LinkItemToChat: the explorer's Shift-click on any tab. Puts the item's link
-- into chat (Search.PutInChat); an item the client has not loaded yet is
-- requested first.
-------------------------------------------------------------------------------
function Search.LinkItemToChat(itemID)
  Utilities.LoadItemThen(itemID, {
    onReady = function(link)
      Search.PutInChat(link)
      Search.AddToHistory(itemID)
    end,
    onFail = function(reason)
      Utilities.Message.Warn("The item data did not load, so no link was made. Try again in a moment.")
      Debug.Warn("UI", "No link for item %s (%s)", tostring(itemID), tostring(reason))
    end,
  })
end

-------------------------------------------------------------------------------
-- Tabs: Results | Variants | Favorites | History | Stats
-------------------------------------------------------------------------------
local TAB_NAMES = { "Results", "Variants", "Favorites", "History", "Stats" }
local TAB_INDEX = {}
for i, name in ipairs(TAB_NAMES) do TAB_INDEX[name:lower()] = i end

function CobysLinkepediaSearchWindowMixin:BuildTabs()
  local tabNames = TAB_NAMES
  local tabTooltips = {
    "Browse and search items in your database",
    "Build crafted and upgrade-track versions of gear, and save them",
    "Items and variants you've marked as favorites",
    "Recently linked items",
    "Database statistics and scan history",
  }

  for i, name in ipairs(tabNames) do
    local tab = CreateFrame("Button", "CobysLinkepediaSearchWindowTab" .. i, self, "PanelTabButtonTemplate")
    if i == 1 then
      -- The top of each tab sits inside the bottom border strip
      tab:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 15, 3)
    else
      tab:SetPoint("LEFT", _G["CobysLinkepediaSearchWindowTab" .. (i - 1)], "RIGHT", 0, 0)
    end
    tab:SetText(name)
    tab:SetID(i)
    local tabKey = name:lower()
    tab:SetScript("OnClick", function()
      self:SetTab(tabKey)
    end)
    Utilities.AddTooltip(tab, tabTooltips[i])
    PanelTemplates_TabResize(tab, 0)
  end

  self.numTabs = #tabNames
  PanelTemplates_SetTab(self, 1)

  -- Tabs are child frames, so they draw over the window's own border
  -- textures. Moving the bottom border (the left corner and the edge; the
  -- right corner stays with the resize grip) onto an overlay above the tabs
  -- lets the border cover their tops, as on Blizzard's windows. The overlay
  -- holds nothing else and takes no mouse input.
  local tabLevel = 0
  for i = 1, self.numTabs do
    tabLevel = math.max(tabLevel, _G["CobysLinkepediaSearchWindowTab" .. i]:GetFrameLevel())
  end
  local overlay = CreateFrame("Frame", nil, self)
  overlay:SetAllPoints()
  overlay:SetFrameLevel(tabLevel + 1)
  if self.BotLeftCorner then self.BotLeftCorner:SetParent(overlay) end
  if self.BottomBorder then self.BottomBorder:SetParent(overlay) end
end

function CobysLinkepediaSearchWindowMixin:SetTab(tabName)
  self.activeTab = tabName
  local tabIndex = TAB_INDEX[tabName] or 1
  PanelTemplates_SetTab(self, tabIndex)

  -- Show/hide content areas
  if Search.SetActiveTab then
    Search.SetActiveTab(tabName)
  end
end

-------------------------------------------------------------------------------
-- Status bar (bottom)
-------------------------------------------------------------------------------
function CobysLinkepediaSearchWindowMixin:BuildStatusBar()
  self.StatusText = self:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  self.StatusText:SetPoint("BOTTOMLEFT", 12, 14)
  self.StatusText:SetJustifyH("LEFT")
  self:UpdateStatusBar()

  -- Debug button (bottom-right)
  CobySuite_CobysLinkepedia.UI.CreateButton(self, {
    size = { 60, 18 }, text = "Debug", fontSize = 11,
    point = { "BOTTOMRIGHT", -8, 10 },
    tooltip = "Toggle the debug log window",
    onClick = function()
      if CobysLinkepedia.DebugWindow then
        CobysLinkepedia.DebugWindow:Toggle()
      end
    end,
  })
end

function CobysLinkepediaSearchWindowMixin:UpdateStatusBar()
  local count = BreakUpLargeNumbers(CobysLinkepedia.Database.GetCount and CobysLinkepedia.Database.GetCount() or 0)
  local query = self.currentQuery or ""
  if query ~= "" then
    local mode = Search.GetSearchMode and Search.GetSearchMode() or "exact"
    local how = mode == "all" and " (all words)" or mode == "any" and " (any word)" or ""
    self.StatusText:SetText("Database: " .. count .. " items | Search" .. how .. ": \"" .. query .. "\"")
  else
    self.StatusText:SetText("Database: " .. count .. " items")
  end
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------
function Search.ToggleWindow()
  local window = CobysLinkepediaSearchWindow
  if window then
    local wasShown = window:IsShown()
    window:SetShown(not wasShown)
    if window:IsShown() then
      if window.SearchBox then
        window.SearchBox:SetFocus()
      end
      window:DoSearch(window.currentQuery or "")
    end
  end
end

-------------------------------------------------------------------------------
-- Frame Creation
-------------------------------------------------------------------------------
do
  -- Shell: drag, resize grip, saved position/size (COBYS_LINKEPEDIA_WINDOW_STATE is
  -- created on ADDON_LOADED, hence the svTable function). No solid
  -- background: the window has always shown the template art alone.
  local f = CobySuite_CobysLinkepedia.UI.CreateWindow({
    name = "CobysLinkepediaSearchWindow",
    mixin = CobysLinkepediaSearchWindowMixin,
    title = Utilities.WrapColor(Utilities.Colors.TEXT_TEAL, "Coby's Linkepedia"),
    icon = CobysLinkepedia.ICON,
    width = DEFAULT_WIDTH,
    height = DEFAULT_HEIGHT,
    resizable = { minWidth = MIN_WIDTH, minHeight = MIN_HEIGHT, maxWidth = 1600, maxHeight = 1000 },
    solidBackground = false,
    -- The search box's own Escape clears it first while it has focus
    escapeCloses = true,
    persist = {
      svTable = function() return COBYS_LINKEPEDIA_WINDOW_STATE end,
      key = "searchWindow",
    },
  })

  f:SetScript("OnSizeChanged", function(self) self:OnSizeChanged() end)

  -- Defer OnLoad so sub-component files (Results.lua, FilterBar.lua, etc.)
  -- have time to load and define their Init functions
  C_Timer.After(0, function() f:OnLoad() end)
end

Debug.Log("INIT", "Search window loaded")
