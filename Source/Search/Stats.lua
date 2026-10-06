-- Stats: database statistics tab (the database's status, quality and item
-- type counts)
--
-- The tab refreshes when it opens and, while it stays open, when the item or
-- variant database has changed: every half second it compares the two
-- generation counters and refreshes only if one moved, at most every five
-- seconds while a scan is writing. The item counts walk every record, so they
-- are kept until the item generation moves; a variant-only change reads the
-- running variant total and recounts nothing.

local Search = CobysLinkepedia.Search
local Database = CobysLinkepedia.Database
local Utilities = CobysLinkepedia.Utilities
local Debug = CobysLinkepedia.Debug

local QUALITY_MAX = 8        -- Enum.ItemQuality: Poor (0) through WoW Token (8)
local TYPE_TILES = 32        -- more than the item classes the game has
local CHECK_INTERVAL = 0.5
local SCAN_REFRESH_INTERVAL = 5

-------------------------------------------------------------------------------
-- Compute database statistics
-------------------------------------------------------------------------------
-- The last item counts and the item generation they were made at. Every
-- write to the item table and every load or swap moves the generation.
local itemStats, itemStatsGeneration

function Search.ComputeStats()
  -- Item counts come from Database, which owns the storage layout; this file
  -- adds the variant total on top. The counts are shared
  -- with the previous call while the items are unchanged: read, never write.
  local generation = Database.GetGeneration()
  if not itemStats or itemStatsGeneration ~= generation then
    itemStats, itemStatsGeneration = Database.ComputeItemStats(), generation
  end
  local items = itemStats
  local stats = {
    totalItems = items.totalItems,
    qualityCounts = items.qualityCounts,
    typeCounts = items.typeCounts,
    variantCount = Database.GetVariantTotal(),
  }

  return stats
end

-------------------------------------------------------------------------------
-- Stats tab content
-------------------------------------------------------------------------------
-- The shared kit's pieces, top to bottom in a scroll frame: the database's
-- status card (the settings window's Item database card, with its Build or
-- Expand button), then a tile per quality and a tile per item type, each
-- with its count and its share of the database. The card and the grids set
-- their own heights; the scroll child follows them.
do
  local Examples = CobysLinkepedia.Config.Examples
  local CONTENT_PAD = 12
  local SECTION_GAP = 14

  -- The stats the tiles read, kept from the last refresh
  local current

  local function Share(count)
    local total = current and current.totalItems or 0
    return total > 0 and count / total or 0
  end

  local function Percent(count)
    local share = Share(count) * 100
    if share > 0 and share < 1 then return "under 1%" end
    return ("%d%%"):format(math.floor(share + 0.5))
  end

  local function QualityTiles()
    local tiles = {}
    for q = 0, QUALITY_MAX do
      local count = current and current.qualityCounts[q] or 0
      local name = Utilities.QualityNames[q] or ("Quality " .. q)
      -- the tiles take { r, g, b }; the game's quality colors are r/g/b fields
      local qc = ITEM_QUALITY_COLORS[q]
      local color = qc and { qc.r, qc.g, qc.b } or nil
      tiles[#tiles + 1] = {
        key = "quality" .. q,
        value = BreakUpLargeNumbers(count),
        label = name,
        color = color,
        bar = Share(count),
        barColor = color,
        dim = count == 0,
        tooltip = count > 0 and ("%s: %s of your items."):format(name, Percent(count))
          or ("No %s items in your database."):format(name),
      }
    end
    return tiles
  end

  local function TypeTiles()
    local sorted = {}
    for classID, count in pairs(current and current.typeCounts or {}) do
      sorted[#sorted + 1] = { id = classID, count = count }
    end
    table.sort(sorted, function(a, b)
      if a.count ~= b.count then return a.count > b.count end
      return a.id < b.id
    end)
    local tiles = {}
    for i, entry in ipairs(sorted) do
      local name = Utilities.GetClassName(entry.id)
      tiles[i] = {
        key = "type" .. entry.id,
        value = BreakUpLargeNumbers(entry.count),
        label = name,
        bar = Share(entry.count),
        tooltip = ("%s: %s of your items."):format(name, Percent(entry.count)),
      }
    end
    return tiles
  end

  -- The card's line, then how many variants the addon has captured
  local function CardDescription()
    local text = select(4, Examples.DatabaseState())
    local variants = current and current.variantCount or 0
    if variants > 0 then
      text = text .. "\n" .. ("%s captured variants: crafted ranks, upgrade levels and other versions."):format(BreakUpLargeNumbers(variants))
    end
    return text
  end

  local function InitStatsTab()
    if Search._statsFrame then return end
    local window = CobysLinkepediaSearchWindow
    if not window then return end

    local f = CreateFrame("Frame", nil, window)
    f:SetPoint("TOPLEFT", 8, -58)
    f:SetPoint("BOTTOMRIGHT", -8, 26)
    f:Hide()

    -- The same thin bar as the Results list beside it, shown only when the
    -- tiles run past the bottom; the wheel scrolls too
    local scroll = CreateFrame("ScrollFrame", nil, f)
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -20, 0)
    scroll:EnableMouseWheel(true)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(math.max(scroll:GetWidth(), 1), 1)
    scroll:SetScrollChild(content)
    local bar = CreateFrame("EventFrame", nil, f, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
    ScrollUtil.InitScrollFrameWithScrollBar(scroll, bar)
    bar:Hide()
    scroll:HookScript("OnScrollRangeChanged", function(self, _, range)
      range = range or 0
      -- Content that shrank keeps the view inside it
      if self:GetVerticalScroll() > range then self:SetVerticalScroll(range) end
      bar:SetShown(range > 0)
    end)

    local Layout   -- assigned below; every piece calls it when its height changes

    f.Card = CobySuite_CobysLinkepedia.UI.CreateStatusCard(content, {
      icon = CobysLinkepedia.ICON,
      state = function() return (Examples.DatabaseState()) end,
      stateText = function() return (select(2, Examples.DatabaseState())) end,
      title = function() return (select(3, Examples.DatabaseState())) end,
      description = CardDescription,
      actions = Examples.DatabaseActions(),
      ticker = 0.5,
      onHeight = function() if Layout then Layout() end end,
    })
    f.Card:SetPoint("TOPLEFT", content, "TOPLEFT", CONTENT_PAD, -CONTENT_PAD)
    f.Card:SetPoint("TOPRIGHT", content, "TOPRIGHT", -CONTENT_PAD, -CONTENT_PAD)

    -- A section header with its divider under it, both following the width
    local function Header(text, below)
      local header, divider = CobySuite_CobysLinkepedia.UI.CreateSection(content, {
        text = text, font = Utilities.Fonts.HEADING, width = 1,
        point = { "TOPLEFT", below, "BOTTOMLEFT", 0, -SECTION_GAP },
      })
      return header, divider
    end

    f.QualityHeader, f.QualityDivider = Header("Items by quality", f.Card)
    f.Qualities = CobySuite_CobysLinkepedia.UI.CreateStatTiles(content, {
      tiles = QualityTiles, maxTiles = QUALITY_MAX + 1, columns = 3, minTileWidth = 140,
      onHeight = function() if Layout then Layout() end end,
    })
    f.Qualities:SetPoint("TOPLEFT", f.QualityDivider, "BOTTOMLEFT", 0, -8)
    f.Qualities:SetPoint("RIGHT", content, "RIGHT", -CONTENT_PAD, 0)

    f.TypeHeader, f.TypeDivider = Header("Items by type", f.Qualities)
    f.Types = CobySuite_CobysLinkepedia.UI.CreateStatTiles(content, {
      tiles = TypeTiles, maxTiles = TYPE_TILES, columns = 4, minTileWidth = 120, height = 44,
      onHeight = function() if Layout then Layout() end end,
    })
    f.Types:SetPoint("TOPLEFT", f.TypeDivider, "BOTTOMLEFT", 0, -8)
    f.Types:SetPoint("RIGHT", content, "RIGHT", -CONTENT_PAD, 0)

    -- The scroll child is as wide as the view and as tall as its pieces
    function Layout()
      local width = content:GetWidth() - 2 * CONTENT_PAD
      f.QualityDivider:SetWidth(math.max(width, 1))
      f.TypeDivider:SetWidth(math.max(width, 1))
      local height = CONTENT_PAD + f.Card:GetHeight()
        + 2 * (SECTION_GAP + f.QualityHeader:GetStringHeight() + 2 + 1 + 8)
        + f.Qualities:GetHeight() + f.Types:GetHeight() + CONTENT_PAD
      content:SetHeight(math.max(height, 1))
    end
    scroll:SetScript("OnSizeChanged", function(_, width)
      content:SetWidth(math.max(width, 1))
      Layout()
    end)

    local seenItems, seenVariants
    local sinceCheck, sinceRefresh = 0, 0

    function f:Refresh()
      local width = scroll:GetWidth()
      if width and width > 1 then content:SetWidth(width) end
      current = Search.ComputeStats()
      f.Card:Refresh()
      f.Qualities:Refresh()
      f.Types:Refresh()
      Layout()
      seenItems, seenVariants = Database.GetGeneration(), Database.GetVariantGeneration()
      sinceRefresh = 0
    end

    f:SetScript("OnShow", function(self)
      sinceCheck = 0
      self:Refresh()
    end)

    -- Runs only while the tab is shown
    f:SetScript("OnUpdate", function(self, elapsed)
      sinceCheck = sinceCheck + elapsed
      sinceRefresh = sinceRefresh + elapsed
      if sinceCheck < CHECK_INTERVAL then return end
      sinceCheck = 0
      if Database.GetGeneration() == seenItems and Database.GetVariantGeneration() == seenVariants then return end
      local status = CobysLinkepedia.Scanner.GetStatus()
      local minGap = (status and status.isActive) and SCAN_REFRESH_INTERVAL or CHECK_INTERVAL
      if sinceRefresh >= minGap then
        self:Refresh()
      end
    end)

    Search._statsFrame = f
  end

  C_Timer.After(0, InitStatsTab)
end

Debug.Log("INIT", "Search stats loaded")
