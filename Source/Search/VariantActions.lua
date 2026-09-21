-- Variant actions: what the explorer does with one variant of an item, for
-- every list that shows variants (the detail pane, the Favorites tab) and
-- for the Variant Builder.
--
-- A variant entry is { id = itemID, variant = { link, savedID, favorite,
-- rank, ilvl, track, kind, source } }: a saved variant (Variants/Store.lua)
-- carries its savedID; a captured one (Database.GetVariants) has none until
-- it is saved. Clicks match the item rows: click opens it in the Variant
-- Builder, Shift-click links it, Ctrl-click opens the dressing room,
-- right-click opens its menu.

local Search = CobysLinkepedia.Search
local Variants = CobysLinkepedia.Variants
local Database = CobysLinkepedia.Database
local Linkify = CobysLinkepedia.Linkify
local Utilities = CobysLinkepedia.Utilities

-------------------------------------------------------------------------------
-- Labels
-------------------------------------------------------------------------------

-- The name a link shows, without its quality icon markup
function Search.VariantName(link, itemID)
  local name = type(link) == "string" and link:match("|h%[(.-)%]|h")
  if name then
    name = name:gsub("|A.-|a", ""):gsub("%s+$", "")
    if name ~= "" then return name end
  end
  local item = itemID and Database.GetItem(itemID)
  return item and item.name or (itemID and ("Item " .. itemID)) or "?"
end

-- "rank 3, item level 318, Champion 6/6, Midnight Season 2", from whichever
-- parts are known, then the quality a quality bonus gives ("Legendary")
function Search.VariantDetail(variant)
  local parts = {}
  if variant.rank and variant.rank > 0 then parts[#parts + 1] = "rank " .. variant.rank end
  if variant.ilvl then parts[#parts + 1] = "item level " .. variant.ilvl end
  if variant.track then parts[#parts + 1] = Variants.TrackText(variant.track) end
  local quality = Variants.QualityOverride(variant.link)
  if quality then parts[#parts + 1] = Variants.QualityName(quality) end
  return table.concat(parts, ", ")
end

-- The item quality (Enum.ItemQuality) a variant shows, which can differ from
-- its base item's: an upgrade-track rank or a crafted quality moves it. Read
-- from the link's colour code, else the client.
function Search.VariantQuality(variant, itemID)
  local link = variant.link
  local quality = type(link) == "string" and tonumber(link:match("|cnIQ(%d+)"))
  if not quality and type(link) == "string" then
    quality = select(3, C_Item.GetItemInfo(link))
  end
  if quality then return quality end
  local item = itemID and Database.GetItem(itemID)
  return item and item.quality or 1
end

-- The optional reagents any recipe for itemID offers, as a set, or nil;
-- cached per item until the recipe index changes
local optionalReagents = {}
CobysLinkepedia.EventBus:Register({ ReceiveEvent = function() wipe(optionalReagents) end },
  { CobysLinkepedia.Events.RecipeIndexUpdated })

local function OptionalReagentSet(itemID)
  local cached = optionalReagents[itemID]
  if cached == nil then
    cached = false
    for _, recipeID in ipairs(Variants.GetRecipeIDs(itemID)) do
      local options = Variants.GetCraftedOptions(recipeID)
      for _, slot in ipairs(options and options.slots or {}) do
        for _, reagentID in ipairs(slot.reagents) do
          cached = cached or {}
          cached[reagentID] = true
        end
      end
    end
    optionalReagents[itemID] = cached
  end
  return cached or nil
end

-- What sets a variant apart, short enough for one row: its track
-- ("Myth 6/6, Midnight Season 2", then "Legendary" when a quality bonus sets
-- one), or the optional reagents in a crafted link ("Competitor's Heraldry,
-- Algari Missive"), or its crafted quality
function Search.VariantSummary(variant, itemID)
  if variant.track then
    local quality = Variants.QualityOverride(variant.link)
    local text = Variants.TrackText(variant.track)
    return quality and (text .. ", " .. Variants.QualityName(quality)) or text
  end
  if not variant.rank or variant.rank <= 0 then return "" end
  local names = {}
  local optional = OptionalReagentSet(itemID)
  if optional then
    local parsed = Database.Capture.ParseItemLink(variant.link)
    for _, modifier in ipairs(parsed and parsed.modifiers or {}) do
      local reagentID = tonumber(modifier.value)
      -- Reagents sit in modifier 43 onward, one per data slot
      if modifier.type >= 43 and reagentID and optional[reagentID] then
        names[#names + 1] = C_Item.GetItemNameByID(reagentID) or ("item " .. reagentID)
      end
    end
  end
  if #names == 0 then return "Quality " .. variant.rank end
  return table.concat(names, ", ")
end

-- The crafted quality icon as inline text, or ""
function Search.VariantRankMarkup(variant, size)
  if not variant.rank or variant.rank <= 0 then return "" end
  local atlas = Utilities.GetQualityAtlas(variant.rank, variant.link)
  return atlas and CreateAtlasMarkup(atlas, size or 14, size or 14) or ""
end

-------------------------------------------------------------------------------
-- Entries
-------------------------------------------------------------------------------

local function SavedEntry(v)
  return {
    id = v.itemID,
    variant = {
      link = v.link, savedID = v.id, favorite = v.favorite, rank = v.rank, ilvl = v.ilvl,
      track = v.track, kind = v.kind, source = v.source,
    },
  }
end
Search.SavedVariantEntry = SavedEntry

-- The item's saved variants, best first, then the captured ones not saved
function Search.VariantEntriesForItem(itemID)
  local entries, keys = {}, {}
  for _, v in ipairs(Variants.GetForItem(itemID)) do
    entries[#entries + 1] = SavedEntry(v)
    keys[v.key] = true
  end
  for _, captured in ipairs(Database.GetVariants(itemID) or {}) do
    if not keys[captured.key] then
      local info = Variants.ReadLinkInfo(captured.link)
      entries[#entries + 1] = {
        id = itemID,
        variant = {
          link = captured.link, rank = captured.rank, ilvl = captured.ilvl,
          track = info and info.track, kind = info and info.kind, source = "captured",
        },
      }
    end
  end
  return entries
end

-- The entry's saved ID, saving a captured variant first. Returns the ID, or
-- nil and a sentence saying why not.
function Search.EnsureVariantSaved(entry)
  local variant = entry and entry.variant
  if not variant then return nil, "No variant." end
  if variant.savedID and Variants.Get(variant.savedID) then return variant.savedID end
  local id, reason = Variants.Save(variant.link, { source = variant.source == "captured" and "captured" or "built" })
  if id then variant.savedID = id end
  return id, reason
end

-------------------------------------------------------------------------------
-- Deleting, with a warning when macros still name it
-------------------------------------------------------------------------------
local deletePopup = Utilities.CreateDialogPopup({
  name = "CobysLinkepediaDeleteVariantPopup",
  title = "Delete Saved Variant",
  width = 400,
  height = 170,
  confirmText = "Delete",
  danger = true,
  hidden = true,
  onConfirm = function(popup)
    local id = popup.variantID
    popup.variantID = nil
    if id and Variants.Delete(id) then
      Utilities.Message(("Deleted saved variant %d."):format(id))
    end
  end,
})

-- Deletes saved variant id; asks first when a macro's ${v=id} would stop
-- linking. Returns true when it was deleted right away.
function Search.DeleteSavedVariant(id)
  local v = Variants.Get(id)
  if not v then return false end
  local macros = Variants.MacrosUsing(id)
  if #macros == 0 then
    Variants.Delete(id)
    return true
  end
  deletePopup.variantID = id
  deletePopup:SetBody(("%s is used by %s: %s.\n\nAfter a delete those macros send %s as typed.")
    :format(Linkify.FormatVariantToken(id), #macros == 1 and "a macro" or (#macros .. " macros"),
      table.concat(macros, ", "), Linkify.FormatVariantToken(id)))
  deletePopup:Show()
  return false
end

-------------------------------------------------------------------------------
-- Clicks and the menu
-------------------------------------------------------------------------------

local function LinkToChat(entry)
  Search.PutInChat(entry.variant.link)
  Search.AddToHistory(entry.id)
end

function Search.HandleVariantClick(entry, button, anchor)
  if not entry or not entry.variant then return end
  if button == "LeftButton" then
    if IsControlKeyDown() then
      DressUpItemLink(entry.variant.link)
    elseif IsShiftKeyDown() then
      LinkToChat(entry)
    else
      Search.OpenBuilder(entry.id, entry.variant)
    end
  elseif button == "RightButton" then
    Search.ShowVariantMenu(anchor, entry)
  end
end

function Search.ShowVariantMenu(anchor, entry)
  local variant = entry.variant
  MenuUtil.CreateContextMenu(anchor, function(_, root)
    root:CreateTitle(Search.VariantName(variant.link, entry.id))
    root:CreateButton("Open in Variant Builder", function()
      Search.OpenBuilder(entry.id, variant)
    end)

    local saved = variant.savedID and Variants.Get(variant.savedID)
    if saved then
      root:CreateButton(saved.favorite and "Remove from Favorites" or "Add to Favorites", function()
        Variants.SetFavorite(saved.id, not saved.favorite)
      end)
    else
      root:CreateButton("Save variant", function()
        local id, reason = Search.EnsureVariantSaved(entry)
        if id then
          Utilities.Message(("Saved as variant %d: %s links it in chat and macros."):format(id, Linkify.FormatVariantToken(id)))
        else
          Utilities.Message.Warn(reason)
        end
      end)
      root:CreateButton("Save and add to Favorites", function()
        local id, reason = Search.EnsureVariantSaved(entry)
        if id then
          Variants.SetFavorite(id, true)
        else
          Utilities.Message.Warn(reason)
        end
      end)
    end

    root:CreateDivider()
    root:CreateButton("Link in chat", function() LinkToChat(entry) end)
    -- The token needs a saved variant, so sending it saves one. Macros get it
    -- from the builder's Add to Macro, a click the macro window allows.
    root:CreateButton("Send variant token to chat", function()
      local id, reason = Search.EnsureVariantSaved(entry)
      if id then
        Search.PutInChat(Linkify.FormatVariantToken(id))
      else
        Utilities.Message.Warn(reason)
      end
    end)

    if saved then
      root:CreateDivider()
      root:CreateButton("Delete saved variant", function()
        Search.DeleteSavedVariant(saved.id)
      end)
    end
  end)
end
