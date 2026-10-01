-- Upgrade-track variants: the link for an item on a season's track and rank,
-- the ranks a track offers, and what any item link says about itself.
--
-- A track link is the base item's link with one bonus ID (TrackData.lua) and
-- nothing else, keeping the base link's level and specialization fields:
--   item:<id>::::::::<linkLevel>:<specID>:::1:<bonusID>:0
-- The client turns that item string into a full link through
-- C_Item.GetItemInfo, in its own layout, and C_Item.GetItemUpgradeInfo on
-- the result confirms the rank and the track (its name string ID, so the
-- check works in any language). The client describes only the current
-- season's tracks, so a past season's link is confirmed by keeping its bonus
-- ID and having an item level, and its track comes from TrackData (marked
-- fromData, with no highest rank). Measured in the 12.1.0 client
-- (Variant-Builder-Lab.md, D5 and D6): every Midnight Season 2 track and rank
-- read back right, and a whisper carried the built link intact. The client
-- accepts any track on any gear (a PvP cloak took them all), so whether an
-- item really drops on a track is the player's call.
--
-- A quality above the rank's own adds a second bonus, one of QUALITY_BONUS,
-- whose only effect sets the quality; the build confirms the client reads
-- that quality back, with the track and rank kept. The client takes the
-- highest quality the bonuses ask for, so a quality below the rank's own
-- never lands: Myth 6 stayed Epic for Common, Uncommon and Rare, in either
-- bonus order, and took Legendary, Artifact and Heirloom (in the client
-- 2026-09-17, Variant-Builder-Lab.md D9).

local Variants = CobysLinkepedia.Variants
local Utilities = CobysLinkepedia.Utilities

local strmatch, strsplit = string.match, strsplit

local RETRY_DELAY = 0.5
local RETRIES = 6
local LOAD_TIMEOUT = 5

-- bonusID -> { season, track, rank }, for reading a link's track
local byBonus = {}
for _, season in ipairs(Variants.SEASONS) do
  for _, track in ipairs(season.tracks) do
    for rank, bonusID in ipairs(track.bonusIDs) do
      byBonus[bonusID] = { season = season, track = track, rank = rank }
    end
  end
end

-- bonusID -> Enum.ItemQuality, for reading a link's quality bonus
local byQualityBonus = {}
for quality, bonusID in pairs(Variants.QUALITY_BONUS) do
  byQualityBonus[bonusID] = quality
end

-- Numbers the client may hand back as secrets are as good as none here
local function Plain(value)
  if Utilities.IsSecret(value) then return nil end
  return value
end

-- Weapons and armor that can be equipped
function Variants.IsGear(itemID)
  local _, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(itemID)
  if classID ~= Enum.ItemClass.Weapon and classID ~= Enum.ItemClass.Armor then return false end
  return equipLoc ~= nil and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE"
end

function Variants.GetSeasons()
  return Variants.SEASONS
end

function Variants.GetSeason(key)
  for _, season in ipairs(Variants.SEASONS) do
    if season.key == key then return season end
  end
  return nil
end

function Variants.GetTrack(seasonKey, name)
  local season = Variants.GetSeason(seasonKey)
  for _, track in ipairs(season and season.tracks or {}) do
    if track.name == name then return track end
  end
  return nil
end

-- The qualities a track link can be given, lowest first. above (optional, the
-- rank's own quality) leaves out the qualities at or below it, which the
-- client refuses: it keeps the higher of the qualities the bonuses ask for.
function Variants.GetTrackQualities(above)
  local list = {}
  for quality in pairs(Variants.QUALITY_BONUS) do
    if not above or quality > above then list[#list + 1] = quality end
  end
  table.sort(list)
  return list
end

-- "Legendary"
function Variants.QualityName(quality)
  return Utilities.QualityNames[quality] or ("Quality " .. tostring(quality))
end

-- The quality a quality bonus in link sets, or nil when it carries none
function Variants.QualityOverride(link)
  local parsed = CobysLinkepedia.Database.Capture.ParseItemLink(link)
  for _, bonusID in ipairs(parsed and parsed.bonusIDs or {}) do
    local quality = byQualityBonus[bonusID]
    if quality then return quality end
  end
  return nil
end

-- "Champion 6/6, Midnight Season 2" from a link info's track ("Champion 6"
-- when the highest rank is not known, as for a past season; "Myth 9/6" past
-- the highest rank the client names)
function Variants.TrackText(track)
  if type(track) ~= "table" then return "" end
  local text = track.text or track.name or ""
  if track.level and track.max then
    text = text .. " " .. track.level .. "/" .. track.max
  elseif track.level then
    text = text .. " " .. track.level
  end
  if track.seasonName then text = text .. ", " .. track.seasonName end
  return text
end

-- What a link says about itself: { itemID, ilvl, rank (crafted quality, 0
-- when none), track = { text, level, max, stringID, seasonKey, seasonName,
-- name, fromData } or nil, qualityOverride (Variants.QualityOverride), kind
-- ("crafted" | "track" | "other") }; nil for
-- anything that is not an item link. The season and English track name come
-- from the link's bonus IDs when TrackData knows them; a track the client
-- does not describe (a past season's) is read from TrackData alone, with
-- fromData set and no max.
function Variants.ReadLinkInfo(link)
  if type(link) ~= "string" then return nil end
  local itemID = tonumber(strmatch(link, "item:(%d+)"))
  if not itemID then return nil end
  local info = { itemID = itemID, rank = 0, kind = "other" }

  local ok, level = pcall(C_Item.GetDetailedItemLevelInfo, link)
  level = ok and Plain(level) or nil
  if type(level) == "number" and level > 0 then info.ilvl = level end

  local okQuality, quality = pcall(C_TradeSkillUI.GetItemCraftedQualityByItemInfo, link)
  quality = okQuality and Plain(quality) or nil
  if type(quality) == "number" and quality > 0 then
    info.rank = quality
    info.kind = "crafted"
  end

  local known
  local parsed = CobysLinkepedia.Database.Capture.ParseItemLink(link)
  for _, bonusID in ipairs(parsed and parsed.bonusIDs or {}) do
    known = known or byBonus[bonusID]
    info.qualityOverride = info.qualityOverride or byQualityBonus[bonusID]
  end

  -- The client's description counts only when it names a track and gives a
  -- real rank and highest rank; for a past season it may give nothing, or a
  -- name with no ranks. The rank can pass the highest (Myth 9/6).
  local okUpgrade, upgrade = pcall(C_Item.GetItemUpgradeInfo, link)
  upgrade = okUpgrade and type(upgrade) == "table" and upgrade or nil
  local text = upgrade and Plain(upgrade.trackString)
  local level = upgrade and Plain(upgrade.currentLevel)
  local max = upgrade and Plain(upgrade.maxLevel)
  if type(text) == "string" and text ~= "" and type(level) == "number" and level >= 1
      and type(max) == "number" and max >= 1 then
    info.track = { text = text, level = level, max = max, stringID = Plain(upgrade.trackStringID) }
  elseif known then
    info.track = {
      text = known.track.name, level = known.rank, stringID = known.track.stringID, fromData = true,
    }
  end
  if info.track then
    if info.kind == "other" then info.kind = "track" end
    if known then
      info.track.seasonKey, info.track.seasonName = known.season.key, known.season.name
      info.track.name = known.track.name
    end
  end
  return info
end

-- The item string for itemID carrying bonusIDs (a track bonus, then any
-- quality bonus), from the base link's level and specialization fields
local function TrackPayload(itemID, baseLink, bonusIDs)
  local payload = strmatch(baseLink, "|Hitem:([^|]*)|h") or ""
  local fields = { strsplit(":", payload) }
  local parts = { itemID, "", "", "", "", "", "", "", fields[9] or "", fields[10] or "", "", "", #bonusIDs }
  for _, bonusID in ipairs(bonusIDs) do parts[#parts + 1] = bonusID end
  parts[#parts + 1] = 0
  return "item:" .. table.concat(parts, ":")
end

-- The ranks a track offers for itemID, as the client reads them now:
-- { { rank, ilvl }, ..., max = the highest rank the client names } in rank
-- order. A rank past that highest one (Myth 9/6) is offered when the client
-- reads it back as that rank, up to the first it does not. A track the
-- client does not describe (a past season's) offers every rank in its data,
-- with no max. nil when the item has not loaded yet (a load is requested;
-- ask again later).
function Variants.GetTrackRanks(itemID, seasonKey, trackName)
  local track = Variants.GetTrack(seasonKey, trackName)
  if not track then return {} end
  local _, baseLink = C_Item.GetItemInfo(itemID)
  if not baseLink then
    C_Item.RequestLoadItemDataByID(itemID)
    return nil
  end

  local function Read(rank)
    local payload = TrackPayload(itemID, baseLink, { track.bonusIDs[rank] })
    local _, link = C_Item.GetItemInfo(payload)
    local target = link or payload
    local okUpgrade, upgrade = pcall(C_Item.GetItemUpgradeInfo, target)
    local okLevel, ilvl = pcall(C_Item.GetDetailedItemLevelInfo, target)
    ilvl = okLevel and Plain(ilvl) or nil
    return okUpgrade and type(upgrade) == "table" and upgrade or nil, type(ilvl) == "number" and ilvl or nil
  end

  local ranks, max = {}, nil
  for rank = 1, #track.bonusIDs do
    local upgrade, ilvl = Read(rank)
    if rank == 1 then
      max = upgrade and Plain(upgrade.maxLevel)
      if type(max) ~= "number" or max < 1 then max = nil end
    end
    if max and rank > max and (upgrade and Plain(upgrade.currentLevel)) ~= rank then break end
    ranks[rank] = { rank = rank, ilvl = ilvl }
  end
  ranks.max = max and math.min(max, #ranks) or nil
  return ranks
end

-- The quality itemID has at a track's rank with no quality bonus, when the
-- client can say now; nil while it loads
function Variants.GetTrackOwnQuality(itemID, seasonKey, trackName, rank)
  local track = Variants.GetTrack(seasonKey, trackName)
  local bonusID = track and type(rank) == "number" and track.bonusIDs[rank]
  if not bonusID then return nil end
  local _, baseLink = C_Item.GetItemInfo(itemID)
  if not baseLink then return nil end
  local _, _, quality = C_Item.GetItemInfo(TrackPayload(itemID, baseLink, { bonusID }))
  quality = Plain(quality)
  return type(quality) == "number" and quality or nil
end

-- Builds itemID's link on a season's track at rank and calls onDone(result):
-- { link, ilvl, track, quality } when the client read back that track and
-- rank, and the quality asked for, else { error, detail }. Returns cancel.
-- quality (optional, a key of QUALITY_BONUS) replaces the rank's own: the
-- plain track link is built first and is the result when it already has that
-- quality; otherwise the quality bonus goes after the track bonus, then
-- before it, and the first link the client reads back with that quality and
-- the same track and rank is the result. A quality below the rank's own is
-- refused: the client keeps the higher one.
function Variants.BuildTrackLink(itemID, seasonKey, trackName, rank, onDone, quality)
  local track = Variants.GetTrack(seasonKey, trackName)
  local cancelled, timer, cancelLoad = false, nil, nil
  local function Cancel()
    cancelled = true
    if timer then timer:Cancel() end
    if cancelLoad then cancelLoad() end
  end
  if not track or type(rank) ~= "number" or not track.bonusIDs[rank] then
    onDone({ error = "Choose a season, a track and a rank." })
    return Cancel
  end
  local qualityBonus = quality ~= nil and Variants.QUALITY_BONUS[quality] or nil
  if quality ~= nil and not qualityBonus then
    onDone({ error = "That quality cannot be given to a track link." })
    return Cancel
  end
  local bonusID = track.bonusIDs[rank]
  local orders = { { bonusID } }
  if qualityBonus then
    orders[2] = { bonusID, qualityBonus }
    orders[3] = { qualityBonus, bonusID }
  end

  -- Whether link reads back as this track and rank: ok, info, readBack, carried
  local function Confirm(link)
    local info = Variants.ReadLinkInfo(link)
    local readBack = info and info.track
    local parsed = CobysLinkepedia.Database.Capture.ParseItemLink(link)
    local carried = false
    for _, id in ipairs(parsed and parsed.bonusIDs or {}) do
      if id == bonusID then carried = true end
    end
    local ok
    if readBack and not readBack.fromData then
      -- A track the client describes: its rank and name must match
      ok = readBack.level == rank and (readBack.stringID == nil or readBack.stringID == track.stringID)
    else
      -- A past season's: the link must keep the bonus ID and have an item level
      ok = carried and info ~= nil and info.ilvl ~= nil and readBack ~= nil and readBack.seasonKey == seasonKey
    end
    return ok, info, readBack, carried
  end

  cancelLoad = Utilities.LoadItemThen(itemID, {
    timeout = LOAD_TIMEOUT,
    onFail = function()
      if not cancelled then onDone({ error = "The item's data did not load; try again in a moment." }) end
    end,
    onReady = function(baseLink)
      local order, attempts, ownQuality = 1, 0, nil
      local tried = {}
      local function Try()
        timer = nil
        if cancelled then return end
        attempts = attempts + 1
        local _, link, linkQuality = C_Item.GetItemInfo(TrackPayload(itemID, baseLink, orders[order]))
        if not link and attempts < RETRIES then
          timer = C_Timer.NewTimer(RETRY_DELAY, Try)
          return
        end
        if not link then
          onDone({ error = "The game did not build a link for this track." })
          return
        end
        linkQuality = Plain(linkQuality)
        local ok, info, readBack, carried = Confirm(link)
        if order == 1 and not ok then
          -- What the client said, for the debug log and the Variants suite
          local okUpgrade, upgrade = pcall(C_Item.GetItemUpgradeInfo, link)
          upgrade = okUpgrade and type(upgrade) == "table" and upgrade or {}
          local detail = ("upgrade info %s %s/%s string %s; bonus %d kept %s; item level %s; read as %s"):format(
            tostring(Plain(upgrade.trackString)), tostring(Plain(upgrade.currentLevel)), tostring(Plain(upgrade.maxLevel)),
            tostring(Plain(upgrade.trackStringID)), bonusID, tostring(carried), tostring(info and info.ilvl),
            readBack and Variants.TrackText(readBack) or "no track")
          CobysLinkepedia.Debug.Warn("UI", "Track build refused for item %d, %s %s %d: %s", itemID, seasonKey, track.name, rank, detail)
          onDone({ error = ("The game did not confirm %s %d for this item."):format(track.name, rank), detail = detail, link = link })
          return
        end
        if ok and (quality == nil or linkQuality == quality) then
          onDone({ link = link, ilvl = info.ilvl, track = readBack, quality = linkQuality })
          return
        end
        if order == 1 then
          ownQuality = linkQuality
        else
          tried[#tried + 1] = ("bonus %s read as quality %s, %s"):format(table.concat(orders[order], " then "),
            tostring(linkQuality), ok and "track kept" or "track lost")
        end
        if order < #orders then
          order, attempts = order + 1, 0
          return Try()
        end
        local detail = table.concat(tried, "; ")
        CobysLinkepedia.Debug.Warn("UI", "Quality %s refused for item %d, %s %s %d: %s",
          tostring(quality), itemID, seasonKey, track.name, rank, detail)
        local refused
        if ownQuality and quality < ownQuality then
          refused = ("%s %d is already %s, and the game never lowers an item's quality."):format(
            track.name, rank, Variants.QualityName(ownQuality))
        else
          refused = ("The game kept %s quality for %s %d on this item."):format(
            ownQuality and Variants.QualityName(ownQuality) or "its own", track.name, rank)
        end
        onDone({ error = refused, detail = detail })
      end
      Try()
    end,
  })
  return Cancel
end
