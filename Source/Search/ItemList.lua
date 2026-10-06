-- Item List: the scrolling list of stored items the Favorites and History
-- tabs and the detail pane's variants show. It uses the same virtual data
-- provider and position-indexed rows as the results table: the ScrollBox
-- recycles a viewport's worth of rows, each installs its handlers once and
-- reads its entry at event time, so a 200-entry history costs the same
-- frames as a 10-entry one.
--
-- An entry is { id = itemID }, or a variant entry (Search/VariantActions.lua)
-- { id = itemID, variant = { link, savedID, ... } }, whose row shows the
-- variant's link tooltip, crafted quality and item level and takes the
-- variant clicks. A pooled row serves both kinds, so every field is set on
-- each init.

local Search = CobysLinkepedia.Search
local Database = CobysLinkepedia.Database
local Utilities = CobysLinkepedia.Utilities

local ROW_HEIGHT = 20
local ICON_SIZE = 16
local VARIANT_INDENT = 14   -- variants under their item in the Favorites tab
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

local function InitRow(row, entry, list)
  if not row._initialized then
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    CobySuite_CobysLinkepedia.UI.AddHoverHighlight(row)
    row.Selected = Search.AddSelectedMark(row)

    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetSize(ICON_SIZE, ICON_SIZE)
    row.Icon:SetPoint("LEFT", 4, 0)

    row.RightText = row:CreateFontString(nil, "OVERLAY", Utilities.Fonts.SMALL)
    row.RightText:SetPoint("RIGHT", -4, 0)
    row.RightText:SetTextColor(unpack(Utilities.Colors.DISABLED_GRAY))

    row.Text = row:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
    row.Text:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)
    row.Text:SetPoint("RIGHT", row.RightText, "LEFT", -8, 0)
    row.Text:SetJustifyH("LEFT")
    row.Text:SetWordWrap(false)

    row:SetScript("OnClick", function(self, button)
      if self.entry and self.entry.variant then
        Search.HandleVariantClick(self.entry, button, self)
      elseif self.item then
        Search.HandleItemClick(self.item, button, self)
      end
    end)

    CobySuite_CobysLinkepedia.UI.AddItemTooltip(row, function(self)
      if self.entry and self.entry.variant then return self.entry.variant.link end
      return self.item and self.item.itemID
    end, "ANCHOR_RIGHT", Search.ItemTooltipOptions)

    row._initialized = true
  end

  row.entry = entry
  -- Only an item's own row is marked; its variant rows are other things
  row.Selected:SetShown(entry ~= nil and not entry.variant and Search.IsSelected(entry.id))
  if not entry then return end
  local stored = Database.GetItem(entry.id)
  -- An id the database no longer holds still gets a usable row: the detail
  -- pane and the row actions work from the id alone
  row.item = stored or { itemID = entry.id, name = "Item " .. entry.id, quality = 1 }

  row.Icon:SetTexture(select(5, C_Item.GetItemInfoInstant(entry.id)) or QUESTION_MARK)
  row.Icon:SetPoint("LEFT", 4 + ((entry.variant and list.indentVariants) and VARIANT_INDENT or 0), 0)

  local variant = entry.variant
  if variant then
    -- One line: the crafted quality icon, then what sets the variant apart
    -- (with the item's name first, except where the list is one item's own)
    local summary = Search.VariantSummary(variant, entry.id)
    local text
    if list.variantSummaryOnly and summary ~= "" then
      text = summary
    else
      text = Search.VariantName(variant.link, entry.id)
      if summary ~= "" then text = text .. "  " .. summary end
    end
    local markup = Search.VariantRankMarkup(variant, 14)
    if markup ~= "" then text = markup .. " " .. text end
    row.Text:SetText(text)
    -- The variant's own quality: a track rank or crafted quality can change it
    local qc = ITEM_QUALITY_COLORS[Search.VariantQuality(variant, entry.id)]
    if qc then row.Text:SetTextColor(qc.r, qc.g, qc.b) else row.Text:SetTextColor(unpack(Utilities.Colors.HIGHLIGHT_WHITE)) end

    local right = {}
    if variant.savedID and variant.favorite then right[#right + 1] = CreateAtlasMarkup("auctionhouse-icon-favorite", 12, 12) end
    if variant.ilvl then right[#right + 1] = tostring(variant.ilvl) end
    if variant.savedID then right[#right + 1] = "v" .. variant.savedID end
    row.RightText:SetText(table.concat(right, "  "))
    return
  end

  row.Text:SetText(row.item.name)
  if stored then
    local qc = ITEM_QUALITY_COLORS[stored.quality or 1]
    if qc then
      row.Text:SetTextColor(qc.r, qc.g, qc.b)
    else
      row.Text:SetTextColor(unpack(Utilities.Colors.HIGHLIGHT_WHITE))
    end
  else
    row.Text:SetTextColor(unpack(Utilities.Colors.DISABLED_GRAY))
  end
  row.RightText:SetText(list.rightText and list.rightText(entry) or "")
end

-- A list filling parent below opts.top (a negative y offset, default 0).
-- opts.rightText(entry) gives each item row's right-hand text;
-- opts.indentVariants indents variant rows under their item;
-- opts.variantSummaryOnly leaves the item's name off variant rows (a list of
-- one item's variants). Show entries
-- with list:SetEntries({ { id = itemID, ... }, ... }); the scroll position
-- stays where it was when the list is refreshed.
function Search.CreateItemList(parent, opts)
  opts = opts or {}
  local list = {
    rightText = opts.rightText, indentVariants = opts.indentVariants,
    variantSummaryOnly = opts.variantSummaryOnly, entries = {},
  }

  local scrollBox = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
  scrollBox:SetPoint("TOPLEFT", 0, opts.top or 0)
  scrollBox:SetPoint("BOTTOMRIGHT", -20, 0)
  scrollBox:SetClipsChildren(true)

  local scrollBar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
  scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 4, 0)
  scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 4, 0)

  local view = CreateScrollBoxListLinearView()
  view:SetElementExtent(ROW_HEIGHT)
  view:SetElementInitializer("Button", function(row, pos)
    InitRow(row, list.entries[pos], list)
  end)
  ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
  -- The bar shows only when the rows overflow
  ScrollUtil.AddManagedScrollBarVisibilityBehavior(scrollBox, scrollBar)
  scrollBox:SetDataProvider(CreateIndexRangeDataProvider(0))

  Search.WatchSelection(function()
    scrollBox:ForEachFrame(function(row)
      local entry = row.entry
      if row.Selected then
        row.Selected:SetShown(entry ~= nil and not entry.variant and Search.IsSelected(entry.id))
      end
    end)
  end)

  local retain = ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition

  function list:SetEntries(entries)
    self.entries = entries
    scrollBox:SetDataProvider(CreateIndexRangeDataProvider(#entries), retain)
  end

  return list
end
