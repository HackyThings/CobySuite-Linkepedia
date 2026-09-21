-- Stats: database statistics tab (quality distribution, item classes, totals)
--
-- Two columns in a scroll frame: quality bars with the summary under them on
-- the left, item classes on the right; every block hangs from the one above
-- it, so a long class list pushes nothing into anything else. The tab
-- refreshes when it opens and, while it stays open, when the item or variant
-- database has changed: every half second it compares the two generation
-- counters and refreshes only if one moved, at most every five seconds while
-- a scan is writing. The item counts walk every record, so they are kept
-- until the item generation moves; a variant-only change reads the running
-- variant total and recounts nothing.

local Search = CobysLinkepedia.Search
local Database = CobysLinkepedia.Database
local Utilities = CobysLinkepedia.Utilities
local Debug = CobysLinkepedia.Debug

local QUALITY_MAX = 8        -- Enum.ItemQuality: Poor (0) through WoW Token (8)
local BAR_ROW_H = 18
local LEFT_W = 300
local RIGHT_W = 260
local COLUMN_GAP = 24
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
  -- adds the variant total and scan coverage on top. The counts are shared
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
    bucketCount = items.bucketCount,
    scanCoverage = 0,
  }

  if not COBYS_LINKEPEDIA_DB then return stats end

  -- Scan coverage: 100% only once a scan has run to its end. An unfinished
  -- scan shows how far it got and never reads as 100%; a database that was
  -- never scanned has no flag.
  local scanState = COBYS_LINKEPEDIA_DB.scanState
  if type(scanState) == "table" then
    stats.scanComplete = scanState.complete
    if scanState.complete then
      stats.scanCoverage = 1
    elseif scanState.complete == false then
      local pos, upper = scanState.lastPosition or 0, scanState.upperBound or 0
      stats.scanCoverage = upper > 0 and math.min(pos / upper, 0.99) or 0
    end
  end

  return stats
end

-------------------------------------------------------------------------------
-- Stats tab content
-------------------------------------------------------------------------------
do
  local function InitStatsTab()
    if Search._statsFrame then return end
    local window = CobysLinkepediaSearchWindow
    if not window then return end

    local f = CreateFrame("Frame", nil, window)
    f:SetPoint("TOPLEFT", 8, -58)
    f:SetPoint("BOTTOMRIGHT", -8, 26)
    f:Hide()

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -26, 0)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(LEFT_W + COLUMN_GAP + RIGHT_W + 24, 1)
    scroll:SetScrollChild(content)

    local title = content:CreateFontString(nil, "OVERLAY", Utilities.Fonts.TITLE)
    title:SetPoint("TOPLEFT", 12, -8)
    title:SetText("Database Statistics")

    -- Left column: quality bars, summary below them
    local qualLabel = content:CreateFontString(nil, "OVERLAY", Utilities.Fonts.BODY)
    qualLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    qualLabel:SetText("Items by Quality")

    f.QualityBars = CreateFrame("Frame", nil, content)
    f.QualityBars:SetPoint("TOPLEFT", qualLabel, "BOTTOMLEFT", 0, -6)
    f.QualityBars:SetSize(LEFT_W, (QUALITY_MAX + 1) * BAR_ROW_H)

    f.SummaryText = content:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
    f.SummaryText:SetPoint("TOPLEFT", f.QualityBars, "BOTTOMLEFT", 0, -12)
    f.SummaryText:SetWidth(LEFT_W)
    f.SummaryText:SetJustifyH("LEFT")
    f.SummaryText:SetWordWrap(true)

    -- Right column: item classes
    local typeLabel = content:CreateFontString(nil, "OVERLAY", Utilities.Fonts.BODY)
    typeLabel:SetPoint("TOPLEFT", qualLabel, "TOPLEFT", LEFT_W + COLUMN_GAP, 0)
    typeLabel:SetText("Items by Type")

    f.TypeText = content:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
    f.TypeText:SetPoint("TOPLEFT", typeLabel, "BOTTOMLEFT", 0, -6)
    f.TypeText:SetWidth(RIGHT_W)
    f.TypeText:SetJustifyH("LEFT")
    f.TypeText:SetWordWrap(true)

    -- One row per quality, built once and reused
    f._qualityRows = {}
    for q = 0, QUALITY_MAX do
      local barY = -q * BAR_ROW_H
      local row = {}
      row.label = f.QualityBars:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
      row.label:SetPoint("TOPLEFT", 0, barY)
      row.countText = f.QualityBars:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
      row.countText:SetPoint("TOPRIGHT", f.QualityBars, "TOPRIGHT", 0, barY)
      row.bar = f.QualityBars:CreateTexture(nil, "ARTWORK")
      row.bar:SetPoint("TOPLEFT", 80, barY - 1)
      f._qualityRows[q] = row
    end

    local seenItems, seenVariants
    local sinceCheck, sinceRefresh = 0, 0

    function f:Refresh()
      local stats = Search.ComputeStats()

      local maxCount = 1
      for _, count in pairs(stats.qualityCounts) do
        if count > maxCount then maxCount = count end
      end
      for q = 0, QUALITY_MAX do
        local row = f._qualityRows[q]
        local count = stats.qualityCounts[q] or 0
        local qc = ITEM_QUALITY_COLORS[q]
        local r, g, b = 1, 1, 1
        if qc then r, g, b = qc.r, qc.g, qc.b end
        row.label:SetText(Utilities.QualityNames[q] or ("Quality " .. q))
        row.label:SetTextColor(r, g, b)
        row.countText:SetText(tostring(count))
        local barWidth = count / maxCount * 150
        if count > 0 then
          row.bar:SetSize(math.max(barWidth, 2), 10)
          row.bar:SetColorTexture(r, g, b, 0.6)
          row.bar:Show()
        else
          row.bar:Hide()
        end
      end

      local sortedTypes = {}
      for classID, count in pairs(stats.typeCounts) do
        sortedTypes[#sortedTypes + 1] = { id = classID, count = count }
      end
      table.sort(sortedTypes, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.id < b.id
      end)
      local typeLines = {}
      for i, entry in ipairs(sortedTypes) do
        typeLines[i] = Utilities.GetClassName(entry.id) .. ": " .. entry.count
      end
      f.TypeText:SetText(#typeLines > 0 and table.concat(typeLines, "\n") or "No items yet")

      local summaryLines = {
        "Total items: " .. stats.totalItems,
        "Prefix buckets: " .. stats.bucketCount,
        "Captured variants: " .. stats.variantCount,
        (stats.scanComplete == nil and "Scan: not run yet")
          or (stats.scanComplete and "Scan: complete (100%)")
          or ("Scan: unfinished (" .. math.floor(stats.scanCoverage * 100) .. "%, /lp expand continues it)"),
      }
      if COBYS_LINKEPEDIA_DB and COBYS_LINKEPEDIA_DB.scanState and COBYS_LINKEPEDIA_DB.scanState.lastScanDate then
        summaryLines[#summaryLines + 1] = "Last scan: " .. date("%Y-%m-%d %H:%M", COBYS_LINKEPEDIA_DB.scanState.lastScanDate)
      end
      f.SummaryText:SetText(table.concat(summaryLines, "\n"))

      -- The scroll child is as tall as the taller column
      local top = 8 + title:GetStringHeight() + 12
      local left = top + qualLabel:GetStringHeight() + 6 + f.QualityBars:GetHeight() + 12 + f.SummaryText:GetStringHeight()
      local right = top + typeLabel:GetStringHeight() + 6 + f.TypeText:GetStringHeight()
      content:SetHeight(math.max(left, right) + 12)

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
