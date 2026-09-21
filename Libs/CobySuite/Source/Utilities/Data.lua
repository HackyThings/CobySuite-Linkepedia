---------------------------------------------------------------------------
-- CobySuite Shared Data: Item classification, quality, expansion lookups
---------------------------------------------------------------------------
local U = CobySuite_CobysLinkepedia.Utilities

---------------------------------------------------------------------------
-- Quality names
---------------------------------------------------------------------------
U.QualityNames = {
  [0] = "Poor", [1] = "Common", [2] = "Uncommon", [3] = "Rare",
  [4] = "Epic", [5] = "Legendary", [6] = "Artifact", [7] = "Heirloom",
  [8] = "WoW Token",
}

---------------------------------------------------------------------------
-- Item classes
---------------------------------------------------------------------------
U.ItemClasses = {
  [0]  = "Consumable",
  [1]  = "Container",
  [2]  = "Weapon",
  [3]  = "Gem",
  [4]  = "Armor",
  [5]  = "Reagent",
  [6]  = "Projectile",
  [7]  = "Tradeskill",
  [8]  = "Item Enhancement",
  [9]  = "Recipe",
  [10] = "Money",
  [11] = "Quiver",
  [12] = "Quest",
  [13] = "Key",
  [14] = "Permanent",
  [15] = "Miscellaneous",
  [16] = "Glyph",
  [17] = "Battle Pet",
  [18] = "WoW Token",
  [19] = "Profession",
  [20] = "Housing",
}

---------------------------------------------------------------------------
-- Item subclasses
---------------------------------------------------------------------------
U.ItemSubClasses = {
  [0] = {  -- Consumable
    [0] = "Generic", [1] = "Potion", [2] = "Elixir", [3] = "Flask",
    [5] = "Food & Drink", [7] = "Bandage", [8] = "Other",
    [9] = "Vantus Rune", [10] = "Phial",
  },
  [1] = {  -- Container
    [0] = "Bag", [1] = "Soul Bag", [2] = "Herb Bag", [3] = "Enchanting Bag",
    [4] = "Engineering Bag", [5] = "Gem Bag", [6] = "Mining Bag",
    [7] = "Leatherworking Bag", [8] = "Inscription Bag", [9] = "Tackle Box",
    [10] = "Cooking Bag", [11] = "Reagent Bag",
  },
  [2] = {  -- Weapon
    [0] = "One-Handed Axe", [1] = "Two-Handed Axe", [2] = "Bow", [3] = "Gun",
    [4] = "One-Handed Mace", [5] = "Two-Handed Mace", [6] = "Polearm",
    [7] = "One-Handed Sword", [8] = "Two-Handed Sword", [10] = "Staff",
    [13] = "Fist Weapon", [14] = "Miscellaneous", [15] = "Dagger",
    [16] = "Thrown", [18] = "Crossbow", [19] = "Wand", [20] = "Fishing Pole",
  },
  [3] = {  -- Gem
    [0] = "Intellect", [1] = "Agility", [2] = "Strength", [3] = "Stamina",
    [4] = "Spirit", [5] = "Critical Strike", [6] = "Mastery", [7] = "Haste",
    [8] = "Versatility", [9] = "Other", [10] = "Multiple Stats", [11] = "Crafting",
  },
  [4] = {  -- Armor
    [0] = "Miscellaneous", [1] = "Cloth", [2] = "Leather", [3] = "Mail",
    [4] = "Plate", [5] = "Cosmetic", [6] = "Shield", [7] = "Libram",
    [8] = "Idol", [9] = "Totem", [10] = "Sigil", [11] = "Relic", [12] = "Off-hand",
  },
  [5] = {  -- Reagent
    [0] = "Reagent", [1] = "Keystone", [2] = "Context Token",
  },
  [7] = {  -- Tradeskill
    [0] = "Tradeskill", [1] = "Parts", [2] = "Explosives",
    [4] = "Jewelcrafting", [5] = "Cloth", [6] = "Leather",
    [7] = "Metal & Stone", [8] = "Cooking", [9] = "Herb", [10] = "Elemental",
    [11] = "Other", [12] = "Enchanting", [16] = "Inscription",
    [18] = "Optional Reagent", [19] = "Finishing Reagent",
  },
  [8] = {  -- Item Enhancement
    [0] = "Head", [1] = "Neck", [2] = "Shoulder", [3] = "Cloak",
    [4] = "Chest", [5] = "Wrist", [6] = "Hands", [7] = "Waist",
    [8] = "Legs", [9] = "Feet", [10] = "Finger", [11] = "Weapon",
    [12] = "Two-Handed Weapon", [13] = "Shield/Off-hand", [14] = "Misc",
  },
  [9] = {  -- Recipe
    [0] = "Book", [1] = "Leatherworking", [2] = "Tailoring",
    [3] = "Engineering", [4] = "Blacksmithing", [5] = "Cooking",
    [6] = "Alchemy", [7] = "First Aid", [8] = "Enchanting", [9] = "Fishing",
    [10] = "Jewelcrafting", [11] = "Inscription",
  },
  [15] = {  -- Miscellaneous
    [0] = "Junk", [1] = "Reagent", [2] = "Companion Pet", [3] = "Holiday",
    [4] = "Other", [5] = "Mount", [6] = "Mount Equipment", [7] = "Toy",
  },
  [16] = {  -- Glyph
    [1] = "Warrior", [2] = "Paladin", [3] = "Hunter", [4] = "Rogue",
    [5] = "Priest", [6] = "Death Knight", [7] = "Shaman", [8] = "Mage",
    [9] = "Warlock", [10] = "Monk", [11] = "Druid", [12] = "Demon Hunter",
  },
  [17] = {  -- Battle Pet
    [0] = "Humanoid", [1] = "Dragonkin", [2] = "Flying", [3] = "Undead",
    [4] = "Critter", [5] = "Magic", [6] = "Elemental", [7] = "Beast",
    [8] = "Aquatic", [9] = "Mechanical",
  },
}

---------------------------------------------------------------------------
-- Expansion names
---------------------------------------------------------------------------
U.ExpansionNames = {
  [0] = "Classic",
  [1] = "TBC",
  [2] = "Wrath",
  [3] = "Cataclysm",
  [4] = "Mists",
  [5] = "Warlords",
  [6] = "Legion",
  [7] = "BfA",
  [8] = "Shadowlands",
  [9] = "Dragonflight",
  [10] = "TWW",
  [11] = "Midnight",
}

---------------------------------------------------------------------------
-- Lookup helpers
---------------------------------------------------------------------------
function U.GetClassName(classID)
  if classID == nil then return nil end
  return U.ItemClasses[classID] or ("Class " .. tostring(classID))
end

function U.GetSubClassName(classID, subClassID)
  local subs = U.ItemSubClasses[classID]
  if subs and subs[subClassID] then return subs[subClassID] end
  return nil
end

function U.GetQualityAtlas(rank, itemID)
  if not rank or rank <= 0 then return nil end
  if itemID and C_TradeSkillUI then
    local info = C_TradeSkillUI.GetItemReagentQualityInfo
        and C_TradeSkillUI.GetItemReagentQualityInfo(itemID)
    if not info and C_TradeSkillUI.GetItemCraftedQualityInfo then
      info = C_TradeSkillUI.GetItemCraftedQualityInfo(itemID)
    end
    if info and info.iconSmall then return info.iconSmall end
  end
  return "Professions-Icon-Quality-Tier" .. rank .. "-Small"
end
