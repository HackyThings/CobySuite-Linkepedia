-- Variant Builder: the search window's Variants tab. It builds any variant
-- of a piece of gear the game allows and keeps the ones the player wants.
--
-- The tab reads top to bottom: the item (with a gear search to pick
-- another), the choices, the preview of the game's own link, and the
-- actions. The choices box holds one of two kinds:
--
--   Upgrade Track  a season, one of its tracks, a rank and a quality,
--                  through Variants.BuildTrackLink; every rank shows its item
--                  level, and the quality is the rank's own until the player
--                  picks another
--   Crafting       the recipe's quality and every optional reagent slot
--                  (embellishments, missives, sparks, crests), through
--                  Variants.BuildCraftedLink, for any recipe the recipe
--                  index knows, learned or not
--
-- Gear a recipe makes opens on Crafting, with a Build as choice to switch to
-- Upgrade Track; any other gear opens on Upgrade Track, and the box says why
-- it has no crafting choices. Every choice rebuilds the preview (debounced; a
-- newer build cancels an older one), which shows the link, its item level,
-- track and size, since a chat line holds 255 bytes. The builder's own
-- changes go the same way: when the recipe index learns the open item's
-- recipe, the preview is dropped and built again on Crafting (a saved
-- record's own recipe; an Upgrade Track choice stays). A preview remembers
-- the choices that built it, and no action takes a preview made from other
-- choices. Save keeps it as a
-- saved variant (Variants/Store.lua); the star favorites it, Link in Chat
-- puts it in chat, and Add to Macro puts its ${v=N} token at the macro
-- window's cursor through the secure apply click (MacroTokens/Editor.lua).
-- Favoriting or adding to a macro saves first. Opening a saved variant
-- restores its choices; Update replaces it with new ones. A captured variant
-- opens with what its link says.
--
-- Every widget is built once, a frame after load, so nothing is created in
-- combat.

local Search = CobysLinkepedia.Search
local Variants = CobysLinkepedia.Variants
local Database = CobysLinkepedia.Database
local Scanner = CobysLinkepedia.Scanner
local Linkify = CobysLinkepedia.Linkify
local MacroTokens = CobysLinkepedia.MacroTokens
local Utilities = CobysLinkepedia.Utilities
local Debug = CobysLinkepedia.Debug
local Events = CobysLinkepedia.Events

local PAD = 10
local ICON_SIZE = 36
local HEADER_HEIGHT = 46
local GAP = 8
local BOX_PAD = 10
local BOX_TOP = 48              -- title and help line above a box's controls
local FIELD_LABEL_HEIGHT = 14   -- a label above its dropdown
local DROPDOWN_HEIGHT = 22
local PICKER_ROWS = 8
local PICKER_ROW_HEIGHT = 20
local PICKER_WIDTH = 260
local PICKER_RESULTS = 60
local SEASON_WIDTH = 180
local TRACK_WIDTH = 124
local RANK_WIDTH = 180
local QUALITY_WIDTH = 120
local QUALITY_X = SEASON_WIDTH + TRACK_WIDTH + RANK_WIDTH + 36   -- beside Rank when the row has room
local FIELD_ROW_GAP = 8
-- The crafting choices: a grid of cells, each a label over its dropdown
-- (recipe when several make the item, quality, then one per optional slot)
local CELL_COLUMNS = 3
local CELL_WIDTH = 196
local CELL_GAP = 14
local CELL_HEIGHT = 44
local MAX_SLOTS = 9
local PREVIEW_HEIGHT = 70
local MENU_SCROLL_HEIGHT = 400
local REBUILD_DELAY = 0.15
local STATUS_SECONDS = 8
local MAX_CHAT_BYTES = 255
local FIRST_REAGENT_MODIFIER = 43   -- a crafted link's data slot N reagent is modifier 43 + N - 1
local DEFAULT_TRACK = "Champion"
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

local frame
local state = {
  itemID = nil,
  mode = "track",          -- "crafted" | "track"
  modeExplicit = false,    -- the mode came from a saved record, a variant's link or the player
  savedID = nil,           -- the saved variant this was opened from, for Update
  openedLink = nil,        -- the variant link this was opened with, if any
  recipes = {},            -- recipe IDs that craft the item
  recipeIndex = 1,
  options = nil,           -- Variants.GetCraftedOptions of the chosen recipe
  missingRecipeID = nil,   -- a saved record's recipe the index does not list
  quality = nil,           -- an index into options.qualities
  reagents = {},           -- [dataSlotIndex] = reagent itemID
  seasonKey = Variants.DEFAULT_SEASON,
  trackName = DEFAULT_TRACK,
  trackRank = nil,         -- nil takes the track's highest rank
  trackQuality = nil,      -- an Enum.ItemQuality in place of the rank's own; nil for its own
  result = nil,            -- { link, ilvl, rank, track, choicesKey } of the last build
  error = nil,
  errorDetail = nil,       -- what the game said about a refused build
  building = false,
}
local buildSerial = 0
local cancelBuild = nil

local function SetColor(fontString, color)
  fontString:SetTextColor(color[1], color[2], color[3])
end

-------------------------------------------------------------------------------
-- Status line
-------------------------------------------------------------------------------
local clearStatus = Utilities.Debounce(STATUS_SECONDS, function()
  if frame then frame.Status:SetText("") end
end)

local function SetStatus(text, ok)
  if not frame then return end
  local color = Utilities.Colors.HIGHLIGHT_WHITE
  if ok == true then
    color = Utilities.Colors.SUCCESS_GREEN
  elseif ok == false then
    color = Utilities.Colors.WARNING_RED
  end
  SetColor(frame.Status, color)
  frame.Status:SetText(text or "")
  clearStatus:Call()
end

-------------------------------------------------------------------------------
-- State helpers
-------------------------------------------------------------------------------

local function ItemRecord(itemID)
  local item = Database.GetItem(itemID)
  if item then return item end
  local name, _, quality = C_Item.GetItemInfo(itemID)
  return { itemID = itemID, name = name or C_Item.GetItemNameByID(itemID) or ("Item " .. itemID), quality = quality or 1 }
end

local function Contains(list, value)
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

local function LoadRecipe(index)
  state.recipeIndex = index
  state.options = state.recipes[index] and Variants.GetCraftedOptions(state.recipes[index]) or nil
  state.reagents = {}
  state.quality = nil
  if state.options then
    Variants.LoadReagents(state.options)
    if #state.options.qualities > 0 then state.quality = #state.options.qualities end
  end
end

-- The crafted choices a captured link carries: its quality and the reagent
-- in each optional slot
local function ChoicesFromCraftedLink(link, rank)
  local options = state.options
  if not options then return end
  if rank and options.qualities[rank] then state.quality = rank end
  local parsed = Database.Capture.ParseItemLink(link)
  for _, modifier in ipairs(parsed and parsed.modifiers or {}) do
    for _, slot in ipairs(options.slots) do
      local reagentID = tonumber(modifier.value)
      if modifier.type == FIRST_REAGENT_MODIFIER + slot.dataSlotIndex - 1 and reagentID and Contains(slot.reagents, reagentID) then
        state.reagents[slot.dataSlotIndex] = reagentID
      end
    end
  end
end

local function RanksNow()
  if not state.itemID then return nil end
  return Variants.GetTrackRanks(state.itemID, state.seasonKey, state.trackName)
end

-- The rank to build: the chosen one, else the highest rank the client names
-- for the track (6 for Midnight Season 2 Myth, which offers 9/6 as well),
-- else the last one offered (a past season's, or the data's last while the
-- item loads). ranks: RanksNow() when the caller already has it
local function EffectiveRank(ranks)
  ranks = ranks or RanksNow()
  local count = ranks and #ranks
  if not count or count == 0 then
    local track = Variants.GetTrack(state.seasonKey, state.trackName)
    count = track and #track.bonusIDs or 1
    ranks = nil
  end
  if state.trackRank and state.trackRank <= count then return state.trackRank end
  return ranks and ranks.max or count
end

-- A season's track by name, else its Champion, else its first
local function TrackIn(seasonKey, name)
  local season = Variants.GetSeason(seasonKey)
  if not season then return nil end
  return Variants.GetTrack(seasonKey, name) or Variants.GetTrack(seasonKey, DEFAULT_TRACK) or season.tracks[1]
end

-- A rank from a saved record or a variant's link, kept only when it is a
-- whole number from 1 up and the track it belongs to is the one TrackIn
-- found (not a stand-in for a track the season lacks); nil otherwise, which
-- builds the track's highest rank
local function AcceptedRank(rank, track, trackName)
  if not Utilities.IsFiniteNumber(rank) or rank < 1 or rank ~= math.floor(rank) then return nil end
  if not track or track.name ~= trackName then return nil end
  return rank
end

-- A quality from a saved record or a variant's link, kept only when a track
-- link can be given it; nil otherwise, which builds the rank's own
local function AcceptedQuality(quality)
  if not Utilities.IsFiniteNumber(quality) or not Variants.QUALITY_BONUS[quality] then return nil end
  return quality
end

-- A quality's name in its colour
local function QualityText(quality)
  local name = Variants.QualityName(quality)
  local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
  return color and color.hex and (color.hex .. name .. "|r") or name
end

local function DefaultMode()
  if #state.recipes > 0 then return "crafted" end
  return "track"
end

-- The choices a build is made from, as one string. A build's result carries
-- the key of the choices that made it; nothing saves or sends a result whose
-- key is not the current one.
local function ChoicesKey()
  if state.mode == "crafted" then
    local slots = {}
    for slotIndex, itemID in pairs(state.reagents) do slots[#slots + 1] = slotIndex .. "=" .. itemID end
    table.sort(slots)
    return ("crafted|%s|%s|%s|%s"):format(tostring(state.itemID), tostring(state.options and state.options.recipeID),
      tostring(state.quality), table.concat(slots, ","))
  end
  return ("track|%s|%s|%s|%s|%s"):format(tostring(state.itemID), tostring(state.seasonKey), tostring(state.trackName),
    tostring(state.trackRank), tostring(state.trackQuality))
end

-- The saved record matching the current build, if any
local function SavedForResult()
  return state.result and Variants.FindByLink(state.result.link) or nil
end

-- What Save and Update store beside the link
local function Meta(result)
  result = result or state.result
  if state.mode == "crafted" then
    local reagents = {}
    for slotIndex, itemID in pairs(state.reagents) do reagents[slotIndex] = itemID end
    return {
      source = "built", kind = "crafted", ilvl = result.ilvl, rank = result.rank,
      choices = { recipeID = state.options and state.options.recipeID, quality = state.quality, reagents = reagents },
    }
  end
  return {
    source = "built", kind = "track", ilvl = result.ilvl, track = result.track,
    choices = { season = state.seasonKey, track = state.trackName, rank = EffectiveRank(), itemQuality = state.trackQuality },
  }
end

-------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------
local Refresh          -- set below
local ChoicesChanged   -- set below

-- The last build, when the choices showing now made it. A result left from
-- other choices (a change that skipped ChoicesChanged) is never paired with
-- them: it is dropped and built again, and the reason says so.
local function CurrentResult()
  local result = state.result
  if not result then return nil, "Build a variant first." end
  if result.choicesKey ~= ChoicesKey() then
    ChoicesChanged()
    return nil, "The choices changed; wait for the new preview."
  end
  return result
end

-- The current build's saved ID, saving it first when it is new
local function EnsureSaved()
  local result, reason = CurrentResult()
  if not result then return nil, reason end
  local saved = Variants.FindByLink(result.link)
  if saved then return saved.id end
  local id, saveReason = Variants.Save(result.link, Meta(result))
  if id then state.savedID = id end
  return id, saveReason
end

local function StopBuild()
  buildSerial = buildSerial + 1
  if cancelBuild then
    local cancel = cancelBuild
    cancelBuild = nil
    cancel()
  end
  state.building = false
end

local function DoBuild()
  StopBuild()
  local serial = buildSerial
  local key = ChoicesKey()
  state.result, state.error = nil, nil
  if not state.itemID then return Refresh() end

  local function Done(result)
    if serial ~= buildSerial then return end
    cancelBuild = nil
    state.building = false
    if result.error then
      state.error, state.errorDetail = result.error, result.detail
    else
      result.choicesKey = key
      state.result = result
    end
    Refresh()
  end

  local cancel
  if state.mode == "crafted" then
    if not state.options then return Refresh() end
    state.building = true
    Refresh()
    cancel = Variants.BuildCraftedLink(state.options, state.quality, state.reagents, Done)
  else
    if not Variants.IsGear(state.itemID) then return Refresh() end
    state.building = true
    Refresh()
    cancel = Variants.BuildTrackLink(state.itemID, state.seasonKey, state.trackName, EffectiveRank(), Done, state.trackQuality)
  end
  if serial == buildSerial and state.building then cancelBuild = cancel end
end

local rebuild = Utilities.Debounce(REBUILD_DELAY, DoBuild)

-------------------------------------------------------------------------------
-- Choices
-------------------------------------------------------------------------------

-- A saved crafted record's choices: the recipe it was built with, then its
-- quality and reagents. A recipe the index does not list (yet, or any more)
-- is never swapped for another one: the builder has no crafting options, so
-- nothing builds, and the crafting box names the missing recipe. Returns
-- whether the recipe was found.
local function ApplySavedCrafted(choices)
  state.missingRecipeID = nil
  for index, recipeID in ipairs(state.recipes) do
    if recipeID == choices.recipeID then
      LoadRecipe(index)
      local options = state.options
      if options then
        if choices.quality and options.qualities[choices.quality] then state.quality = choices.quality end
        local reagents = type(choices.reagents) == "table" and choices.reagents or {}
        for _, slot in ipairs(options.slots) do
          local reagentID = reagents[slot.dataSlotIndex]
          if reagentID and Contains(slot.reagents, reagentID) then
            state.reagents[slot.dataSlotIndex] = reagentID
          end
        end
      end
      return true
    end
  end
  state.options, state.quality, state.reagents = nil, nil, {}
  state.missingRecipeID = choices.recipeID
  return false
end

-- Loads itemID into the builder. variant (a variant entry's variant, or nil)
-- opens a saved or captured variant with its choices. keepDetail leaves the
-- detail pane alone (the Variants suite).
local function SetItem(itemID, variant, keepDetail)
  StopBuild()
  rebuild:Cancel()
  state.itemID = itemID
  state.savedID = variant and variant.savedID or nil
  state.openedLink = variant and variant.link or nil
  state.result, state.error = nil, nil
  state.recipes = itemID and Variants.GetRecipeIDs(itemID) or {}
  state.options, state.quality, state.reagents = nil, nil, {}
  state.missingRecipeID = nil
  state.modeExplicit = false
  if #state.recipes > 0 then LoadRecipe(1) end
  state.trackRank = nil
  state.trackQuality = nil

  local saved = state.savedID and Variants.Get(state.savedID)
  local choices = saved and saved.choices
  if choices and choices.recipeID then
    state.mode = "crafted"
    state.modeExplicit = true
    ApplySavedCrafted(choices)
  elseif choices and choices.track then
    state.mode = "track"
    state.modeExplicit = true
    -- Records saved before seasons were offered are Midnight Season 2's
    state.seasonKey = Variants.GetSeason(choices.season) and choices.season or Variants.DEFAULT_SEASON
    local track = TrackIn(state.seasonKey, choices.track)
    state.trackName = track and track.name or DEFAULT_TRACK
    state.trackRank = AcceptedRank(choices.rank, track, choices.track)
    state.trackQuality = AcceptedQuality(choices.itemQuality)
  elseif variant and variant.link then
    local info = Variants.ReadLinkInfo(variant.link)
    if info and info.kind == "crafted" and #state.recipes > 0 then
      state.mode = "crafted"
      state.modeExplicit = true
      ChoicesFromCraftedLink(variant.link, info.rank)
    elseif info and info.track and info.track.seasonKey and Variants.GetSeason(info.track.seasonKey) then
      state.mode = "track"
      state.modeExplicit = true
      state.seasonKey = info.track.seasonKey
      local track = TrackIn(state.seasonKey, info.track.name)
      state.trackName = track and track.name or DEFAULT_TRACK
      state.trackRank = AcceptedRank(info.track.level, track, info.track.name)
      state.trackQuality = AcceptedQuality(info.qualityOverride)
    else
      state.mode = DefaultMode()
    end
  else
    state.mode = DefaultMode()
  end

  if itemID and not keepDetail and Search.SelectItem then Search.SelectItem(ItemRecord(itemID)) end
  Refresh()
  rebuild:Call()
end

-- After any choice, the player's or the builder's own: the previous build no
-- longer matches the choices, so it is dropped at once (Save and the rest must
-- never pair an old link with new choices) and a new one follows
ChoicesChanged = function()
  StopBuild()
  state.result, state.error = nil, nil
  state.building = true
  Refresh()
  rebuild:Call()
end

local function SetMode(mode)
  state.modeExplicit = true
  if state.mode == mode then return end
  state.mode = mode
  ChoicesChanged()
end

-- The recipe index may know the item's recipes now (it finished while the
-- tab showed, or while it was hidden). They are picked up through the same
-- invalidation as a choice: a saved crafted record gets its own recipe back
-- (or still names it missing); an Upgrade Track choice from a saved record,
-- a link or the player stays, and only gains the recipe for Build as; any
-- other item switches to Crafting, as it would have opened with the index
-- built. Nothing to pick up does nothing.
local function PickUpRecipes()
  if not state.itemID then return end
  if #state.recipes > 0 and not state.missingRecipeID then return end
  local recipes = Variants.GetRecipeIDs(state.itemID)
  if #recipes == 0 then return end
  local hadRecipes = #state.recipes > 0
  state.recipes = recipes

  local saved = state.savedID and Variants.Get(state.savedID)
  local choices = saved and saved.choices
  if choices and choices.recipeID then
    -- Still missing from a list that already had recipes: nothing changed
    if not ApplySavedCrafted(choices) and hadRecipes then return Refresh() end
    if state.mode == "crafted" then return ChoicesChanged() end
    return Refresh()
  end
  LoadRecipe(1)
  if state.modeExplicit and state.mode == "track" then
    return Refresh()
  end
  state.mode = "crafted"
  local info = state.openedLink and Variants.ReadLinkInfo(state.openedLink)
  if info and info.kind == "crafted" then ChoicesFromCraftedLink(state.openedLink, info.rank) end
  ChoicesChanged()
end

local function SetRecipe(index)
  LoadRecipe(index)
  ChoicesChanged()
end

local function SetQuality(index)
  state.quality = index
  ChoicesChanged()
end

local function SetReagent(slot, itemID)
  state.reagents[slot.dataSlotIndex] = itemID
  ChoicesChanged()
end

local function SetSeason(key)
  state.seasonKey = key
  local track = TrackIn(key, state.trackName)
  state.trackName = track and track.name or DEFAULT_TRACK
  state.trackRank = nil
  ChoicesChanged()
end

local function SetTrack(name)
  state.trackName = name
  state.trackRank = nil
  ChoicesChanged()
end

local function SetRank(rank)
  state.trackRank = rank
  ChoicesChanged()
end

local function SetTrackQuality(quality)
  state.trackQuality = quality
  ChoicesChanged()
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

local function RefreshHeader()
  if not state.itemID then
    frame.Icon:SetTexture(QUESTION_MARK)
    frame.ItemName:SetText("No item chosen")
    SetColor(frame.ItemName, Utilities.Colors.DISABLED_GRAY)
    frame.ItemInfo:SetText("Find gear with the search box on the right, or pick it in Results and click Build Variant.")
    return
  end
  local item = ItemRecord(state.itemID)
  local _, itemType, itemSubType, equipLoc, icon = C_Item.GetItemInfoInstant(state.itemID)
  frame.Icon:SetTexture(icon or QUESTION_MARK)
  frame.ItemName:SetText(item.name)
  local qc = ITEM_QUALITY_COLORS[item.quality or 1]
  if qc then frame.ItemName:SetTextColor(qc.r, qc.g, qc.b) end

  local parts = { "Item " .. state.itemID }
  local slot = equipLoc and equipLoc ~= "" and _G[equipLoc]
  if type(slot) == "string" and slot ~= "" then parts[#parts + 1] = slot end
  if itemSubType and itemSubType ~= "" and itemSubType ~= slot then parts[#parts + 1] = itemSubType end
  if #state.recipes > 0 then parts[#parts + 1] = "crafted" end
  local editing = state.savedID and Variants.Get(state.savedID)
  if editing then parts[#parts + 1] = "editing saved variant " .. editing.id end
  frame.ItemInfo:SetText(table.concat(parts, "  |  "))
end

-- Shows the controls of the current mode, sizes the box around them, and
-- fills the help line
local function RefreshChoices()
  local box = frame.Choices
  local hasItem = state.itemID ~= nil
  box:SetShown(hasItem)
  if not hasItem then return end

  local canCraft = #state.recipes > 0
  frame.ModeLabel:SetShown(canCraft)
  frame.ModeDropdown:SetShown(canCraft)
  if canCraft then frame.ModeDropdown:GenerateMenu() end
  frame.BoxHelp:ClearAllPoints()
  frame.BoxHelp:SetPoint("TOPLEFT", frame.BoxTitle, "BOTTOMLEFT", 0, -5)
  if canCraft then
    frame.BoxHelp:SetPoint("RIGHT", frame.ModeLabel, "LEFT", -12, 0)
  else
    frame.BoxHelp:SetPoint("RIGHT", box, "RIGHT", -BOX_PAD, 0)
  end

  local trackMode = state.mode == "track"
  local crafted = state.mode == "crafted" and state.options ~= nil
  frame.TrackPanel:SetShown(trackMode)
  frame.CraftedPanel:SetShown(crafted)
  frame.NoCrafting:SetShown(state.mode == "crafted" and not crafted)

  local height = BOX_TOP
  if trackMode then
    frame.BoxTitle:SetText("Upgrade Track")
    frame.BoxHelp:SetText("Any season, track and rank, and any quality above the rank's own. The game accepts any track on any gear, so whether this item drops on it is yours to check.")
    frame.SeasonDropdown:GenerateMenu()
    frame.TrackDropdown:GenerateMenu()
    frame.RankDropdown:GenerateMenu()
    frame.TrackQualityDropdown:GenerateMenu()

    -- Quality beside Rank when the row has room, else on a row of its own
    local fieldHeight = FIELD_LABEL_HEIGHT + DROPDOWN_HEIGHT
    local width = frame.TrackPanel:GetWidth()
    local rows = (width == 0 or width >= QUALITY_X + QUALITY_WIDTH) and 1 or 2
    frame.TrackQualityLabel:ClearAllPoints()
    if rows == 1 then
      frame.TrackQualityLabel:SetPoint("TOPLEFT", QUALITY_X, 0)
    else
      frame.TrackQualityLabel:SetPoint("TOPLEFT", 0, -(fieldHeight + FIELD_ROW_GAP))
    end
    local fieldsHeight = rows * fieldHeight + (rows - 1) * FIELD_ROW_GAP
    frame.TrackPanel:SetHeight(fieldsHeight + 24)
    frame.TrackNote:ClearAllPoints()
    frame.TrackNote:SetPoint("TOPLEFT", frame.TrackPanel, "TOPLEFT", 0, -(fieldsHeight + FIELD_ROW_GAP))
    frame.TrackNote:SetPoint("RIGHT", box, "RIGHT", -BOX_PAD, 0)
    height = height + fieldsHeight

    -- Where embellishments and missives would go, when they cannot
    local note
    if not canCraft then
      local status = Scanner.GetRecipeScanStatus()
      if status.complete then
        note = "Crafted quality, embellishments and missives come from a crafting recipe, and no recipe the game lists makes this item."
      else
        note = ("Crafting choices appear here for crafted gear once the recipe index is built (%d%%)."):format(math.floor(status.fraction * 100))
      end
    end
    -- A past season's track: the game keeps the item level but no longer
    -- describes the track
    local result = state.result
    if not note and result and result.track and result.track.fromData then
      note = "The game no longer describes this season's tracks, so the item keeps the rank's item level but may not name its track."
    end
    frame.TrackNote:SetText(note or "")
    frame.TrackNote:SetShown(note ~= nil)
    if note then height = height + 22 end
  elseif crafted then
    local options = state.options
    frame.BoxTitle:SetText("Crafting")
    frame.BoxHelp:SetText(("Recipe: %s%s. Choose a quality and any optional reagents; * marks a slot the recipe requires."):format(
      options.name or options.recipeID, options.learned and "" or " (not learned)"))

    -- The visible cells, in order, placed left to right and down, as many
    -- columns as the width allows (the detail pane's width changes it)
    local width = frame.CraftedPanel:GetWidth()
    local columns = width > 0 and math.floor((width + CELL_GAP) / (CELL_WIDTH + CELL_GAP)) or CELL_COLUMNS
    columns = math.max(1, math.min(CELL_COLUMNS, columns))
    local cells = {}
    local function Place(label, dropdown, shown)
      label:SetShown(shown)
      dropdown:SetShown(shown)
      if not shown then return end
      local index = #cells
      cells[index + 1] = label
      label:ClearAllPoints()
      label:SetPoint("TOPLEFT", (index % columns) * (CELL_WIDTH + CELL_GAP), -math.floor(index / columns) * CELL_HEIGHT)
      dropdown:GenerateMenu()
    end
    Place(frame.RecipeLabel, frame.RecipeDropdown, #state.recipes > 1)
    Place(frame.QualityLabel, frame.QualityDropdown, #options.qualities > 0)
    local slots = options.slots
    for i, row in ipairs(frame.SlotRows) do
      local slot = slots[i]
      row.slot = slot
      if slot then
        row.Label:SetText((slot.text or "Reagent") .. (slot.required and " *" or ""))
      end
      Place(row.Label, row.Dropdown, slot ~= nil)
    end

    local rows = math.ceil(#cells / columns)
    local note = ""
    if #slots == 0 then
      note = "This recipe takes no optional reagents."
    elseif #slots > #frame.SlotRows then
      note = ("%d more slots are not shown."):format(#slots - #frame.SlotRows)
    end
    frame.SlotNote:SetText(note)
    frame.SlotNote:ClearAllPoints()
    frame.SlotNote:SetPoint("TOPLEFT", 0, -rows * CELL_HEIGHT)
    height = height + rows * CELL_HEIGHT + (note ~= "" and 16 or 0)
  else
    frame.BoxTitle:SetText("Crafting")
    frame.BoxHelp:SetText("")
    local status = Scanner.GetRecipeScanStatus()
    frame.ScanButton:Hide()
    if status.active then
      local text = ("The recipe index is being built: %d%%"):format(math.floor(status.fraction * 100))
      if status.waiting then
        text = text .. " (waiting: " .. status.waiting .. ")"
      elseif status.eta then
        text = text .. " (" .. Utilities.FormatDuration(status.eta) .. " left)"
      end
      frame.NoCraftingText:SetText(text .. ". Crafting choices appear when it finishes.")
    elseif state.missingRecipeID then
      frame.NoCraftingText:SetText(("This saved variant was built with recipe %s, which the recipe index does not list, so its crafting choices cannot be rebuilt."):format(
        tostring(state.missingRecipeID)))
      frame.ScanButton:SetShown(not status.complete)
    elseif status.complete then
      frame.NoCraftingText:SetText("No recipe the game lists makes this item, so it takes no quality, embellishments or missives.")
    else
      frame.NoCraftingText:SetText("Crafting choices need the recipe index, built once per game patch in under a minute.")
      frame.ScanButton:Show()
    end
    height = height + math.max(20, math.ceil(frame.NoCraftingText:GetStringHeight()) + 6)
      + (frame.ScanButton:IsShown() and 30 or 0)
  end

  box:SetHeight(height + BOX_PAD)
end

local function RefreshPreview()
  local p = frame.Preview
  p:SetShown(state.itemID ~= nil)
  local result = state.result
  if result then
    p.Icon:SetTexture(select(5, C_Item.GetItemInfoInstant(state.itemID)) or QUESTION_MARK)
    p.Name:SetText(result.link)
    local parts = {}
    if result.ilvl then parts[#parts + 1] = "Item level " .. result.ilvl end
    if result.track then parts[#parts + 1] = Variants.TrackText(result.track) end
    local bytes = #result.link
    parts[#parts + 1] = bytes > MAX_CHAT_BYTES and Utilities.WrapColor("FF4D4D", bytes .. " bytes, too long for one chat line")
      or (bytes .. " bytes")
    p.Info:SetText(table.concat(parts, "  |  "))
    p.LinkBox:SetValue((result.link:gsub("|", "||")), result.link)
  else
    p.Icon:SetTexture(QUESTION_MARK)
    if state.building then
      p.Name:SetText("Building...")
    elseif state.error then
      p.Name:SetText(Utilities.WrapColor("FF4D4D", state.error))
    else
      p.Name:SetText("Choose above to build a variant.")
    end
    -- What the game said about a refused build
    p.Info:SetText(state.error and state.errorDetail or "")
    p.LinkBox:SetValue("", false)
  end
end

local function RefreshActions()
  local hasItem = state.itemID ~= nil
  frame.Actions:SetShown(hasItem)
  if not hasItem then return end
  local result = state.result
  local saved = SavedForResult()
  local editing = state.savedID and Variants.Get(state.savedID)

  frame.SaveButton:SetEnabled(result ~= nil and saved == nil)
  frame.SaveButton:SetText(saved and ("Saved as " .. saved.id) or "Save")
  local showUpdate = result ~= nil and saved == nil and editing ~= nil
  frame.UpdateButton:SetShown(showUpdate)
  if editing then frame.UpdateButton:SetText("Update " .. editing.id) end
  frame.Star:ClearAllPoints()
  frame.Star:SetPoint("LEFT", showUpdate and frame.UpdateButton or frame.SaveButton, "RIGHT", 8, 0)
  frame.Star:SetShown(result ~= nil)
  frame.Star:Refresh()
  frame.LinkButton:SetEnabled(result ~= nil)
  frame.MacroButton:SetEnabled(result ~= nil)
  frame.DeleteButton:SetEnabled(saved ~= nil)
end

Refresh = function()
  if not frame then return end
  RefreshHeader()
  RefreshChoices()
  RefreshPreview()
  RefreshActions()
end

-------------------------------------------------------------------------------
-- Item picker: gear search without leaving the tab
-------------------------------------------------------------------------------
local cancelPick = nil   -- cancels the picker's search still running

local function StopPick()
  if cancelPick then
    local cancel = cancelPick
    cancelPick = nil
    cancel()
  end
end

local function HidePicker()
  StopPick()
  frame.PickerList:Hide()
end

local function ShowPicked(matches)
  local rows = frame.PickerRows
  local found = 0
  -- Crafted gear (the kind with quality, embellishment and missive choices)
  -- first within each match group, and tagged
  local crafted = {}
  for _, item in ipairs(matches) do
    crafted[item.itemID] = Database.HasRecipesForItem(item.itemID)
  end
  table.sort(matches, function(a, b)
    if (a.isSubstring and true or false) ~= (b.isSubstring and true or false) then return not a.isSubstring end
    if crafted[a.itemID] ~= crafted[b.itemID] then return crafted[a.itemID] end
    if a.quality ~= b.quality then return a.quality > b.quality end
    if a.name ~= b.name then return a.name < b.name end
    return a.itemID < b.itemID
  end)
  for _, item in ipairs(matches) do
    if Variants.IsGear(item.itemID) then
      found = found + 1
      local row = rows[found]
      row.itemID = item.itemID
      row.Icon:SetTexture(select(5, C_Item.GetItemInfoInstant(item.itemID)) or QUESTION_MARK)
      row.Name:SetText(item.name)
      row.Tag:SetText(crafted[item.itemID] and "crafted" or "")
      local qc = ITEM_QUALITY_COLORS[item.quality or 1]
      if qc then row.Name:SetTextColor(qc.r, qc.g, qc.b) end
      row:Show()
      if found == #rows then break end
    end
  end
  for i = found + 1, #rows do
    rows[i].itemID = nil
    rows[i]:Hide()
  end
  frame.PickerEmpty:SetShown(found == 0)
  frame.PickerList:SetHeight(math.max(found, 1) * PICKER_ROW_HEIGHT + 8)
  frame.PickerList:Show()
end

-- Searched by class, so non-gear cannot use up the result cap: one search per
-- class, each over frames, one after the other. The list on screen stays
-- until both end.
local PICK_CLASSES = { Enum.ItemClass.Weapon, Enum.ItemClass.Armor }

local function DoPick(text)
  StopPick()
  if not text or strtrim(text) == "" then return HidePicker() end
  local matches = {}
  local function Next(i)
    if i > #PICK_CLASSES then
      cancelPick = nil
      ShowPicked(matches)
      return
    end
    local finished = false
    local cancel = Database.SearchAsync(text, PICKER_RESULTS, { type = PICK_CLASSES[i] }, function(results)
      finished = true
      for _, item in ipairs(results) do
        matches[#matches + 1] = item
      end
      Next(i + 1)
    end)
    if not finished then cancelPick = cancel end
  end
  Next(1)
end

-------------------------------------------------------------------------------
-- Build the tab
-------------------------------------------------------------------------------
local function CreateFieldLabel(parent, text)
  local label = parent:CreateFontString(nil, "OVERLAY", Utilities.Fonts.SMALL)
  SetColor(label, Utilities.Colors.STATUS_GOLD)
  label:SetText(text)
  return label
end

-- A labelled dropdown: the label above, the dropdown under it
local function CreateField(parent, text, width, x)
  local label = CreateFieldLabel(parent, text)
  label:SetPoint("TOPLEFT", x, 0)
  local dropdown = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  dropdown:SetSize(width, DROPDOWN_HEIGHT)
  dropdown:SetPoint("TOPLEFT", label, "TOPLEFT", 0, -FIELD_LABEL_HEIGHT)
  return label, dropdown
end

local function BuildHeader()
  frame.Icon = frame:CreateTexture(nil, "ARTWORK")
  frame.Icon:SetSize(ICON_SIZE, ICON_SIZE)
  frame.Icon:SetPoint("TOPLEFT", PAD, -PAD + 4)
  frame.IconButton = CreateFrame("Button", nil, frame)
  frame.IconButton:SetAllPoints(frame.Icon)
  CobySuite_CobysLinkepedia.UI.AddItemTooltip(frame.IconButton, function()
    return state.itemID
  end, "ANCHOR_RIGHT", Search.ItemTooltipOptions)

  frame.Picker = CobySuite_CobysLinkepedia.UI.CreateSearchBox(frame, {
    width = PICKER_WIDTH - 20,
    point = { "TOPRIGHT", frame, "TOPRIGHT", -PAD, -PAD },
    maxLetters = 100,
    debounce = 0.2,
    placeholder = "Find gear to build (crafted first)",
    onSearch = function(text) DoPick(text) end,
  })

  frame.ItemName = frame:CreateFontString(nil, "OVERLAY", Utilities.Fonts.BODY)
  frame.ItemName:SetPoint("TOPLEFT", frame.Icon, "TOPRIGHT", 8, -2)
  frame.ItemName:SetPoint("RIGHT", frame.Picker, "LEFT", -16, 0)
  frame.ItemName:SetJustifyH("LEFT")
  frame.ItemName:SetWordWrap(false)

  frame.ItemInfo = frame:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  frame.ItemInfo:SetPoint("TOPLEFT", frame.ItemName, "BOTTOMLEFT", 0, -4)
  frame.ItemInfo:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
  frame.ItemInfo:SetJustifyH("LEFT")
  frame.ItemInfo:SetWordWrap(false)
  SetColor(frame.ItemInfo, Utilities.Colors.LABEL_GRAY)

  -- The picker's results float over everything below: a higher strata than
  -- the dropdowns under it, and a solid layer inside the border, since the
  -- backdrop's texture is see-through by itself (as the autocomplete list's)
  local list = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  list:SetWidth(PICKER_WIDTH)
  list:SetPoint("TOPRIGHT", frame.Picker, "BOTTOMRIGHT", 0, -2)
  list:SetFrameStrata("DIALOG")
  list:SetBackdrop(Utilities.Backdrops.CONTENT)
  local bg = Utilities.Colors.DIALOG_BG
  list:SetBackdropColor(bg[1], bg[2], bg[3], 1)
  local solid = list:CreateTexture(nil, "BACKGROUND", nil, -8)
  solid:SetPoint("TOPLEFT", 3, -3)
  solid:SetPoint("BOTTOMRIGHT", -3, 3)
  solid:SetColorTexture(bg[1], bg[2], bg[3], 1)
  list:EnableMouse(true)
  list:Hide()
  frame.PickerList = list

  frame.PickerEmpty = list:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  frame.PickerEmpty:SetPoint("TOPLEFT", 8, -8)
  frame.PickerEmpty:SetText("No weapons or armor match.")
  SetColor(frame.PickerEmpty, Utilities.Colors.DISABLED_GRAY)

  frame.PickerRows = {}
  for i = 1, PICKER_ROWS do
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(PICKER_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * PICKER_ROW_HEIGHT)
    row:SetPoint("RIGHT", -4, 0)
    row.Highlight = CobySuite_CobysLinkepedia.UI.AddHoverHighlight(row)
    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetSize(16, 16)
    row.Icon:SetPoint("LEFT", 4, 0)
    row.Tag = row:CreateFontString(nil, "OVERLAY", Utilities.Fonts.SMALL)
    row.Tag:SetPoint("RIGHT", -4, 0)
    SetColor(row.Tag, Utilities.Colors.STATUS_GOLD)
    row.Name = row:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
    row.Name:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)
    row.Name:SetPoint("RIGHT", row.Tag, "LEFT", -6, 0)
    row.Name:SetJustifyH("LEFT")
    row.Name:SetWordWrap(false)
    row:SetScript("OnClick", function(self)
      if not self.itemID then return end
      HidePicker()
      frame.Picker:ClearSearch()
      frame.Picker:ClearFocus()
      SetItem(self.itemID)
    end)
    CobySuite_CobysLinkepedia.UI.AddItemTooltip(row, function(self) return self.itemID end, "ANCHOR_RIGHT", Search.ItemTooltipOptions)
    row:Hide()
    frame.PickerRows[i] = row
  end
end

local function BuildTrackPanel(box)
  local panel = CreateFrame("Frame", nil, box)
  panel:SetPoint("TOPLEFT", BOX_PAD, -BOX_TOP)
  panel:SetPoint("RIGHT", -BOX_PAD, 0)
  panel:SetHeight(FIELD_LABEL_HEIGHT + DROPDOWN_HEIGHT + 24)
  frame.TrackPanel = panel

  local _
  _, frame.SeasonDropdown = CreateField(panel, "Season", SEASON_WIDTH, 0)
  frame.SeasonDropdown:SetupMenu(function(_, root)
    for _, season in ipairs(Variants.GetSeasons()) do
      root:CreateRadio(season.name, function() return state.seasonKey == season.key end,
        function() SetSeason(season.key) end)
    end
  end)

  _, frame.TrackDropdown = CreateField(panel, "Track", TRACK_WIDTH, SEASON_WIDTH + 12)
  frame.TrackDropdown:SetupMenu(function(_, root)
    local season = Variants.GetSeason(state.seasonKey)
    for _, track in ipairs(season and season.tracks or {}) do
      root:CreateRadio(track.name, function() return state.trackName == track.name end,
        function() SetTrack(track.name) end)
    end
  end)

  _, frame.RankDropdown = CreateField(panel, "Rank", RANK_WIDTH, SEASON_WIDTH + TRACK_WIDTH + 24)
  frame.RankDropdown:SetupMenu(function(_, root)
    local ranks = RanksNow()
    local current = EffectiveRank(ranks or {})
    local track = Variants.GetTrack(state.seasonKey, state.trackName)
    if not ranks or #ranks == 0 then
      -- The item has not loaded: offer the data's ranks without item levels
      ranks = {}
      for rank = 1, track and #track.bonusIDs or 0 do ranks[rank] = { rank = rank } end
    end
    for _, entry in ipairs(ranks) do
      local text = ("%d / %d"):format(entry.rank, ranks.max or #ranks)
      if entry.ilvl then text = text .. ("   item level %d"):format(entry.ilvl) end
      root:CreateRadio(text, function() return current == entry.rank end,
        function() SetRank(entry.rank) end)
    end
  end)

  -- The rank's own quality first, as the default and named when the client
  -- can say, then the higher ones a track link can be given (the client keeps
  -- the higher of two qualities, so a lower one never lands). Every quality
  -- shows while the client cannot say what the rank's own is, and a build
  -- that asks for a lower one says why. Placed by RefreshChoices.
  frame.TrackQualityLabel, frame.TrackQualityDropdown = CreateField(panel, "Quality", QUALITY_WIDTH, QUALITY_X)
  frame.TrackQualityDropdown:SetupMenu(function(_, root)
    local own = state.itemID and Variants.GetTrackOwnQuality(state.itemID, state.seasonKey, state.trackName, EffectiveRank())
    root:CreateRadio(own and (QualityText(own) .. " (default)") or "Default",
      function() return state.trackQuality == nil or state.trackQuality == own end,
      function() SetTrackQuality(nil) end)
    for _, quality in ipairs(Variants.GetTrackQualities(own)) do
      root:CreateRadio(QualityText(quality), function() return state.trackQuality == quality end,
        function() SetTrackQuality(quality) end)
    end
  end)

  frame.TrackNote = panel:CreateFontString(nil, "OVERLAY", Utilities.Fonts.SMALL)
  frame.TrackNote:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -(FIELD_LABEL_HEIGHT + DROPDOWN_HEIGHT + 8))
  frame.TrackNote:SetPoint("RIGHT", box, "RIGHT", -BOX_PAD, 0)
  frame.TrackNote:SetJustifyH("LEFT")
  frame.TrackNote:SetWordWrap(false)
  SetColor(frame.TrackNote, Utilities.Colors.LABEL_GRAY)
  panel:Hide()
end

local function BuildCraftedPanel(box)
  local panel = CreateFrame("Frame", nil, box)
  panel:SetPoint("TOPLEFT", BOX_PAD, -BOX_TOP)
  panel:SetPoint("RIGHT", -BOX_PAD, 0)
  panel:SetHeight(4 * CELL_HEIGHT + 16)
  frame.CraftedPanel = panel

  frame.RecipeLabel, frame.RecipeDropdown = CreateField(panel, "Recipe", CELL_WIDTH, 0)
  frame.RecipeDropdown:SetupMenu(function(_, root)
    for index, recipeID in ipairs(state.recipes) do
      local okInfo, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
      local name = okInfo and info and info.name or ("Recipe " .. recipeID)
      if okInfo and info and not info.learned then name = name .. " (not learned)" end
      root:CreateRadio(name, function() return state.recipeIndex == index end, function() SetRecipe(index) end)
    end
  end)

  frame.QualityLabel, frame.QualityDropdown = CreateField(panel, "Quality", CELL_WIDTH, 0)
  frame.QualityDropdown:SetupMenu(function(_, root)
    local options = state.options
    for index, quality in ipairs(options and options.qualities or {}) do
      local icon = quality.atlas and (CreateAtlasMarkup(quality.atlas, 16, 16) .. " ") or ""
      root:CreateRadio(icon .. "Quality " .. index, function() return state.quality == index end,
        function() SetQuality(index) end)
    end
  end)

  frame.SlotRows = {}
  for i = 1, MAX_SLOTS do
    local row = {}
    -- Placed by RefreshChoices; the dropdown follows its label
    row.Label, row.Dropdown = CreateField(panel, "", CELL_WIDTH, 0)
    row.Label:SetWidth(CELL_WIDTH)
    row.Label:SetJustifyH("LEFT")
    row.Label:SetWordWrap(false)
    row.Dropdown:SetDefaultText("None")
    row.Dropdown:SetupMenu(function(_, root)
      local slot = row.slot
      if not slot then return end
      root:SetScrollMode(MENU_SCROLL_HEIGHT)
      root:CreateRadio("None", function() return state.reagents[slot.dataSlotIndex] == nil end,
        function() SetReagent(slot, nil) end)
      for _, reagentID in ipairs(slot.reagents) do
        local name = C_Item.GetItemNameByID(reagentID) or ("Item " .. reagentID)
        local radio = root:CreateRadio(name, function() return state.reagents[slot.dataSlotIndex] == reagentID end,
          function() SetReagent(slot, reagentID) end)
        radio:SetTooltip(function(tooltip) tooltip:SetItemByID(reagentID) end)
      end
    end)
    row.Label:Hide()
    row.Dropdown:Hide()
    frame.SlotRows[i] = row
  end

  frame.SlotNote = panel:CreateFontString(nil, "OVERLAY", Utilities.Fonts.SMALL)
  SetColor(frame.SlotNote, Utilities.Colors.LABEL_GRAY)
  panel:Hide()
end

local function BuildNoCrafting(box)
  local panel = CreateFrame("Frame", nil, box)
  panel:SetPoint("TOPLEFT", BOX_PAD, -BOX_TOP + 16)
  panel:SetPoint("RIGHT", -BOX_PAD, 0)
  panel:SetHeight(60)
  frame.NoCrafting = panel

  frame.NoCraftingText = panel:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  frame.NoCraftingText:SetPoint("TOPLEFT", 0, 0)
  frame.NoCraftingText:SetPoint("RIGHT", 0, 0)
  frame.NoCraftingText:SetJustifyH("LEFT")
  SetColor(frame.NoCraftingText, Utilities.Colors.LABEL_GRAY)

  frame.ScanButton = Utilities.CreateButton(panel, {
    text = "Index Recipes", size = { 120, 22 }, fontSize = 11,
    point = { "TOPLEFT", frame.NoCraftingText, "BOTTOMLEFT", 0, -8 },
    tooltip = "Look through the game's recipes for the ones that craft weapons and armor (/lp recipes)",
    onClick = function()
      Scanner.StartRecipeScan(true)
      Refresh()
    end,
  })
  panel:Hide()
end

local function BuildChoices()
  local box = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  box:SetPoint("TOPLEFT", PAD, -HEADER_HEIGHT - 4)
  box:SetPoint("RIGHT", -PAD, 0)
  box:SetHeight(120)
  box:SetBackdrop(Utilities.Backdrops.CONTENT)
  local bg = Utilities.Colors.CONTENT_BG
  box:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
  frame.Choices = box

  frame.BoxTitle = box:CreateFontString(nil, "OVERLAY", Utilities.Fonts.BODY)
  frame.BoxTitle:SetPoint("TOPLEFT", BOX_PAD, -9)
  SetColor(frame.BoxTitle, Utilities.Colors.STATUS_GOLD)

  frame.BoxHelp = box:CreateFontString(nil, "OVERLAY", Utilities.Fonts.SMALL)
  frame.BoxHelp:SetPoint("TOPLEFT", frame.BoxTitle, "BOTTOMLEFT", 0, -5)
  frame.BoxHelp:SetPoint("RIGHT", box, "RIGHT", -BOX_PAD, 0)
  frame.BoxHelp:SetJustifyH("LEFT")
  frame.BoxHelp:SetWordWrap(false)
  SetColor(frame.BoxHelp, Utilities.Colors.LABEL_GRAY)

  -- Build as: only for gear a recipe makes, which can also be put on a track
  frame.ModeDropdown = CreateFrame("DropdownButton", nil, box, "WowStyle1DropdownTemplate")
  frame.ModeDropdown:SetSize(150, DROPDOWN_HEIGHT)
  frame.ModeDropdown:SetPoint("TOPRIGHT", -BOX_PAD, -6)
  frame.ModeDropdown:SetupMenu(function(_, root)
    root:CreateRadio("Crafting", function() return state.mode == "crafted" end, function() SetMode("crafted") end)
    root:CreateRadio("Upgrade Track", function() return state.mode == "track" end, function() SetMode("track") end)
  end)
  frame.ModeLabel = CreateFieldLabel(box, "Build as")
  frame.ModeLabel:SetPoint("RIGHT", frame.ModeDropdown, "LEFT", -8, 0)

  BuildTrackPanel(box)
  BuildCraftedPanel(box)
  BuildNoCrafting(box)
  box:Hide()
end

local function BuildPreview()
  local p = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  p:SetHeight(PREVIEW_HEIGHT)
  p:SetPoint("TOPLEFT", frame.Choices, "BOTTOMLEFT", 0, -GAP)
  p:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
  p:SetBackdrop(Utilities.Backdrops.CONTENT)
  local bg = Utilities.Colors.CONTENT_BG
  p:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
  frame.Preview = p

  p.Icon = p:CreateTexture(nil, "ARTWORK")
  p.Icon:SetSize(30, 30)
  p.Icon:SetPoint("TOPLEFT", 8, -8)
  p.IconButton = CreateFrame("Button", nil, p)
  p.IconButton:SetAllPoints(p.Icon)
  CobySuite_CobysLinkepedia.UI.AddItemTooltip(p.IconButton, function()
    return state.result and state.result.link
  end, "ANCHOR_RIGHT", Search.ItemTooltipOptions)

  p.Name = p:CreateFontString(nil, "OVERLAY", Utilities.Fonts.BODY)
  p.Name:SetPoint("TOPLEFT", p.Icon, "TOPRIGHT", 8, 0)
  p.Name:SetPoint("RIGHT", -8, 0)
  p.Name:SetJustifyH("LEFT")
  p.Name:SetWordWrap(false)

  p.Info = p:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  p.Info:SetPoint("TOPLEFT", p.Name, "BOTTOMLEFT", 0, -3)
  p.Info:SetPoint("RIGHT", -8, 0)
  p.Info:SetJustifyH("LEFT")
  p.Info:SetWordWrap(false)
  SetColor(p.Info, Utilities.Colors.LABEL_GRAY)

  -- The link as a string, readable (pipes doubled); the copy icon selects the
  -- raw link for Ctrl+C, as the detail pane's field does
  p.LinkBox = CobySuite_CobysLinkepedia.UI.CreateCopyField(p, {
    tooltip = "Select the raw link string so Ctrl+C copies it",
    point = { "BOTTOMLEFT", 14, 6 },
  })
  p.LinkBox:SetPoint("RIGHT", -34, 0)
  p:Hide()
end

local function BuildActions()
  local actions = CreateFrame("Frame", nil, frame)
  actions:SetHeight(22)
  actions:SetPoint("TOPLEFT", frame.Preview, "BOTTOMLEFT", 0, -GAP)
  actions:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
  frame.Actions = actions

  frame.SaveButton = Utilities.CreateButton(actions, {
    text = "Save", size = { 100, 22 }, fontSize = 11,
    point = { "LEFT", actions, "LEFT", 0, 0 },
    tooltip = "Keep this variant. Saved variants get a number that ${v=N} tokens link.",
    onClick = function()
      local result, notReady = CurrentResult()
      if not result then return SetStatus(notReady, false) end
      local id, reason = Variants.Save(result.link, Meta(result))
      if id then
        state.savedID = id
        SetStatus(("Saved as variant %d: %s links it in chat and macros."):format(id, Linkify.FormatVariantToken(id)), true)
      else
        SetStatus(reason, false)
      end
    end,
  })

  frame.UpdateButton = Utilities.CreateButton(actions, {
    text = "Update", size = { 90, 22 }, fontSize = 11,
    point = { "LEFT", frame.SaveButton, "RIGHT", 4, 0 },
    tooltip = "Replace the saved variant you opened with these choices; macros using its token link the new one",
    onClick = function()
      if not state.savedID then return end
      local result, notReady = CurrentResult()
      if not result then return SetStatus(notReady, false) end
      local ok, reason = Variants.Update(state.savedID, result.link, Meta(result))
      if ok then
        SetStatus(("Updated saved variant %d."):format(state.savedID), true)
      else
        SetStatus(reason, false)
      end
    end,
  })
  frame.UpdateButton:Hide()

  frame.Star = CobySuite_CobysLinkepedia.UI.CreateFavoriteStar(actions, {
    height = 18,
    point = { "LEFT", frame.SaveButton, "RIGHT", 8, 0 },
    tooltipOn = "Remove from Favorites",
    tooltipOff = "Add to Favorites (saves it)",
    isFavorite = function()
      local saved = SavedForResult()
      return saved ~= nil and saved.favorite == true
    end,
    onToggle = function(on)
      local id, reason = EnsureSaved()
      if not id then return SetStatus(reason, false) end
      Variants.SetFavorite(id, on)
    end,
  })
  frame.Star:Hide()

  frame.LinkButton = Utilities.CreateButton(actions, {
    text = "Link in Chat", size = { 100, 22 }, fontSize = 11,
    point = { "LEFT", frame.Star, "RIGHT", 8, 0 },
    tooltip = "Put this variant's link in the chat box",
    onClick = function()
      local result, notReady = CurrentResult()
      if not result then return SetStatus(notReady, false) end
      Search.PutInChat(result.link)
      Search.AddToHistory(state.itemID)
      if #result.link > MAX_CHAT_BYTES then
        SetStatus("This link is longer than a chat line holds, so it cannot be sent.", false)
      end
    end,
  })

  -- A secure apply button: the click itself changes the macro
  frame.MacroButton = Utilities.CreateButton(actions, {
    text = "Add to Macro", size = { 110, 22 }, fontSize = 11,
    point = { "LEFT", frame.LinkButton, "RIGHT", 4, 0 },
    tooltip = "With the macro window open (/macro), add this variant's ${v=N} token at the macro's cursor (saves it). The macro window closes and reopens for a moment.",
  })
  MacroTokens.AttachSecureApply(frame.MacroButton, function()
    local index, reason = MacroTokens.GetEditTarget()
    if not index then
      SetStatus(reason, false)
      return false, reason
    end
    local result, notReady = CurrentResult()
    if not result then
      SetStatus(notReady, false)
      return false, notReady
    end
    -- Staged with the number the variant has or will get, so a macro with no
    -- room refuses before anything is saved
    local saved = Variants.FindByLink(result.link)
    local ok, change = MacroTokens.StageInsertVariant(saved and saved.id or Variants.PeekNextID())
    if not ok then
      SetStatus(change, false)
      return false, change
    end
    local id, saveReason = EnsureSaved()
    if not id then
      SetStatus(saveReason, false)
      return false, saveReason
    end
    ok, change = MacroTokens.StageInsertVariant(id)
    if ok and change then
      SetStatus(("Added %s to the macro."):format(Linkify.FormatVariantToken(id)), true)
    elseif not ok then
      SetStatus(change, false)
    end
    return ok, change
  end)

  frame.DeleteButton = Utilities.CreateButton(actions, {
    text = "Delete", size = { 70, 22 }, fontSize = 11,
    point = { "RIGHT", actions, "RIGHT", 0, 0 },
    tooltip = "Delete this saved variant",
    onClick = function()
      local saved = SavedForResult()
      if not saved then return end
      if Search.DeleteSavedVariant(saved.id) then
        SetStatus(("Deleted saved variant %d."):format(saved.id), true)
      end
    end,
  })

  frame.Status = frame:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  frame.Status:SetPoint("TOPLEFT", actions, "BOTTOMLEFT", 2, -GAP)
  frame.Status:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
  frame.Status:SetJustifyH("LEFT")
  frame.Status:SetWordWrap(false)
  actions:Hide()
end

local refreshSoon = Utilities.Coalesce(0.2, function()
  if frame and frame:IsVisible() then Refresh() end
end)

local function Init()
  if frame then return end
  local window = CobysLinkepediaSearchWindow
  if not window then return end

  frame = CreateFrame("Frame", nil, window)
  frame:SetPoint("TOPLEFT", 8, -58)
  frame:SetPoint("BOTTOMRIGHT", Search.ContentEdge, "BOTTOMRIGHT", 0, 26)
  frame:Hide()

  BuildHeader()
  BuildChoices()
  BuildPreview()
  BuildActions()

  frame:SetScript("OnShow", function(self)
    self:RegisterEvent("ITEM_DATA_LOAD_RESULT")
    -- Opened by hand: build for the item the detail pane shows
    if not state.itemID then
      local item = Search.GetDetailItem and Search.GetDetailItem()
      if item and Variants.IsGear(item.itemID) then
        SetItem(item.itemID)
        return
      end
    end
    -- The recipe index may have finished while the tab was hidden
    PickUpRecipes()
    Refresh()
  end)
  frame:SetScript("OnHide", function(self)
    self:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
    HidePicker()
  end)
  -- The crafting grid's columns follow the width
  frame:SetScript("OnSizeChanged", function() refreshSoon:Call() end)
  -- Reagent names and rank item levels arrive as items load
  frame:SetScript("OnEvent", function() refreshSoon:Call() end)

  CobysLinkepedia.EventBus:Register({ ReceiveEvent = function(_, event)
    if not frame:IsVisible() then return end
    -- The index may now know this item's recipe
    if event == Events.RecipeScanComplete then PickUpRecipes() end
    refreshSoon:Call()
  end }, {
    Events.SavedVariantsChanged, Events.RecipeScanStarted, Events.RecipeScanProgress,
    Events.RecipeScanComplete, Events.RecipeScanCancelled,
  })

  Search._variantBuilderFrame = frame
  Debug.Log("INIT", "Variant builder initialized")
end

-------------------------------------------------------------------------------
-- Public
-------------------------------------------------------------------------------

-- Opens the search window on the Variants tab, for itemID when given.
-- variant (a variant entry's variant) opens that saved or captured variant.
function Search.OpenBuilder(itemID, variant)
  local window = CobysLinkepediaSearchWindow
  if not window or not frame then return end
  if not window:IsShown() then
    -- The usual open (it also fills Results), without leaving the cursor in
    -- the search box, where typing would switch back to Results
    Search.ToggleWindow()
    if window.SearchBox then window.SearchBox:ClearFocus() end
  end
  window:SetTab("variants")
  if itemID then SetItem(itemID, variant) end
end

-- For the Variants suite: the builder's steps without its window, what it
-- holds, its action buttons, and a copy of its state to put back
Search._variantBuilderTest = {
  SetItem = function(itemID, variant) SetItem(itemID, variant, true) end,
  SetMode = SetMode,
  SetTrackQuality = SetTrackQuality,
  PickUpRecipes = PickUpRecipes,
  -- The debounced build, now
  BuildNow = function()
    rebuild:Cancel()
    DoBuild()
  end,
  EnsureSaved = function() return EnsureSaved() end,
  GetState = function()
    return {
      itemID = state.itemID, mode = state.mode, modeExplicit = state.modeExplicit,
      recipeCount = #state.recipes, recipeID = state.options and state.options.recipeID,
      missingRecipeID = state.missingRecipeID, quality = state.quality,
      seasonKey = state.seasonKey, trackName = state.trackName, trackRank = state.trackRank,
      trackQuality = state.trackQuality,
      hasResult = state.result ~= nil, building = state.building,
    }
  end,
  -- Enabled or shown state of the actions, or nil before the tab is built
  GetActions = function()
    if not frame then return nil end
    return {
      save = frame.SaveButton:IsEnabled(), link = frame.LinkButton:IsEnabled(),
      macro = frame.MacroButton:IsEnabled(), star = frame.Star:IsShown(),
    }
  end,
  Snapshot = function()
    local copy = {}
    for k, v in pairs(state) do copy[k] = v end
    return copy
  end,
  Restore = function(copy)
    StopBuild()
    rebuild:Cancel()
    for k in pairs(state) do state[k] = nil end
    for k, v in pairs(copy) do state[k] = v end
    Refresh()
  end,
}

-- Deferred like the other tabs: the window's own OnLoad runs a frame after load
C_Timer.After(0, Init)

Debug.Log("INIT", "Search variant builder loaded")
