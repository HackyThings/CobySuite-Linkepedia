-- Filter Bar: the search window's top row right of the search box: the
-- search mode picker, then the quality, type and expansion filters and Clear

local Search = CobysLinkepedia.Search
local Utilities = CobysLinkepedia.Utilities
local Debug = CobysLinkepedia.Debug

-- Session-only filter state (resets on login)
local filterState = {
  type = false,
  quality = false,
  expansion = false,
}

local filterFrame = nil

-- Forward declaration
local ApplyFilters

-------------------------------------------------------------------------------
-- Options: labels from the shared quality, class and expansion tables, and
-- quality colours from the game's own table
-------------------------------------------------------------------------------
local MAX_QUALITY = 8

-- The item classes a filter offers, in menu order (retired classes such as
-- Projectile and Quiver hold no current items and are left out)
local TYPE_ORDER = { 2, 4, 0, 7, 3, 9, 8, 1, 5, 12, 13, 16, 15, 17, 18, 19, 20 }

local function QualityOptions()
  local labels, values = { "All Qualities" }, { false }
  for q = 0, MAX_QUALITY do
    local name = Utilities.QualityNames[q]
    if name then
      local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
      labels[#labels + 1] = color and color.hex and (color.hex .. name .. "|r") or name
      values[#values + 1] = q
    end
  end
  return labels, values
end

local function TypeOptions()
  local labels, values = { "All Types" }, { false }
  for _, classID in ipairs(TYPE_ORDER) do
    labels[#labels + 1] = Utilities.GetClassName(classID)
    values[#values + 1] = classID
  end
  return labels, values
end

local function ExpansionOptions()
  local labels, values = { "All Expansions" }, { false }
  local expansion = 0
  while Utilities.ExpansionNames[expansion] do
    labels[#labels + 1] = Utilities.ExpansionNames[expansion]
    values[#values + 1] = expansion
    expansion = expansion + 1
  end
  return labels, values
end

-------------------------------------------------------------------------------
-- Build filter bar
-------------------------------------------------------------------------------

-- One filter dropdown with no label, bound to a filterState key
local function FilterDropDown(key, width, point, labels, values)
  return Utilities.CreateDropDown(filterFrame, {
    label = false, width = width, height = 26, point = point,
    labels = labels, values = values, value = false,
    onValueChanged = function(value)
      filterState[key] = value
      ApplyFilters()
    end,
  })
end

local ROW_HEIGHT = 26
local GAP = Utilities.Spacing.GROUP_GAP
local QUALITY_WIDTH, TYPE_WIDTH, EXPANSION_WIDTH, CLEAR_WIDTH = 140, 140, 130, 60
local MODE_WIDTH = 104

-- The search box's mode picker (Search.SetSearchMode)
local MODE_LABELS = { "Exact", "All words", "Any word" }
local MODE_VALUES = { "exact", "all", "any" }
local MODE_TIPS = {
  "The text as you typed it, in one piece. Put it in \"quotes\" for whole words only.",
  "Every word, in any order and anywhere in the name.",
  "At least one of the words.",
}

-- The top row, from the right: Clear, expansion, type and quality, then the
-- mode picker, whose left edge the search box runs up to (set at the end of
-- this function). The filters serve the Results tab and hide on the others;
-- the picker stays with the box.
function Search.InitFilterBar(window)
  filterFrame = CreateFrame("Frame", nil, window)
  filterFrame:SetSize(QUALITY_WIDTH + TYPE_WIDTH + EXPANSION_WIDTH + CLEAR_WIDTH + GAP * 3, ROW_HEIGHT)
  filterFrame:SetPoint("TOPRIGHT", window, "TOPRIGHT", -12, -30)

  local qualityDD, typeDD, expDD

  local clearButton = Utilities.CreateButton(filterFrame, {
    text = "Clear",
    size = { CLEAR_WIDTH, 22 },
    fontSize = 11,
    point = { "RIGHT", 0, 0 },
    tooltip = "Clear the quality, type and expansion filters",
    onClick = function()
      filterState.type = false
      filterState.quality = false
      filterState.expansion = false
      qualityDD:SetValue(false)
      typeDD:SetValue(false)
      expDD:SetValue(false)
      ApplyFilters()
    end,
  })

  local expLabels, expValues = ExpansionOptions()
  expDD = FilterDropDown("expansion", EXPANSION_WIDTH, { "RIGHT", clearButton, "LEFT", -GAP, 0 }, expLabels, expValues)

  local typeLabels, typeValues = TypeOptions()
  typeDD = FilterDropDown("type", TYPE_WIDTH, { "RIGHT", expDD, "LEFT", -GAP, 0 }, typeLabels, typeValues)

  local qualityLabels, qualityValues = QualityOptions()
  qualityDD = FilterDropDown("quality", QUALITY_WIDTH, { "RIGHT", typeDD, "LEFT", -GAP, 0 }, qualityLabels, qualityValues)

  -- The window's child, not the filter row's, so it shows on every tab
  local modeDD = Utilities.CreateDropDown(window, {
    label = false, width = MODE_WIDTH, height = ROW_HEIGHT,
    point = { "RIGHT", filterFrame, "LEFT", -GAP * 2, 0 },
    labels = MODE_LABELS, values = MODE_VALUES, tooltips = MODE_TIPS,
    value = Search.GetSearchMode(),
    onValueChanged = function(mode) Search.SetSearchMode(mode) end,
  })
  -- The search box ran to the window's edge until now (Window.lua); end it at the picker
  if window.SearchBox then
    window.SearchBox:SetPoint("RIGHT", modeDD, "LEFT", -GAP, 0)
  end

  Search._filterBar = filterFrame
end

-------------------------------------------------------------------------------
-- Apply current filters
-------------------------------------------------------------------------------
ApplyFilters = function()
  Search.SetFilters(filterState)
end

Debug.Log("INIT", "Search filter bar loaded")
