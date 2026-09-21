-- Recipe index: which recipes craft which gear
--
-- The game has no lookup from an item to the recipe that makes it, so the
-- recipe scan (Scanner/Recipes.lua) walks every spell ID and stores the
-- weapons and armor recipes output here, for the Variant Builder.
--
-- COBYS_LINKEPEDIA_DB.recipes = {
--   byItem = { [itemID] = recipeID, or { recipeID, ... } when several make it },
--   scan   = the recipe scan's own progress (Scanner/Recipes.lua owns it),
-- }
-- It is derived data, so it lives in the item database: Reset and corrupt-data
-- recovery clear it with everything else, while a Build (WipeItems) keeps it
-- because the recipes have not changed.

local Database = CobysLinkepedia.Database

local tonumber, type, pairs, ipairs = tonumber, type, pairs, ipairs

local generation = 0

local function Recipes()
  local db = COBYS_LINKEPEDIA_DB
  if type(db) ~= "table" then return nil end
  if type(db.recipes) ~= "table" then db.recipes = {} end
  local recipes = db.recipes
  if type(recipes.byItem) ~= "table" then recipes.byItem = {} end
  if type(recipes.scan) ~= "table" then recipes.scan = {} end
  return recipes
end

local function IsID(value)
  return type(value) == "number" and value >= 1 and value == math.floor(value)
end

-- Drops entries that are not an item ID mapped to recipe IDs. Database.Load
-- calls it; a damaged index costs only its damaged entries.
function Database.ValidateRecipes()
  local recipes = Recipes()
  if not recipes then return end
  local dropped = 0
  for itemID, value in pairs(recipes.byItem) do
    local ok = IsID(itemID)
    if ok and type(value) == "table" then
      local kept = {}
      for _, recipeID in ipairs(value) do
        if IsID(recipeID) then kept[#kept + 1] = recipeID end
      end
      if #kept == 0 then
        ok = false
      else
        recipes.byItem[itemID] = #kept == 1 and kept[1] or kept
      end
    elseif ok then
      ok = IsID(value)
    end
    if not ok then
      recipes.byItem[itemID] = nil
      dropped = dropped + 1
    end
  end
  generation = generation + 1
  if dropped > 0 then
    CobysLinkepedia.Debug.Warn("DATABASE", "Dropped %d damaged recipe index entries", dropped)
  end
end

-- Records that recipeID crafts itemID. Returns whether it was new.
function Database.StoreRecipe(itemID, recipeID)
  local recipes = Recipes()
  itemID, recipeID = tonumber(itemID), tonumber(recipeID)
  if not recipes or not IsID(itemID) or not IsID(recipeID) then return false end

  local byItem = recipes.byItem
  local current = byItem[itemID]
  if current == nil then
    byItem[itemID] = recipeID
  elseif type(current) == "number" then
    if current == recipeID then return false end
    byItem[itemID] = { current, recipeID }
  else
    for _, known in ipairs(current) do
      if known == recipeID then return false end
    end
    current[#current + 1] = recipeID
  end
  generation = generation + 1
  return true
end

-- Whether any recipe is known to craft itemID (no list is built)
function Database.HasRecipesForItem(itemID)
  local recipes = Recipes()
  return (recipes and recipes.byItem[tonumber(itemID)]) ~= nil
end

-- The recipe IDs known to craft itemID, lowest first, as a new list; nil
-- when none are
function Database.GetRecipesForItem(itemID)
  local recipes = Recipes()
  local value = recipes and recipes.byItem[tonumber(itemID)]
  if value == nil then return nil end
  if type(value) == "number" then return { value } end
  local list = {}
  for i, recipeID in ipairs(value) do list[i] = recipeID end
  table.sort(list)
  return list
end

-- Calls fn(itemID, recipeIDs) for every indexed item, in no order; fn must
-- not store
function Database.ForEachRecipe(fn)
  local recipes = Recipes()
  if not recipes then return end
  for itemID in pairs(recipes.byItem) do
    fn(itemID, Database.GetRecipesForItem(itemID))
  end
end

-- How many items the index knows a recipe for. The cache is kept per index
-- table as well as per generation, so a swapped database (the suites' scratch
-- one) never reports the other table's count.
local countCache, countGeneration, countTable = 0, -1, nil
function Database.GetRecipeCount()
  local recipes = Recipes()
  local byItem = recipes and recipes.byItem
  if countGeneration ~= generation or countTable ~= byItem then
    local n = 0
    if byItem then
      for _ in pairs(byItem) do n = n + 1 end
    end
    countCache, countGeneration, countTable = n, generation, byItem
  end
  return countCache
end

function Database.ClearRecipes()
  local recipes = Recipes()
  if not recipes then return end
  recipes.byItem = {}
  recipes.scan = {}
  generation = generation + 1
end

-- The recipe scan's progress table, live (Scanner/Recipes.lua reads and
-- writes it); nil before the database exists
function Database.GetRecipeScanState()
  local recipes = Recipes()
  return recipes and recipes.scan
end

-- Changes whenever the index does; compare, never interpret
function Database.GetRecipeGeneration()
  return generation
end

CobysLinkepedia.Debug.Log("INIT", "Recipe index module loaded")
