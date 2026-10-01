-- Detail Pane: panel showing item information, beside every tab but Stats
-- Shows empty state when no item is selected. Below the item's fields, the
-- variants section lists its saved and captured variants (a scrolling
-- item list of variant entries, Search/VariantActions.lua) and, for gear,
-- a Build Variant button that opens the Variants tab on it.

local Search = CobysLinkepedia.Search
local Utilities = CobysLinkepedia.Utilities
local Debug = CobysLinkepedia.Debug

local FIELD_RIGHT = 40   -- a field's right end to the pane's: room for its copy icon
local GRIP_WIDTH = 8

local detailFrame = nil
local currentItem = nil
local cancelLinkLoad = nil   -- the pending link load; a newer selection cancels it

-------------------------------------------------------------------------------
-- Helper: show all detail content elements
-------------------------------------------------------------------------------
local function ShowContent(f)
  f.Icon:Show()
  f.ItemName:Show()
  f.QualityText:Show()
  f.Divider:Show()
  f.ItemIDLabel:Show()
  f.LinkLabel:Show()
  f.LinkBox:Show()
  f.WowheadLabel:Show()
  f.WowheadBox:Show()
  f.VariantsLabel:Show()
  f.VariantsBox:Show()
end

-------------------------------------------------------------------------------
-- Build the detail pane (shown beside every tab but Stats)
-------------------------------------------------------------------------------
local function CreateDetailPane(parent)
  local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  f:SetWidth(parent.detailWidth or Search.DETAIL_PANE_WIDTH)
  f:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, -58)
  f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 26)
  f:SetBackdrop(Utilities.Backdrops.CONTENT)
  local bg = Utilities.Colors.CONTENT_BG
  f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])

  -- Empty state placeholder (shown when no item selected)
  f.EmptyText = f:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  f.EmptyText:SetPoint("CENTER")
  f.EmptyText:SetText("Select an item to\nview details")
  f.EmptyText:SetTextColor(unpack(Utilities.Colors.DISABLED_GRAY))
  f.EmptyText:SetJustifyH("CENTER")

  -- Item icon
  f.Icon = f:CreateTexture(nil, "ARTWORK")
  f.Icon:SetSize(36, 36)
  f.Icon:SetPoint("TOPLEFT", 12, -12)
  f.Icon:Hide()

  -- Hovering the icon shows the item's tooltip, as the lists do
  f.IconButton = CreateFrame("Button", nil, f)
  f.IconButton:SetAllPoints(f.Icon)
  CobySuite_CobysLinkepedia.UI.AddItemTooltip(f.IconButton, function()
    return currentItem and currentItem.itemID
  end, "ANCHOR_RIGHT", Search.ItemTooltipOptions)

  -- Item name
  f.ItemName = f:CreateFontString(nil, "OVERLAY", Utilities.Fonts.BODY)
  f.ItemName:SetPoint("TOPLEFT", f.Icon, "TOPRIGHT", 8, -2)
  f.ItemName:SetPoint("RIGHT", -8, 0)
  f.ItemName:SetJustifyH("LEFT")
  f.ItemName:SetWordWrap(true)
  f.ItemName:Hide()

  -- Item quality text
  f.QualityText = f:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  -- Under the name however far it wraps
  f.QualityText:SetPoint("TOPLEFT", f.ItemName, "BOTTOMLEFT", 0, -2)
  f.QualityText:SetTextColor(unpack(Utilities.Colors.LABEL_GRAY))
  f.QualityText:Hide()

  -- Divider
  f.Divider = f:CreateTexture(nil, "ARTWORK")
  f.Divider:SetHeight(1)
  -- Placed under the taller of the icon and the name block in ShowDetail
  f.Divider:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -56)
  f.Divider:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  local dg = Utilities.Colors.DIVIDER_GRAY
  f.Divider:SetColorTexture(dg[1], dg[2], dg[3], dg[4])
  f.Divider:Hide()

  -- Item ID
  f.ItemIDLabel = f:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  f.ItemIDLabel:SetPoint("TOPLEFT", f.Divider, "BOTTOMLEFT", 0, -8)
  f.ItemIDLabel:SetTextColor(unpack(Utilities.Colors.LABEL_GRAY))
  f.ItemIDLabel:Hide()

  -- Link string (copyable)
  f.LinkLabel = f:CreateFontString(nil, "OVERLAY", Utilities.Fonts.SMALL)
  f.LinkLabel:SetPoint("TOPLEFT", f.ItemIDLabel, "BOTTOMLEFT", 0, -8)
  f.LinkLabel:SetText("Link string:")
  f.LinkLabel:SetTextColor(unpack(Utilities.Colors.LABEL_GRAY))
  f.LinkLabel:Hide()

  -- The link as a string: escape codes are shown literally (pipes doubled
  -- for display), so the field reads as the raw text it is. The copy icon
  -- puts the raw single-pipe link in, focused and selected, so Ctrl+C takes
  -- exactly those bytes; leaving the field puts the readable form back.
  f.LinkBox = CobySuite_CobysLinkepedia.UI.CreateCopyField(f, {
    tooltip = "Select the raw link string so Ctrl+C copies it",
    point = { "TOPLEFT", f.LinkLabel, "BOTTOMLEFT", 0, -2 },
  })
  f.LinkBox:SetPoint("RIGHT", f, "RIGHT", -FIELD_RIGHT, 0)
  f.LinkBox:Hide()

  -- Wowhead URL
  f.WowheadLabel = f:CreateFontString(nil, "OVERLAY", Utilities.Fonts.SMALL)
  f.WowheadLabel:SetPoint("TOPLEFT", f.LinkBox, "BOTTOMLEFT", 0, -8)
  f.WowheadLabel:SetText("Wowhead:")
  f.WowheadLabel:SetTextColor(unpack(Utilities.Colors.LABEL_GRAY))
  f.WowheadLabel:Hide()

  f.WowheadBox = CobySuite_CobysLinkepedia.UI.CreateCopyField(f, {
    tooltip = "Select the Wowhead link so Ctrl+C copies it",
    point = { "TOPLEFT", f.WowheadLabel, "BOTTOMLEFT", 0, -2 },
  })
  f.WowheadBox:SetPoint("RIGHT", f, "RIGHT", -FIELD_RIGHT, 0)
  f.WowheadBox:Hide()

  -- Variants: a label with the counts, Build Variant for gear, and a list
  -- filling the rest of the pane
  f.VariantsLabel = f:CreateFontString(nil, "OVERLAY", Utilities.Fonts.SMALL)
  f.VariantsLabel:SetPoint("TOPLEFT", f.WowheadBox, "BOTTOMLEFT", -4, -14)
  f.VariantsLabel:SetTextColor(unpack(Utilities.Colors.LABEL_GRAY))
  f.VariantsLabel:Hide()

  f.BuildButton = Utilities.CreateButton(f, {
    text = "Build Variant", size = { 96, 20 }, fontSize = 11,
    tooltip = "Open the Variants tab to build a crafted or upgrade-track version of this item",
    onClick = function()
      if currentItem then Search.OpenBuilder(currentItem.itemID) end
    end,
  })
  f.BuildButton:SetPoint("RIGHT", f, "RIGHT", -10, 0)
  f.BuildButton:SetPoint("BOTTOM", f.VariantsLabel, "BOTTOM", 0, -5)
  f.BuildButton:Hide()

  f.VariantsBox = CreateFrame("Frame", nil, f)
  f.VariantsBox:SetPoint("TOPLEFT", f.VariantsLabel, "BOTTOMLEFT", 0, -8)
  f.VariantsBox:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 8)
  f.VariantsBox:Hide()
  -- The pane already names the item, so its variant rows show only what
  -- sets each apart
  f.VariantList = Search.CreateItemList(f.VariantsBox, { variantSummaryOnly = true })

  f.VariantsEmpty = f.VariantsBox:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  f.VariantsEmpty:SetPoint("TOPLEFT", 4, -4)
  f.VariantsEmpty:SetPoint("RIGHT", -8, 0)
  f.VariantsEmpty:SetJustifyH("LEFT")
  f.VariantsEmpty:SetTextColor(unpack(Utilities.Colors.DISABLED_GRAY))

  -- Loading indicator
  f.LoadingText = f:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  f.LoadingText:SetPoint("CENTER")
  f.LoadingText:SetText("Loading item data...")
  f.LoadingText:SetTextColor(unpack(Utilities.Colors.DISABLED_GRAY))
  f.LoadingText:Hide()

  return f
end

-- The link field's two forms: the readable escaped string, and the raw link
-- Copy selects. With no link the message shows and there is nothing to copy.
local function SetLinkText(link, message)
  if link then
    detailFrame.LinkBox:SetValue((link:gsub("|", "||")), link)
  else
    detailFrame.LinkBox:SetValue(message, false)
  end
end

-- The variants section for the item on show
local function RefreshVariants()
  if not detailFrame or not currentItem then return end
  local f = detailFrame
  local itemID = currentItem.itemID
  local entries = Search.VariantEntriesForItem(itemID)
  local saved = 0
  for _, entry in ipairs(entries) do
    if entry.variant.savedID then saved = saved + 1 end
  end
  local captured = #entries - saved
  if #entries == 0 then
    f.VariantsLabel:SetText("Variants")
  else
    local parts = {}
    if saved > 0 then parts[#parts + 1] = saved .. " saved" end
    if captured > 0 then parts[#parts + 1] = captured .. " captured" end
    f.VariantsLabel:SetText("Variants: " .. table.concat(parts, ", "))
  end
  f.VariantList:SetEntries(entries)

  local gear = CobysLinkepedia.Variants.IsGear(itemID)
  f.BuildButton:SetShown(gear)
  if #entries > 0 then
    f.VariantsEmpty:SetText("")
  elseif gear then
    f.VariantsEmpty:SetText("None yet. Build one, or carry, loot or see one linked.")
  else
    f.VariantsEmpty:SetText("None captured.")
  end
end

local refreshVariants = Utilities.Coalesce(0.1, RefreshVariants)

-- The item the pane shows, or nil
function Search.GetDetailItem()
  return currentItem
end

-- The divider goes under whichever is lower, the icon or the wrapped name
-- with its quality line. The name wraps again when the pane's width changes,
-- so this runs on resize too.
local function PlaceDivider()
  if not (detailFrame and currentItem) then return end
  local textHeight = 2 + detailFrame.ItemName:GetStringHeight() + 2 + detailFrame.QualityText:GetStringHeight()
  detailFrame.Divider:ClearAllPoints()
  detailFrame.Divider:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 12, -12 - math.max(36, textHeight) - 8)
  detailFrame.Divider:SetPoint("RIGHT", detailFrame, "RIGHT", -12, 0)
end

-------------------------------------------------------------------------------
-- Show detail for an item
-------------------------------------------------------------------------------
function Search.ShowDetail(item)
  if not item or not detailFrame then return end
  currentItem = item

  -- Hide empty state, show content
  detailFrame.EmptyText:Hide()
  detailFrame.LoadingText:Show()
  ShowContent(detailFrame)

  -- Populate with instant data
  local _, _, _, _, icon = C_Item.GetItemInfoInstant(item.itemID)
  detailFrame.Icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")

  local qualityColor = ITEM_QUALITY_COLORS[item.quality or 1]
  detailFrame.ItemName:SetText(item.name)
  if qualityColor then detailFrame.ItemName:SetTextColor(qualityColor.r, qualityColor.g, qualityColor.b) end

  detailFrame.QualityText:SetText(Utilities.QualityNames[item.quality] or "Unknown")

  PlaceDivider()
  detailFrame.ItemIDLabel:SetText("Item ID: " .. item.itemID)
  detailFrame.WowheadBox:SetValue("https://www.wowhead.com/item=" .. item.itemID)

  -- The full link, now or once the item loads. One request at a time: a
  -- newer selection cancels the previous one, so no callback can fill the
  -- pane for an item it no longer shows.
  if cancelLinkLoad then
    local cancel = cancelLinkLoad
    cancelLinkLoad = nil
    cancel()
  end
  SetLinkText(nil, "Loading...")
  local loadItemID = item.itemID
  local cancel = Utilities.LoadItemThen(loadItemID, {
    timeout = 5,
    onReady = function(link)
      cancelLinkLoad = nil
      if currentItem and currentItem.itemID == loadItemID then
        SetLinkText(link)
        detailFrame.LoadingText:Hide()
      end
    end,
    onFail = function(reason)
      cancelLinkLoad = nil
      if currentItem and currentItem.itemID == loadItemID then
        SetLinkText(nil, "(unavailable)")
        detailFrame.LoadingText:Hide()
        Debug.Warn("UI", "Item data for ID %d did not load (%s)", loadItemID, tostring(reason))
      end
    end,
  })
  local shown, raw = detailFrame.LinkBox:GetValue()
  if currentItem and currentItem.itemID == loadItemID and not raw and shown == "Loading..." then
    cancelLinkLoad = cancel
  end

  RefreshVariants()
end

-------------------------------------------------------------------------------
-- Init (called by Window.lua OnLoad): creates the pane at once
-------------------------------------------------------------------------------
-- The grip on the pane's left edge: drag to make the pane wider or narrower
-- (the content left of it follows, Window.lua), double-click for the default.
-- The client has no left-right resize cursor (UI_RESIZE_CURSOR is diagonal),
-- so the cursor stays as it is and a small pair of arrows sits on the grip at
-- the mouse's height while it is hovered or dragged.
local ARROW_WIDTH, ARROW_HEIGHT = 7, 11

local function CreateWidthGrip(window, pane)
  local grip = CreateFrame("Button", nil, window)
  grip:SetWidth(GRIP_WIDTH)
  grip:SetPoint("TOPRIGHT", pane, "TOPLEFT", 0, 0)
  grip:SetPoint("BOTTOMRIGHT", pane, "BOTTOMLEFT", 0, 0)
  grip:SetFrameLevel(pane:GetFrameLevel() + 5)

  grip.Line = grip:CreateTexture(nil, "OVERLAY")
  grip.Line:SetPoint("TOP", 0, -4)
  grip.Line:SetPoint("BOTTOM", 0, 4)
  grip.Line:SetWidth(2)
  local gold = Utilities.Colors.STATUS_GOLD
  grip.Line:SetColorTexture(gold[1], gold[2], gold[3], 0.6)

  grip.Arrows = CreateFrame("Frame", nil, grip)
  grip.Arrows:SetSize(2 * ARROW_WIDTH + 6, ARROW_HEIGHT)
  grip.Arrows:SetFrameLevel(grip:GetFrameLevel() + 1)
  local left = grip.Arrows:CreateTexture(nil, "OVERLAY")
  left:SetAtlas("Minimal_SliderBar_Button_Left")
  left:SetSize(ARROW_WIDTH, ARROW_HEIGHT)
  left:SetPoint("LEFT")
  local right = grip.Arrows:CreateTexture(nil, "OVERLAY")
  right:SetAtlas("Minimal_SliderBar_Button_Right")
  right:SetSize(ARROW_WIDTH, ARROW_HEIGHT)
  right:SetPoint("RIGHT")

  -- The arrows follow the mouse up and down the grip
  local function FollowMouse()
    local bottom, top = grip:GetBottom(), grip:GetTop()
    if not bottom then return end
    local y = select(2, GetCursorPosition()) / grip:GetEffectiveScale()
    y = math.max(bottom + ARROW_HEIGHT, math.min(top - ARROW_HEIGHT, y))
    grip.Arrows:ClearAllPoints()
    grip.Arrows:SetPoint("CENTER", grip, "BOTTOM", 0, y - bottom)
  end

  local function ShowMarks(shown)
    grip.Line:SetShown(shown)
    grip.Arrows:SetShown(shown)
  end
  ShowMarks(false)

  local function StopDrag(self)
    if not self.dragging then return end
    self.dragging = nil
    window:SaveDetailWidth()
    if not self:IsMouseOver() then
      self:SetScript("OnUpdate", nil)
      ShowMarks(false)
    else
      self:SetScript("OnUpdate", FollowMouse)
    end
  end

  grip:RegisterForClicks("LeftButtonUp")
  grip:SetScript("OnEnter", function(self)
    ShowMarks(true)
    FollowMouse()
    if not self.dragging then self:SetScript("OnUpdate", FollowMouse) end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Drag to resize the detail pane. Double-click for the default width.", 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  grip:SetScript("OnLeave", function(self)
    GameTooltip:Hide()
    if self.dragging then return end
    self:SetScript("OnUpdate", nil)
    ShowMarks(false)
  end)
  grip:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" then return end
    GameTooltip:Hide()
    local scale = window:GetEffectiveScale()
    local startX = GetCursorPosition() / scale
    local startWidth = window.detailWidth
    self.dragging = true
    self:SetScript("OnUpdate", function()
      -- The pane grows as its left edge moves left
      window:ApplyDetailWidth(startWidth - (GetCursorPosition() / scale - startX), true)
      FollowMouse()
    end)
  end)
  grip:SetScript("OnMouseUp", StopDrag)
  grip:SetScript("OnHide", function(self)
    StopDrag(self)
    self:SetScript("OnUpdate", nil)
    ShowMarks(false)
  end)
  grip:SetScript("OnDoubleClick", function()
    window:ApplyDetailWidth(Search.DETAIL_PANE_WIDTH, true)
    window:SaveDetailWidth()
  end)
  return grip
end

function Search.InitDetailPane(window)
  detailFrame = CreateDetailPane(window)
  Search._detailFrame = detailFrame
  -- Shown and hidden with the pane (the Stats tab has none)
  detailFrame.WidthGrip = CreateWidthGrip(window, detailFrame)
  detailFrame:HookScript("OnShow", function() detailFrame.WidthGrip:Show() end)
  detailFrame:HookScript("OnHide", function() detailFrame.WidthGrip:Hide() end)
  -- Once now and once the text has laid out at the new width
  detailFrame:HookScript("OnSizeChanged", function()
    PlaceDivider()
    RunNextFrame(PlaceDivider)
  end)

  -- The variants list follows saves, deletes, favorites and new captures
  CobysLinkepedia.EventBus:Register({ ReceiveEvent = function(_, event, a, b)
    if not currentItem or not detailFrame:IsVisible() then return end
    -- SavedVariantsChanged(id, itemID) and ItemCaptured(itemID) name the item
    local itemID = event == CobysLinkepedia.Events.ItemCaptured and a or b
    if itemID == nil or itemID == currentItem.itemID then refreshVariants:Call() end
  end }, { CobysLinkepedia.Events.SavedVariantsChanged, CobysLinkepedia.Events.ItemCaptured })
  -- Changes made while the pane was hidden (captures in play, the macro
  -- panel, a closed window) show when it is shown again
  detailFrame:HookScript("OnShow", function() refreshVariants:Call() end)
  Debug.Log("INIT", "Detail pane initialized (always visible)")
end

Debug.Log("INIT", "Search detail pane loaded")
