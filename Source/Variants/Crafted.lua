-- Crafted variants: the choices a recipe offers and the game's own link for
-- a set of choices.
--
-- C_TradeSkillUI.GetRecipeOutputItemData(recipeID, reagents, nil, qualityID)
-- returns the link the crafting-orders form previews, for any recipe the
-- client knows, learned or not, with no profession window open, and with
-- reagents the player does not own. Measured in the 12.1.0 client
-- (the Variant Builder lab notes, D2 to D4 and D7):
--   - each quality ID gives its own link and item level;
--   - Modifying slots (missives, embellishments, sparks, crests, PvP
--     heraldry) change the item, so each is offered with all its reagents;
--   - Basic-slot reagent ranks only change two link modifiers and Finishing
--     slots change nothing visible, so neither is offered;
--   - reagent names need an item load first;
--   - a crafted link is about 152 bytes, plus about 10 per Modifying reagent;
--   - the link carries its quality, and each Modifying reagent as a modifier
--     whose value is the reagent's item ID.
-- A built link is offered only when it reads back the chosen quality and
-- carries every chosen reagent. Only C_TradeSkillUI and C_Item calls are made.

local Variants = CobysLinkepedia.Variants
local Database = CobysLinkepedia.Database
local Utilities = CobysLinkepedia.Utilities

local RETRY_DELAY = 0.5
local RETRIES = 6
local LOAD_TIMEOUT = 5

local MODIFYING = Enum.CraftingReagentType and Enum.CraftingReagentType.Modifying or 0

local function ReagentItemID(reagent)
  if type(reagent) ~= "table" then return nil end
  if type(reagent.reagent) == "table" then return reagent.reagent.itemID end
  return reagent.itemID
end

local function Schematic(recipeID)
  local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
  return ok and schematic or nil
end

-- The indexed recipes that still craft itemID, lowest ID first
function Variants.GetRecipeIDs(itemID)
  local list = Database.GetRecipesForItem(itemID)
  if not list then return {} end
  local out = {}
  for _, recipeID in ipairs(list) do
    local schematic = Schematic(recipeID)
    if schematic and schematic.outputItemID == itemID then out[#out + 1] = recipeID end
  end
  return out
end

-- What a recipe lets the builder choose:
--   { recipeID, name, itemID, learned,
--     qualities = { { index, qualityID, atlas }, ... } (empty without ranks),
--     slots = { { dataSlotIndex, text, required, quantity, reagents = { itemID, ... } }, ... } }
-- nil when the recipe has no schematic
function Variants.GetCraftedOptions(recipeID)
  local schematic = Schematic(recipeID)
  if not schematic or not schematic.outputItemID or schematic.outputItemID <= 0 then return nil end
  local okInfo, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
  info = okInfo and info or {}

  local options = {
    recipeID = recipeID,
    name = info.name or schematic.name,
    itemID = schematic.outputItemID,
    learned = info.learned,
    qualities = {},
    slots = {},
  }

  for index, qualityID in ipairs(info.qualityIDs or {}) do
    local okQuality, qualityInfo = pcall(C_TradeSkillUI.GetRecipeItemQualityInfo, recipeID, index)
    options.qualities[index] = {
      index = index,
      qualityID = qualityID,
      atlas = okQuality and type(qualityInfo) == "table" and qualityInfo.iconSmall or nil,
    }
  end

  for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
    if slot.reagentType == MODIFYING and not slot.hiddenInCraftingForm then
      local reagents = {}
      for _, reagent in ipairs(slot.reagents or {}) do
        local itemID = ReagentItemID(reagent)
        if itemID then reagents[#reagents + 1] = itemID end
      end
      if #reagents > 0 then
        options.slots[#options.slots + 1] = {
          dataSlotIndex = slot.dataSlotIndex,
          text = slot.slotInfo and slot.slotInfo.slotText or nil,
          required = slot.required and true or false,
          quantity = slot.quantityRequired or 1,
          reagents = reagents,
        }
      end
    end
  end
  return options
end

-- Asks the client for every reagent's data, so the slot menus have names
function Variants.LoadReagents(options)
  for _, slot in ipairs(options and options.slots or {}) do
    for _, itemID in ipairs(slot.reagents) do
      C_Item.RequestLoadItemDataByID(itemID)
    end
  end
end

-- Builds the link for a recipe's options at quality (an index into
-- options.qualities, or nil) with reagents ({ [dataSlotIndex] = itemID })
-- and calls onDone(result): { link, ilvl, rank } or { error }. Returns
-- cancel.
function Variants.BuildCraftedLink(options, quality, reagents, onDone)
  local cancelled, timer, cancelLoad = false, nil, nil
  local function Cancel()
    cancelled = true
    if timer then timer:Cancel() end
    if cancelLoad then cancelLoad() end
  end

  local reagentInfos = {}
  for _, slot in ipairs(options.slots) do
    local itemID = reagents and reagents[slot.dataSlotIndex]
    if itemID then
      reagentInfos[#reagentInfos + 1] = {
        reagent = { itemID = itemID },
        dataSlotIndex = slot.dataSlotIndex,
        quantity = slot.quantity,
      }
    end
  end
  local qualityID = quality and options.qualities[quality] and options.qualities[quality].qualityID or nil

  cancelLoad = Utilities.LoadItemThen(options.itemID, {
    timeout = LOAD_TIMEOUT,
    onFail = function()
      if not cancelled then onDone({ error = "The item's data did not load; try again in a moment." }) end
    end,
    onReady = function()
      local attempts = 0
      local function Try()
        timer = nil
        if cancelled then return end
        attempts = attempts + 1
        local ok, output = pcall(C_TradeSkillUI.GetRecipeOutputItemData, options.recipeID, reagentInfos, nil, qualityID)
        local link = ok and type(output) == "table" and output.hyperlink or nil
        if not link and attempts < RETRIES then
          timer = C_Timer.NewTimer(RETRY_DELAY, Try)
          return
        end
        if not link then
          onDone({ error = "The game did not build a link for these choices." })
          return
        end
        local info = Variants.ReadLinkInfo(link)
        if qualityID and (not info or info.rank ~= quality) then
          onDone({ error = ("The game did not read quality %d back from the link."):format(quality) })
          return
        end
        local parsed = CobysLinkepedia.Database.Capture.ParseItemLink(link)
        local carried = {}
        for _, modifier in ipairs(parsed and parsed.modifiers or {}) do
          local value = tonumber(modifier.value)
          if value then carried[value] = true end
        end
        for _, reagentInfo in ipairs(reagentInfos) do
          local reagentID = reagentInfo.reagent.itemID
          if not carried[reagentID] then
            onDone({ error = ("The game left %s out of the link."):format(C_Item.GetItemNameByID(reagentID) or ("item " .. reagentID)) })
            return
          end
        end
        onDone({ link = link, ilvl = info and info.ilvl, rank = info and info.rank })
      end
      Try()
    end,
  })
  return Cancel
end
