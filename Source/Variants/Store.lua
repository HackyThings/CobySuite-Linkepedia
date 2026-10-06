-- Saved variants: item variants the player built in the Variant Builder or
-- chose to keep, each under a short number that ${v=N} tokens name.
--
-- They live in COBYS_LINKEPEDIA_STATE beside favorites and history, not in
-- the item database, because Reset and corrupt-data recovery clear the
-- database's captured variants and a Build's prune can drop some, and a
-- macro's saved variant must outlive those.
--
-- COBYS_LINKEPEDIA_STATE.savedVariants = { nextID = n, byID = { [id] = record } }
--   id        the record's number; IDs count up and are never reused, so a
--             macro's ${v=N} never starts naming a different variant after a
--             delete
--   itemID    the base item
--   link      the variant's full link
--   key       Database.VariantKeyForLink(link); one record per key
--   source    "built" (the builder) or "captured" (kept from play)
--   kind      "crafted", "track" or "other"
--   ilvl, rank, track ({ text, level, max, stringID, seasonKey, seasonName,
--             name, fromData })   read from the link when saved
--   choices   what the builder chose, to open it again: crafted
--             { recipeID, quality, reagents = { [dataSlotIndex] = itemID } },
--             track { season, track = name, rank, itemQuality } (itemQuality
--             an Enum.ItemQuality in place of the rank's own, or nil)
--   favorite  true when it shows in the Favorites tab
--
-- Every change fires SavedVariantsChanged(id, itemID, change) with change
-- "saved", "updated", "deleted" or "favorite".

local Variants = CobysLinkepedia.Variants
local Database = CobysLinkepedia.Database
local Linkify = CobysLinkepedia.Linkify

local floor = math.floor
local strfind = string.find

local CAP = 500

-- Lookups rebuilt whenever the saved table is replaced (a test run's
-- snapshot restores it as a new table), kept current on every change
local indexedTable = nil
local byKey = {}      -- key -> id
local byItem = {}     -- itemID -> { [id] = true }
local count = 0

local function Saved()
  local state = COBYS_LINKEPEDIA_STATE
  local saved = type(state) == "table" and state.savedVariants
  if type(saved) ~= "table" or type(saved.byID) ~= "table" then return nil end
  return saved
end

local function IndexAdd(v)
  byKey[v.key] = v.id
  local set = byItem[v.itemID]
  if not set then
    set = {}
    byItem[v.itemID] = set
  end
  set[v.id] = true
  count = count + 1
end

local function IndexRemove(v)
  if byKey[v.key] == v.id then byKey[v.key] = nil end
  local set = byItem[v.itemID]
  if set then
    set[v.id] = nil
    if next(set) == nil then byItem[v.itemID] = nil end
  end
  count = count - 1
end

-- The live saved table with its lookups current, or nil
local function Live()
  local saved = Saved()
  if not saved then return nil end
  if indexedTable ~= saved.byID then
    indexedTable = saved.byID
    byKey, byItem, count = {}, {}, 0
    for _, v in pairs(saved.byID) do IndexAdd(v) end
  end
  return saved
end

local function Fire(id, itemID, change)
  CobysLinkepedia.EventBus:Fire(CobysLinkepedia.Events.SavedVariantsChanged, id, itemID, change)
end

local function IsID(value)
  return type(value) == "number" and value >= 1 and value == floor(value)
end

-- Fills kind, ilvl, rank and track from the link where meta did not give them
local function ApplyMeta(v, meta)
  meta = meta or {}
  if meta.source then v.source = meta.source end
  if meta.choices then v.choices = meta.choices end
  local info = Variants.ReadLinkInfo(v.link) or {}
  v.kind = meta.kind or info.kind or v.kind or "other"
  v.ilvl = meta.ilvl or info.ilvl or v.ilvl
  v.rank = meta.rank or info.rank or v.rank
  v.track = meta.track or info.track or v.track
end

-------------------------------------------------------------------------------
-- Load-time repair
-------------------------------------------------------------------------------

-- Makes COBYS_LINKEPEDIA_STATE.savedVariants well formed: records that are
-- not a table with a numeric ID, an item ID and an item link whose item
-- matches are dropped, keys are recomputed, a second record for one key is
-- dropped (the lower ID stays), and nextID moves past every ID in use.
-- Config.InitializeData calls it.
function Variants.ValidateSaved()
  local state = COBYS_LINKEPEDIA_STATE
  if type(state) ~= "table" then return end
  if type(state.savedVariants) ~= "table" then state.savedVariants = {} end
  local saved = state.savedVariants
  if type(saved.byID) ~= "table" then saved.byID = {} end

  local ids, dropped = {}, 0
  for id, v in pairs(saved.byID) do
    local ok = IsID(id) and type(v) == "table" and IsID(v.itemID)
      and type(v.link) == "string" and strfind(v.link, "|Hitem:", 1, true) ~= nil
    local parsed = ok and Database.Capture.ParseItemLink(v.link)
    if ok and parsed and parsed.itemID == v.itemID then
      ids[#ids + 1] = id
    else
      saved.byID[id] = nil
      dropped = dropped + 1
    end
  end
  table.sort(ids)

  local seen, maxID = {}, 0
  for _, id in ipairs(ids) do
    local v = saved.byID[id]
    v.id = id
    v.key = Database.VariantKeyForLink(v.link)
    if seen[v.key] then
      saved.byID[id] = nil
      dropped = dropped + 1
    else
      seen[v.key] = true
      maxID = id
      if v.favorite ~= true then v.favorite = nil end
      if v.source ~= "built" and v.source ~= "captured" then v.source = "built" end
      if v.kind ~= "crafted" and v.kind ~= "track" and v.kind ~= "other" then v.kind = "other" end
      if type(v.ilvl) ~= "number" then v.ilvl = nil end
      if type(v.rank) ~= "number" then v.rank = nil end
      if type(v.track) ~= "table" then v.track = nil end
      if type(v.choices) ~= "table" then v.choices = nil end
    end
  end

  local nextID = tonumber(saved.nextID)
  if not IsID(nextID) or nextID <= maxID then nextID = maxID + 1 end
  saved.nextID = nextID
  indexedTable = nil
  if dropped > 0 then
    CobysLinkepedia.Debug.Warn("CONFIG", "Dropped %d damaged or duplicate saved variants", dropped)
  end
end

-------------------------------------------------------------------------------
-- Changes
-------------------------------------------------------------------------------

-- Saves link as a variant, or refreshes the saved one with the same key.
-- meta: source, kind, choices, ilvl, rank, track (read from the link when
-- missing). Returns id and whether it is new, or nil and a sentence saying
-- why not.
function Variants.Save(link, meta)
  local saved = Live()
  if not saved then return nil, "Saved variants are not ready yet." end
  local parsed = type(link) == "string" and strfind(link, "|Hitem:", 1, true) and Database.Capture.ParseItemLink(link)
  if not parsed then return nil, "That is not an item link." end
  local key = Database.VariantKeyForLink(link)

  local existing = byKey[key]
  if existing and saved.byID[existing] then
    local v = saved.byID[existing]
    v.link = link
    ApplyMeta(v, meta)
    Fire(existing, v.itemID, "updated")
    return existing, false
  end
  if count >= CAP then
    return nil, ("You have %d saved variants, the most there can be; delete some first."):format(CAP)
  end

  local id = saved.nextID
  saved.nextID = id + 1
  local v = { id = id, itemID = parsed.itemID, link = link, key = key, source = "built" }
  ApplyMeta(v, meta)
  saved.byID[id] = v
  IndexAdd(v)
  Fire(id, v.itemID, "saved")
  return id, true
end

-- Replaces saved variant id with a new link (the builder's Update). Returns
-- true, or nil and a sentence saying why not.
function Variants.Update(id, link, meta)
  local saved = Live()
  local v = saved and saved.byID[id]
  if not v then return nil, "That saved variant no longer exists." end
  local parsed = type(link) == "string" and Database.Capture.ParseItemLink(link)
  if not parsed or parsed.itemID ~= v.itemID then return nil, "That link is for a different item." end
  local key = Database.VariantKeyForLink(link)
  local other = byKey[key]
  if other and other ~= id and saved.byID[other] then
    return nil, ("Those choices are already saved as variant %d."):format(other)
  end
  IndexRemove(v)
  v.link, v.key = link, key
  v.ilvl, v.rank, v.track = nil, nil, nil
  ApplyMeta(v, meta)
  IndexAdd(v)
  Fire(id, v.itemID, "updated")
  return true
end

function Variants.Delete(id)
  local saved = Live()
  local v = saved and saved.byID[id]
  if not v then return false end
  saved.byID[id] = nil
  IndexRemove(v)
  Fire(id, v.itemID, "deleted")
  return true
end

function Variants.SetFavorite(id, favorite)
  local saved = Live()
  local v = saved and saved.byID[id]
  if not v then return false end
  favorite = favorite and true or nil
  if v.favorite == favorite then return true end
  v.favorite = favorite
  Fire(id, v.itemID, "favorite")
  return true
end

-------------------------------------------------------------------------------
-- Reads. Records returned are the stored ones: read them, never change them.
-------------------------------------------------------------------------------

function Variants.Get(id)
  local saved = Live()
  return saved and saved.byID[tonumber(id)] or nil
end

function Variants.FindByLink(link)
  local saved = Live()
  local key = saved and type(link) == "string" and Database.VariantKeyForLink(link)
  local id = key and byKey[key]
  return id and saved.byID[id] or nil
end

function Variants.LinkFor(id)
  local v = Variants.Get(id)
  return v and v.link
end

function Variants.GetCount()
  return Live() and count or 0
end

-- The number the next saved variant will get
function Variants.PeekNextID()
  local saved = Live()
  return saved and saved.nextID or 1
end

-- The lowest number a saved variant has now, or nil with none saved.
-- Numbers are never reused, so it can be far above 1.
function Variants.LowestID()
  local saved = Live()
  if not saved then return nil end
  local lowest
  for id in pairs(saved.byID) do
    if not lowest or id < lowest then lowest = id end
  end
  return lowest
end

-- Higher rank first, then higher item level, then the older record
local function Before(a, b)
  if (a.rank or 0) ~= (b.rank or 0) then return (a.rank or 0) > (b.rank or 0) end
  if (a.ilvl or 0) ~= (b.ilvl or 0) then return (a.ilvl or 0) > (b.ilvl or 0) end
  return a.id < b.id
end

function Variants.GetForItem(itemID)
  local saved = Live()
  local set = saved and byItem[itemID]
  local list = {}
  if not set then return list end
  for id in pairs(set) do list[#list + 1] = saved.byID[id] end
  table.sort(list, Before)
  return list
end

-- Every favorited variant, grouped by base item (item ID order), best first
-- within an item
function Variants.GetFavorites()
  local saved = Live()
  local list = {}
  if not saved then return list end
  for _, v in pairs(saved.byID) do
    if v.favorite then list[#list + 1] = v end
  end
  table.sort(list, function(a, b)
    if a.itemID ~= b.itemID then return a.itemID < b.itemID end
    return Before(a, b)
  end)
  return list
end

-- The names of the macros whose text has a ${v=id} token
function Variants.MacrosUsing(id)
  local names = {}
  local numAccount, numCharacter = GetNumMacros()
  local characterBase = Constants.MacroConsts.MAX_ACCOUNT_MACROS
  local function Check(index)
    local name, _, body = GetMacroInfo(index)
    if not body or not strfind(body, "${", 1, true) then return end
    for _, token in ipairs(Linkify.FindTokens(body)) do
      if token.key == "v" and token.variantID == id then
        names[#names + 1] = name
        return
      end
    end
  end
  for i = 1, numAccount do Check(i) end
  for i = characterBase + 1, characterBase + numCharacter do Check(i) end
  return names
end

CobysLinkepedia.Debug.Log("INIT", "Saved variants module loaded")
