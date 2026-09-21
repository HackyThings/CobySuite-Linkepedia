-- Macro tokens, panel side: a panel on the right of Blizzard's macro window.
-- It explains the item token syntax, lists the tokens in the selected macro
-- with the item each one links right now, and finds items to add as ${i=ID}
-- at the cursor. Both lists scroll. A token row can be edited in place
-- (click it or its pencil; the check mark saves), removed (its red X), and an
-- n= token pinned to its exact id. After a Shift-click into a chat line the
-- hint becomes a button that swaps the name for its token.
--
-- Built at login, so nothing is created in combat, and parented to MacroFrame
-- once Blizzard_MacroUI loads (on demand), so it shows, hides and scales with
-- it. Every change to a macro goes through Editor.lua's secure apply click.
-- It wears the macro window's own frame art (ButtonFrameTemplate without
-- the portrait). Its close button folds it away, leaving a book tab on the
-- macro window's edge that brings it back. Its right edge and corner grip
-- drag its width between MIN_WIDTH and MAX_WIDTH. Both choices are saved.
-- The panel only reads the editor.

local MacroTokens = CobysLinkepedia.MacroTokens
local Linkify = CobysLinkepedia.Linkify
local Database = CobysLinkepedia.Database
local Config = CobysLinkepedia.Config
local Utilities = CobysLinkepedia.Utilities
local Search = CobysLinkepedia.Search
local Debug = CobysLinkepedia.Debug

local MIN_WIDTH = 262
local MAX_WIDTH = 524
local DEFAULT_WIDTH = 393
local EDGE_GRIP_WIDTH = 8
local EDGE = 12                -- content inset from the frame art
local LEGEND_KEY_WIDTH = 72
local LEGEND_ROW_HEIGHT = 15
local TOKEN_ROW_HEIGHT = 28
local FIND_ROW_HEIGHT = 22
local ICON_SIZE = 20
local MAX_TOKEN_ROWS = 3       -- visible at once; the list scrolls
local MAX_FIND_ROWS = 4        -- visible at once; the list scrolls
local FIND_RESULT_LIMIT = 50   -- results a search returns
local LIST_PAD = 4             -- inset box edge to its rows
local REFRESH_DELAY = 0.2
local FIND_DELAY = 0.15
local STATUS_SECONDS = 6
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local TAB_ICON = "Interface\\Icons\\INV_Misc_Book_09"

local panel, tab
local findResults = {}    -- the items the current search returned
local cancelFind = nil    -- cancels the search still running
local tokenEntries = {}   -- { token, itemID } per token in the selected macro
local editing = nil       -- { row, token } while a row is being edited in place
local refresh             -- the coalesced RefreshPanel, set once it exists

local function SetColor(fontString, color)
  fontString:SetTextColor(color[1], color[2], color[3])
end

-------------------------------------------------------------------------------
-- Open or folded
-------------------------------------------------------------------------------
-- COBYS_LINKEPEDIA_WINDOW_STATE.macroTokenPanel: { open = bool, width = n }
local function PanelState()
  local root = COBYS_LINKEPEDIA_WINDOW_STATE
  if type(root) ~= "table" then return nil end
  if type(root.macroTokenPanel) ~= "table" then root.macroTokenPanel = {} end
  return root.macroTokenPanel
end

local function IsOpen()
  local state = PanelState()
  return not (state and state.open == false)
end

local function ClampWidth(width)
  return math.max(MIN_WIDTH, math.min(MAX_WIDTH, width))
end

local function SavedWidth()
  local state = PanelState()
  local width = state and tonumber(state.width)
  if not Utilities.IsFiniteNumber(width) then return DEFAULT_WIDTH end
  return ClampWidth(width)
end

local function ApplyOpenState()
  if not panel or not tab or not panel._attached then return end
  local open = IsOpen()
  panel:SetShown(open)
  tab:SetShown(not open)
end

local function SetOpen(open)
  local state = PanelState()
  if state then state.open = open end
  ApplyOpenState()
end

-------------------------------------------------------------------------------
-- Width drag
--
-- The panel keeps its two anchors on the macro window, so StartSizing (which
-- re-anchors a frame to the screen) is not used: the drag follows the cursor
-- and sets only the width, clamped, then saves it.
-------------------------------------------------------------------------------
local function EndWidthDrag()
  if not panel or not panel._dragging then return end
  panel._dragging = nil
  panel:SetScript("OnUpdate", nil)
  local state = PanelState()
  if state then state.width = math.floor(panel:GetWidth() + 0.5) end
end

local function BeginWidthDrag()
  if not panel then return end
  local scale = panel:GetEffectiveScale()
  local startX = GetCursorPosition() / scale
  local startWidth = panel:GetWidth()
  panel._dragging = true
  panel:SetScript("OnUpdate", function(self)
    self:SetWidth(ClampWidth(startWidth + GetCursorPosition() / scale - startX))
  end)
end

local function WireWidthDrag(handle)
  handle:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then BeginWidthDrag() end
  end)
  handle:SetScript("OnMouseUp", EndWidthDrag)
end

-------------------------------------------------------------------------------
-- Status line
-------------------------------------------------------------------------------
local clearStatus = Utilities.Debounce(STATUS_SECONDS, function()
  if panel then panel.Status:SetText("") end
end)

-- ok true shows success, false a failure, nil a neutral note
function MacroTokens.SetStatus(text, ok)
  if not panel then return end
  local color = Utilities.Colors.HIGHLIGHT_WHITE
  if ok == true then
    color = Utilities.Colors.SUCCESS_GREEN
  elseif ok == false then
    color = Utilities.Colors.WARNING_RED
  end
  SetColor(panel.Status, color)
  panel.Status:SetText(text or "")
  clearStatus:Call()
end

-------------------------------------------------------------------------------
-- Building blocks
-------------------------------------------------------------------------------

-- Name and quality for an item id, from the database or the client
local function ItemLabel(itemID)
  local item = Database.GetItem(itemID)
  if item then return item.name, item.quality end
  local name, _, quality = C_Item.GetItemInfo(itemID)
  return name or C_Item.GetItemNameByID(itemID), quality
end

local function SetQualityColor(fontString, quality)
  local color = ITEM_QUALITY_COLORS[quality or 1]
  if color then fontString:SetTextColor(color.r, color.g, color.b) end
end

local function SetIcon(texture, itemID)
  local icon = itemID and select(5, C_Item.GetItemInfoInstant(itemID))
  texture:SetTexture(icon or QUESTION_MARK)
end

local function CreateSectionHeader(anchor, offsetY, text)
  local header = panel:CreateFontString(nil, "OVERLAY", Utilities.Fonts.BODY)
  header:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, offsetY)
  SetColor(header, Utilities.Colors.STATUS_GOLD)
  header:SetText(text)
  return header
end

-- A recessed box (the inset art Blizzard's own lists sit in) for rows rows
local function CreateListBox(header, rows, rowHeight)
  local box = CreateFrame("Frame", nil, panel, "InsetFrameTemplate")
  box:SetPoint("TOPLEFT", header, "BOTTOMLEFT", -2, -5)
  box:SetPoint("RIGHT", panel, "RIGHT", -EDGE + 2, 0)
  box:SetHeight(rows * rowHeight + 2 * LIST_PAD)

  box.Empty = box:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  box.Empty:SetPoint("LEFT", 12, 0)
  box.Empty:SetPoint("RIGHT", -12, 0)
  box.Empty:SetJustifyH("CENTER")
  SetColor(box.Empty, Utilities.Colors.LABEL_GRAY)
  return box
end

-- A ScrollBox filling a list box. initRow(row, position) fills a pooled row;
-- the bar shows only when the rows overflow, and the rows widen without it.
local function CreateScrollList(box, rowHeight, initRow)
  local scroll = CreateFrame("Frame", nil, box, "WowScrollBoxList")
  local bar = CreateFrame("EventFrame", nil, box, "MinimalScrollBar")
  bar:SetPoint("TOPRIGHT", box, "TOPRIGHT", -6, -LIST_PAD - 2)
  bar:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -6, LIST_PAD + 2)

  local view = CreateScrollBoxListLinearView()
  view:SetElementExtent(rowHeight)
  view:SetElementInitializer("Button", initRow)
  ScrollUtil.InitScrollBoxListWithScrollBar(scroll, bar, view)

  local withBar = {
    CreateAnchor("TOPLEFT", box, "TOPLEFT", LIST_PAD, -LIST_PAD),
    CreateAnchor("BOTTOMRIGHT", box, "BOTTOMRIGHT", -20, LIST_PAD),
  }
  local withoutBar = {
    withBar[1],
    CreateAnchor("BOTTOMRIGHT", box, "BOTTOMRIGHT", -LIST_PAD, LIST_PAD),
  }
  ScrollUtil.AddManagedScrollBarVisibilityBehavior(scroll, bar, withBar, withoutBar)
  scroll:SetDataProvider(CreateIndexRangeDataProvider(0))
  return scroll
end

-------------------------------------------------------------------------------
-- The token list
--
-- A ScrollBox over tokenEntries; rows are pooled, so each row builds its
-- children once and reads its entry when initialised. One shared edit box
-- and its check mark move into the row being edited. While it is open the
-- list is not rebuilt; scrolling, Escape or a different macro closes it.
--
-- Pin, the red X, the check mark, the Shift-click suggestion and the search
-- results change the macro, so each is a secure apply button
-- (MacroTokens.AttachSecureApply in Editor.lua): the click itself stages the
-- change and applies it.
-------------------------------------------------------------------------------

local function EndEdit()
  if not editing then return end
  local row = editing.row
  editing = nil
  local box, save = panel.TokenEdit, panel.TokenEditSave
  box:ClearFocus()
  box:Hide()
  box:ClearAllPoints()
  box:SetParent(panel)
  save:Hide()
  save:ClearAllPoints()
  save:SetParent(panel)
  row.Name:Show()
  row.Detail:Show()
  refresh:Call()
end

local function BeginEdit(row)
  if not row.token then return end
  EndEdit()
  local index, reason = MacroTokens.GetEditTarget()
  if not index then
    MacroTokens.SetStatus(reason, false)
    return
  end

  editing = { row = row, token = row.token }
  local box, save = panel.TokenEdit, panel.TokenEditSave
  save:SetParent(row)
  save:ClearAllPoints()
  save:SetPoint("RIGHT", row.Edit, "LEFT", -8, 0)
  save:SetFrameLevel(row:GetFrameLevel() + 5)
  save:Show()
  box:SetParent(row)
  box:ClearAllPoints()
  box:SetPoint("LEFT", row.Icon, "RIGHT", 12, 0)
  box:SetPoint("RIGHT", save, "LEFT", -10, 0)
  box:SetFrameLevel(row:GetFrameLevel() + 5)
  box:SetText(row.token.text)
  row.Name:Hide()
  row.Detail:Hide()
  row.Pin:Hide()
  box:Show()
  box:SetFocus()
  box:HighlightText()
  MacroTokens.SetStatus("Click the check mark to save, or press Escape. An empty token is removed.")
end

local function BuildTokenRow(row)
  row:RegisterForClicks("LeftButtonUp")

  row.Highlight = CobySuite_CobysLinkepedia.UI.AddHoverHighlight(row, { 1, 1, 1, 0.08 })

  row.Icon = row:CreateTexture(nil, "ARTWORK")
  row.Icon:SetSize(ICON_SIZE, ICON_SIZE)
  row.Icon:SetPoint("LEFT", 4, 0)
  row.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  row.Remove = CobySuite_CobysLinkepedia.UI.CreateIconButton(row, {
    atlas = "common-icon-redx", size = 14,
    highlightAtlas = "common-icon-redx", highlightAlpha = 0.35,
    point = { "RIGHT", row, "RIGHT", -6, 0 },
    tooltip = "Remove this token from the macro",
  })
  MacroTokens.AttachSecureApply(row.Remove, function()
    EndEdit()
    return MacroTokens.StageRemove(row.token)
  end)

  row.Edit = CobySuite_CobysLinkepedia.UI.CreateIconButton(row, {
    atlas = "Pencil-Icon", size = 16,
    highlightAtlas = "Pencil-Icon", highlightAlpha = 0.4,
    point = { "RIGHT", row.Remove, "LEFT", -8, 0 },
    tooltip = "Edit this token",
    onClick = function() BeginEdit(row) end,
  })

  row.Pin = Utilities.CreateButton(row, {
    text = "Pin", size = { 40, 20 },
    point = { "RIGHT", row.Edit, "LEFT", -8, 0 },
    tooltip = "Rewrite this token as the exact ${i=ID} of the item it links now",
  })
  MacroTokens.AttachSecureApply(row.Pin, function()
    EndEdit()
    return MacroTokens.StagePin(row.token)
  end)

  row.Name = row:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  row.Name:SetPoint("BOTTOMLEFT", row.Icon, "RIGHT", 6, 1)
  row.Name:SetJustifyH("LEFT")
  row.Name:SetWordWrap(false)

  row.Detail = row:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  row.Detail:SetPoint("TOPLEFT", row.Icon, "RIGHT", 6, -1)
  row.Detail:SetJustifyH("LEFT")
  row.Detail:SetWordWrap(false)
  SetColor(row.Detail, Utilities.Colors.LABEL_GRAY)

  row:SetScript("OnClick", function(self) BeginEdit(self) end)
  Utilities.AddItemTooltip(row, function(self) return self.link or self.itemID end, "ANCHOR_RIGHT", Search.ItemTooltipOptions)
  row._built = true
end

-- Name, rank, item level and track of a saved variant, for its token row
local function VariantLabel(variant)
  local name = Search.VariantName(variant.link, variant.itemID)
  local detail = Search.VariantDetail(variant)
  return detail ~= "" and (name .. ", " .. detail) or name
end

local function InitTokenRow(row, pos)
  if not row._built then BuildTokenRow(row) end
  local entry = tokenEntries[pos]
  row.token = entry and entry.token
  row.itemID = entry and entry.itemID
  row.link = nil
  if not entry then return end

  local token, itemID = entry.token, entry.itemID
  SetIcon(row.Icon, itemID)
  row.Detail:SetText(token.text)
  if token.key == "v" then
    local variant = CobysLinkepedia.Variants.Get(token.variantID)
    if variant then
      row.link = variant.link
      row.Name:SetText(VariantLabel(variant))
      SetQualityColor(row.Name, Search.VariantQuality(variant, variant.itemID))
    else
      row.Name:SetText("No saved variant " .. token.variantID)
      SetColor(row.Name, Utilities.Colors.WARNING_RED)
    end
  elseif itemID then
    local name, quality = ItemLabel(itemID)
    local label = name or ("Item " .. itemID)
    if token.rank then label = label .. ", rank " .. token.rank end
    if token.ilvl then label = label .. ", item level " .. token.ilvl end
    row.Name:SetText(label)
    SetQualityColor(row.Name, quality)
    if token.qualified and not Database.MatchVariant(itemID, token.rank, token.ilvl) then
      row.Detail:SetText(token.text .. "  (no captured variant)")
    end
  else
    row.Name:SetText("No item matches")
    SetColor(row.Name, Utilities.Colors.WARNING_RED)
  end

  local showPin = token.key == "n" and itemID ~= nil
  row.Pin:SetShown(showPin)
  local rightOf = showPin and row.Pin or row.Edit
  row.Name:SetPoint("RIGHT", rightOf, "LEFT", -8, 0)
  row.Detail:SetPoint("RIGHT", rightOf, "LEFT", -8, 0)
end

local function CreateTokenList()
  local scroll = CreateScrollList(panel.TokenBox, TOKEN_ROW_HEIGHT, InitTokenRow)
  scroll:RegisterCallback(BaseScrollBoxEvents.OnScroll, function() EndEdit() end, panel)
  panel.TokenScroll = scroll

  -- The shared inline editor. It never commits by itself: a change needs the
  -- check mark's secure click, so Enter points at it and Escape closes it.
  panel.TokenEdit = CobySuite_CobysLinkepedia.UI.CreateTextInput(panel, { width = 120, maxLetters = 255 })
  panel.TokenEdit:SetScript("OnEnterPressed", function()
    MacroTokens.SetStatus("Click the check mark to save the token.")
  end)
  panel.TokenEdit:SetScript("OnEscapePressed", function() EndEdit() end)
  panel.TokenEdit:SetScript("OnEditFocusLost", nil)
  panel.TokenEdit:Hide()

  panel.TokenEditSave = CobySuite_CobysLinkepedia.UI.CreateIconButton(panel, {
    atlas = "common-icon-checkmark", size = 16,
    highlightAtlas = "common-icon-checkmark", highlightAlpha = 0.4,
    tooltip = "Save this token to the macro",
  })
  panel.TokenEditSave:Hide()
  MacroTokens.AttachSecureApply(panel.TokenEditSave, function()
    if not editing then return true, nil end
    local ok, change = MacroTokens.StageEdit(editing.token, panel.TokenEdit:GetText())
    -- Closed on the next frame: hiding the check mark now would hide the
    -- apply button in the middle of its click
    if ok then C_Timer.After(0, EndEdit) end
    return ok, change
  end)
end

local function InitFindRow(row, pos)
  if not row._built then
    row:RegisterForClicks("LeftButtonUp")
    row.Highlight = CobySuite_CobysLinkepedia.UI.AddHoverHighlight(row, { 1, 1, 1, 0.08 })

    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetSize(ICON_SIZE, ICON_SIZE)
    row.Icon:SetPoint("LEFT", 4, 0)
    row.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.Name = row:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
    row.Name:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)
    row.Name:SetPoint("RIGHT", -4, 0)
    row.Name:SetJustifyH("LEFT")
    row.Name:SetWordWrap(false)

    Utilities.AddItemTooltip(row, function(self) return self.itemID end, "ANCHOR_RIGHT", Search.ItemTooltipOptions)
    MacroTokens.AttachSecureApply(row, function(self)
      EndEdit()
      return MacroTokens.StageInsertItem(self.itemID)
    end)
    row._built = true
  end

  local item = findResults[pos]
  row.itemID = item and item.itemID
  if not item then return end
  SetIcon(row.Icon, item.itemID)
  row.Name:SetText(item.name)
  SetQualityColor(row.Name, item.quality)
end

-------------------------------------------------------------------------------
-- Shift-click suggestion: after Blizzard puts an item's name into a chat
-- line, the hint line becomes a button that swaps the name for its token
-------------------------------------------------------------------------------
local SUGGESTION_SECONDS = 20
local suggestion = nil

local function HideSuggestion()
  suggestion = nil
  if not panel then return end
  panel.Suggestion:Hide()
  panel.Hint:Show()
end
local hideSuggestion = Utilities.Debounce(SUGGESTION_SECONDS, HideSuggestion)

function MacroTokens.OnSuggestion(offer)
  if not panel or not panel:IsVisible() then return end
  suggestion = offer
  local format = offer.newVariant and "Save and use %s for %s" or "Use %s for %s"
  panel.Suggestion:SetText(format:format(offer.token, offer.inserted))
  panel.Suggestion:Show()
  panel.Hint:Hide()
  hideSuggestion:Call()
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------
local function RefreshHint()
  if Config.Get(Config.Options.EXPAND_ITEM_TOKENS) then
    panel.Hint:SetText("Shift-click an item into a chat line to get its token.")
    SetColor(panel.Hint, Utilities.Colors.LABEL_GRAY)
  else
    panel.Hint:SetText("Item tokens are turned off in /lp settings.")
    SetColor(panel.Hint, Utilities.Colors.WARNING_RED)
  end
end

local function RefreshTokens()
  -- An open edit keeps its row: the list is rebuilt once it closes
  if editing then return end

  -- The selector reports index 1 even when the tab has no macros
  local selected = MacroFrame and MacroFrame:GetSelectedIndex()
  if selected and not GetMacroInfo(MacroFrame:GetMacroDataIndex(selected)) then selected = nil end
  local tokens = selected and Linkify.FindTokens(MacroFrameText:GetText() or "") or {}

  tokenEntries = {}
  for i, token in ipairs(tokens) do
    tokenEntries[i] = { token = token, itemID = Linkify.ResolveTokenItem(token) }
  end
  panel.TokenScroll:SetDataProvider(CreateIndexRangeDataProvider(#tokenEntries), ScrollBoxConstants.RetainScrollPosition)

  local box = panel.TokenBox
  if not selected then
    box.Empty:SetText("Select a macro.")
  elseif #tokens == 0 then
    box.Empty:SetText("No tokens in this macro yet.")
  else
    box.Empty:SetText("")
  end
  if #tokens > 0 then
    panel.TokenCount:SetText(#tokens == 1 and "1 token" or (#tokens .. " tokens"))
  else
    panel.TokenCount:SetText("")
  end
end

function MacroTokens.RefreshPanel()
  if not panel or not panel:IsVisible() then return end
  RefreshHint()
  RefreshTokens()
end

refresh = Utilities.Coalesce(REFRESH_DELAY, function() MacroTokens.RefreshPanel() end)

-- Editor.lua calls this after Blizzard selects a macro; an edit or a
-- suggestion made on the old text no longer applies
function MacroTokens.OnMacroChanged()
  EndEdit()
  HideSuggestion()
  refresh:Call()
end

local FIND_PROMPT = "Click a result to add its token at the cursor."

-- results nil: no query, the prompt shows
local function ShowFound(results)
  local box = panel.FindBox
  if not results then
    findResults = {}
    box.Empty:SetText(FIND_PROMPT)
    panel.FindCount:SetText("")
  else
    findResults = results
    box.Empty:SetText(#findResults == 0 and "No items match." or "")
    if #findResults >= FIND_RESULT_LIMIT then
      panel.FindCount:SetText(("first %d results"):format(FIND_RESULT_LIMIT))
    elseif #findResults > 0 then
      panel.FindCount:SetText(#findResults == 1 and "1 result" or (#findResults .. " results"))
    else
      panel.FindCount:SetText("")
    end
  end
  -- A new search starts at the top of its list
  panel.FindScroll:SetDataProvider(CreateIndexRangeDataProvider(#findResults))
end

-- The search runs over frames (a short one ends in this one); the list on
-- screen stays until it ends
local function DoFind(query)
  if cancelFind then
    local cancel = cancelFind
    cancelFind = nil
    cancel()
  end
  if not query or strtrim(query) == "" then
    ShowFound(nil)
    return
  end
  local finished = false
  local cancel = Database.SearchAsync(query, FIND_RESULT_LIMIT, nil, function(results)
    finished = true
    cancelFind = nil
    ShowFound(results)
  end)
  if not finished then cancelFind = cancel end
end

-------------------------------------------------------------------------------
-- Build and attach
-------------------------------------------------------------------------------
local LEGEND = {
  { "${i=ID}", "the exact item" },
  { "${n=text}", "the best name match" },
  { "${v=N}", "a saved variant" },
  { "~R2  ~450", "a rank or item level" },
}

local function Build()
  panel = CreateFrame("Frame", "CobysLinkepediaMacroTokenPanel", UIParent, "ButtonFrameTemplate")
  ButtonFrameTemplate_HidePortrait(panel)
  panel.Inset:Hide()
  panel:SetWidth(SavedWidth())
  panel:SetTitle("Linkepedia Item Tokens")
  panel:EnableMouse(true)
  panel:Hide()
  -- Folding, not closing: the tab brings it back
  panel.CloseButton:SetScript("OnClick", function() SetOpen(false) end)

  -- Legend: token forms in gold, what they link beside them in one column
  local previous
  for i, entry in ipairs(LEGEND) do
    local key = panel:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
    if previous then
      key:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -(LEGEND_ROW_HEIGHT - 11))
    else
      key:SetPoint("TOPLEFT", panel, "TOPLEFT", EDGE + 2, -34)
    end
    key:SetWidth(LEGEND_KEY_WIDTH)
    key:SetJustifyH("LEFT")
    SetColor(key, Utilities.Colors.STATUS_GOLD)
    key:SetText(entry[1])

    local meaning = panel:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
    meaning:SetPoint("LEFT", key, "RIGHT", 4, 0)
    meaning:SetText(entry[2])
    previous = key
  end

  panel.Hint = panel:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  panel.Hint:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -8)
  panel.Hint:SetPoint("RIGHT", panel, "RIGHT", -EDGE - 2, 0)
  panel.Hint:SetJustifyH("LEFT")
  panel.Hint:SetSpacing(2)

  panel.Suggestion = Utilities.CreateButton(panel, {
    text = "", size = { MIN_WIDTH - 2 * EDGE, 22 },
    point = { "TOPLEFT", panel.Hint, "TOPLEFT", -2, 5 },
    tooltip = "Replace the item name you just Shift-clicked in with its token",
  })
  panel.Suggestion:SetPoint("RIGHT", panel, "RIGHT", -EDGE - 2, 0)
  local label = panel.Suggestion:GetFontString()
  label:ClearAllPoints()
  label:SetPoint("LEFT", 8, 0)
  label:SetPoint("RIGHT", -8, 0)
  label:SetWordWrap(false)
  panel.Suggestion:Hide()
  MacroTokens.AttachSecureApply(panel.Suggestion, function()
    local offer = suggestion
    -- Hidden on the next frame: hiding it now would hide the apply button
    -- in the middle of its click
    C_Timer.After(0, HideSuggestion)
    return MacroTokens.StageSuggestion(offer)
  end)

  -- This macro
  panel.TokenHeader = CreateSectionHeader(panel.Hint, -14, "This Macro")
  panel.TokenCount = panel:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  panel.TokenCount:SetPoint("RIGHT", panel, "RIGHT", -EDGE - 2, 0)
  panel.TokenCount:SetPoint("BOTTOM", panel.TokenHeader, "BOTTOM", 0, 0)
  SetColor(panel.TokenCount, Utilities.Colors.LABEL_GRAY)
  panel.TokenBox = CreateListBox(panel.TokenHeader, MAX_TOKEN_ROWS, TOKEN_ROW_HEIGHT)
  CreateTokenList()

  -- Add an item
  panel.FindHeader = CreateSectionHeader(panel.TokenBox, -12, "Add an Item")
  panel.FindHeader:ClearAllPoints()
  panel.FindHeader:SetPoint("TOPLEFT", panel.TokenBox, "BOTTOMLEFT", 2, -12)
  panel.SearchBox = CobySuite_CobysLinkepedia.UI.CreateSearchBox(panel, {
    width       = MIN_WIDTH - 2 * EDGE - 6,
    point       = { "TOPLEFT", panel.FindHeader, "BOTTOMLEFT", 6, -5 },
    maxLetters  = 100,
    debounce    = FIND_DELAY,
    placeholder = "Search items",
    onSearch    = function(text) DoFind(text) end,
  })
  -- A right anchor as well, so the box follows the panel's width
  panel.SearchBox:SetPoint("RIGHT", panel, "RIGHT", -EDGE - 2, 0)
  panel.FindBox = CreateListBox(panel.FindHeader, MAX_FIND_ROWS, FIND_ROW_HEIGHT)
  panel.FindBox:ClearAllPoints()
  panel.FindBox:SetPoint("TOPLEFT", panel.SearchBox, "BOTTOMLEFT", -8, -5)
  panel.FindBox:SetPoint("RIGHT", panel, "RIGHT", -EDGE + 2, 0)
  panel.FindBox.Empty:SetText(FIND_PROMPT)
  panel.FindScroll = CreateScrollList(panel.FindBox, FIND_ROW_HEIGHT, InitFindRow)
  panel.FindCount = panel:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  panel.FindCount:SetPoint("RIGHT", panel, "RIGHT", -EDGE - 2, 0)
  panel.FindCount:SetPoint("BOTTOM", panel.FindHeader, "BOTTOM", 0, 0)
  SetColor(panel.FindCount, Utilities.Colors.LABEL_GRAY)

  panel.Status = panel:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  panel.Status:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", EDGE + 2, 10)
  panel.Status:SetPoint("RIGHT", panel, "RIGHT", -EDGE - 20, 0)
  panel.Status:SetJustifyH("LEFT")
  panel.Status:SetWordWrap(false)

  panel:SetScript("OnShow", function(self)
    self:RegisterEvent("ITEM_DATA_LOAD_RESULT")
    MacroTokens.RefreshPanel()
  end)
  panel:SetScript("OnHide", function(self)
    self:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
    EndWidthDrag()
    EndEdit()
    HideSuggestion()
  end)

  -- Width: the corner grip, and the whole right edge below the close button
  panel.ResizeGrip = CobySuite_CobysLinkepedia.UI.CreateResizeGrip(panel)
  panel.ResizeGrip:ClearAllPoints()
  panel.ResizeGrip:SetPoint("BOTTOMRIGHT", -6, 6)
  WireWidthDrag(panel.ResizeGrip)
  CobySuite_CobysLinkepedia.UI.AddTooltip(panel.ResizeGrip, "Drag to change the panel's width")

  panel.EdgeGrip = CreateFrame("Frame", nil, panel)
  panel.EdgeGrip:SetWidth(EDGE_GRIP_WIDTH)
  panel.EdgeGrip:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -30)
  panel.EdgeGrip:SetPoint("BOTTOMRIGHT", panel.ResizeGrip, "TOPRIGHT", 6, 2)
  panel.EdgeGrip:EnableMouse(true)
  panel.EdgeGrip.Highlight = panel.EdgeGrip:CreateTexture(nil, "HIGHLIGHT")
  panel.EdgeGrip.Highlight:SetPoint("TOPRIGHT", -2, 0)
  panel.EdgeGrip.Highlight:SetPoint("BOTTOMRIGHT", -2, 0)
  panel.EdgeGrip.Highlight:SetWidth(2)
  local gold = Utilities.Colors.STATUS_GOLD
  panel.EdgeGrip.Highlight:SetColorTexture(gold[1], gold[2], gold[3], 0.6)
  WireWidthDrag(panel.EdgeGrip)
  panel:SetScript("OnEvent", function() refresh:Call() end)

  -- The folded state: the addon's book on the macro window's edge
  tab = CobySuite_CobysLinkepedia.UI.CreateIconButton(UIParent, {
    size = 32,
    texture = TAB_ICON,
    texCoord = { 0.07, 0.93, 0.07, 0.93 },
    tooltip = "Linkepedia Item Tokens",
    onClick = function() SetOpen(true) end,
  })
  tab:Hide()

  CobysLinkepedia.EventBus:Register({ ReceiveEvent = function() refresh:Call() end },
    { CobysLinkepedia.Events.ConfigChanged, CobysLinkepedia.Events.DatabaseUpdated,
      CobysLinkepedia.Events.SavedVariantsChanged })
end

-- Called once Blizzard_MacroUI has loaded (Editor.lua), and again by
-- EnsurePanel when the build had to wait for combat to end
function MacroTokens.AttachPanel()
  if not panel or not MacroFrame or panel._attached then return end
  panel._attached = true

  panel:SetParent(MacroFrame)
  panel:ClearAllPoints()
  panel:SetPoint("TOPLEFT", MacroFrame, "TOPRIGHT", 0, 0)
  panel:SetPoint("BOTTOMLEFT", MacroFrame, "BOTTOMRIGHT", 0, 0)
  tab:SetParent(MacroFrame)
  tab:ClearAllPoints()
  tab:SetPoint("TOPLEFT", MacroFrame, "TOPRIGHT", 2, -60)

  MacroFrameText:HookScript("OnTextChanged", function() refresh:Call() end)
  ApplyOpenState()
  Debug.Log("UI", "Item token panel attached to the macro window")
end

function MacroTokens.EnsurePanel()
  if panel then return end
  if InCombatLockdown() then
    EventUtil.RegisterOnceFrameEventAndCallback("PLAYER_REGEN_ENABLED", function()
      MacroTokens.EnsurePanel()
    end)
    return
  end
  Build()
  MacroTokens.AttachPanel()
end

Debug.Log("INIT", "Macro tokens panel loaded")
