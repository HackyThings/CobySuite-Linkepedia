-- Item Database: string buckets are the live form, indexed for lookup
--
-- COBYS_LINKEPEDIA_DB.items[prefix] is a string of records separated by \30;
-- a record is eight \31-separated fields:
--   id, name, quality, classID, subClassID, itemLevel, reqLevel, expansionID
-- That string is what the SavedVariable holds on disk and what this module
-- searches, so login builds no table per item and logout serialises
-- nothing. The
-- earlier form expanded every record into a Lua table at login (176K tables,
-- tens of MB and a visible pause) and walked those tables for every query;
-- searching the strings is a handful of C-level string.find calls per bucket
-- instead. Records hold no icon: rows take icons from
-- C_Item.GetItemInfoInstant.
--
-- Beside the strings the module keeps, rebuilt by Load():
--   idToPrefix[itemID] = prefix   O(1) GetItem, Remove and duplicate detection
--   prefixList / prefixIndex      a small integer per bucket, for entry handles
--   pending[prefix] = { record }  Store appends here; the bucket is joined up
--                                 before it is next read (Bucket) or at logout
--                                 (Flush), so a scan write is one table insert
--
-- An "entry" (what NewBrowseBuilder hands out and MaterializeEntry /
-- EntrySortKey take back) is a number: prefixIdx * 2^26 + record offset.
-- Appends never move a record. A cut (Remove, or Store over an existing id)
-- rewrites the bucket and bumps the generation the browse list already
-- watches; both consumers also check the id at the offset and fall back to
-- GetItem when it is not the one they were given.

local Database = CobysLinkepedia.Database

local strfind, strmatch, strsub, strbyte, strlower, strupper, strrep =
  string.find, string.match, string.sub, string.byte, string.lower, string.upper, string.rep
local tconcat, tsort, tinsert, tremove = table.concat, table.sort, table.insert, table.remove
local floor, huge = math.floor, math.huge
local tonumber, type, pairs, ipairs, next = tonumber, type, pairs, ipairs, next

local RS = "\30"          -- record separator
local FS = "\31"          -- field separator
local RS_BYTE = 30

local HANDLE_BASE = 67108864   -- 2^26: record offset below, bucket index above

-- Patterns are anchored at a record start (string.match with an init
-- position). The name class excludes both separators, so a damaged record
-- can never swallow the one after it; Store refuses names containing either.
local NAME = "([^\30\31]*)"
local NUM  = "(%-?%d+)"
local SKIP = "%-?%d+"
-- id, nameStart, name, nameStop, quality, classID, subClassID, itemLevel, reqLevel, expansionID
local RECORD = "^(%d+)\31()" .. NAME .. "()\31" .. NUM .. "\31" .. NUM .. "\31" .. NUM .. "\31" .. NUM .. "\31" .. NUM .. "\31" .. NUM
-- id and the position just past the eighth field, for the shape check at load
local RECORD_SHAPE = "^(%d+)\31[^\30\31]*\31" .. SKIP .. "\31" .. SKIP .. "\31" .. SKIP .. "\31" .. SKIP .. "\31" .. SKIP .. "\31" .. SKIP .. "()"
-- id, name, quality (unfiltered browse) / id, name, quality, classID, expansionID (filtered)
local BROWSE_MIN  = "^(%d+)\31" .. NAME .. "\31" .. NUM
local BROWSE_FULL = "^(%d+)\31" .. NAME .. "\31" .. NUM .. "\31" .. NUM .. "\31" .. SKIP .. "\31" .. SKIP .. "\31" .. SKIP .. "\31" .. NUM
-- The same with the name's span around it (a query build places each hit
-- against the name): id, nameStart, name, nameStop, quality[, classID, expansionID]
local BROWSE_SPAN_MIN  = "^(%d+)\31()" .. NAME .. "()\31" .. NUM
local BROWSE_SPAN_FULL = "^(%d+)\31()" .. NAME .. "()\31" .. NUM .. "\31" .. NUM .. "\31" .. SKIP .. "\31" .. SKIP .. "\31" .. SKIP .. "\31" .. NUM
-- id, quality, classID
local STATS = "^(%d+)\31[^\30\31]*\31" .. NUM .. "\31" .. NUM
-- id, name
local ID_NAME = "^(%d+)\31" .. NAME
-- FIELD[n]: id and numeric field n (3 = quality .. 8 = expansionID).
-- VALUE[n]: field n alone, for a handle known to be current (no id string
-- is made, so a sort over every item leaves no per-item garbage)
local FIELD, VALUE = {}, {}
for n = 3, 8 do
  FIELD[n] = "^(%d+)\31[^\30\31]*" .. strrep("\31" .. SKIP, n - 3) .. "\31" .. NUM
  VALUE[n] = "^%d+\31[^\30\31]*" .. strrep("\31" .. SKIP, n - 3) .. "\31" .. NUM
end

local MAX_QUALITY = 8   -- Enum.ItemQuality: 0 Poor .. 7 Heirloom, 8 WoWToken

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local prefixList = {}    -- idx -> prefix
local prefixIndex = {}   -- prefix -> idx
local idToPrefix = {}    -- itemID -> prefix
local pending = {}       -- prefix -> { record, ... } not yet joined to the string
local itemCount = 0

-- Bumped on every write to the item table (Store, Remove, wipes, load), so a
-- reader that caches a view of it, like the search window's browse list, can
-- tell it moved without an event per write: the idle scan stores up to
-- idleScanRate items (default 5) every second and a rebuild wipes
-- everything, and neither fires DatabaseUpdated.
local generation = 0

-- Bumped when a variant is added, pruned or learns its metadata, and on a
-- reset or load; compare, never interpret. The epoch changes only on reset
-- and load, so a metadata answer that arrives after either is dropped.
local variantGeneration = 0
local variantEpoch = 0
local variantTotal = 0        -- variant records across every item's list
local indexComplete = false   -- the last Load ran to its end (WoW can cut a long script off in combat)
local TrimVariants            -- defined with the variants below; Load calls it

local function Log(fmt, ...) CobysLinkepedia.Debug.Log("DATABASE", fmt, ...) end
local function Warn(fmt, ...) CobysLinkepedia.Debug.Warn("DATABASE", fmt, ...) end

-------------------------------------------------------------------------------
-- Internal helpers
-------------------------------------------------------------------------------

-- The item table of the SavedVariable, or nil before it exists
local function Items()
  local db = COBYS_LINKEPEDIA_DB
  if type(db) ~= "table" then return nil end
  local items = db.items
  if type(items) ~= "table" then return nil end
  return items
end

-- The 2-character uppercase prefix key for an item name
local function GetPrefixKey(name)
  if not name or name == "" then return nil end
  local upper = strupper(name)
  if #upper == 1 then
    return upper
  end
  return strsub(upper, 1, 2)
end

-- Query text as a Lua pattern that matches either case of A-Z, with every
-- other byte literal (the shared CobySuite.Utilities.CasePattern). Built once
-- per query; matching then allocates nothing. ASCII only, which is the
-- addon's supported scope.
local CasePattern = CobySuite_CobysLinkepedia.Utilities.CasePattern
local IsFiniteNumber = CobySuite_CobysLinkepedia.Utilities.IsFiniteNumber

local function PrefixIdx(prefix)
  local idx = prefixIndex[prefix]
  if not idx then
    idx = #prefixList + 1
    prefixList[idx] = prefix
    prefixIndex[prefix] = idx
  end
  return idx
end

-- The bucket string for a prefix with any pending records joined on
local function Bucket(prefix)
  local items = Items()
  if not items then return nil end
  local queue = pending[prefix]
  if queue then
    pending[prefix] = nil
    local tail = tconcat(queue, RS)
    local head = items[prefix]
    if head and head ~= "" then
      items[prefix] = head .. RS .. tail
    else
      items[prefix] = tail
    end
  end
  return items[prefix]
end

local function FlushAll()
  if next(pending) == nil then return end
  for prefix in pairs(pending) do
    Bucket(prefix)
  end
end

-- Start of the record that contains byte position pos
local function RecordStart(bucket, pos)
  local i = pos - 1
  while i >= 1 do
    if strbyte(bucket, i) == RS_BYTE then return i + 1 end
    i = i - 1
  end
  return 1
end

-- Last byte of the record that starts at start
local function RecordEnd(bucket, start)
  local sep = strfind(bucket, RS, start, true)
  return sep and (sep - 1) or #bucket
end

-- Offset of itemID's record in bucket, or nil
local function FindRecord(bucket, itemID)
  local key = itemID .. FS
  if strsub(bucket, 1, #key) == key then return 1 end
  local pos = strfind(bucket, RS .. key, 1, true)
  return pos and (pos + 1) or nil
end

-- The record at start: id, name, quality, classID, subClassID, itemLevel,
-- reqLevel, expansionID, nameStart, nameEnd; nil when no record starts there
local function ParseAt(bucket, start)
  local id, nameStart, name, nameStop, q, c, sc, il, rl, e = strmatch(bucket, RECORD, start)
  if not id then return nil end
  return tonumber(id), name, tonumber(q), tonumber(c), tonumber(sc), tonumber(il), tonumber(rl), tonumber(e),
    nameStart, nameStop - 1
end

local function NewItem(id, name, q, c, sc, il, rl, e)
  return {
    itemID = id,
    name = name,
    quality = q,
    _classID = c,
    _subClassID = sc,
    itemLevel = il,
    reqLevel = rl,
    _expansionID = e,
  }
end

-- Removes itemID's record from the bucket; the bucket goes when it empties
local function CutRecord(prefix, itemID)
  local items = Items()
  local bucket = Bucket(prefix)
  if not bucket then return false end
  local start = FindRecord(bucket, itemID)
  if not start then return false end
  local stop = RecordEnd(bucket, start)
  local rest
  if start == 1 then
    rest = strsub(bucket, stop + 2)
  else
    rest = strsub(bucket, 1, start - 2) .. strsub(bucket, stop + 1)
  end
  if rest == "" then
    items[prefix] = nil
  else
    items[prefix] = rest
  end
  return true
end

local function Int(v, default)
  if type(v) ~= "number" then return default end
  return floor(v)
end

local function ResetIndex()
  wipe(prefixList)
  wipe(prefixIndex)
  wipe(idToPrefix)
  wipe(pending)
  itemCount = 0
end

-- Same rule for Search and the browse builder: the stored classID when the
-- scan had one, the client's when it stored -1
local function PassesFilters(id, q, c, e, fType, fQuality, fExpansion)
  if fQuality and q ~= fQuality then return false end
  if fExpansion and e ~= fExpansion then return false end
  if fType then
    if c and c >= 0 then
      if c ~= fType then return false end
    else
      local _, _, _, _, _, cid = C_Item.GetItemInfoInstant(id)
      if cid ~= fType then return false end
    end
  end
  return true
end

-- The id of the record occupying [start, stop] when that record is exactly
-- eight numeric-and-name fields with a canonical positive id; nil for anything else. A start anchor alone
-- would accept a numeric field followed by junk, and an id with a leading
-- zero would count but never be found by FindRecord.
local function ValidRecordID(bucket, start, stop)
  local idStr, after = strmatch(bucket, RECORD_SHAPE, start)
  if not idStr then return nil end
  if after ~= stop + 1 then return nil end
  local id = tonumber(idStr)
  if not id or id < 1 or tostring(id) ~= idStr then return nil end
  return id
end

-- Search ranking: true when (q1, name1, id1) ranks ahead of (q2, name2, id2).
-- Quality descending, then name in byte order, then item id, so the order
-- is total and a capped search is exactly the head of the uncapped one.
local function RanksBefore(q1, n1, id1, q2, n2, id2)
  if q1 ~= q2 then return q1 > q2 end
  if n1 ~= n2 then return n1 < n2 end
  return id1 < id2
end

local function ByRank(a, b)
  return RanksBefore(a.quality, a.name, a.itemID, b.quality, b.name, b.itemID)
end

-- An empty table whose array part already holds n slots (table.create, in
-- the client since 11.1.7). Filling a 176K-entry list one index at a time
-- grows it by doubling, and each doubling copies the array and adds to the
-- collector's debt inside one frame. Without table.create (offline runs) a
-- plain table.
local tcreate = table.create
function Database.NewArray(n)
  if tcreate and n and n > 0 then return tcreate(n, 0) end
  return {}
end
local NewArray = Database.NewArray

-- Entry handle -> prefix, offset
local function Decode(handle)
  local idx = floor(handle / HANDLE_BASE)
  return prefixList[idx], handle - idx * HANDLE_BASE
end

-------------------------------------------------------------------------------
-- Storage lifecycle
--
-- Everything outside this file reaches the item buckets through the API
-- below, so their layout can change without touching any other module.
-- scanState is shared with the scanner and Core.
-------------------------------------------------------------------------------

-- Creates the SavedVariable and its sub-tables if this is a fresh install (or
-- a wipe left them nil). Idempotent.
function Database.EnsureStorage()
  if type(COBYS_LINKEPEDIA_DB) ~= "table" then
    COBYS_LINKEPEDIA_DB = {}
  end
  local db = COBYS_LINKEPEDIA_DB
  if db.items == nil then db.items = {} end
  if db.variants == nil then db.variants = {} end
  if db.scanState == nil then db.scanState = {} end
  if db.recipes == nil then db.recipes = {} end
end

-- Shape check run before anything reads the database. Returns true, or false
-- and a reason. On a failure Core's ADDON_LOADED handler starts an empty
-- database, and at login shows the corrupt-data dialog below, which offers a
-- rebuild.
function Database.ValidateStorage()
  local db = COBYS_LINKEPEDIA_DB
  if db == nil then return true end
  if type(db) ~= "table" then
    return false, "COBYS_LINKEPEDIA_DB is not a table"
  end
  if db.items ~= nil then
    if type(db.items) ~= "table" then
      return false, "COBYS_LINKEPEDIA_DB.items is not a table"
    end
    for prefix, bucket in pairs(db.items) do
      if type(bucket) ~= "string" then
        return false, "bucket " .. tostring(prefix) .. " is not a string"
      end
    end
  end
  if db.variants ~= nil and type(db.variants) ~= "table" then
    return false, "COBYS_LINKEPEDIA_DB.variants is not a table"
  end
  if db.scanState ~= nil and type(db.scanState) ~= "table" then
    return false, "COBYS_LINKEPEDIA_DB.scanState is not a table"
  end
  return true
end

-- nil, or a number that is neither NaN nor infinite
local function OptionalFinite(value)
  return value == nil or IsFiniteNumber(value)
end

-- A variant record the comparators and lookups can use: a table with a string
-- link and key, and an item level, rank and first-seen time that are each
-- absent or a finite number. The writers only ever store that; a damaged or
-- hand-edited SavedVariable can hold anything, and one bad field reaching a
-- sort (the total-cap trim at load, GetVariants at send) raises an error.
local function IsValidVariant(v)
  return type(v) == "table" and type(v.link) == "string" and type(v.key) == "string"
    and OptionalFinite(v.ilvl) and OptionalFinite(v.rank) and OptionalFinite(v.seen)
end

-- Removes the records IsValidVariant refuses from one list, keeping the order
-- of the rest. Returns how many went.
local function DropDamagedVariants(list)
  local kept, dropped = 0, 0
  for i = 1, #list do
    local v = list[i]
    if IsValidVariant(v) then
      kept = kept + 1
      list[kept] = v
    else
      dropped = dropped + 1
    end
  end
  for i = #list, kept + 1, -1 do list[i] = nil end
  return dropped
end

-- Indexes the bucket strings: fills idToPrefix and the prefix list, counts
-- items. Builds no table per item beyond the index entry. A record that
-- is not exactly the eight-field shape ending at the record boundary, one
-- whose id is not a canonical
-- positive integer, a second record for an id already seen, or a bucket
-- that is not a string is dropped, and a bucket that lost records is
-- rewritten without them, once. Called at ADDON_LOADED and by
-- ReplaceStorage; safe to call again. The index counts as complete only once
-- the walk reaches its end: the client stops a script that runs too long in
-- combat, and a Load cut off that way leaves part of the items unindexed
-- until the next Load (Database.IsIndexComplete, EnsureIndex).
function Database.Load()
  indexComplete = false
  FlushAll()
  ResetIndex()
  local started = debugprofilestop()
  local items = Items()
  local dropped = 0

  if items then
    for prefix, bucket in pairs(items) do
      if type(bucket) ~= "string" then
        items[prefix] = nil
        dropped = dropped + 1
        Warn("Dropped bucket %s: not a string", tostring(prefix))
      elseif bucket == "" then
        items[prefix] = nil
      else
        PrefixIdx(prefix)
        local bad = false
        local len, start = #bucket, 1
        while start <= len do
          local stop = RecordEnd(bucket, start)
          local id = ValidRecordID(bucket, start, stop)
          if id and not idToPrefix[id] then
            idToPrefix[id] = prefix
            itemCount = itemCount + 1
          else
            bad = true
          end
          start = stop + 2
        end

        if bad then
          local kept, seen, n = {}, {}, 0
          start = 1
          while start <= len do
            local stop = RecordEnd(bucket, start)
            local id = ValidRecordID(bucket, start, stop)
            if id and idToPrefix[id] == prefix and not seen[id] then
              seen[id] = true
              n = n + 1
              kept[n] = strsub(bucket, start, stop)
            else
              dropped = dropped + 1
            end
            start = stop + 2
          end
          if n > 0 then
            items[prefix] = tconcat(kept, RS)
          else
            items[prefix] = nil
          end
        end
      end
    end
  end

  -- A variant entry, a variant record or an idle queue that is damaged is
  -- dropped on its own; the rest of the database is kept
  local db = COBYS_LINKEPEDIA_DB
  if type(db) == "table" then
    if type(db.variants) == "table" then
      local damaged = 0
      for itemID, list in pairs(db.variants) do
        if type(list) ~= "table" then
          db.variants[itemID] = nil
          Warn("Dropped the variant entry for %s: not a table", tostring(itemID))
        else
          -- Before the trim below, whose sort compares these fields
          damaged = damaged + DropDamagedVariants(list)
        end
      end
      if damaged > 0 then
        Warn("Dropped %d damaged variant records", damaged)
      end
      local trimmed = TrimVariants(db.variants)
      if trimmed > 0 then
        Warn("Dropped %d variants past the total cap", trimmed)
      end
    else
      variantTotal = 0
    end
    local scanState = db.scanState
    if type(scanState) == "table" and scanState.pendingIDs ~= nil and type(scanState.pendingIDs) ~= "table" then
      scanState.pendingIDs = nil
      Warn("Dropped scanState.pendingIDs: not a table")
    end
    -- The recipe index is rebuildable, so damage costs only the damaged part
    if Database.ValidateRecipes then Database.ValidateRecipes() end
  end

  generation = generation + 1
  variantGeneration = variantGeneration + 1
  variantEpoch = variantEpoch + 1
  if dropped > 0 then
    Warn("Load dropped %d damaged or duplicate records", dropped)
  end
  indexComplete = true
  Log("Indexed %d items in %d buckets in %.0f ms", itemCount, #prefixList, debugprofilestop() - started)
end

-- Whether the last Load indexed every item (false while none has run, or
-- after one was cut off)
function Database.IsIndexComplete()
  return indexComplete
end

-- Loads again if the last Load did not finish. Returns whether it loaded.
function Database.EnsureIndex()
  if indexComplete then return false end
  Database.Load()
  return true
end

-- Joins every pending record onto its bucket string. Core calls it at
-- PLAYER_LOGOUT so the SavedVariable writer sees everything; reads flush the
-- bucket they touch on their own.
function Database.Flush()
  FlushAll()
end

-- Makes db the live SavedVariable table and indexes it, after flushing the
-- table it replaces. Returns the previous table. The in-game suites run
-- against a scratch database this way and put the player's back after.
-- deferLoad: make db the SavedVariable now but leave the index empty and
-- incomplete until Database.EnsureIndex (for a swap in combat, where a full
-- Load could be cut off; the table the game saves must be right at once)
function Database.ReplaceStorage(db, deferLoad)
  FlushAll()
  local previous = COBYS_LINKEPEDIA_DB
  COBYS_LINKEPEDIA_DB = db
  if deferLoad then
    ResetIndex()
    indexComplete = false
    generation = generation + 1
    variantGeneration = variantGeneration + 1
    variantEpoch = variantEpoch + 1
  else
    Database.Load()
  end
  return previous
end

-- Wipe the item table only, keeping variants, favorites and history. A build
-- scan is advertised as "rebuild from scratch", so nothing from the old table
-- may survive it.
function Database.WipeItems()
  local db = COBYS_LINKEPEDIA_DB
  if type(db) ~= "table" then return end
  db.items = {}
  ResetIndex()
  generation = generation + 1
  Log("Item table wiped for a from-scratch rebuild")
end

-- Empties items, variants, the recipe index and scan state. Any scan (the
-- recipe scan too) is stopped first so nothing refills the emptied tables,
-- capture forgets the links it handled this session, and one DatabaseUpdated
-- follows the replacement (the stop itself fires nothing), then one
-- RecipeIndexUpdated for the emptied recipe index (the Variants tab and the
-- reagent cache in Search/VariantActions.lua listen to it). The reset and
-- corrupt-data dialogs go through here. Favorites, history and saved
-- variants live in COBYS_LINKEPEDIA_STATE and are untouched.
function Database.Reset()
  local Scanner = CobysLinkepedia.Scanner
  if Scanner and Scanner.StopScan then Scanner.StopScan(false) end
  if Scanner and Scanner.CancelRecipeScan then Scanner.CancelRecipeScan(false) end
  if Database.Capture and Database.Capture.ResetSession then
    Database.Capture.ResetSession()
  end

  if type(COBYS_LINKEPEDIA_DB) ~= "table" then
    COBYS_LINKEPEDIA_DB = {}
  end
  local db = COBYS_LINKEPEDIA_DB
  db.items = {}
  db.variants = {}
  variantTotal = 0
  db.scanState = {}
  Database.ClearRecipes()
  ResetIndex()
  generation = generation + 1
  variantGeneration = variantGeneration + 1
  variantEpoch = variantEpoch + 1
  Log("Database reset")
  CobysLinkepedia.EventBus:Fire(CobysLinkepedia.Events.DatabaseUpdated)
  CobysLinkepedia.EventBus:Fire(CobysLinkepedia.Events.RecipeIndexUpdated)
end

-------------------------------------------------------------------------------
-- Writes
-------------------------------------------------------------------------------

-- Store an item (full metadata from scanning). An id already stored, under
-- this prefix or another, is replaced: a rename that crosses a prefix cannot
-- leave a duplicate behind.
function Database.Store(itemID, name, quality, classID, subClassID, itemLevel, reqLevel, expansionID)
  if not Items() then return end
  itemID = tonumber(itemID)
  if not itemID or type(name) ~= "string" or name == "" then return end
  if strfind(name, "[\30\31]") then return end
  local prefix = GetPrefixKey(name)
  if not prefix then return end
  itemID = floor(itemID)

  local old = idToPrefix[itemID]
  if old then
    CutRecord(old, itemID)
  else
    itemCount = itemCount + 1
  end

  local record = itemID .. FS .. name
    .. FS .. Int(quality, 0)
    .. FS .. Int(classID, -1)
    .. FS .. Int(subClassID, -1)
    .. FS .. Int(itemLevel, 0)
    .. FS .. Int(reqLevel, 0)
    .. FS .. Int(expansionID, -1)

  local queue = pending[prefix]
  if not queue then
    queue = {}
    pending[prefix] = queue
  end
  queue[#queue + 1] = record
  idToPrefix[itemID] = prefix
  PrefixIdx(prefix)
  generation = generation + 1
end

-------------------------------------------------------------------------------
-- Variants
--
-- COBYS_LINKEPEDIA_DB.variants[itemID] is a list of records, one for each
-- distinct variant of the base item seen in play:
--   key   the variant's identity: item id, its bonus ids sorted, and its
--         modifier type/value pairs sorted by type. Everything else in the
--         item string (enchant, gems, suffix, unique id, link level,
--         specialization, context, crafter) and the link's colour and name
--         are left out, so one variant seen from different players or in
--         different wrappers is one record. Modifiers stay in: nothing on
--         the client says which of them change the item.
--   link  the most recent full link seen for it
--   ilvl  its actual item level (C_Item.GetDetailedItemLevelInfo); nil until known
--   rank  its crafted or reagent quality, 0 for an item that has none; nil until known
--   seen  when it was first captured (time())
-- Metadata is read when the variant is stored, while its link is fresh;
-- what the client cannot answer yet stays nil and is read again once the
-- item has loaded. An unknown value never equals an explicit qualifier. At
-- most VARIANT_CAP records per item and variantTotalCap in all: a new variant
-- past either evicts the oldest record whose metadata is still unknown, else
-- the oldest overall (from its own item's list for the per-item cap, from any
-- item's for the total). Load trims a database already past the total.
-------------------------------------------------------------------------------
local VARIANT_CAP = 12
local VARIANT_TOTAL_CAP = 5000
local variantTotalCap = VARIANT_TOTAL_CAP
local METADATA_TIMEOUT = 10
local resolving = setmetatable({}, { __mode = "k" })   -- records waiting on an item load

-- A secret value is as good as none here
local function Plain(value)
  if CobySuite_CobysLinkepedia.Utilities.IsSecret(value) then return nil end
  return value
end

local function VariantKey(parsed)
  local bonus = {}
  for i, id in ipairs(parsed.bonusIDs) do bonus[i] = id end
  tsort(bonus)
  local mods = {}
  for i, m in ipairs(parsed.modifiers) do mods[i] = m end
  tsort(mods, function(a, b)
    if a.type ~= b.type then return a.type < b.type end
    return tostring(a.value) < tostring(b.value)
  end)
  local modParts = {}
  for i, m in ipairs(mods) do modParts[i] = m.type .. "=" .. tostring(m.value) end
  return parsed.itemID .. ":" .. tconcat(bonus, ",") .. ":" .. tconcat(modParts, ",")
end

-- Fills whatever metadata the client can answer for the record's link now.
-- Returns whether anything was filled.
local function ReadVariantMeta(v)
  local changed = false
  if v.ilvl == nil then
    local ok, level
    ok, level = pcall(C_Item.GetDetailedItemLevelInfo, v.link)
    level = ok and Plain(level) or nil
    if type(level) == "number" and level > 0 then
      v.ilvl = level
      changed = true
    end
  end
  if v.rank == nil then
    local ok, quality = pcall(C_TradeSkillUI.GetItemCraftedQualityByItemInfo, v.link)
    quality = ok and Plain(quality) or nil
    if type(quality) ~= "number" then
      ok, quality = pcall(C_TradeSkillUI.GetItemReagentQualityByItemInfo, v.link)
      quality = ok and Plain(quality) or nil
    end
    if type(quality) == "number" then
      v.rank = quality
      changed = true
    end
  end
  return changed
end

-- Loads the base item and reads the record's metadata again. Once the item
-- has loaded, a quality the client still cannot give means the item has
-- none (rank 0); an item level it cannot give stays unknown. One load per
-- record at a time; an answer arriving after a reset or load is dropped.
local function ResolveVariantMeta(itemID, v)
  if resolving[v] or (v.ilvl ~= nil and v.rank ~= nil) then return end
  local LoadItemThen = CobysLinkepedia.Utilities.LoadItemThen
  if not LoadItemThen then return end
  resolving[v] = true
  local epoch = variantEpoch
  LoadItemThen(itemID, {
    timeout = METADATA_TIMEOUT,
    onReady = function()
      resolving[v] = nil
      if epoch ~= variantEpoch then return end
      ReadVariantMeta(v)
      if v.rank == nil then v.rank = 0 end
      variantGeneration = variantGeneration + 1
    end,
    onFail = function()
      resolving[v] = nil
    end,
  })
end

-- Whether record a is evicted before record b: unknown metadata first, then
-- the oldest first seen
local function EvictsBefore(a, b)
  local unknownA = a.ilvl == nil or a.rank == nil
  local unknownB = b.ilvl == nil or b.rank == nil
  if unknownA ~= unknownB then return unknownA end
  return (a.seen or 0) < (b.seen or 0)
end

-- Evicts one record from an item's own list (the per-item cap)
local function EvictOne(list)
  local victim
  for i, v in ipairs(list) do
    if not victim or EvictsBefore(v, list[victim]) then victim = i end
  end
  if victim then
    table.remove(list, victim)
    variantTotal = variantTotal - 1
  end
end

-- Evicts the one record, across every item, that goes first (the total cap).
-- An item left with no records loses its list.
local function EvictOneAnywhere(variants)
  local victimID, victimList, victimIndex
  for itemID, list in pairs(variants) do
    for i, v in ipairs(list) do
      if not victimList or EvictsBefore(v, victimList[victimIndex]) then
        victimID, victimList, victimIndex = itemID, list, i
      end
    end
  end
  if not victimList then return end
  table.remove(victimList, victimIndex)
  variantTotal = variantTotal - 1
  if #victimList == 0 then variants[victimID] = nil end
end

-- Keeps the table records of a list, in order, minus any that drop (an
-- optional set) names. Returns how many.
local function CompactList(list, drop)
  local kept = 0
  for i = 1, #list do
    local v = list[i]
    if type(v) == "table" and not (drop and drop[v]) then
      kept = kept + 1
      list[kept] = v
    end
  end
  for i = #list, kept + 1, -1 do list[i] = nil end
  return kept
end

-- Recounts every item's records, dropping any that is not a table, and evicts
-- down to the total cap in one sorted pass. Returns how many were evicted.
TrimVariants = function(variants)
  local all, n = {}, 0
  for itemID, list in pairs(variants) do
    if CompactList(list) == 0 then
      variants[itemID] = nil
    else
      for i = 1, #list do
        n = n + 1
        all[n] = list[i]
      end
    end
  end
  variantTotal = n
  if n <= variantTotalCap then return 0 end

  tsort(all, EvictsBefore)
  local evict = {}
  for i = 1, n - variantTotalCap do evict[all[i]] = true end
  for itemID, list in pairs(variants) do
    if CompactList(list, evict) == 0 then variants[itemID] = nil end
  end
  variantTotal = variantTotalCap
  variantGeneration = variantGeneration + 1
  return n - variantTotalCap
end

-- Stores a variant link for its base item. parsed is Capture.ParseItemLink's
-- result when the caller has it. Returns true for a new variant, false for
-- one already known (its link is refreshed), nil when the link is not a
-- variant of itemID or the database is not ready.
function Database.StoreVariant(itemID, link, parsed)
  local db = COBYS_LINKEPEDIA_DB
  if type(db) ~= "table" or type(db.variants) ~= "table" then return nil end
  itemID = tonumber(itemID)
  if not itemID or type(link) ~= "string" then return nil end
  local Capture = Database.Capture
  parsed = parsed or (Capture and Capture.ParseItemLink(link))
  if not parsed or parsed.itemID ~= itemID or #parsed.bonusIDs == 0 then return nil end

  local key = VariantKey(parsed)
  local list = db.variants[itemID]
  if not list then
    list = {}
    db.variants[itemID] = list
  end
  for _, v in ipairs(list) do
    if v.key == key then
      v.link = link
      return false
    end
  end

  local v = { key = key, link = link, seen = time() }
  ReadVariantMeta(v)
  if #list >= VARIANT_CAP then EvictOne(list) end
  if variantTotal >= variantTotalCap then
    EvictOneAnywhere(db.variants)
    -- The victim may have been this item's last record, taking its list
    db.variants[itemID] = list
  end
  list[#list + 1] = v
  variantTotal = variantTotal + 1
  variantGeneration = variantGeneration + 1
  ResolveVariantMeta(itemID, v)
  return true
end

-- Drops the variants of items that no longer exist. The scanner calls it when
-- a Build completes. A base the Build did not store is no proof: the server
-- can withhold an item's full data for the whole pass (the item is then
-- deferred to the idle queue, or dropped past the queue's cap), and an item
-- past the discovery gap is never asked for. So a list goes only when its
-- base is not indexed and the client does not know the item id at all
-- (C_Item.GetItemInfoInstant answers from the client's own data, at most one
-- call per variant list). Returns how many items lost their variants.
function Database.PruneVariants()
  local db = COBYS_LINKEPEDIA_DB
  if type(db) ~= "table" or type(db.variants) ~= "table" then return 0 end
  local pruned, kept = 0, 0
  for itemID, list in pairs(db.variants) do
    if not idToPrefix[itemID] then
      if type(itemID) == "number" and C_Item.GetItemInfoInstant(itemID) ~= nil then
        kept = kept + 1
      else
        variantTotal = variantTotal - #list
        db.variants[itemID] = nil
        pruned = pruned + 1
      end
    end
  end
  if pruned > 0 then
    variantGeneration = variantGeneration + 1
    Log("Pruned the variants of %d items the game no longer has", pruned)
  end
  if kept > 0 then
    Log("Kept the variants of %d items the database does not hold but the game still knows", kept)
  end
  return pruned
end

-- The identity key a variant record carries (see above) for any item link
-- or item string, or nil when it is not one. Saved variants dedupe by it.
function Database.VariantKeyForLink(link)
  local Capture = Database.Capture
  local parsed = Capture and Capture.ParseItemLink(link)
  return parsed and VariantKey(parsed) or nil
end

-- Changes whenever the variant lists do; compare, never interpret
function Database.GetVariantGeneration()
  return variantGeneration
end

-- How many variant records are stored across every item
function Database.GetVariantTotal()
  return variantTotal
end

-- Sets the total cap (nil restores the default, 5,000) and evicts down to it
-- now. Returns the previous cap. For the in-game suites.
function Database.SetVariantTotalCap(cap)
  local previous = variantTotalCap
  variantTotalCap = tonumber(cap) or VARIANT_TOTAL_CAP
  local db = COBYS_LINKEPEDIA_DB
  if type(db) == "table" and type(db.variants) == "table" then
    TrimVariants(db.variants)
  end
  return previous
end

-- Remove an item. The name is accepted for callers that have it; the index
-- knows the bucket either way.
function Database.Remove(itemID, name)
  local prefix = idToPrefix[itemID]
  if not prefix then return false end
  CutRecord(prefix, itemID)
  idToPrefix[itemID] = nil
  itemCount = itemCount - 1
  generation = generation + 1
  return true
end

-------------------------------------------------------------------------------
-- Counts and iteration
-------------------------------------------------------------------------------

function Database.GetCount()
  return itemCount
end

-- Changes whenever the item table is written; compare, never interpret.
function Database.GetGeneration()
  return generation
end

-- Calls fn(itemID) once for every stored item. Order is unspecified; fn must
-- not store or remove.
function Database.ForEachID(fn)
  for id in pairs(idToPrefix) do
    fn(id)
  end
end

-- Calls fn(itemID, name, quality, classID, subClassID, itemLevel, reqLevel,
-- expansionID) for every stored item. Order is unspecified. The in-game
-- suites build their oracle from this and check Search and the browse
-- builder against it.
function Database.ForEach(fn)
  local items = Items()
  if not items then return end
  FlushAll()
  for _, bucket in pairs(items) do
    local len, start = #bucket, 1
    while start <= len do
      local stop = RecordEnd(bucket, start)
      local id, name, q, c, sc, il, rl, e = ParseAt(bucket, start)
      if id then
        fn(id, name, q, c, sc, il, rl, e)
      end
      start = stop + 2
    end
  end
end

-- Item counts by quality and by item class, for the stats tab. Class comes
-- from the stored field; an entry that stored none (-1) falls back to the
-- instant API, as the search filters do.
function Database.ComputeItemStats()
  local stats = { totalItems = 0, bucketCount = 0, qualityCounts = {}, typeCounts = {} }
  local items = Items()
  if not items then return stats end
  FlushAll()

  local qualityCounts, typeCounts = stats.qualityCounts, stats.typeCounts
  for _, bucket in pairs(items) do
    stats.bucketCount = stats.bucketCount + 1
    local len, start = #bucket, 1
    while start <= len do
      local stop = RecordEnd(bucket, start)
      local idStr, qStr, cStr = strmatch(bucket, STATS, start)
      if idStr then
        stats.totalItems = stats.totalItems + 1
        local q = tonumber(qStr) or 0
        qualityCounts[q] = (qualityCounts[q] or 0) + 1

        local classID = tonumber(cStr)
        if not classID or classID < 0 then
          local _, _, _, _, _, cid = C_Item.GetItemInfoInstant(tonumber(idStr))
          classID = cid
        end
        if classID and classID >= 0 then
          typeCounts[classID] = (typeCounts[classID] or 0) + 1
        end
      end
      start = stop + 2
    end
  end
  return stats
end

-------------------------------------------------------------------------------
-- Lookups
-------------------------------------------------------------------------------

-- Direct item ID lookup
function Database.GetItem(itemID)
  local prefix = idToPrefix[itemID]
  if not prefix then return nil end
  local bucket = Bucket(prefix)
  if not bucket then return nil end
  local start = FindRecord(bucket, itemID)
  if not start then return nil end
  local id, name, q, c, sc, il, rl, e = ParseAt(bucket, start)
  if not id then return nil end
  return NewItem(id, name, q, c, sc, il, rl, e)
end

-- Exact case-insensitive name lookup (used by auto-linkify). One
-- case-insensitive find over the name's own bucket: the name field is the
-- only field bounded by \31 on both sides that can hold letters, and a name
-- without letters is confirmed against the record before it is returned.
-- It runs at send for each [bracketed] name; ${n=...} tokens reach it through
-- Linkify.ResolveTokenItem (send, the macro panel and editor), which keeps
-- each name's answer until the database generation moves.
function Database.GetExact(name)
  if type(name) ~= "string" or name == "" then return nil end
  if strfind(name, "[\30\31]") then return nil end
  local prefix = GetPrefixKey(name)
  local bucket = prefix and Bucket(prefix)
  if not bucket then return nil end

  -- Several ids can share a name (quest versions, reissued gear): the
  -- highest quality wins, then the lowest id
  local pattern = FS .. CasePattern(name) .. FS
  local best
  local init = 1
  while true do
    local p = strfind(bucket, pattern, init)
    if not p then break end
    local recordStart = RecordStart(bucket, p)
    local id, n, q, c, sc, il, rl, e, nameStart = ParseAt(bucket, recordStart)
    if id and nameStart == p + 1 then
      if not best or q > best.quality or (q == best.quality and id < best.itemID) then
        best = NewItem(id, n, q, c, sc, il, rl, e)
      end
      init = RecordEnd(bucket, recordStart) + 2
    else
      init = p + 1
    end
  end
  return best
end

-- Rank descending, then item level descending, then first seen; an unknown
-- value sorts after every known one
local function VariantBefore(a, b)
  local ra, rb = a.rank or -1, b.rank or -1
  if ra ~= rb then return ra > rb end
  local la, lb = a.ilvl or -1, b.ilvl or -1
  if la ~= lb then return la > lb end
  return (a.seen or 0) < (b.seen or 0)
end

-- The item's variant records, best first (VariantBefore), or nil when it has
-- none. These are the stored records: read them, never change them. Records
-- with unknown metadata get another read, and a load when that is not enough.
function Database.GetVariants(itemID)
  local db = COBYS_LINKEPEDIA_DB
  if type(db) ~= "table" or type(db.variants) ~= "table" then return nil end
  local list = db.variants[itemID]
  if not list or #list == 0 then return nil end

  local ordered = {}
  for i, v in ipairs(list) do
    if v.ilvl == nil or v.rank == nil then
      if ReadVariantMeta(v) then variantGeneration = variantGeneration + 1 end
      ResolveVariantMeta(itemID, v)
    end
    ordered[i] = v
  end
  tsort(ordered, VariantBefore)
  return ordered
end

-- For callers that only need to know how many variants exist (the dropdown
-- marker, the detail pane count)
function Database.GetVariantCount(itemID)
  if not COBYS_LINKEPEDIA_DB or not COBYS_LINKEPEDIA_DB.variants then return 0 end
  local variants = COBYS_LINKEPEDIA_DB.variants[itemID]
  return variants and #variants or 0
end

-- The variant link a [Name~qualifier] asks for. With no qualifier, the best
-- captured variant. With qualifiers, the best variant whose stored rank
-- and item level equal every qualifier given; unknown metadata never
-- matches. nil when nothing does.
function Database.MatchVariant(itemID, rank, ilvl)
  local variants = Database.GetVariants(itemID)
  if not variants then return nil end
  if not rank and not ilvl then return variants[1].link end
  for _, v in ipairs(variants) do
    if (not rank or v.rank == rank) and (not ilvl or v.ilvl == ilvl) then
      return v.link
    end
  end
  return nil
end

-------------------------------------------------------------------------------
-- Whole-word matching, shared by Search and the query build
-------------------------------------------------------------------------------
-- Is the match at `pos` (length wordLen) on word boundaries? An ASCII letter
-- or an apostrophe on either side continues the word; any other byte (digits,
-- the bytes of accented letters, the separators) is a boundary.
local function IsWholeWord(text, pos, wordLen)
  if pos > 1 then
    local before = strbyte(text, pos - 1)
    if (before >= 97 and before <= 122) or (before >= 65 and before <= 90) or before == 39 then
      return false
    end
  end
  local after = pos + wordLen
  if after <= #text then
    local ch = strbyte(text, after)
    if (ch >= 97 and ch <= 122) or (ch >= 65 and ch <= 90) or ch == 39 then
      return false
    end
  end
  return true
end

-- First occurrence of `pattern` (a CasePattern, `wordLen` bytes long) at or
-- after init that sits on word boundaries
local function FindWholeWord(text, pattern, wordLen, init)
  local start = init or 1
  while true do
    local pos = strfind(text, pattern, start)
    if not pos then return nil end
    if IsWholeWord(text, pos, wordLen) then return pos end
    start = pos + 1
  end
end

-- First occurrence of plain lowercase needle at or after init that sits on
-- word boundaries, in lowercased text
local function FindWholeWordPlain(text, needle, init)
  local start = init or 1
  while true do
    local pos = strfind(text, needle, start, true)
    if not pos then return nil end
    if IsWholeWord(text, pos, #needle) then return pos end
    start = pos + 1
  end
end

-- The terms of a query for the "any" and "all" search modes, lowercased:
-- each word between spaces, and a "quoted phrase" kept whole and matched on
-- word boundaries. A quote with no partner is dropped.
local function QueryTerms(query)
  local terms, pos, len = {}, 1, #query
  while pos <= len do
    local _, phraseEnd, phrase = strfind(query, '^"([^"]*)"', pos)
    if phraseEnd then
      if phrase ~= "" then terms[#terms + 1] = { text = strlower(phrase), whole = true } end
      pos = phraseEnd + 1
    else
      local wordStart, wordEnd = strfind(query, '^[^%s"]+', pos)
      if wordStart then
        terms[#terms + 1] = { text = strlower(strsub(query, wordStart, wordEnd)), whole = false }
        pos = wordEnd + 1
      else
        pos = pos + 1   -- a space, or a lone quote
      end
    end
  end
  return terms
end

-- Does a lowercased name hold the term?
local function NameHasTerm(name, term)
  if term.whole then return FindWholeWordPlain(name, term.text, 1) ~= nil end
  return strfind(name, term.text, 1, true) ~= nil
end

-------------------------------------------------------------------------------
-- Browse builder: every item in default order, built across frames
--
-- Browse mode (empty query) walks the buckets under a per-frame time budget
-- and keeps only (itemID, handle) pairs; the results view materialises a
-- result table only for the rows it draws. With a query the same walk keeps
-- only the items whose name holds it, which is how the search window runs a
-- text search: a match costs two array slots, never a result table, however
-- many items match.
--
-- The budget is checked inside a bucket too, every WALK_CHECK records, so the
-- largest bucket (thousands of records) no longer makes one long frame; a
-- bucket's items join the output only when its walk ends.
--
-- There is no global sort. Prefixes are visited in sorted order and each
-- bucket's lowered names are sorted once with Lua's own string order (a
-- table.sort without a comparator function, so the comparisons run in C), so
-- within one quality every item arrives in case-insensitive name order, and
-- concatenating the quality groups highest first yields "quality descending,
-- then name" directly. The walk also records that same name order across all
-- qualities, which Finish turns into positions (a name column sort is then a
-- copy, not a sort).
--
-- Each bucket is lowercased once per walk and read in that form: lowercasing
-- changes no byte offsets, so handles stay valid, and a record yields its
-- lowered name as its only string.
-------------------------------------------------------------------------------
local WALK_CHECK = 256              -- records (or hits) between budget checks inside a bucket
local GROUP_SCALE = 1048576         -- 2^20: quality * GROUP_SCALE + index within the group
local FINISH_PAUSE_EVERY = 4096     -- entries between pause() calls in Finish

-- filters: type, quality, expansion. query: nil or "" for every item, else
-- text an item's name must hold, case-insensitive. mode says how the query
-- reads:
--   "exact" (the default): the text as typed, one piece; "quoted" for whole
--     words, as Database.Search reads it
--   "all": every word of it, in any order and anywhere in the name
--   "any": at least one of its words
-- In "all" and "any" a "quoted phrase" is one term matched on whole words.
-- "all" walks the records that hold its longest term and checks the others
-- in the name; "any" with two or more terms examines every record, as a
-- browse does, and a single term walks like "all".
function Database.NewBrowseBuilder(filters, query, mode)
  local items = Items()
  FlushAll()
  local filterType = filters and filters.type
  local filterQuality = filters and filters.quality
  local filterExpansion = filters and filters.expansion
  local filtered = (filterType or filterQuality or filterExpansion) and true or false

  -- needle drives the walk; others (mode "all") must be in the name too;
  -- anyTerms (mode "any") replaces the needle with a check of every record
  local needle, wholeWord, others, anyTerms = nil, false, nil, nil
  local impossible = false
  local hasQuery = type(query) == "string" and query ~= ""
  if hasQuery and (mode == "all" or mode == "any") then
    local terms = {}
    for _, term in ipairs(QueryTerms(query)) do
      -- A term holding a record separator is in no name
      if strfind(term.text, "[\30\31]") then
        if mode == "all" then impossible = true end
      else
        terms[#terms + 1] = term
      end
    end
    if #terms == 0 then
      impossible = true
    elseif mode == "any" and #terms > 1 then
      anyTerms = terms
    else
      -- "all", or a single term: the longest term finds the records
      local driver = 1
      for i = 2, #terms do
        if #terms[i].text > #terms[driver].text then driver = i end
      end
      needle, wholeWord = terms[driver].text, terms[driver].whole
      if #terms > 1 then
        others = {}
        for i, term in ipairs(terms) do
          if i ~= driver then others[#others + 1] = term end
        end
      end
    end
  elseif hasQuery then
    needle = query
    if #needle >= 2 and strsub(needle, 1, 1) == '"' and strsub(needle, -1) == '"' then
      needle = strsub(needle, 2, -2)
      wholeWord = true
    end
    needle = strlower(needle)
    -- A query nothing can match leaves the walk empty
    impossible = needle == "" or strfind(needle, "[\30\31]") ~= nil
  end

  -- The name test after the walk's own: every other term, or any term
  local function NameMatches(name)
    if others then
      for i = 1, #others do
        if not NameHasTerm(name, others[i]) then return false end
      end
      return true
    end
    if anyTerms then
      for i = 1, #anyTerms do
        if NameHasTerm(name, anyTerms[i]) then return true end
      end
      return false
    end
    return true
  end
  local checkName = (others or anyTerms) and true or false

  local pattern
  if needle then
    pattern = filtered and BROWSE_SPAN_FULL or BROWSE_SPAN_MIN
  else
    pattern = filtered and BROWSE_FULL or BROWSE_MIN
  end

  local prefixes = {}
  if items and not impossible then
    for prefix in pairs(items) do
      prefixes[#prefixes + 1] = prefix
    end
    -- Prefix keys are uppercase but the per-bucket sort below is on lowercased
    -- names; the two orders disagree for the six ASCII characters between "Z"
    -- and "a", so compare prefixes lowercased too and the base order is one
    -- consistent case-insensitive name order.
    tsort(prefixes, function(a, b)
      return strlower(a) < strlower(b)
    end)
  end

  local groups = {}
  for q = 0, MAX_QUALITY do
    groups[q] = { ids = {}, entries = {}, n = 0 }
  end
  -- name order over all qualities: quality * GROUP_SCALE + group index. A
  -- walk of every item knows its size roughly in advance
  local nameCodes = (filtered or needle or anyTerms) and {} or NewArray(itemCount)
  local nameCount = 0

  local builder = {
    total = #prefixes,        -- buckets to walk
    position = 0,             -- buckets opened so far
    visited = 0,              -- records examined (the whole walk, for the Browse suite)
    emitted = 0,              -- items in the output so far
    closing = 0,              -- slices of bucket closes run (each does some of the work)
    done = (#prefixes == 0),
  }

  -- The bucket being walked: its lowered text, the walk's cursor and the
  -- kept records (id, handle, quality, lowered name)
  local cur

  local function Open(prefix)
    local bucket = items[prefix]
    if not bucket then return nil end
    local lower = strlower(bucket)
    return {
      lower = lower, len = #lower, base = PrefixIdx(prefix) * HANDLE_BASE,
      cursor = 1, walked = false,
      ids = {}, handles = {}, quals = {}, names = {}, n = 0,
    }
  end

  local function Keep(c, id, start, qStr, name, cStr, eStr)
    local q = tonumber(qStr) or 0
    if filtered and not PassesFilters(id, q, tonumber(cStr), tonumber(eStr), filterType, filterQuality, filterExpansion) then
      return
    end
    local n = c.n + 1
    c.n = n
    c.ids[n] = id
    c.handles[n] = c.base + start
    c.quals[n] = q
    c.names[n] = name
  end

  -- Walks the current bucket until it ends (returns true) or the budget is
  -- spent (returns false); at least one check's worth of work either way
  local function Walk(c, frameStart, budgetMs)
    local lower, len = c.lower, c.len
    local sinceCheck = 0
    if needle then
      -- Only the records the needle lands in, each at most once
      local init = c.cursor
      while init <= len do
        local p
        if wholeWord then
          p = FindWholeWordPlain(lower, needle, init)
        else
          p = strfind(lower, needle, init, true)
        end
        if not p then
          init = len + 1
          break
        end
        local start = RecordStart(lower, p)
        local idStr, nameStart, name, nameStop, qStr, cStr, eStr = strmatch(lower, pattern, start)
        if not idStr then
          init = p + 1
        elseif p < nameStart then
          -- A digit needle hit the id field; the name is still ahead
          init = nameStart
        else
          if p < nameStop and (not checkName or NameMatches(name)) then
            Keep(c, tonumber(idStr), start, qStr, name, cStr, eStr)
          end
          init = RecordEnd(lower, start) + 2
          builder.visited = builder.visited + 1
        end
        sinceCheck = sinceCheck + 1
        if sinceCheck >= WALK_CHECK then
          sinceCheck = 0
          if (debugprofilestop() - frameStart) >= budgetMs then
            c.cursor = init
            return init > len
          end
        end
      end
      c.cursor = init
      return true
    end

    local start = c.cursor
    while start <= len do
      local stop = RecordEnd(lower, start)
      builder.visited = builder.visited + 1
      local idStr, name, qStr, cStr, eStr = strmatch(lower, pattern, start)
      if idStr and (not checkName or NameMatches(name)) then
        Keep(c, tonumber(idStr), start, qStr, name, cStr, eStr)
      end
      start = stop + 2
      sinceCheck = sinceCheck + 1
      if sinceCheck >= WALK_CHECK then
        sinceCheck = 0
        if (debugprofilestop() - frameStart) >= budgetMs then
          c.cursor = start
          return start > len
        end
      end
    end
    c.cursor = start
    return true
  end

  local function Emit(c, src)
    local q = c.quals[src]
    if q < 0 or q > MAX_QUALITY then q = 0 end
    local g = groups[q]
    local gn = g.n + 1
    g.n = gn
    g.ids[gn] = c.ids[src]
    g.entries[gn] = c.handles[src]
    nameCount = nameCount + 1
    nameCodes[nameCount] = q * GROUP_SCALE + gn
  end

  -- Puts a walked bucket's items into the output in name order. The lowered
  -- names are sorted in place by Lua's own string order; a name-to-record
  -- index finds each record again. Records sharing a name go highest quality
  -- first, then in stored order (only those few lists need a comparator).
  -- Three phases (index the names, sort, emit), each resumable, so a large
  -- bucket's close spreads over steps like its walk. Returns true when done.
  local function Close(c, frameStart, budgetMs)
    local n, names, quals = c.n, c.names, c.quals
    local function Spent(i)
      return i % WALK_CHECK == 0 and (debugprofilestop() - frameStart) >= budgetMs
    end

    if not c.phase then
      c.phase, c.i, c.slot = 1, 1, {}
    end
    if c.phase == 1 then
      local slot, shared = c.slot, c.shared
      for i = c.i, n do
        local name = names[i]
        local s = slot[name]
        if s == nil then
          slot[name] = i
        elseif type(s) == "number" then
          local list = { s, i, taken = 0 }
          slot[name] = list
          shared = shared or {}
          shared[#shared + 1] = list
        else
          s[#s + 1] = i
        end
        if Spent(i) and i < n then
          c.i, c.shared = i + 1, shared
          builder.closing = builder.closing + 1
          return false
        end
      end
      if shared then
        local function HigherQualityFirst(a, b)
          local qa, qb = quals[a], quals[b]
          if qa ~= qb then return qa > qb end
          return a < b
        end
        for _, list in ipairs(shared) do
          tsort(list, HigherQualityFirst)
        end
      end
      c.phase, c.shared = 2, nil
      builder.closing = builder.closing + 1
      if (debugprofilestop() - frameStart) >= budgetMs then return false end
    end
    if c.phase == 2 then
      if n > 1 then tsort(names) end
      c.phase, c.i = 3, 1
      builder.closing = builder.closing + 1
      if (debugprofilestop() - frameStart) >= budgetMs then return false end
    end
    local slot = c.slot
    for k = c.i, n do
      local s = slot[names[k]]
      if type(s) == "number" then
        Emit(c, s)
      else
        s.taken = s.taken + 1
        Emit(c, s[s.taken])
      end
      if Spent(k) and k < n then
        c.i = k + 1
        builder.emitted = nameCount
        builder.closing = builder.closing + 1
        return false
      end
    end
    builder.emitted = nameCount
    builder.closing = builder.closing + 1
    return true
  end

  -- Walks until budgetMs is spent (always some work, even on a zero budget).
  -- Returns true once every bucket has been walked and closed.
  function builder:Step(budgetMs)
    if self.done then return true end
    local frameStart = debugprofilestop()
    repeat
      if cur and cur.walked then
        if Close(cur, frameStart, budgetMs) then cur = nil end
      else
        if not cur then
          if self.position >= self.total then break end
          self.position = self.position + 1
          cur = Open(prefixes[self.position])
        end
        if cur then cur.walked = Walk(cur, frameStart, budgetMs) end
      end
    until (debugprofilestop() - frameStart) >= budgetMs
    self.done = (self.position >= self.total) and cur == nil
    return self.done
  end

  -- How far the walk is, 0 to 1 (buckets opened, and the open one's cursor)
  function builder:GetProgress()
    if self.total == 0 then return 1 end
    local partial = 0
    if cur and cur.len > 0 then partial = math.min(1, (cur.cursor - 1) / cur.len) end
    return math.max(0, math.min(1, (self.position - 1 + partial) / self.total))
  end

  -- Concatenates the quality groups into two flat position-indexed arrays.
  -- descending (the default) puts the highest quality first. Also returns the
  -- span of each non-empty group ({from, to} in output order) and nameOrder:
  -- the output positions in case-insensitive name order over every quality
  -- (records sharing a name: highest quality first in a descending Finish).
  -- pause, when given, is called every FINISH_PAUSE_EVERY entries (the
  -- results view passes one that yields its coroutine when the frame's budget
  -- is spent). Before the walk ends a Finish holds what has been emitted so
  -- far (builder.emitted items).
  function builder:Finish(descending, pause)
    local ids, entries, n = NewArray(nameCount), NewArray(nameCount), 0
    local bounds = {}
    local groupStart = {}
    local from, to, step = MAX_QUALITY, 0, -1
    if descending == false then
      from, to, step = 0, MAX_QUALITY, 1
    end
    for q = from, to, step do
      local g = groups[q]
      groupStart[q] = n + 1
      if g.n > 0 then
        local first = n + 1
        local gIDs, gEntries = g.ids, g.entries
        for k = 1, g.n do
          n = n + 1
          ids[n] = gIDs[k]
          entries[n] = gEntries[k]
          if pause and n % FINISH_PAUSE_EVERY == 0 then pause() end
        end
        bounds[#bounds + 1] = { from = first, to = n }
      end
    end

    local nameOrder = NewArray(nameCount)
    for i = 1, nameCount do
      local code = nameCodes[i]
      local q = floor(code / GROUP_SCALE)
      nameOrder[i] = groupStart[q] + (code - q * GROUP_SCALE) - 1
      if pause and i % FINISH_PAUSE_EVERY == 0 then pause() end
    end
    return ids, entries, n, bounds, nameOrder
  end

  return builder
end

-- A result table for one entry handle, built on demand by the results view
-- for the rows it actually draws. A handle a cut has moved falls back to the
-- index; an item removed outright yields an empty placeholder rather than
-- nil, so a row drawn between the write and the next refresh still has
-- something to show.
function Database.MaterializeEntry(itemID, handle)
  if type(handle) == "number" then
    local prefix, start = Decode(handle)
    local bucket = prefix and Bucket(prefix)
    if bucket then
      local id, name, q, c, sc, il, rl, e = ParseAt(bucket, start)
      if id == itemID then
        return NewItem(id, name, q, c, sc, il, rl, e)
      end
    end
  end
  return Database.GetItem(itemID) or NewItem(itemID, "", 0, -1, -1, 0, 0, -1)
end

-- Numeric field n of the record at handle when the record is itemID's, else
-- the same field through the index (nil when the item is gone)
local FALLBACK_FIELD = { [3] = "quality", [4] = "_classID", [5] = "_subClassID", [6] = "itemLevel", [7] = "reqLevel", [8] = "_expansionID" }
local function FieldOf(itemID, handle, n, current)
  if type(handle) == "number" then
    local prefix, start = Decode(handle)
    local bucket = prefix and Bucket(prefix)
    if bucket and current then
      local v = strmatch(bucket, VALUE[n], start)
      if v then return tonumber(v) end
    elseif bucket then
      local idStr, v = strmatch(bucket, FIELD[n], start)
      if idStr and tonumber(idStr) == itemID then
        return tonumber(v)
      end
    end
  end
  local item = Database.GetItem(itemID)
  return item and item[FALLBACK_FIELD[n]] or nil
end

local function NameOf(itemID, handle)
  if type(handle) == "number" then
    local prefix, start = Decode(handle)
    local bucket = prefix and Bucket(prefix)
    if bucket then
      local idStr, name = strmatch(bucket, ID_NAME, start)
      if idStr and tonumber(idStr) == itemID then
        return name
      end
    end
  end
  local item = Database.GetItem(itemID)
  return item and item.name or ""
end

-- Sort key for a results column, read straight from the record so a column
-- sort over a whole list never materialises 176K result tables. String
-- columns are lowercased, so text sorts ignore case. Every column yields
-- one type (number or string) so the comparator is total.
-- current: the handle was made at the database's present generation
-- (Database.GetGeneration), so it still points at its own record and the
-- item id is not read back. Every write that can move a record bumps the
-- generation.
function Database.EntrySortKey(itemID, handle, column, current)
  if column == "itemID" then
    return itemID
  elseif column == "name" then
    return strlower(NameOf(itemID, handle))
  elseif column == "quality" then
    return FieldOf(itemID, handle, 3, current) or 0
  elseif column == "itemLevel" then
    return FieldOf(itemID, handle, 6, current) or 0
  elseif column == "reqLevel" then
    return FieldOf(itemID, handle, 7, current) or 0
  end

  local U = CobysLinkepedia.Utilities
  if column == "type" then
    return strlower(U.GetClassName(FieldOf(itemID, handle, 4, current)) or "")
  elseif column == "subType" then
    return strlower(U.GetSubClassName(FieldOf(itemID, handle, 4, current), FieldOf(itemID, handle, 5, current)) or "")
  elseif column == "expansion" then
    local expID = FieldOf(itemID, handle, 8, current)
    return strlower((expID and expID >= 0 and U.ExpansionNames[expID]) or "")
  end
  return 0
end

-------------------------------------------------------------------------------
-- Search
-------------------------------------------------------------------------------

-- Primary search: prefix matches, then substring matches, each group in
-- RanksBefore order, cut to maxResults (0 or less for no cap)
-- Supports quoted queries: "test" matches whole-word only
--
-- Each bucket is searched as one string. Every hit is placed against the
-- name span of the record it landed in: inside the name it counts (a prefix
-- match when it starts the name field), before it (the id, for digit
-- queries) the search moves to the name, after it the record is skipped.
-- Nothing is assumed about which fields can hold which bytes. After a hit
-- the search continues past that record, so a name matching twice yields
-- one result.
--
-- A match at the start of a name can only sit in a bucket whose key starts
-- the way the query does: the query's own two-character key, or for a
-- one-character query every key beginning with that character. Those buckets
-- go first. Every prefix match ranks before every substring match, so once a
-- capped search holds its cap of prefix matches the other buckets cannot
-- change the result and are skipped; otherwise every bucket is walked, so a
-- better match stored anywhere is never dropped.
--
-- Database.NewSearch returns the search as a stepper that works under a time
-- budget (checked inside a bucket too), for typing in a search box;
-- Database.Search runs one to the end at once.
local SEARCH_CHECK = 256   -- hits between budget checks inside a bucket

function Database.NewSearch(text, maxResults, filters)
  local search = { done = true }
  function search:Step() return true end
  function search:Results() return {} end

  local items = Items()
  if not items then return search end
  maxResults = maxResults or 20

  -- An empty query is not a search. Browsing every item in default order is
  -- owned by NewBrowseBuilder, which does it across frames.
  if type(text) ~= "string" or text == "" then return search end

  local filterType = filters and filters.type
  local filterQuality = filters and filters.quality
  local filterExpansion = filters and filters.expansion

  -- Detect quoted whole-word search
  local wholeWord = false
  local searchText = text
  if #searchText >= 2 and strsub(searchText, 1, 1) == '"' and strsub(searchText, -1) == '"' then
    searchText = strsub(searchText, 2, -2)
    wholeWord = true
    if searchText == "" then return search end
  end
  if strfind(searchText, "[\30\31]") then return search end

  FlushAll()

  local prefix = GetPrefixKey(searchText)
  local pattern = CasePattern(searchText)
  local wordLen = #searchText

  local prefixResults = {}
  local substringResults = {}
  local noCap = maxResults <= 0
  local K = noCap and huge or maxResults

  -- Offers a match to one result group. Uncapped groups take every match
  -- and are sorted once at the end. A capped group holds its best K in
  -- order (binary search and shift; K is small), and a match that cannot
  -- make it is dropped before a result table is built for it.
  local function Offer(list, id, name, q, c, sc, il, rl, e, isSubstring)
    local n = #list
    if not noCap and n >= K then
      local worst = list[n]
      if not RanksBefore(q, name, id, worst.quality, worst.name, worst.itemID) then return end
    end
    local item = NewItem(id, name, q, c, sc, il, rl, e)
    if isSubstring then item.isSubstring = true end
    if noCap then
      list[n + 1] = item
      return
    end
    local lo, hi = 1, n + 1
    while lo < hi do
      local mid = floor((lo + hi) / 2)
      local m = list[mid]
      if RanksBefore(q, name, id, m.quality, m.name, m.itemID) then
        hi = mid
      else
        lo = mid + 1
      end
    end
    tinsert(list, lo, item)
    if n + 1 > K then list[n + 1] = nil end
  end

  -- Walks one bucket from init, offering every match. Returns the position
  -- to resume from, or nil once the bucket is done. With a budget it stops
  -- every SEARCH_CHECK hits to look at the clock.
  local function Scan(bucket, init, frameStart, budgetMs)
    local len = #bucket
    local sinceCheck = 0
    while init <= len do
      local p
      if wholeWord then
        p = FindWholeWord(bucket, pattern, wordLen, init)
      else
        p = strfind(bucket, pattern, init)
      end
      if not p then return nil end

      local id, name, q, c, sc, il, rl, e, nameStart, nameEnd = ParseAt(bucket, RecordStart(bucket, p))
      if not id then
        init = p + 1
      elseif p < nameStart then
        -- A digit query hit the id field; the name is still ahead
        init = nameStart
      else
        if p <= nameEnd and PassesFilters(id, q, c, e, filterType, filterQuality, filterExpansion) then
          if p == nameStart then
            Offer(prefixResults, id, name, q, c, sc, il, rl, e, false)
          else
            Offer(substringResults, id, name, q, c, sc, il, rl, e, true)
          end
        end
        init = RecordEnd(bucket, nameEnd + 1) + 2
      end
      if budgetMs then
        sinceCheck = sinceCheck + 1
        if sinceCheck >= SEARCH_CHECK then
          sinceCheck = 0
          if (debugprofilestop() - frameStart) >= budgetMs then
            return init <= len and init or nil
          end
        end
      end
    end
    return nil
  end

  -- The walk: the buckets that can hold prefix matches, then the rest
  local order, candidates = {}, 0
  if prefix then
    if #prefix >= 2 then
      if items[prefix] then order[1] = prefix end
    else
      for key in pairs(items) do
        if strsub(key, 1, 1) == prefix then order[#order + 1] = key end
      end
    end
  end
  candidates = #order
  local isCandidate = {}
  for i = 1, candidates do isCandidate[order[i]] = true end
  for key in pairs(items) do
    if not isCandidate[key] then order[#order + 1] = key end
  end

  local position, cursor = 0, nil   -- the bucket being walked and where in it
  search.done = false

  -- Walks until budgetMs is spent (nil: to the end). Returns true when done.
  function search:Step(budgetMs)
    if self.done then return true end
    local frameStart = budgetMs and debugprofilestop()
    while true do
      if not cursor then
        -- Enough prefix matches from the candidate buckets: nothing else can rank higher
        if position >= candidates and not noCap and #prefixResults >= K then break end
        position = position + 1
        if position > #order then break end
        cursor = 1
      end
      local bucket = items[order[position]]
      cursor = bucket and Scan(bucket, cursor, frameStart, budgetMs) or nil
      if budgetMs and (debugprofilestop() - frameStart) >= budgetMs then
        if cursor or position < #order then return false end
      end
    end
    self.done = true
    return true
  end

  -- Prefix matches first, then substring matches, cut to the cap
  function search:Results()
    if noCap then
      tsort(prefixResults, ByRank)
      tsort(substringResults, ByRank)
    end
    local results = {}
    for _, item in ipairs(prefixResults) do
      if #results >= K then break end
      results[#results + 1] = item
    end
    for _, item in ipairs(substringResults) do
      if #results >= K then break end
      results[#results + 1] = item
    end
    return results
  end

  return search
end

function Database.Search(text, maxResults, filters)
  local search = Database.NewSearch(text, maxResults, filters)
  search:Step()
  return search:Results()
end

-- Runs a search across frames under budgetMs (default 6) and calls
-- onDone(results) when it ends: at once when the first slice finishes it.
-- Returns a function that cancels it (onDone is then never called). The
-- frames that drive it are built here at load, never in combat; with all of
-- them busy a search finishes at once instead.
local searchFrames = {}
for i = 1, 4 do searchFrames[i] = CreateFrame("Frame") end
function Database.SearchAsync(text, maxResults, filters, onDone, budgetMs)
  budgetMs = budgetMs or 6
  local search = Database.NewSearch(text, maxResults, filters)
  if search:Step(budgetMs) or #searchFrames == 0 then
    search:Step()
    onDone(search:Results())
    return function() end
  end
  local frame = tremove(searchFrames)
  local cancelled = false
  local function Release()
    frame:SetScript("OnUpdate", nil)
    searchFrames[#searchFrames + 1] = frame
  end
  frame:SetScript("OnUpdate", function()
    if search:Step(budgetMs) then
      Release()
      onDone(search:Results())
    end
  end)
  return function()
    if cancelled then return end
    cancelled = true
    if not search.done then Release() end
  end
end

-------------------------------------------------------------------------------
-- Reset and corrupt-data dialogs: named (Escape closes them through
-- UISpecialFrames), built once at load rather than per open (never in
-- combat); the reset dialog's text is refreshed each time it opens
-------------------------------------------------------------------------------
-- Reset stops any scan itself, so the confirm needs no further check
local resetPopup = CobysLinkepedia.Utilities.CreateDialogPopup({
  name = "CobysLinkepediaResetPopup",
  icon = CobysLinkepedia.ICON,
  title = "Delete the item database?",
  width = 400,
  confirmText = "Reset",
  danger = true,
  hidden = true,
  onConfirm = function()
    Database.Reset()
    CobysLinkepedia.Utilities.Message("Item database has been reset.")
  end,
})

local corruptPopup = CobysLinkepedia.Utilities.CreateDialogPopup({
  name = "CobysLinkepediaCorruptPopup",
  icon = CobysLinkepedia.ICON,
  title = "Database Corrupted",
  width = 400,
  body = "Your item database was damaged and has been cleared.\n" ..
    "Favorites, history and settings are untouched.\n\n" ..
    "Rebuild it now?",
  confirmText = "Rebuild Now",
  cancelText = "Dismiss",
  danger = true,
  hidden = true,
  onConfirm = function()
    Database.Reset()
    -- StartBuild refuses by itself while a test run holds the scanner
    CobysLinkepedia.Scanner.StartBuild(true)
  end,
})

function Database.ShowResetConfirmation()
  resetPopup:SetBody(
    "This will delete your item database (" .. BreakUpLargeNumbers(Database.GetCount()) .. " items), its captured variants and the recipe index.\n" ..
    "Settings, favorites, history and saved variants are kept.\n\n" ..
    "This cannot be undone."
  )
  resetPopup:Show()
end

function Database.ShowCorruptDialog()
  corruptPopup:Show()
end

CobysLinkepedia.Debug.Log("INIT", "Database module loaded")
