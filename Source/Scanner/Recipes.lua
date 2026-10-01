-- Recipe scan: fills the recipe index (Database/Recipes.lua) the Variant
-- Builder needs, since the game has no lookup from an item to the recipe
-- that makes it. It walks every spell ID; each one that exists and has a
-- recipe schematic whose output is a weapon or armor is stored.
--
-- Measured in the 12.1.0 client (the Variant Builder lab notes, D1): spell IDs run to about 1.32 million, the whole walk costs about 5 s of
-- CPU with no Lua errors and no item or trade skill events, so at the Medium
-- budget it spreads over about 17 s. Only C_Spell and C_TradeSkillUI getters
-- are called; nothing opens or touches a profession window.
--
-- It starts by itself a little after login when this client build has not
-- been indexed (a patch adds recipes), resumes where it stopped after a
-- reload, and yields: no work in combat, while the scanner is held (test
-- runs), during an item scan, or while a profession window is open.
-- /lp recipes starts it by hand (a finished index is walked again) and
-- /lp recipes cancel stops it until the next login or the next /lp recipes.

local Scanner = CobysLinkepedia.Scanner
local Database = CobysLinkepedia.Database
local Debug = CobysLinkepedia.Debug

local START_DELAY = 10          -- seconds after login
local CALLS_PER_CHECK = 200     -- spell IDs between budget checks
local GAP = 250000              -- this many IDs past the last existing spell ends the walk
local MIN_WALK = 200000         -- the gap rule starts counting only past here
local HARD_CAP = 4000000
local DEFAULT_CEILING = 1330000 -- progress estimate before a walk has finished once
local PROGRESS_INTERVAL = 0.5

local DoesSpellExist = C_Spell.DoesSpellExist
local GetRecipeSchematic = C_TradeSkillUI.GetRecipeSchematic
local GetItemInfoInstant = C_Item.GetItemInfoInstant

local frame = CreateFrame("Frame")
local job = nil                 -- { activeSeconds, startPosition, found, sinceProgress, waiting }
local cancelledThisSession = false

local function Fire(event, ...)
  CobysLinkepedia.EventBus:Fire(event, ...)
end

local function ClientBuild()
  local version, build = GetBuildInfo()
  return version .. "." .. build
end

-- Why the job is waiting, or nil when it may work this frame
local function WaitReason()
  if UnitAffectingCombat("player") then return "combat" end
  if Scanner.IsHeld() then return "held" end
  if Scanner.IsScanActive() then return "item scan" end
  if ProfessionsFrame and ProfessionsFrame:IsShown() then return "profession window" end
  return nil
end

local function IsGear(itemID)
  local _, _, _, _, _, classID = GetItemInfoInstant(itemID)
  return classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor
end

local function Stop()
  frame:SetScript("OnUpdate", nil)
  job = nil
end

local function Complete(scan)
  scan.complete = true
  scan.ceiling = scan.lastExisting
  local found = job.found
  Stop()
  Debug.Log("SCAN", "Recipe scan complete: spells to %d, %d gear items indexed", scan.ceiling or 0, Database.GetRecipeCount())
  Fire(CobysLinkepedia.Events.RecipeIndexUpdated)
  Fire(CobysLinkepedia.Events.RecipeScanComplete, found)
end

local function Step(_, elapsed)
  if not job then return end
  -- Starting or ending a wait is news to the progress display
  local reason = WaitReason()
  if reason ~= job.waiting then
    job.waiting = reason
    Fire(CobysLinkepedia.Events.RecipeScanProgress)
  end
  if reason then return end
  local scan = Database.GetRecipeScanState()
  if not scan then return end

  job.activeSeconds = job.activeSeconds + elapsed
  local budget = Scanner.GetTimeBudget()
  local frameStart = debugprofilestop()
  local id, last = scan.next or 0, scan.lastExisting or 0
  local found, finished = 0, false

  repeat
    for _ = 1, CALLS_PER_CHECK do
      id = id + 1
      if DoesSpellExist(id) then
        last = id
        local ok, schematic = pcall(GetRecipeSchematic, id, false)
        local output = ok and schematic and schematic.outputItemID
        if output and output > 0 and IsGear(output) and Database.StoreRecipe(output, id) then
          found = found + 1
        end
      end
      if (id > MIN_WALK and id - last > GAP) or id >= HARD_CAP then
        finished = true
        break
      end
    end
  until finished or debugprofilestop() - frameStart >= budget

  scan.next, scan.lastExisting = id, last
  job.found = job.found + found

  if finished then
    Complete(scan)
    return
  end
  job.sinceProgress = job.sinceProgress + elapsed
  if job.sinceProgress >= PROGRESS_INTERVAL then
    job.sinceProgress = 0
    Fire(CobysLinkepedia.Events.RecipeScanProgress)
  end
end

-- Starts or resumes the walk. manual also walks a finished index again.
-- Returns whether a walk is now running.
function Scanner.StartRecipeScan(manual)
  if job then return true end
  local scan = Database.GetRecipeScanState()
  if not scan then return false end

  local build = ClientBuild()
  if scan.build ~= build then
    -- A new client build: walk again from the start, keeping what is indexed
    scan.build, scan.next, scan.lastExisting, scan.complete = build, 0, 0, false
  elseif scan.complete then
    if not manual then return false end
    scan.next, scan.lastExisting, scan.complete = 0, 0, false
  end

  cancelledThisSession = false
  job = { activeSeconds = 0, startPosition = scan.next or 0, found = 0, sinceProgress = 0 }
  frame:SetScript("OnUpdate", Step)
  Debug.Log("SCAN", "Recipe scan %s at spell %d", (scan.next or 0) > 0 and "resumed" or "started", scan.next or 0)
  Fire(CobysLinkepedia.Events.RecipeScanStarted)
  return true
end

-- Stops the walk where it is; the next login (or /lp recipes) continues it.
-- notify false is for Database.Reset, which fires its own update. keepSchedule
-- (the Variants suite) leaves this session's automatic start alone.
function Scanner.CancelRecipeScan(notify, keepSchedule)
  if not job then return false end
  Stop()
  if not keepSchedule then cancelledThisSession = true end
  Debug.Log("SCAN", "Recipe scan cancelled")
  if notify ~= false then
    Fire(CobysLinkepedia.Events.RecipeScanCancelled)
  end
  return true
end

-- Whether a walk is running (it may be waiting; see waiting)
function Scanner.IsRecipeScanActive()
  return job ~= nil
end

-- { active, waiting (a reason or nil), complete (for this client build),
--   fraction, indexed, eta (seconds, or nil) }
function Scanner.GetRecipeScanStatus()
  local scan = Database.GetRecipeScanState() or {}
  local position = scan.next or 0
  local ceiling = math.max(scan.ceiling or DEFAULT_CEILING, position, 1)
  local status = {
    active = job ~= nil,
    waiting = job and WaitReason() or nil,
    complete = scan.complete == true and scan.build == ClientBuild(),
    fraction = math.min(position / ceiling, 1),
    indexed = Database.GetRecipeCount(),
  }
  if job and job.activeSeconds >= 1 and position > job.startPosition then
    local rate = (position - job.startPosition) / job.activeSeconds
    status.eta = math.max(ceiling - position, 0) / rate
  end
  return status
end

-- Core calls this at PLAYER_LOGIN
function Scanner.ScheduleRecipeScan()
  C_Timer.After(START_DELAY, function()
    if job or cancelledThisSession then return end
    local status = Scanner.GetRecipeScanStatus()
    if not status.complete then Scanner.StartRecipeScan(false) end
  end)
end

-- /lp recipes [cancel]
function Scanner.RecipeScanCommand(arg)
  local Utilities = CobysLinkepedia.Utilities
  if arg == "cancel" or arg == "stop" then
    if Scanner.CancelRecipeScan(true) then
      Utilities.Message("Recipe scan stopped. It continues at your next login, or with /lp recipes.")
    else
      Utilities.Message("No recipe scan is running.")
    end
    return
  end
  if job then
    local status = Scanner.GetRecipeScanStatus()
    Utilities.Message(("The recipe scan is running: %d%%, %d gear items indexed so far."):format(
      math.floor(status.fraction * 100), status.indexed))
    return
  end
  Scanner.StartRecipeScan(true)
  Utilities.Message("Recipe scan started. It takes under a minute and pauses in combat; /lp recipes cancel stops it.")
end

-- A recipe scan finishing tells the player once, quietly
CobysLinkepedia.EventBus:Register({ ReceiveEvent = function()
  local Utilities = CobysLinkepedia.Utilities
  Utilities.Message(("Recipe index ready: %d craftable weapons and armor pieces."):format(Database.GetRecipeCount()), "verbose")
end }, { CobysLinkepedia.Events.RecipeScanComplete })

Debug.Log("INIT", "Recipe scan module loaded")
