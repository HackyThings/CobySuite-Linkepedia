-- Variant Capture: stores the item variants the player encounters in play
-- Reads item links from bags, equipment, loot, trade, mail and chat, and
-- stores the ones carrying bonus ids against their base item
-- (Database.StoreVariant owns the record format).

local Capture = {}
CobysLinkepedia.Database.Capture = Capture

local Database = CobysLinkepedia.Database
local Debug = CobysLinkepedia.Debug

local strmatch, strsub = string.match, string.sub

-- Links already settled this session (avoid spam), with a cap
local processedLinks = {}
local processedCount = 0
local MAX_PROCESSED_LINKS = 10000

-------------------------------------------------------------------------------
-- Item link parsing
--
-- The item string (warcraft.wiki.gg, ItemLink), colon-separated, empty
-- fields kept:
--   1 itemID, 2 enchantID, 3-6 gemID1-4, 7 suffixID, 8 uniqueID,
--   9 linkLevel, 10 specializationID, 11 modifiersMask, 12 itemContext,
--   13 numBonusIDs, then that many bonus ids, then numModifiers and that
--   many type/value pairs, then three relic bonus lists, crafterGUID and
--   extraEnchantID.
-------------------------------------------------------------------------------
local FIELD_NUM_BONUS_IDS = 13
local MAX_LIST = 64   -- longer than any real list; a larger count is damage

-- A field holding a whole number: its value, else nil ("", "1.5", "-2", "x")
local function WholeNumber(field)
  if field and strmatch(field, "^%d+$") then return tonumber(field) end
  return nil
end

-- { itemID, bonusIDs = { id, ... }, modifiers = { { type =, value = }, ... },
-- payload } for an item link or a bare item string, or nil. A variant is a
-- link with at least one bonus id. The display name is never read, so a
-- name containing ":" cannot shift a field.
function Capture.ParseItemLink(link)
  if type(link) ~= "string" then return nil end
  local payload = strmatch(link, "|Hitem:([^|]*)|h") or strmatch(link, "^item:([^|]*)$")
  if not payload then return nil end

  local fields = { strsplit(":", payload) }
  local itemID = tonumber(fields[1])
  if not itemID then return nil end

  local parsed = { itemID = itemID, bonusIDs = {}, modifiers = {}, payload = payload }
  local pos = FIELD_NUM_BONUS_IDS

  -- The bonus list counts only when it is well formed: an empty count field
  -- is no list, and a count that is not a whole number up to MAX_LIST, or
  -- any of its fields that is not a bonus id, makes the link no variant. The
  -- fields after a damaged list have no known position, so nothing more is read.
  local countField = fields[pos]
  local numBonus = 0
  if countField and countField ~= "" then
    numBonus = WholeNumber(countField)
    if not numBonus or numBonus > MAX_LIST then return parsed end
  end
  pos = pos + 1
  local bonusIDs = {}
  for i = 1, numBonus do
    local id = WholeNumber(fields[pos])
    if not id then return parsed end
    bonusIDs[i] = id
    pos = pos + 1
  end
  parsed.bonusIDs = bonusIDs

  -- Modifiers the same way; a damaged list leaves them empty
  countField = fields[pos]
  local numModifiers = 0
  if countField and countField ~= "" then
    numModifiers = WholeNumber(countField)
    if not numModifiers or numModifiers > MAX_LIST then return parsed end
  end
  pos = pos + 1
  local modifiers = {}
  for i = 1, numModifiers do
    local modType = WholeNumber(fields[pos])
    if not modType then return parsed end
    modifiers[i] = { type = modType, value = fields[pos + 1] or "" }
    pos = pos + 2
  end
  parsed.modifiers = modifiers
  return parsed
end

-------------------------------------------------------------------------------
-- Processing
-------------------------------------------------------------------------------

-- Remembers a link as settled for this session
local function MarkProcessed(link)
  if processedCount >= MAX_PROCESSED_LINKS then
    wipe(processedLinks)
    processedCount = 0
  end
  processedLinks[link] = true
  processedCount = processedCount + 1
end

-- Stores the link's variant if it is new. A link is remembered only once its
-- outcome cannot change (not a variant, stored, or already known). A variant
-- whose base item is not in the database yet is not remembered, so a later
-- sighting captures it once a scan has stored the base; Database.Reset makes
-- capture forget everything (ResetSession).
local function ProcessItemLink(link)
  if not link or processedLinks[link] then return end

  local parsed = Capture.ParseItemLink(link)
  if not parsed or #parsed.bonusIDs == 0 then
    MarkProcessed(link)
    return
  end

  local baseItem = Database.GetItem(parsed.itemID)
  if not baseItem then return end

  -- true stored, false already known, nil not storable
  local isNew = Database.StoreVariant(parsed.itemID, link, parsed)
  if isNew == nil then return end
  MarkProcessed(link)
  if isNew then
    Debug.Log("CAPTURE", "New variant captured: %s (ID: %d)", baseItem.name, parsed.itemID)
    CobysLinkepedia.EventBus:Fire(CobysLinkepedia.Events.ItemCaptured, parsed.itemID, baseItem.name, link)
  end
end

-- The in-game Capture suite feeds links through this directly
Capture.ProcessItemLink = ProcessItemLink

-- Forgets every link handled this session (Database.Reset)
function Capture.ResetSession()
  wipe(processedLinks)
  processedCount = 0
end

-- Scans a text string for item links. Chat message args may be secret
-- strings in modern WoW: tostring and string.gmatch both silently accept
-- them but still throw on actual use, so the whole scan runs under pcall and
-- an unreadable message is skipped.
local function ScanTextForLinks(text)
  if not text then return end
  -- Every match below contains the literal |Hitem:, so one plain find
  -- settles most chat lines without the iterator or the closure
  local ok, pos = pcall(string.find, text, "|Hitem:", 1, true)
  if not ok or not pos then return end
  pcall(function()
    for link in text:gmatch("|c.-|Hitem:.-|h.-|h|r") do
      ProcessItemLink(link)
    end
  end)
end

-------------------------------------------------------------------------------
-- Bags and equipment
--
-- A sweep reads every carried container (backpack through the reagent bag)
-- and every equipped slot, after a change settles (BAG_UPDATE comes in
-- bursts), and never in combat: a change seen in combat, or a sweep that
-- comes due in combat, marks the sweep dirty and PLAYER_REGEN_ENABLED runs
-- it once. A sweep also runs after login and after every completed scan,
-- because items already carried or worn raise no event and their base item
-- may only just have been stored.
-------------------------------------------------------------------------------
local sweepDirty = false

local function ScanBags()
  -- 0 is the backpack; NUM_TOTAL_EQUIPPED_BAG_SLOTS is the reagent bag
  for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
    for slot = 1, C_Container.GetContainerNumSlots(bag) do
      local link = C_Container.GetContainerItemLink(bag, slot)
      if link then ProcessItemLink(link) end
    end
  end
end

local function ScanEquipment()
  for slot = INVSLOT_FIRST_EQUIPPED, INVSLOT_LAST_EQUIPPED do
    local link = GetInventoryItemLink("player", slot)
    if link then ProcessItemLink(link) end
  end
end

local function Sweep()
  if UnitAffectingCombat("player") then
    sweepDirty = true
    return
  end
  sweepDirty = false
  ScanBags()
  ScanEquipment()
end

local sweepSettled = CobySuite_CobysLinkepedia.Utilities.Debounce(0.1, Sweep)

-------------------------------------------------------------------------------
-- Event registration
-------------------------------------------------------------------------------
local captureFrame = CreateFrame("Frame")
local registered = false

function Capture.RegisterEvents()
  if registered then return end
  registered = true

  -- Bags and equipment
  captureFrame:RegisterEvent("BAG_UPDATE")
  captureFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
  captureFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

  -- Loot window
  captureFrame:RegisterEvent("LOOT_OPENED")

  -- Chat messages (various channels for links from other players)
  captureFrame:RegisterEvent("CHAT_MSG_SAY")
  captureFrame:RegisterEvent("CHAT_MSG_YELL")
  captureFrame:RegisterEvent("CHAT_MSG_PARTY")
  captureFrame:RegisterEvent("CHAT_MSG_PARTY_LEADER")
  captureFrame:RegisterEvent("CHAT_MSG_RAID")
  captureFrame:RegisterEvent("CHAT_MSG_RAID_LEADER")
  captureFrame:RegisterEvent("CHAT_MSG_GUILD")
  captureFrame:RegisterEvent("CHAT_MSG_OFFICER")
  captureFrame:RegisterEvent("CHAT_MSG_WHISPER")
  captureFrame:RegisterEvent("CHAT_MSG_CHANNEL")
  captureFrame:RegisterEvent("CHAT_MSG_INSTANCE_CHAT")
  captureFrame:RegisterEvent("CHAT_MSG_INSTANCE_CHAT_LEADER")
  captureFrame:RegisterEvent("CHAT_MSG_LOOT")

  -- Trade window: both sides raise their own change event
  captureFrame:RegisterEvent("TRADE_SHOW")
  captureFrame:RegisterEvent("TRADE_PLAYER_ITEM_CHANGED")
  captureFrame:RegisterEvent("TRADE_TARGET_ITEM_CHANGED")

  -- Mail
  captureFrame:RegisterEvent("MAIL_INBOX_UPDATE")

  Debug.Log("CAPTURE", "Item capture events registered")

  -- Items already carried or worn raise no event of their own
  if Database.GetCount() > 0 then
    sweepSettled:Call()
  end
end

-- A completed scan may have stored the base items of what the player carries
CobysLinkepedia.EventBus:Register({ ReceiveEvent = function()
  if registered then sweepSettled:Call() end
end }, { CobysLinkepedia.Events.ScanComplete })

captureFrame:SetScript("OnEvent", function(_, event, arg1)
  if event == "PLAYER_REGEN_ENABLED" then
    if sweepDirty then sweepSettled:Call() end
    return
  end

  if event == "BAG_UPDATE" or event == "PLAYER_EQUIPMENT_CHANGED" then
    if UnitAffectingCombat("player") then
      sweepDirty = true
    else
      sweepSettled:Call()
    end
    return
  end

  -- Loot, trade, mail and chat are momentary; in combat they are skipped
  if UnitAffectingCombat("player") then return end

  if event == "LOOT_OPENED" then
    for i = 1, GetNumLootItems() do
      ProcessItemLink(GetLootSlotLink(i))
    end

  elseif event == "TRADE_SHOW" then
    for i = 1, MAX_TRADE_ITEMS or 7 do
      ProcessItemLink(GetTradeTargetItemLink(i))
      ProcessItemLink(GetTradePlayerItemLink(i))
    end

  elseif event == "TRADE_TARGET_ITEM_CHANGED" then
    if arg1 then ProcessItemLink(GetTradeTargetItemLink(arg1)) end

  elseif event == "TRADE_PLAYER_ITEM_CHANGED" then
    if arg1 then ProcessItemLink(GetTradePlayerItemLink(arg1)) end

  elseif event == "MAIL_INBOX_UPDATE" then
    local numMail = GetInboxNumItems()
    for i = 1, math.min(numMail, 50) do
      for j = 1, ATTACHMENTS_MAX_RECEIVE do
        ProcessItemLink(GetInboxItemLink(i, j))
      end
    end

  elseif strsub(event, 1, 8) == "CHAT_MSG" then
    -- arg1 is the message text
    ScanTextForLinks(arg1)
  end
end)

Debug.Log("INIT", "Database capture module loaded")
