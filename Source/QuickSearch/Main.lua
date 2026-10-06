-- Quick Search: a floating search bar (Spotlight style) that puts an item
-- link into chat. Opens from /lp qs or its key binding; draggable, position
-- saved. A window like the others (MEDIUM, toplevel), raised when it opens.
--
-- Picking a result puts its link into the chat box that was open when the
-- bar opened, or, with none open, opens chat with the link typed in. An item
-- the client has not loaded yet is requested first; if it never loads, chat
-- says so rather than the bar closing with nothing to show.

local QuickSearch = CobysLinkepedia.QuickSearch
local Database = CobysLinkepedia.Database
local Utilities = CobysLinkepedia.Utilities
local Search = CobysLinkepedia.Search
local Debug = CobysLinkepedia.Debug

local MAX_RESULTS = 10
local ROW_HEIGHT = 22
local BAR_WIDTH = 400
local ICON_SIZE = 18
local PAD = 8             -- frame edge to the search box, and below the last row
local ROW_GAP = 4         -- search box bottom to the first row
local SEARCH_DELAY = 0.15 -- seconds after the last keystroke
local LOAD_TIMEOUT = 3

local frame = nil
local resultRows = {}
local currentResults = {}
local selectedIndex = 0
local targetEditBox = nil     -- the chat box open when the bar opened
local cancelLoad = nil
local cancelSearch = nil      -- cancels the search still running
local searchQuery = nil       -- the text that search is for

-- Forward declarations for local functions referenced before definition
local UpdateSelectionVisuals, SelectItem, DoSearch, FinishSearch, StopSearch

-------------------------------------------------------------------------------
-- Window state persistence
-------------------------------------------------------------------------------
local function SavePosition()
  if not frame then return end
  CobySuite_CobysLinkepedia.UI.SaveWindowState(frame, COBYS_LINKEPEDIA_WINDOW_STATE, "quickSearchBar")
end

local function RestorePosition()
  if not frame then return end
  CobySuite_CobysLinkepedia.UI.RestoreWindowState(frame, COBYS_LINKEPEDIA_WINDOW_STATE, "quickSearchBar",
    { point = "TOP", relPoint = "TOP", x = 0, y = -200 })
end

-- Frame height for n visible rows: the search box, then the rows below it
local function SetRowCount(n)
  local height = PAD + frame.SearchBox:GetHeight() + PAD
  if n > 0 then
    height = height + ROW_GAP + n * ROW_HEIGHT
  end
  frame:SetHeight(height)
end

-------------------------------------------------------------------------------
-- Row creation
-------------------------------------------------------------------------------
local function CreateRow(parent, index, searchBox)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(ROW_HEIGHT)
  -- Rows hang from the search box's bottom edge, so they can never overlap it
  row:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", -8, -ROW_GAP - (index - 1) * ROW_HEIGHT)
  row:SetPoint("RIGHT", parent, "RIGHT", -4, 0)

  CobySuite_CobysLinkepedia.UI.AddHoverHighlight(row, { 1, 1, 1, 0.08 })

  row.Selection = row:CreateTexture(nil, "BACKGROUND")
  row.Selection:SetAllPoints()
  row.Selection:SetColorTexture(0.3, 0.6, 1, 0.2)
  row.Selection:Hide()

  row.Icon = row:CreateTexture(nil, "ARTWORK")
  row.Icon:SetSize(ICON_SIZE, ICON_SIZE)
  row.Icon:SetPoint("LEFT", 4, 0)

  row.Name = row:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  row.Name:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)
  row.Name:SetPoint("RIGHT", -6, 0)
  row.Name:SetJustifyH("LEFT")
  row.Name:SetWordWrap(false)

  row:SetScript("OnClick", function()
    -- A row built for the previous text cannot be picked while a search waits
    -- or runs
    if row.itemData and not searchBox:IsSearchPending() and not cancelSearch then
      SelectItem(row.itemData)
    end
  end)

  CobySuite_CobysLinkepedia.UI.AddItemTooltip(row, function(self)
    if not self.itemData then return nil end
    selectedIndex = index
    UpdateSelectionVisuals()
    return self.itemData.itemID
  end, "ANCHOR_RIGHT", Search.ItemTooltipOptions)

  return row
end

-------------------------------------------------------------------------------
-- Selection visuals
-------------------------------------------------------------------------------
UpdateSelectionVisuals = function()
  for i, row in ipairs(resultRows) do
    row.Selection:SetShown(i == selectedIndex)
  end
end

-------------------------------------------------------------------------------
-- Select an item from results
-------------------------------------------------------------------------------
SelectItem = function(item)
  if not item then return end
  local target = targetEditBox
  QuickSearch.Hide()

  if cancelLoad then
    local cancel = cancelLoad
    cancelLoad = nil
    cancel()
  end
  local itemID, name = item.itemID, item.name
  local cancel = Utilities.LoadItemThen(itemID, {
    timeout = LOAD_TIMEOUT,
    onReady = function(link)
      cancelLoad = nil
      if target and target:IsShown() then
        ChatFrameUtil.ActivateChat(target)
        target:Insert(link)
      else
        -- No box open, or the one that was closed when the bar took focus:
        -- open chat on that box's own window, else the usual one
        ChatFrameUtil.OpenChat(link, target and target.chatFrame)
      end
      Search.AddToHistory(itemID)
    end,
    onFail = function(reason)
      cancelLoad = nil
      Utilities.Message.Warn("The item data for " .. name .. " did not load, so no link was made. Try again in a moment.")
      Debug.Warn("UI", "Quick search: no link for item %d (%s)", itemID, tostring(reason))
    end,
  })
  cancelLoad = cancel
end

-------------------------------------------------------------------------------
-- Create frame. EnsureFrame builds it at login; a /reload in combat waits
-- for the fight to end, and until then the bar cannot open.
-------------------------------------------------------------------------------
local function GetOrCreateFrame()
  if frame then return frame end
  if InCombatLockdown() then return nil end

  frame = CreateFrame("Frame", "CobysLinkepediaQuickSearch", UIParent, "BackdropTemplate")
  frame:SetWidth(BAR_WIDTH)
  frame:SetBackdrop(Utilities.Backdrops.DIALOG)
  local bg = Utilities.Colors.DIALOG_BG
  frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
  -- The backdrop's texture is see-through by itself: a solid layer inside the
  -- border keeps the results readable over chat and the world
  local solid = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
  solid:SetPoint("TOPLEFT", 8, -8)
  solid:SetPoint("BOTTOMRIGHT", -8, 8)
  solid:SetColorTexture(bg[1], bg[2], bg[3], 1)
  frame:SetFrameStrata("MEDIUM")
  frame:SetToplevel(true)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SavePosition()
  end)
  frame:Hide()

  -- The shared search box: debounced search, clear button, placeholder.
  -- Escape hides the bar rather than clearing the box. Enter while a search
  -- is still pending or running finishes it first, so it never picks a row
  -- that belonged to the previous text; Up, Down and Tab (as Down) move the
  -- selection once rows are current.
  local searchBox = CobySuite_CobysLinkepedia.UI.CreateSearchBox(frame, {
    width       = BAR_WIDTH - 24,
    point       = { "TOPLEFT", 12, -PAD },
    maxLetters  = 100,
    debounce    = SEARCH_DELAY,
    placeholder = "Search items",
    onSearch    = function(text) DoSearch(text) end,
    onEscape    = function() QuickSearch.Hide() end,
    onEnter     = function(box)
      box:FlushSearch()
      FinishSearch()
      local item = currentResults[selectedIndex] or currentResults[1]
      if item then SelectItem(item) end
    end,
    onKeyDown   = function(box, key)
      if box:IsSearchPending() or cancelSearch or #currentResults == 0 then return end
      if key == "DOWN" or key == "TAB" then
        selectedIndex = math.min(selectedIndex + 1, #currentResults)
        UpdateSelectionVisuals()
      elseif key == "UP" then
        selectedIndex = math.max(selectedIndex - 1, 1)
        UpdateSelectionVisuals()
      end
    end,
  })
  frame.SearchBox = searchBox

  for i = 1, MAX_RESULTS do
    resultRows[i] = CreateRow(frame, i, searchBox)
    resultRows[i]:Hide()
  end

  -- What an empty answer means, in the first row's place
  frame.EmptyText = frame:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  frame.EmptyText:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", -4, -ROW_GAP - 4)
  frame.EmptyText:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
  frame.EmptyText:SetJustifyH("LEFT")
  frame.EmptyText:SetTextColor(unpack(Utilities.Colors.LABEL_GRAY))
  frame.EmptyText:Hide()

  SetRowCount(0)
  RestorePosition()
  return frame
end

-------------------------------------------------------------------------------
-- Search
-------------------------------------------------------------------------------
-- query: the text the results answer (nil or blank for a cleared box,
-- which shows nothing under it)
local function ShowResults(results, query)
  currentResults = results
  selectedIndex = #currentResults > 0 and 1 or 0

  local numVisible = math.min(#currentResults, MAX_RESULTS)
  local empty
  if numVisible == 0 and query and strtrim(query) ~= "" then
    empty = Database.GetCount() == 0 and "Build your item database first: /lp build."
      or "No matching items. Try a shorter name."
  end
  frame.EmptyText:SetText(empty or "")
  frame.EmptyText:SetShown(empty ~= nil)
  SetRowCount(empty and 1 or numVisible)
  local hints = Search.DuplicateHints(currentResults)

  for i = 1, MAX_RESULTS do
    local row = resultRows[i]
    local item = currentResults[i]
    if item then
      row.itemData = item

      local _, _, _, _, icon = C_Item.GetItemInfoInstant(item.itemID)
      row.Icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")

      row.Name:SetText(Search.NameWithHint(item.name, hints[i]))
      local qualityColor = ITEM_QUALITY_COLORS[item.quality or 1]
      if qualityColor then row.Name:SetTextColor(qualityColor.r, qualityColor.g, qualityColor.b) end

      row:Show()
    else
      row:Hide()
      row.itemData = nil
    end
  end

  UpdateSelectionVisuals()
end

StopSearch = function()
  if cancelSearch then
    local cancel = cancelSearch
    cancelSearch, searchQuery = nil, nil
    cancel()
  end
end

-- The search runs over frames (a short one ends in this one); the rows on
-- screen stay until it ends
DoSearch = function(query)
  if not frame then return end
  StopSearch()

  if not query or strtrim(query) == "" then
    ShowResults({})
    return
  end

  local finished = false
  local cancel = Database.SearchAsync(query, MAX_RESULTS, nil, function(results)
    finished = true
    cancelSearch, searchQuery = nil, nil
    ShowResults(results, query)
  end)
  if not finished then cancelSearch, searchQuery = cancel, query end
end

-- Enter with a search still running: finish it in this frame
FinishSearch = function()
  if not cancelSearch then return end
  local query = searchQuery
  StopSearch()
  ShowResults(Database.Search(query, MAX_RESULTS), query)
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------
function QuickSearch.EnsureFrame()
  if frame then return end
  CobySuite_CobysLinkepedia.Utilities.RunOutOfCombat(GetOrCreateFrame)
end

function QuickSearch.Toggle()
  if frame and frame:IsShown() then
    QuickSearch.Hide()
  else
    QuickSearch.Show()
  end
end

function QuickSearch.Show()
  local f = GetOrCreateFrame()
  if not f then
    Utilities.Message.Warn("Quick search can't open for the first time in combat. Try again after combat.")
    return
  end

  -- The chat box open for typing right now, remembered before the bar takes
  -- focus from it
  local active = ChatFrameUtil.GetActiveWindow()
  targetEditBox = (active and active:IsShown()) and active or nil

  f:Show()
  f:Raise()
  f.SearchBox:SetText("")
  f.SearchBox:SetFocus()
  StopSearch()
  currentResults = {}
  selectedIndex = 0
  for _, row in ipairs(resultRows) do row:Hide() end
  f.EmptyText:Hide()
  SetRowCount(0)
  Debug.Log("UI", "Quick search opened")
end

function QuickSearch.Hide()
  if frame then
    frame.SearchBox:CancelPendingSearch()
    StopSearch()
    frame:Hide()
    frame.SearchBox:ClearFocus()
  end
end

Debug.Log("INIT", "Quick search module loaded")
