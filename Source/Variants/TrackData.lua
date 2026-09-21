-- Upgrade tracks by season: one bonus ID per track rank, which is all an item
-- link needs to carry a track and rank (Variants/Tracks.lua). Item levels and
-- each track's highest rank are never stored here; the client reads them back
-- from the built links.
--
-- From the 12.1.0.69814 client's own tables (wago.tools: ItemBonus rows of
-- type 34 give a bonus ID's track group and track name string, and
-- ItemBonusListGroupEntry gives its rank), with season names from Raidbots'
-- seasons.json. A group's list runs past the highest rank the client names
-- for a track: every Midnight track lists 8 where the client says 6, and
-- Myth (both seasons) and Season 1 Hero list 9. Those ranks have no upgrade
-- cost in the client's tables but are real (Myth 9/6); the builder offers
-- each one the client reads back as that rank (Tracks.lua, GetTrackRanks).
-- The client describes only the current season's tracks (C_Item.
-- GetItemUpgradeInfo returns nothing for a past season's, checked in game
-- 2026-09-16), so a past season's ranks are the ones listed here, each still
-- with its own item level.
-- Only seasons whose bonus IDs the client still treats as upgrade tracks are
-- here: The War Within Seasons 1 and 2 lost that data, so their links would
-- carry no track. Midnight Season 2 was checked in game for every track and
-- rank (the Variant Builder lab notes, D5).
--
-- A new season: add its block at the top and point DEFAULT_SEASON at it.

local Variants = CobysLinkepedia.Variants

local function Range(first, last, extra)
  local list = {}
  for id = first, last do list[#list + 1] = id end
  for _, id in ipairs(extra or {}) do list[#list + 1] = id end
  return list
end

-- stringID: the client's track name string (970 Explorer, 971 Adventurer,
-- 972 Veteran, 973 Champion, 974 Hero, 978 Myth), for a read-back that does
-- not depend on the client's language. Newest season first.
Variants.SEASONS = {
  {
    key = "mid2", name = "Midnight Season 2",
    tracks = {
      { name = "Adventurer", stringID = 971, bonusIDs = Range(12817, 12824) },
      { name = "Veteran",    stringID = 972, bonusIDs = Range(12825, 12832) },
      { name = "Champion",   stringID = 973, bonusIDs = Range(12833, 12840) },
      { name = "Hero",       stringID = 974, bonusIDs = Range(12841, 12848) },
      { name = "Myth",       stringID = 978, bonusIDs = Range(12849, 12856, { 13848 }) },
    },
  },
  {
    key = "mid1", name = "Midnight Season 1",
    tracks = {
      { name = "Explorer",   stringID = 970, bonusIDs = { 12704, 12762, 12763, 12764, 12765, 12766, 12767, 12768 } },
      { name = "Adventurer", stringID = 971, bonusIDs = Range(12769, 12776) },
      { name = "Veteran",    stringID = 972, bonusIDs = Range(12777, 12784) },
      { name = "Champion",   stringID = 973, bonusIDs = Range(12785, 12792) },
      { name = "Hero",       stringID = 974, bonusIDs = Range(12793, 12800, { 13653 }) },
      { name = "Myth",       stringID = 978, bonusIDs = Range(12801, 12808, { 13654 }) },
    },
  },
  {
    key = "tww3", name = "The War Within Season 3",
    tracks = {
      { name = "Explorer",   stringID = 970, bonusIDs = Range(12265, 12272) },
      { name = "Adventurer", stringID = 971, bonusIDs = Range(12274, 12281) },
      { name = "Veteran",    stringID = 972, bonusIDs = Range(12282, 12289) },
      { name = "Champion",   stringID = 973, bonusIDs = Range(12290, 12297) },
      { name = "Hero",       stringID = 974, bonusIDs = Range(12350, 12355, { 13443, 13444 }) },
      { name = "Myth",       stringID = 978, bonusIDs = Range(12356, 12361, { 13445, 13446 }) },
    },
  },
}

Variants.DEFAULT_SEASON = "mid2"

-- Bonus IDs whose only effect sets an item's quality (an ItemBonus list of one
-- type 3 row in the same client tables), by Enum.ItemQuality. A track rank's
-- own list sets its quality too (Midnight Season 2 Adventurer Rare, the rest
-- Epic); one of these added beside it asks for another. Poor has none.
Variants.QUALITY_BONUS = {
  [1] = 5246,   -- Common
  [2] = 5247,   -- Uncommon
  [3] = 5248,   -- Rare
  [4] = 5252,   -- Epic
  [5] = 5249,   -- Legendary
  [6] = 5250,   -- Artifact
  [7] = 5251,   -- Heirloom
}
