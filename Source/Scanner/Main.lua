-- Scanner: builds the item database by iterating item IDs
-- Pipeline: DISCOVER → QUERY (micro-batched) → REFINE (micro-batched) → COMPLETE
--
--   Phase 1 - DISCOVER:  GetItemInfoInstant to find all valid IDs (client-only, fast)
--   Phase 2 - QUERY:     GetItemInfo on valid IDs in micro-batches
--                         Each batch: query → short wait → harvest → next batch
--   Phase 3 - REFINE_WAIT: 5-second pause for server stragglers
--   Phase 4 - REFINE:    Re-query everything that failed Phase 2, in micro-batches
--                         Same batch cycle as QUERY but over the missed IDs only

local Scanner = CobysLinkepedia.Scanner
local Database = CobysLinkepedia.Database
local Config = CobysLinkepedia.Config
local Debug = CobysLinkepedia.Debug

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local DISCOVER_CEILING = 1000000
local DISCOVER_GAP_THRESHOLD = 100000
local DISCOVER_BUDGET_MS = 10
local REFINE_WAIT_DURATION = 5  -- seconds between Phase 2 and Phase 4

-- Per-frame time budgets (keeps frame rate smooth)
local TIME_BUDGETS = {
  Slow   = 2,
  Medium = 5,
  Fast   = 8,
}

-- Wait duration per micro-batch (seconds)
local WAIT_TIMES = {
  Slow   = 0.5,
  Medium = 0.3,
  Fast   = 0.1,
}

-- Max uncached items per micro-batch before triggering a wait
local BATCH_CAPS = {
  Slow   = 50,
  Medium = 100,
  Fast   = 200,
}

-- Intensity override for one scan, chosen with a modifier on the Build and
-- Expand buttons (Shift for Boost, Ctrl+Shift for Max). nil follows the Scan
-- speed setting. The override raises only the number of uncached items
-- requested per batch; the per-frame time budget stays with the setting, so
-- the Lua side stays bounded and the cost is the client and server load of
-- that many item loads in flight at once, which is what the tooltips warn
-- about.
-- Above 1,000 the client misses items: responses do not all arrive inside
-- the batch wait and fall through to refine, so the ceiling stays there.
local INTENSITY_CAPS = {
  Boost = 500,
  Max   = 1000,
}

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local STATE_IDLE         = "IDLE"
local STATE_DISCOVER     = "DISCOVER"
local STATE_QUERY        = "QUERY"
local STATE_QUERY_WAIT   = "QUERY_WAIT"
local STATE_QUERY_HARVEST = "QUERY_HARVEST"
local STATE_REFINE_WAIT  = "REFINE_WAIT"
local STATE_REFINE       = "REFINE"
local STATE_REFINE_WAIT_BATCH = "REFINE_WAIT_BATCH"
local STATE_REFINE_HARVEST = "REFINE_HARVEST"
local STATE_PAUSED       = "PAUSED"
local STATE_COMPLETE     = "COMPLETE"

local state = STATE_IDLE
local scanMode = nil          -- "build" | "expand"
local scanIntensity = nil     -- nil | "Boost" | "Max" for the current scan
local scanActive = false
local pausedInCombat = false
local prePauseState = nil

-- Test-run hold (see Scanner.Hold). Declared here, above every function that
-- reads it: StartBuild, StartExpand and Resume come before the Hold section.
local held = false
local heldScan = false

-- Deadline for the three wait states, checked by OnUpdate. These used to be
-- driven by one-shot C_Timer callbacks guarded on `state`; a pause (combat or
-- manual) overwrote `state` first, so the callback no-oped, the timer was
-- consumed, and the scan sat in the wait state forever once resumed.
local waitUntil = nil
local startTime = 0
local itemsFound = 0
local lastFoundName = nil
local lastFoundID = nil

-- Rate and ETA work from the active time spent in the current display
-- phase: pauses add nothing, and a long Query phase does not drag down the
-- Refine rate that follows it
local ratePhase = nil
local phaseActiveSeconds = 0

-- Phase 1: DISCOVER
local discoverPos = 0
local discoverValidIDs = {}
local discoverValidCount = 0    -- always == #discoverValidIDs; see ReleaseScanTables
local discoverMaxFound = 0
local discoverGapCount = 0

-- Phase 2: QUERY (micro-batched)
local queryIdx = 0              -- index into discoverValidIDs (persists across batches)
local batchUncachedIDs = {}     -- uncached IDs for current micro-batch
local harvestIdx = 0            -- index into batchUncachedIDs during harvest

-- Collects all IDs that failed Phase 2 harvest (input for Phase 4)
local queryFailedIDs = {}

-- Phase 4: REFINE (micro-batched over queryFailedIDs)
local refineIdx = 0             -- index into queryFailedIDs
local refineBatchIDs = {}       -- uncached IDs for current refine micro-batch
local refineHarvestIdx = 0
local refineFinalPending = {}   -- IDs that still fail after refine (saved for idle scan)

-- Expand mode: stored and dead IDs
local expandKnownIDs = nil

-- How many IDs this scan found dead (unanswered for the second scan running, or refused)
local deadThisScan = 0

-- Idle scan state (see its section below)
local IDLE_TICK_SECONDS = 1
local IDLE_MAX_RETRIES = 3
local idleTicker = nil
local idleNext = 1              -- queue position the next ask starts at
local idleAsked = {}            -- IDs asked for on the last tick...
local idleAskedPos = {}         -- ...their queue positions...
local idleAskedFrom = nil       -- ...and the queue they came from
local idleFailCounts = {}      -- itemID -> unanswered asks so far (dead at IDLE_MAX_RETRIES)
local idleSession = { asked = 0, stored = 0, dead = 0 }   -- this session's counts, for the status window
local PENDING_CAP = 5000        -- most unresolved IDs a completed scan hands the idle queue

-- Localized C_Item functions, the clock and the client build. The Scanner
-- suite swaps these through Scanner._test for a scripted client; nothing
-- else writes them.
local CItem_GetItemInfo = C_Item.GetItemInfo
local CItem_GetItemInfoInstant = C_Item.GetItemInfoInstant
local CItem_RequestLoad = C_Item.RequestLoadItemDataByID
local Now = GetTime
local function RealClientBuild() return (select(2, GetBuildInfo())) end
local ClientBuild = RealClientBuild

-- The walk's end and the idle queue's size, fixed outside the suite
local discoverCeiling = DISCOVER_CEILING
local pendingCap = PENDING_CAP

-------------------------------------------------------------------------------
-- Scan tables
-------------------------------------------------------------------------------
-- Drops every per-scan array by assigning fresh tables (wipe() on tables this
-- size is a GC spike) and zeroes the DISCOVER append counter with them. This
-- is the only place that may reset discoverValidIDs: the counter has to equal
-- its length exactly, so the two are never reset apart.
local function ReleaseScanTables()
  discoverValidIDs = {}
  discoverValidCount = 0
  batchUncachedIDs = {}
  queryFailedIDs = {}
  refineBatchIDs = {}
  refineFinalPending = {}
end

-------------------------------------------------------------------------------
-- Scan frame
-------------------------------------------------------------------------------
local scanFrame = CreateFrame("Frame")

-------------------------------------------------------------------------------
-- Known-ID bitset (Expand's skip set and the dead-ID set)
--
-- Expand skips every ID the database already holds and every dead one. A
-- hash set of 176K keys sizes its node array to 262,144 entries, about 10 MB
-- for the scan's duration; a bitset over the million-ID range is about 32K
-- numbers in one array, half a megabyte, and answers the same question. 31 bits per word
-- keeps every value a positive 32-bit integer for the bit library, which the
-- client has shipped since patch 1.9.
-------------------------------------------------------------------------------
local BITS_PER_WORD = 31
local bit_band, bit_bor = bit.band, bit.bor
local BIT_MASK = {}
for b = 0, BITS_PER_WORD - 1 do
  BIT_MASK[b] = bit.lshift(1, b)
end

-- Pre-filled so the table lives in Lua's array part (16 bytes a slot) rather
-- than growing hash nodes as bits are set.
local function NewBitset(maxID)
  local set = {}
  for w = 1, math.floor(maxID / BITS_PER_WORD) + 1 do
    set[w] = 0
  end
  return set
end

local function BitsetSet(set, id)
  local w = math.floor(id / BITS_PER_WORD) + 1
  set[w] = bit_bor(set[w] or 0, BIT_MASK[id % BITS_PER_WORD])
end

local function BitsetTest(set, id)
  local word = set[math.floor(id / BITS_PER_WORD) + 1]
  return word ~= nil and bit_band(word, BIT_MASK[id % BITS_PER_WORD]) ~= 0
end

-------------------------------------------------------------------------------
-- Dead IDs
--
-- The client's own item data (GetItemInfoInstant, which never asks the
-- server) lists tens of thousands of IDs the server does not serve: on build
-- 69875 an Expand over the whole range found 37,151 of them beside the 176,219
-- it stores, and the server named at most 4. The server turns a minority
-- of them down (ITEM_DATA_LOAD_RESULT success false, the 10.0.5 behaviour)
-- and leaves the rest unanswered; measured in the client on 2026-09-21,
-- build 69875: an Expand over 17,325 such IDs got 1,023 refusals in time and
-- about as many again too late for that scan (the next Expand found 986
-- waiting the moment it started), and no answer of any kind for some 15,000
-- across two scans; the suite's live lab got none for 40 of 40 in ten
-- seconds, while 40 stored items all loaded within 1.1 s. So a refusal kills
-- an ID at once, whenever it arrives (serverRefused is kept for the session
-- and read by scans and the idle scan alike), and silence kills it when it
-- went unanswered twice:
--   - through two complete scans (each asks in query and again in refine):
--     the first leaves it in scanState.unanswered, the second finds it there
--     (SettleUnanswered); or
--   - through a scan and then IDLE_MAX_RETRIES idle asks (the newest
--     PENDING_CAP of a scan's unanswered IDs go to the idle queue).
-- Expand and the idle queue skip dead IDs instead of asking again. On that
-- build two Expands settled all 37,139 of them and the third asked the
-- server nothing (a 2 s walk). Both
-- lists are saved per build (scanState.dead and scanState.unanswered,
-- ascending IDs as hex deltas) and start empty on a new build, so each build
-- checks every ID afresh; a Build starts them over too.
-------------------------------------------------------------------------------
local deadSet, deadList, deadFor, deadBuild, deadDirty
local serverRefused = {}   -- itemID -> true, from ITEM_DATA_LOAD_RESULT this session

local function EncodeIDs(ids)
  local out, prev = {}, 0
  for i = 1, #ids do
    out[i] = string.format("%x", ids[i] - prev)
    prev = ids[i]
  end
  return table.concat(out, ",")
end

-- Calls fn(id) for each ID; false when the text is damaged
local function DecodeIDs(text, fn)
  local id = 0
  for hex in text:gmatch("[^,]+") do
    local delta = tonumber(hex, 16)
    if not delta or delta <= 0 then return false end
    id = id + delta
    fn(id)
  end
  return true
end

-- Writes the list into the scanState it was loaded from, when it changed.
-- That table may no longer be the live one (a suite's scratch storage, a
-- Reset): its owner keeps what it learned either way.
local function WriteDead()
  if not deadSet or not deadDirty or type(deadFor) ~= "table" then return end
  table.sort(deadList)
  if #deadList > 0 then
    deadFor.dead = { build = deadBuild, count = #deadList, ids = EncodeIDs(deadList) }
  else
    deadFor.dead = nil
  end
  deadDirty = false
end

-- A saved list's IDs as a new set and list; nil when the text is damaged
local function DecodeDead(text)
  local set, list = NewBitset(DISCOVER_CEILING), {}
  local ok = DecodeIDs(text, function(id)
    if id <= DISCOVER_CEILING and not BitsetTest(set, id) then
      BitsetSet(set, id)
      list[#list + 1] = id
    end
  end)
  if not ok then return nil end
  return set, list
end

-- The dead set for the current storage and client build, loaded on first use
local function Dead()
  local scanState = COBYS_LINKEPEDIA_DB and COBYS_LINKEPEDIA_DB.scanState
  local build = ClientBuild()
  if deadSet and deadFor == scanState and deadBuild == build then return deadSet end
  WriteDead()
  deadSet, deadList, deadFor, deadBuild, deadDirty = nil, nil, scanState, build, false
  local saved = type(scanState) == "table" and scanState.dead or nil
  if type(saved) == "table" and saved.build == build and type(saved.ids) == "string" then
    deadSet, deadList = DecodeDead(saved.ids)
    if not deadSet then
      Debug.Warn("SCAN", "The saved dead-ID list was damaged and starts over")
      deadDirty = true
    end
  elseif saved ~= nil then
    deadDirty = true   -- another build's list: dropped at the next save
  end
  if not deadSet then deadSet, deadList = NewBitset(DISCOVER_CEILING), {} end
  return deadSet
end

local function IsDead(id)
  return BitsetTest(Dead(), id)
end

local function MarkDead(id)
  local set = Dead()
  serverRefused[id] = nil
  if BitsetTest(set, id) then return end
  BitsetSet(set, id)
  deadList[#deadList + 1] = id
  deadDirty = true
end

-- Saves the list: at logout and when a scan completes
Scanner.SaveDead = WriteDead

-- How many IDs are dead for this client build
function Scanner.GetDeadCount()
  Dead()
  return #deadList
end

local function ForgetDead()
  local scanState = COBYS_LINKEPEDIA_DB and COBYS_LINKEPEDIA_DB.scanState
  if type(scanState) == "table" then
    scanState.dead = nil
    scanState.unanswered = nil
  end
  deadSet = nil
end

-- The IDs the last complete scan on this client build left unanswered, as a
-- set; nil when there are none (or the saved text is damaged)
local function UnansweredSet()
  local scanState = COBYS_LINKEPEDIA_DB and COBYS_LINKEPEDIA_DB.scanState
  local saved = type(scanState) == "table" and scanState.unanswered or nil
  if type(saved) ~= "table" or saved.build ~= ClientBuild() or type(saved.ids) ~= "string" then return nil end
  return (DecodeDead(saved.ids))
end

-- How many IDs have gone unanswered through one complete scan so far
function Scanner.GetUnansweredCount()
  local scanState = COBYS_LINKEPEDIA_DB and COBYS_LINKEPEDIA_DB.scanState
  local saved = type(scanState) == "table" and scanState.unanswered or nil
  if type(saved) ~= "table" or saved.build ~= ClientBuild() or type(saved.count) ~= "number" then return 0 end
  return saved.count
end

-- A completing scan's unanswered IDs (list): one the scan before it also left
-- unanswered is dead now; the rest are remembered for the next scan, which
-- replaces the record. Returns the ones still worth asking about, for the
-- idle queue, and how many died.
local function SettleUnanswered(list)
  local before = UnansweredSet()
  local remaining, died = {}, 0
  for i = 1, #list do
    local id = list[i]
    if before and BitsetTest(before, id) then
      MarkDead(id)
      died = died + 1
    else
      remaining[#remaining + 1] = id
    end
  end
  local scanState = COBYS_LINKEPEDIA_DB and COBYS_LINKEPEDIA_DB.scanState
  if type(scanState) == "table" then
    if #remaining > 0 then
      local sorted = {}
      for i = 1, #remaining do sorted[i] = remaining[i] end
      table.sort(sorted)
      scanState.unanswered = { build = ClientBuild(), count = #sorted, ids = EncodeIDs(sorted) }
    else
      scanState.unanswered = nil
    end
  end
  return remaining, died
end

-- The server's answers to item load requests, whoever made them. Only a
-- refusal is kept, until the scanner marks that ID dead.
local loadResultFrame = CreateFrame("Frame")
loadResultFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
loadResultFrame:SetScript("OnEvent", function(_, _, itemID, success)
  if success == false and type(itemID) == "number" then
    serverRefused[itemID] = true
  end
end)

-------------------------------------------------------------------------------
-- Speed helpers
-------------------------------------------------------------------------------
local function GetTimeBudget()
  local speed = Config.Get(Config.Options.SCAN_SPEED) or "Medium"
  return TIME_BUDGETS[speed] or TIME_BUDGETS.Medium
end

local function GetWaitTime()
  local speed = Config.Get(Config.Options.SCAN_SPEED) or "Medium"
  return WAIT_TIMES[speed] or WAIT_TIMES.Medium
end

local function GetBatchCap()
  local override = scanIntensity and INTENSITY_CAPS[scanIntensity]
  if override then return override end
  local speed = Config.Get(Config.Options.SCAN_SPEED) or "Medium"
  return BATCH_CAPS[speed] or BATCH_CAPS.Medium
end

-------------------------------------------------------------------------------
-- Progress helpers
-------------------------------------------------------------------------------
-- Display phase for the status bar (groups internal sub-states)
local function GetDisplayPhase()
  if state == STATE_DISCOVER then return "DISCOVER" end
  if state == STATE_QUERY or state == STATE_QUERY_WAIT or state == STATE_QUERY_HARVEST then
    return "SCANNING"
  end
  if state == STATE_REFINE_WAIT then return "REFINE_WAIT" end
  if state == STATE_REFINE or state == STATE_REFINE_WAIT_BATCH or state == STATE_REFINE_HARVEST then
    return "REFINING"
  end
  if state == STATE_PAUSED then return "PAUSED" end
  return state
end

-- Current (position, bound) pair for whichever phase the scan is in. Drives
-- the live progress bar, and on cancel supplies the pair persisted to
-- scanState so the saved progress reflects where the scan actually stopped.
local function GetProgressPair(forState)
  local s = forState or state
  if s == STATE_DISCOVER then
    return discoverPos, discoverCeiling
  elseif s == STATE_REFINE or s == STATE_REFINE_WAIT_BATCH or s == STATE_REFINE_HARVEST then
    -- During refine, show progress against the failed IDs
    return refineIdx, #queryFailedIDs
  elseif s == STATE_REFINE_WAIT then
    return 0, #queryFailedIDs
  end
  return queryIdx, #discoverValidIDs
end

-------------------------------------------------------------------------------
-- State machine
--
-- One step function per state, which OnUpdate calls. They stay apart because
-- the client's Lua 5.1 allows a function 60 upvalues, and the whole machine
-- in one function needs more.
-------------------------------------------------------------------------------

-- Stores the item when the client has it, or marks it dead when the server
-- refused it. False when it is still unknown, for the caller to request or
-- defer.
local function Resolve(itemID)
  local name, _, quality, iLvl, reqLvl, _, _, _, _, _, _, classID, subClassID, _, expansionID = CItem_GetItemInfo(itemID)
  if name then
    Database.Store(itemID, name, quality, classID, subClassID, iLvl, reqLvl, expansionID)
    itemsFound = itemsFound + 1
    lastFoundName = name
    lastFoundID = itemID
    return true
  end
  if serverRefused[itemID] then
    MarkDead(itemID)
    deadThisScan = deadThisScan + 1
    return true
  end
  return false
end

-- True once a wait state's deadline has passed, which it clears. Checking the
-- deadline here rather than from a C_Timer callback means a pause cannot
-- strand the scan: whatever the pause cost, the deadline has simply passed by
-- the time OnUpdate runs again.
local function WaitOver()
  if waitUntil and Now() >= waitUntil then
    waitUntil = nil
    return true
  end
  return false
end

-- Every valid ID has been queried: refine the misses after a pause for the
-- server's stragglers, or finish
local function EndQuery()
  if #queryFailedIDs > 0 then
    state = STATE_REFINE_WAIT
    Debug.State("SCAN", "Query done: %d items found, %d missed. Waiting %ds before refine...",
      itemsFound, #queryFailedIDs, REFINE_WAIT_DURATION)
    CobysLinkepedia.Utilities.Message(string.format(
      "Refining: waiting %ds for %d remaining items...", REFINE_WAIT_DURATION, #queryFailedIDs), "normal")
    waitUntil = Now() + REFINE_WAIT_DURATION
  else
    state = STATE_COMPLETE
  end
end

---------------------------------------------------------------------------
-- Phase 1: DISCOVER
---------------------------------------------------------------------------
-- One slice of the discover walk, for the scan (StepDiscover) and the
-- performance run's probe alike. w holds the walk: pos (the last ID looked
-- at), known (the stored and dead IDs an Expand skips; nil for a Build),
-- ids and count (the valid IDs found), maxFound and gapCount. Stops at the
-- ceiling, at a Build's gap stop, or when the budget is spent.
local function DiscoverSlice(w, budgetMs)
  local frameStart = debugprofilestop()
  local known, ids, ceiling = w.known, w.ids, discoverCeiling
  local pos, count, maxFound, gap = w.pos, w.count, w.maxFound, w.gapCount

  while pos < ceiling do
    pos = pos + 1

    local skip = known and BitsetTest(known, pos)
    if not skip and CItem_GetItemInfoInstant(pos) then
      -- Counter rather than #: the length operator is a binary search in 5.1
      -- and this runs once per valid ID, 176K times per build.
      count = count + 1
      ids[count] = pos
      if pos > maxFound then
        maxFound = pos
        gap = 0
      end
    elseif skip then
      -- Known ID (stored, or dead for this build): the client lists it, so it
      -- counts toward the highest ID found
      if pos > maxFound then
        maxFound = pos
        gap = 0
      end
    elseif pos > maxFound then
      gap = gap + 1
      -- Expand mode skips the gap threshold and scans the full 1M range
      -- to catch any new items Blizzard added above the previous frontier.
      if not known and gap >= DISCOVER_GAP_THRESHOLD then break end
    end

    if (pos % 2000) == 0 then
      if (debugprofilestop() - frameStart) >= budgetMs then break end
    end
  end

  w.pos, w.count, w.maxFound, w.gapCount = pos, count, maxFound, gap
end

local discoverWalk = {}

local function StepDiscover()
  local w = discoverWalk
  w.pos, w.known, w.ids, w.count = discoverPos, expandKnownIDs, discoverValidIDs, discoverValidCount
  w.maxFound, w.gapCount = discoverMaxFound, discoverGapCount
  DiscoverSlice(w, DISCOVER_BUDGET_MS)
  discoverPos, discoverValidCount = w.pos, w.count
  discoverMaxFound, discoverGapCount = w.maxFound, w.gapCount
  w.known, w.ids = nil, nil

  -- Expand ignores the gap threshold here as well as inside the loop above:
  -- it promises the full range up to the ceiling, and a new item can sit
  -- past a long run of unused IDs
  if discoverPos >= discoverCeiling or (not expandKnownIDs and discoverGapCount >= DISCOVER_GAP_THRESHOLD) then
    local validCount = #discoverValidIDs
    Debug.State("SCAN", "Discover complete at ID %d: %d valid IDs (max ID: %d)", discoverPos, validCount, discoverMaxFound)

    if COBYS_LINKEPEDIA_DB and COBYS_LINKEPEDIA_DB.scanState then
      COBYS_LINKEPEDIA_DB.scanState.upperBound = discoverMaxFound
    end

    local Msg = CobysLinkepedia.Utilities.Message
    if expandKnownIDs then
      Msg(string.format("Found %d new item IDs to query (max ID: %d)...", validCount, discoverMaxFound), "verbose")
    else
      Msg(string.format("Found %d valid item IDs (max ID: %d). Querying...", validCount, discoverMaxFound), "verbose")
    end

    state = STATE_QUERY
    queryIdx = 0
    batchUncachedIDs = {}
  end
end

---------------------------------------------------------------------------
-- Phase 2: QUERY (micro-batch: query → wait → harvest → loop)
---------------------------------------------------------------------------
local function StepQuery()
  local timeBudget = GetTimeBudget()
  local frameStart = debugprofilestop()
  local batchCap = GetBatchCap()
  local total = #discoverValidIDs   -- fixed for the whole QUERY phase

  while queryIdx < total do
    queryIdx = queryIdx + 1
    local itemID = discoverValidIDs[queryIdx]

    if not Resolve(itemID) then
      -- An explicit request, so the server's answer (ITEM_DATA_LOAD_RESULT)
      -- arrives whatever GetItemInfo does under the hood
      CItem_RequestLoad(itemID)
      batchUncachedIDs[#batchUncachedIDs + 1] = itemID
      if #batchUncachedIDs >= batchCap then break end
    end

    if (queryIdx % 20) == 0 then
      if (debugprofilestop() - frameStart) >= timeBudget then break end
    end
  end

  -- Batch full or all IDs done: harvest if needed
  if #batchUncachedIDs >= batchCap or queryIdx >= total then
    if #batchUncachedIDs > 0 then
      state = STATE_QUERY_WAIT
      waitUntil = Now() + GetWaitTime()
    elseif queryIdx >= total then
      -- All queried, nothing uncached
      EndQuery()
    end
  end
end

-- Waiting for the server to deliver the uncached batch
local function StepQueryWait()
  if WaitOver() then
    state = STATE_QUERY_HARVEST
    harvestIdx = 0
  end
end

local function StepQueryHarvest()
  local timeBudget = GetTimeBudget()
  local frameStart = debugprofilestop()

  while harvestIdx < #batchUncachedIDs do
    harvestIdx = harvestIdx + 1
    local itemID = batchUncachedIDs[harvestIdx]

    if not Resolve(itemID) then
      queryFailedIDs[#queryFailedIDs + 1] = itemID
    end

    if (harvestIdx % 50) == 0 then
      if (debugprofilestop() - frameStart) >= timeBudget then break end
    end
  end

  if harvestIdx >= #batchUncachedIDs then
    batchUncachedIDs = {}
    harvestIdx = 0

    if queryIdx >= #discoverValidIDs then
      EndQuery()
    else
      state = STATE_QUERY
    end
  end
end

---------------------------------------------------------------------------
-- Phase 3: REFINE_WAIT (a pause for the server's stragglers)
---------------------------------------------------------------------------
local function StepRefineWait()
  if WaitOver() then
    state = STATE_REFINE
    refineIdx = 0
    refineBatchIDs = {}
    refineFinalPending = {}
  end
end

---------------------------------------------------------------------------
-- Phase 4: REFINE (micro-batch over queryFailedIDs)
---------------------------------------------------------------------------
local function StepRefine()
  local timeBudget = GetTimeBudget()
  local frameStart = debugprofilestop()
  local batchCap = GetBatchCap()
  local total = #queryFailedIDs   -- fixed once REFINE begins

  while refineIdx < total do
    refineIdx = refineIdx + 1
    local itemID = queryFailedIDs[refineIdx]

    if not Resolve(itemID) then
      CItem_RequestLoad(itemID)
      refineBatchIDs[#refineBatchIDs + 1] = itemID
      if #refineBatchIDs >= batchCap then break end
    end

    if (refineIdx % 20) == 0 then
      if (debugprofilestop() - frameStart) >= timeBudget then break end
    end
  end

  if #refineBatchIDs >= batchCap or refineIdx >= total then
    if #refineBatchIDs > 0 then
      state = STATE_REFINE_WAIT_BATCH
      waitUntil = Now() + GetWaitTime()
    elseif refineIdx >= total then
      state = STATE_COMPLETE
    end
  end
end

local function StepRefineWaitBatch()
  if WaitOver() then
    state = STATE_REFINE_HARVEST
    refineHarvestIdx = 0
  end
end

local function StepRefineHarvest()
  local timeBudget = GetTimeBudget()
  local frameStart = debugprofilestop()

  while refineHarvestIdx < #refineBatchIDs do
    refineHarvestIdx = refineHarvestIdx + 1
    local itemID = refineBatchIDs[refineHarvestIdx]

    if not Resolve(itemID) then
      refineFinalPending[#refineFinalPending + 1] = itemID
    end

    if (refineHarvestIdx % 50) == 0 then
      if (debugprofilestop() - frameStart) >= timeBudget then break end
    end
  end

  if refineHarvestIdx >= #refineBatchIDs then
    refineBatchIDs = {}
    refineHarvestIdx = 0

    if refineIdx >= #queryFailedIDs then
      state = STATE_COMPLETE
    else
      state = STATE_REFINE
    end
  end
end

---------------------------------------------------------------------------
-- COMPLETE
---------------------------------------------------------------------------
local function StepComplete()
  scanActive = false
  scanIntensity = nil
  expandKnownIDs = nil
  scanFrame:SetScript("OnUpdate", nil)

  local elapsed = Now() - startTime
  local minutes = math.floor(elapsed / 60)
  local seconds = math.floor(elapsed % 60)

  -- Where every valid ID of this pass ended up: stored, dead (unanswered
  -- for the second complete scan running, or refused), deferred to the idle
  -- retry queue, or past the queue's cap (those wait for the next scan,
  -- which kills them if they stay silent). Over the cap the newest IDs stay:
  -- an item the server is slow to send after a patch has a high ID, while
  -- the low ones that fail are mostly retired items.
  local queried = #discoverValidIDs
  local silentTwice
  refineFinalPending, silentTwice = SettleUnanswered(refineFinalPending)
  deadThisScan = deadThisScan + silentTwice
  local deferred = #refineFinalPending
  local dropped = 0
  if deferred > pendingCap then
    table.sort(refineFinalPending, function(a, b) return a > b end)
    dropped = deferred - pendingCap
    local capped = {}
    for i = 1, pendingCap do capped[i] = refineFinalPending[i] end
    refineFinalPending = capped
    deferred = pendingCap
  end

  local scanState = COBYS_LINKEPEDIA_DB and COBYS_LINKEPEDIA_DB.scanState
  if scanState then
    -- The pass ran to its end. Deferred and dropped items are counted on
    -- their own; complete does not mean every item loaded.
    scanState.complete = true
    scanState.lastPosition = discoverMaxFound
    scanState.upperBound = discoverMaxFound
    scanState.lastScanDate = time()
    scanState.lastMode = scanMode
    -- Replaced every time, an empty queue included, so IDs an earlier scan
    -- left pending and this one stored are not retried again
    scanState.pendingIDs = refineFinalPending
  end
  Scanner.SaveDead()

  -- Variants of items gone from the game go once a Build completes. The
  -- pass does not store every base that still exists (deferred and dropped
  -- items above), so PruneVariants asks the client whether each missing
  -- base is still an item. Not at the start of a Build (every base is
  -- wiped then) or on a cancel.
  if scanMode == "build" then
    Database.PruneVariants()
  end

  Debug.State("SCAN", "Scan counts (%s): %d queried, %d stored, %d dead (%d unanswered for the second scan running), %d deferred to the idle queue, %d over the %d cap (asked again by the next scan)",
    scanMode or "?", queried, itemsFound, deadThisScan, silentTwice, deferred, dropped, pendingCap)
  CobysLinkepedia.Utilities.Message(string.format(
    "Queried %d item IDs: %d stored, %d the server does not have, %d queued for idle retry, %d left for the next scan.",
    queried, itemsFound, deadThisScan, deferred, dropped), "verbose")

  ReleaseScanTables()

  Debug.State("SCAN", "Scan complete: %d items found in %dm %ds", itemsFound, minutes, seconds)
  CobysLinkepedia.EventBus:Fire(CobysLinkepedia.Events.ScanComplete, itemsFound)
  CobysLinkepedia.EventBus:Fire(CobysLinkepedia.Events.DatabaseUpdated)

  local Msg = CobysLinkepedia.Utilities.Message.Success
  if Msg then
    Msg(string.format("Scan complete! Found %d items in %dm %ds.", itemsFound, minutes, seconds), "normal")
  end
end

local STEPS = {
  [STATE_DISCOVER]          = StepDiscover,
  [STATE_QUERY]             = StepQuery,
  [STATE_QUERY_WAIT]        = StepQueryWait,
  [STATE_QUERY_HARVEST]     = StepQueryHarvest,
  [STATE_REFINE_WAIT]       = StepRefineWait,
  [STATE_REFINE]            = StepRefine,
  [STATE_REFINE_WAIT_BATCH] = StepRefineWaitBatch,
  [STATE_REFINE_HARVEST]    = StepRefineHarvest,
  [STATE_COMPLETE]          = StepComplete,
}

local function OnUpdate(self, elapsed)
  if not scanActive then return end

  -- Combat pause
  if UnitAffectingCombat("player") then
    if state ~= STATE_PAUSED then
      prePauseState = state
      pausedInCombat = true
      state = STATE_PAUSED
      Debug.State("SCAN", "Paused for combat")
    end
    return
  end
  if pausedInCombat and state == STATE_PAUSED then
    pausedInCombat = false
    state = prePauseState or STATE_DISCOVER
    Debug.State("SCAN", "Resumed after combat → %s", state)
  end
  if state == STATE_PAUSED then return end

  -- Active time in the current display phase (pauses never reach here)
  local phase = GetDisplayPhase()
  if phase ~= ratePhase then
    ratePhase = phase
    phaseActiveSeconds = 0
  end
  phaseActiveSeconds = phaseActiveSeconds + (elapsed or 0)

  local step = STEPS[state]
  if step then step() end
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------
local function ResetScanState(intensity)
  state = STATE_DISCOVER
  scanActive = true
  scanIntensity = INTENSITY_CAPS[intensity or ""] and intensity or nil
  pausedInCombat = false
  prePauseState = nil
  waitUntil = nil
  itemsFound = 0
  deadThisScan = 0
  startTime = Now()
  lastFoundName = nil
  lastFoundID = nil
  ratePhase = nil
  phaseActiveSeconds = 0

  -- Unfinished until StepComplete says otherwise. A cancel or a
  -- reload leaves it false, which is what the login notice looks for; a
  -- database that was never scanned has no flag at all. The previous scan's
  -- position goes too, so a reload mid-scan never reports the old one's.
  local scanState = COBYS_LINKEPEDIA_DB and COBYS_LINKEPEDIA_DB.scanState
  if scanState then
    scanState.complete = false
    scanState.lastPosition = nil
    scanState.upperBound = nil
    -- Which kind of scan this is, for the status window
    scanState.lastMode = scanMode
  end

  discoverPos = 0
  discoverMaxFound = 0
  discoverGapCount = 0

  queryIdx = 0
  harvestIdx = 0

  refineIdx = 0
  refineHarvestIdx = 0

  ReleaseScanTables()
end

local function DoStartBuild(intensity)
  scanMode = "build"
  expandKnownIDs = nil
  ResetScanState(intensity)

  -- "Rebuild from scratch" is what the confirmation promises, so make it true.
  -- Expand deliberately does not do this: it adds to what is already there.
  -- The dead-ID list starts over with it, so every ID is asked again.
  Database.WipeItems()
  ForgetDead()

  scanFrame:SetScript("OnUpdate", OnUpdate)

  Debug.State("SCAN", "Build scan started (%s), discovering valid IDs...", scanIntensity or "normal")
  CobysLinkepedia.Utilities.Message("Discovering valid item IDs...", "normal")
end

-- The Rebuild confirmation: one named dialog built at load (never in combat,
-- and Escape closes it through UISpecialFrames), its text refreshed each time
-- it opens. The confirm checks again, since a scan can start while it is open.
local rebuildIntensity = nil
local rebuildPopup = CobysLinkepedia.Utilities.CreateDialogPopup({
  name = "CobysLinkepediaRebuildPopup",
  title = "Rebuild Database",
  width = 400,
  height = 150,
  confirmText = "Rebuild",
  hidden = true,
})
rebuildPopup.ConfirmButton:SetScript("OnClick", function()
  rebuildPopup:Hide()
  if held then
    CobysLinkepedia.Utilities.Message.Warn("The scanner is held by a test run.")
    return
  end
  if scanActive then
    CobysLinkepedia.Utilities.Message.Warn("A scan started while this dialog was open, so Rebuild did not run.")
    return
  end
  DoStartBuild(rebuildIntensity)
end)

-- intensity: nil (Scan speed setting), "Boost" or "Max"; see INTENSITY_CAPS
function Scanner.StartBuild(skipConfirm, intensity)
  if held then
    CobysLinkepedia.Utilities.Message.Warn("The scanner is held by a test run.")
    return
  end
  if scanActive then
    CobysLinkepedia.Utilities.Message.Warn("A scan is already in progress.")
    return
  end

  local count = Database.GetCount()
  if not skipConfirm and count > 0 then
    rebuildIntensity = intensity
    rebuildPopup:SetBody(
      "This will rebuild your item database from scratch.\n" ..
      "Your current database has " .. count .. " items.\n\n" ..
      "Use Expand to fill in gaps instead."
    )
    rebuildPopup:Show()
    return
  end

  DoStartBuild(intensity)
end

-- The IDs an Expand skips: every stored ID and every dead one. Returns the
-- set and both counts.
local function BuildKnownIDs()
  local known = NewBitset(DISCOVER_CEILING)
  local skipCount = 0
  Database.ForEachID(function(id)
    BitsetSet(known, id)
    skipCount = skipCount + 1
  end)
  Dead()
  local deadCount = #deadList
  for i = 1, deadCount do
    BitsetSet(known, deadList[i])
  end
  return known, skipCount, deadCount
end

-- An Expand: the walk skips every stored ID and every ID dead for this
-- client build, and the server is asked only about the rest
local function StartExpandScan(intensity)
  local skipCount, deadCount
  expandKnownIDs, skipCount, deadCount = BuildKnownIDs()

  scanMode = "expand"
  ResetScanState(intensity)

  scanFrame:SetScript("OnUpdate", OnUpdate)

  Debug.State("SCAN", "Expand scan started (%s): %d stored and %d dead skipped, discovering new IDs...",
    scanIntensity or "normal", skipCount, deadCount)
  CobysLinkepedia.Utilities.Message(string.format(
    "Discovering new item IDs (skipping %d stored and %d the server does not have)...", skipCount, deadCount), "normal")
end

-- intensity: nil (Scan speed setting), "Boost" or "Max"; see INTENSITY_CAPS
function Scanner.StartExpand(intensity)
  if held then
    CobysLinkepedia.Utilities.Message.Warn("The scanner is held by a test run.")
    return
  end
  if scanActive then
    CobysLinkepedia.Utilities.Message.Warn("A scan is already in progress.")
    return
  end
  StartExpandScan(intensity)
end

function Scanner.Pause()
  if not scanActive or state == STATE_PAUSED then return end
  prePauseState = state
  state = STATE_PAUSED
  Debug.State("SCAN", "Scan paused in %s phase", prePauseState or "?")
  CobysLinkepedia.Utilities.Message("Scan paused.")
end

function Scanner.Resume()
  if not scanActive or state ~= STATE_PAUSED then return end
  if held then
    CobysLinkepedia.Utilities.Message.Warn("The scanner is held by a test run.")
    return
  end
  if pausedInCombat then
    CobysLinkepedia.Utilities.Message.Warn("Cannot resume during combat.")
    return
  end
  state = prePauseState or STATE_DISCOVER
  prePauseState = nil
  Debug.State("SCAN", "Scan resumed → %s", state)
  CobysLinkepedia.Utilities.Message("Scan resumed.")
end

-- Stops the running scan and records how far it got. notify false is for
-- Database.Reset, which replaces the storage and fires its own single
-- DatabaseUpdated afterwards: the stop then fires no ScanCancelled or
-- DatabaseUpdated and prints nothing. Returns whether a scan was stopped.
function Scanner.StopScan(notify)
  if not scanActive then return false end

  -- Capture real progress before the state is cleared: for an unfinished
  -- scan the Stats tab's coverage and the status window's "stopped at" read
  -- lastPosition over upperBound, so the two must not be equal. When paused,
  -- the phase the scan was actually in is prePauseState, not STATE_PAUSED.
  local pos, total = GetProgressPair((state == STATE_PAUSED and prePauseState) or state)

  scanActive = false
  state = STATE_IDLE
  pausedInCombat = false
  prePauseState = nil
  heldScan = false
  waitUntil = nil
  scanIntensity = nil
  expandKnownIDs = nil
  scanFrame:SetScript("OnUpdate", nil)

  -- scanState.complete stays false from the start. An Expand picks up the
  -- rest (it walks the range again, skipping what is stored and dead)
  -- without losing what is stored
  if COBYS_LINKEPEDIA_DB and COBYS_LINKEPEDIA_DB.scanState then
    COBYS_LINKEPEDIA_DB.scanState.lastPosition = pos
    COBYS_LINKEPEDIA_DB.scanState.upperBound = math.max(total, pos)
  end

  ReleaseScanTables()

  Debug.State("SCAN", "Scan stopped (%d items found so far)", itemsFound)
  if notify ~= false then
    CobysLinkepedia.EventBus:Fire(CobysLinkepedia.Events.ScanCancelled)
    CobysLinkepedia.EventBus:Fire(CobysLinkepedia.Events.DatabaseUpdated)
    CobysLinkepedia.Utilities.Message("Scan cancelled. The items found so far are kept; /lp expand continues the scan.")
  end
  return true
end

function Scanner.Cancel()
  Scanner.StopScan(true)
end

function Scanner.GetStatus()
  local displayPhase = GetDisplayPhase()
  -- While paused, progress belongs to the phase the pause interrupted
  local pos, total = GetProgressPair((state == STATE_PAUSED and prePauseState) or state)

  -- Rate over the current phase's active time; none while paused
  local rate = 0
  if state ~= STATE_PAUSED and phaseActiveSeconds > 0 and pos > 0 then
    rate = pos / phaseActiveSeconds
  end

  return {
    state = displayPhase,
    scanMode = scanMode,
    intensity = scanIntensity,
    position = pos,
    upperBound = total,
    itemsFound = itemsFound,
    rate = rate,
    isActive = scanActive,
    lastFoundName = lastFoundName,
    lastFoundID = lastFoundID,
  }
end

-- The last scan as scanState records it: its mode ("build" or "expand", or
-- nil in a database saved before modes were kept), whether it ran to its
-- end, when the last one that did finished, and where an unfinished one stopped
function Scanner.GetLastScan()
  local s = COBYS_LINKEPEDIA_DB and COBYS_LINKEPEDIA_DB.scanState
  if type(s) ~= "table" then return nil end
  return {
    mode = s.lastMode,
    complete = s.complete,
    finishedAt = s.lastScanDate,
    position = s.lastPosition,
    upperBound = s.upperBound,
  }
end

-------------------------------------------------------------------------------
-- Hold: keeps the scanner quiet for as long as it is in force. The in-game
-- suites take one for the duration of a run (a one-time "is it paused"
-- check would not do: a scan paused by combat resumes on its own when the
-- fight ends, and a new scan or the idle ticker could start mid-run). A
-- running scan is paused and the combat handler will not resume it;
-- Start, Resume and StartIdle refuse while held; Release resumes only the
-- scan the hold itself paused. An idle ticker already running is not stopped
-- by a hold; the suites stop it themselves (scanner_quiet in Tests/Setup.lua).
-------------------------------------------------------------------------------
function Scanner.Hold()
  if held then return end
  held = true
  if scanActive and state ~= STATE_PAUSED then
    prePauseState = state
    pausedInCombat = false
    state = STATE_PAUSED
    heldScan = true
    Debug.State("SCAN", "Scan held in %s phase", prePauseState or "?")
  elseif scanActive and pausedInCombat then
    -- Paused by combat: the hold owns it now, so PLAYER_REGEN_ENABLED
    -- leaves it alone until Release
    pausedInCombat = false
    heldScan = true
  end
end

function Scanner.Release()
  if not held then return end
  held = false
  if heldScan and scanActive and state == STATE_PAUSED then
    if UnitAffectingCombat("player") then
      pausedInCombat = true   -- the combat handler resumes it when the fight ends
    else
      state = prePauseState or STATE_DISCOVER
      prePauseState = nil
      Debug.State("SCAN", "Hold released, scan resumed -> %s", state)
    end
  end
  heldScan = false
end

function Scanner.IsHeld()
  return held
end

-- For the recipe scan (Scanner/Recipes.lua), which yields to an item scan
-- and spends the same per-frame budget
function Scanner.IsScanActive()
  return scanActive
end

Scanner.GetTimeBudget = GetTimeBudget

-- Seconds left in the current phase at its active-time rate. None while
-- paused or waiting on a batch, and none in the first second of a phase.
function Scanner.GetETA()
  if not scanActive or state == STATE_PAUSED then return nil end
  if state == STATE_REFINE_WAIT or state == STATE_QUERY_WAIT or state == STATE_REFINE_WAIT_BATCH then
    return nil
  end
  local pos, total = GetProgressPair(state)
  if pos <= 0 or phaseActiveSeconds < 1 then return nil end
  return (phaseActiveSeconds / pos) * (total - pos)
end

-------------------------------------------------------------------------------
-- Idle scan
--
-- Works through the queue a completed scan left (scanState.pendingIDs), the
-- items the server held back. Every second, out of combat and while no scan
-- runs, it settles the IDs it asked for on the tick before, then asks for
-- the next few (the idleScanRate option, default 5). An ID leaves the queue
-- stored once the server has sent it, or dead for this client build when the
-- server refused it or went unanswered IDLE_MAX_RETRIES times (Expand then
-- skips it); one still unanswered waits for the
-- next pass through the queue.
-------------------------------------------------------------------------------

-- Settles one queued ID: true when it leaves the queue. With `asked`, a look
-- that finds nothing counts as one of its tries.
local function IdleSettle(itemID, asked)
  if type(itemID) ~= "number" or IsDead(itemID) then return true end

  local name, _, quality, iLvl, reqLvl, _, _, _, _, _, _, classID, subClassID, _, expansionID = CItem_GetItemInfo(itemID)
  if name then
    local existing = Database.GetItem(itemID)
    if existing and existing.name ~= name then
      Debug.Log("SCAN", "Idle scan: item %d renamed '%s' -> '%s'", itemID, existing.name, name)
      Database.Remove(itemID, existing.name)
    end
    Database.Store(itemID, name, quality, classID, subClassID, iLvl, reqLvl, expansionID)
    lastFoundName = name
    lastFoundID = itemID
    idleFailCounts[itemID] = nil
    idleSession.stored = idleSession.stored + 1
    return true
  end
  if serverRefused[itemID] then
    idleFailCounts[itemID] = nil
    MarkDead(itemID)
    idleSession.dead = idleSession.dead + 1
    Debug.Log("SCAN", "Idle scan: the server does not have item %d", itemID)
    return true
  end
  if asked then
    local fails = (idleFailCounts[itemID] or 0) + 1
    if fails >= IDLE_MAX_RETRIES then
      idleFailCounts[itemID] = nil
      MarkDead(itemID)
      idleSession.dead = idleSession.dead + 1
      Debug.Log("SCAN", "Idle scan: item %d did not answer in %d tries, dead for this client build", itemID, IDLE_MAX_RETRIES)
      return true
    end
    idleFailCounts[itemID] = fails
  end
  return false
end

-- Takes a settled ID out of the queue: from the position it was asked at
-- while it is still there, else from wherever it is now. idleNext keeps
-- pointing at the same next ID.
local function IdleRemove(pending, itemID, pos)
  if pending[pos] ~= itemID then
    pos = nil
    for i = 1, #pending do
      if pending[i] == itemID then
        pos = i
        break
      end
    end
    if not pos then return end
  end
  table.remove(pending, pos)
  if pos < idleNext then idleNext = idleNext - 1 end
end

local function IdleTick()
  if scanActive or UnitAffectingCombat("player") then return end
  local scanState = COBYS_LINKEPEDIA_DB and COBYS_LINKEPEDIA_DB.scanState
  local pending = type(scanState) == "table" and scanState.pendingIDs
  if type(pending) ~= "table" then return end

  -- Settle the last tick's asks, the latest position first so each removal
  -- leaves the earlier positions where they were. A queue replaced since (a
  -- completed scan, a Reset) has no use for them and starts at its front.
  if idleAskedFrom == pending then
    for i = #idleAsked, 1, -1 do
      if IdleSettle(idleAsked[i], true) then
        IdleRemove(pending, idleAsked[i], idleAskedPos[i])
      end
    end
  else
    idleNext = 1
    wipe(idleFailCounts)
  end
  wipe(idleAsked)
  wipe(idleAskedPos)
  idleAskedFrom = pending

  -- Ask for the next few. A pass ends at the back of the queue, and the next
  -- tick starts the following one at the front.
  local rate = Config.Get(Config.Options.IDLE_SCAN_RATE) or 5
  for _ = 1, rate do
    if idleNext > #pending then
      idleNext = 1
      break
    end
    local itemID = pending[idleNext]
    if IdleSettle(itemID, false) then
      table.remove(pending, idleNext)   -- settled without asking: dead, or sent already
    else
      -- An explicit request, so the server's answer (ITEM_DATA_LOAD_RESULT)
      -- arrives whatever GetItemInfo does under the hood
      CItem_RequestLoad(itemID)
      idleSession.asked = idleSession.asked + 1
      idleAsked[#idleAsked + 1] = itemID
      idleAskedPos[#idleAskedPos + 1] = idleNext
      idleNext = idleNext + 1
    end
  end
end

function Scanner.StartIdle()
  if idleTicker or held then return end

  idleTicker = C_Timer.NewTicker(IDLE_TICK_SECONDS, IdleTick)

  Debug.Log("SCAN", "Idle scanner started (%d item IDs a second)", Config.Get(Config.Options.IDLE_SCAN_RATE) or 5)
end

function Scanner.StopIdle()
  if idleTicker then
    idleTicker:Cancel()
    idleTicker = nil
    Debug.Log("SCAN", "Idle scanner stopped")
  end
end

-- Whether the idle ticker is installed (it also writes to the database);
-- the suites stop it around a run and start it again only if it was on
function Scanner.IsIdleRunning()
  return idleTicker ~= nil
end

-- The idle scan for the status window: whether the ticker runs and what
-- stops its ticks now (blocked: "scan", "combat" or nil), the queue and how
-- far this pass has got, the speed, and this session's counts
function Scanner.GetIdleStatus()
  local scanState = COBYS_LINKEPEDIA_DB and COBYS_LINKEPEDIA_DB.scanState
  local pending = type(scanState) == "table" and scanState.pendingIDs
  if type(pending) ~= "table" then pending = nil end
  local queued = pending and #pending or 0
  local blocked
  if scanActive then
    blocked = "scan"
  elseif UnitAffectingCombat("player") then
    blocked = "combat"
  end
  return {
    running = idleTicker ~= nil,
    blocked = blocked,
    rate = Config.Get(Config.Options.IDLE_SCAN_RATE) or 5,
    queued = queued,
    -- Queue positions already asked this pass; none yet for a queue it has not ticked on
    passDone = (pending and idleAskedFrom == pending) and math.min(idleNext - 1, queued) or 0,
    asked = idleSession.asked,
    stored = idleSession.stored,
    dead = idleSession.dead,
  }
end

-- Brings the idle ticker in line with the option: started when enabled
-- (StartIdle itself refuses while held or already running), stopped when not
function Scanner.ReconcileIdle()
  if Config.Get(Config.Options.IDLE_SCAN_ENABLED) ~= false then
    Scanner.StartIdle()
  else
    Scanner.StopIdle()
  end
end

-- The ticker follows its enabled option; the speed is read at every tick. A
-- nil key (Defaults, a restored snapshot) re-reads the option.
CobysLinkepedia.EventBus:Register({ ReceiveEvent = function(_, _, key)
  if key == nil or key == Config.Options.IDLE_SCAN_ENABLED then
    Scanner.ReconcileIdle()
  end
end }, { CobysLinkepedia.Events.ConfigChanged })

-------------------------------------------------------------------------------
-- Combat events
-------------------------------------------------------------------------------
local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_REGEN_DISABLED" then
    if scanActive and state ~= STATE_PAUSED then
      prePauseState = state
      pausedInCombat = true
      state = STATE_PAUSED
      Debug.State("SCAN", "Combat lockdown: scan paused")
    end
  elseif event == "PLAYER_REGEN_ENABLED" then
    if scanActive and pausedInCombat then
      pausedInCombat = false
      state = prePauseState or STATE_DISCOVER
      prePauseState = nil
      Debug.State("SCAN", "Combat ended: scan resumed → %s", state)
    end
  end
end)

-------------------------------------------------------------------------------
-- FindMaxItemID: standalone diagnostic
-------------------------------------------------------------------------------
-- One frame and at most one job. The walk takes the main scanner's per-frame
-- budget (the Scan speed setting) and waits out combat the same way.
local FINDMAX_CEILING = 1000000
local findMaxFrame = CreateFrame("Frame")
local findMaxJob = nil

function Scanner.CancelFindMax()
  if not findMaxJob then return false end
  findMaxFrame:SetScript("OnUpdate", nil)
  findMaxJob = nil
  Debug.Log("SCAN", "FindMax cancelled")
  return true
end

-- arg "cancel" stops a running job
function Scanner.FindMaxItemID(arg)
  local Utilities = CobysLinkepedia.Utilities
  if arg == "cancel" then
    if Scanner.CancelFindMax() then
      Utilities.Message("Max item ID scan cancelled.")
    else
      Utilities.Message("No max item ID scan is running.")
    end
    return
  end
  if findMaxJob then
    Utilities.Message.Warn("A max item ID scan is already running. /lp findmax cancel stops it.")
    return
  end

  Utilities.Message("Scanning for max item ID (0 to " .. FINDMAX_CEILING .. "). /lp findmax cancel stops it.")
  local job = { pos = 0, maxFound = 0, validCount = 0, startedAt = Now() }
  findMaxJob = job

  findMaxFrame:SetScript("OnUpdate", function(self)
    if UnitAffectingCombat("player") then return end
    local budget = GetTimeBudget()
    local frameStart = debugprofilestop()

    while job.pos <= FINDMAX_CEILING do
      if CItem_GetItemInfoInstant(job.pos) then
        job.maxFound = job.pos
        job.validCount = job.validCount + 1
      end
      job.pos = job.pos + 1

      if (job.pos % 1000) == 0 and (debugprofilestop() - frameStart) >= budget then break end
    end

    if job.pos > FINDMAX_CEILING then
      self:SetScript("OnUpdate", nil)
      findMaxJob = nil
      local duration = Now() - job.startedAt
      Debug.Log("SCAN", "FindMax complete: max ID = %d, valid = %d, scanned %d in %.1fs",
        job.maxFound, job.validCount, FINDMAX_CEILING, duration)
      Utilities.Message(string.format("Max item ID: |cFFFFD100%d|r  (%d valid IDs found in %.1fs)",
        job.maxFound, job.validCount, duration))
    end
  end)
end

-------------------------------------------------------------------------------
-- Performance probes (Search.RunPerformance): the scanner's own work, timed
-- without starting a scan. Each runs the functions the scans run. The
-- discover probe and the dead-list measure ask the server nothing and change
-- nothing saved; the idle tick is a real tick (it asks the server and settles
-- queue entries), so it runs only while the idle scan is on.
-------------------------------------------------------------------------------
Scanner.Perf = {
  -- The discover walk's share of a frame, in a Build and an Expand
  WALK_BUDGET_MS = DISCOVER_BUDGET_MS,
}

-- The known-ID set an Expand builds as it starts, in one call (buildMs),
-- then a walker over the whole range that does what its discover walk does, one probe:Step(budgetMs) a frame. build = true walks as
-- a Build does instead: nothing skipped, stopping at the gap past the highest
-- ID. probe.listed counts the IDs the walk would ask the server about.
function Scanner.Perf.NewDiscoverProbe(build)
  local probe = { stored = 0, dead = 0, buildMs = 0, pos = 0, listed = 0, done = false }
  local known
  if not build then
    local t = debugprofilestop()
    known, probe.stored, probe.dead = BuildKnownIDs()
    probe.buildMs = debugprofilestop() - t
  end
  local w = { pos = 0, known = known, ids = {}, count = 0, maxFound = 0, gapCount = 0 }
  function probe:Step(budgetMs)
    DiscoverSlice(w, budgetMs)
    self.pos, self.listed = w.pos, w.count
    self.done = w.pos >= discoverCeiling or (not known and w.gapCount >= DISCOVER_GAP_THRESHOLD)
  end
  return probe
end

-- The dead-ID list's saved form: the sort and encode a save pays (at logout
-- and a scan's end), then the decode the first lookup after login pays, on a
-- copy. The live list and the saved text stay as they are.
function Scanner.Perf.MeasureDeadList()
  Dead()
  local list = {}
  for i = 1, #deadList do list[i] = deadList[i] end
  local t = debugprofilestop()
  table.sort(list)
  local text = EncodeIDs(list)
  local encodeMs = debugprofilestop() - t
  t = debugprofilestop()
  DecodeDead(text)
  return { count = #list, bytes = #text, encodeMs = encodeMs, decodeMs = debugprofilestop() - t }
end

-- One idle tick, the idle scan's own work one second sooner than its ticker
-- would do it: milliseconds, the queue it worked on and the speed. nil while
-- the idle scan is off, so the run never asks the server for anything the
-- player turned off.
function Scanner.Perf.IdleTick()
  if not idleTicker then return nil end
  local status = Scanner.GetIdleStatus()
  local t = debugprofilestop()
  IdleTick()
  return debugprofilestop() - t, status.queued, status.rate
end

-------------------------------------------------------------------------------
-- Test seams (the Scanner suite): a scripted client and a small ID range,
-- server refusals, the dead-ID list, one idle tick, and a scan driven one
-- OnUpdate at a time
-------------------------------------------------------------------------------
Scanner._test = {
  EncodeIDs = EncodeIDs,
  DecodeIDs = DecodeIDs,
  -- client: { info = fn(id), instant = fn(id), request = fn(id), now = fn(),
  -- build = fn() }; any field left out, or nil for the whole table, is the
  -- real client again
  SetClient = function(client)
    client = client or {}
    CItem_GetItemInfo = client.info or C_Item.GetItemInfo
    CItem_GetItemInfoInstant = client.instant or C_Item.GetItemInfoInstant
    CItem_RequestLoad = client.request or C_Item.RequestLoadItemDataByID
    Now = client.now or GetTime
    ClientBuild = client.build or RealClientBuild
  end,
  -- The walk's last ID and the idle queue's cap; nil restores each
  SetLimits = function(ceiling, cap)
    discoverCeiling = ceiling or DISCOVER_CEILING
    pendingCap = cap or PENDING_CAP
  end,
  -- An ITEM_DATA_LOAD_RESULT, delivered as the client delivers it
  LoadResult = function(itemID, success)
    loadResultFrame:GetScript("OnEvent")(loadResultFrame, "ITEM_DATA_LOAD_RESULT", itemID, success)
  end,
  ClearRefusals = function() wipe(serverRefused) end,
  IsDead = IsDead,
  MarkDead = MarkDead,
  ForgetDead = ForgetDead,
  IdleTick = IdleTick,
  -- One OnUpdate of the running scan; a scan started from a test runs only
  -- here as long as the test does not yield
  Step = function(elapsed) OnUpdate(scanFrame, elapsed or 0.05) end,
}

Debug.Log("INIT", "Scanner module loaded")
