-- Favorites: persistent list of favorited item IDs, and the tab that lists
-- them with favorited saved variants under their item

local Search = CobysLinkepedia.Search
local Utilities = CobysLinkepedia.Utilities
local Debug = CobysLinkepedia.Debug

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------
function Search.AddFavorite(itemID)
  if not COBYS_LINKEPEDIA_STATE or not COBYS_LINKEPEDIA_STATE.favorites then return end
  if COBYS_LINKEPEDIA_STATE.favorites[itemID] then return end

  COBYS_LINKEPEDIA_STATE.favorites[itemID] = true
  Debug.Log("UI", "Added favorite: %d", itemID)
  CobysLinkepedia.EventBus:Fire(CobysLinkepedia.Events.FavoriteChanged, itemID, true)
end

function Search.RemoveFavorite(itemID)
  if not COBYS_LINKEPEDIA_STATE or not COBYS_LINKEPEDIA_STATE.favorites then return end
  if not COBYS_LINKEPEDIA_STATE.favorites[itemID] then return end

  COBYS_LINKEPEDIA_STATE.favorites[itemID] = nil
  Debug.Log("UI", "Removed favorite: %d", itemID)
  CobysLinkepedia.EventBus:Fire(CobysLinkepedia.Events.FavoriteChanged, itemID, false)
end

function Search.IsFavorite(itemID)
  if not COBYS_LINKEPEDIA_STATE or not COBYS_LINKEPEDIA_STATE.favorites then return false end
  return COBYS_LINKEPEDIA_STATE.favorites[itemID] == true
end

-------------------------------------------------------------------------------
-- Favorites tab content: a scrolling item list left of the detail pane.
-- Item rows use the explorer's shared click actions (Search.HandleItemClick)
-- and variant rows the variant ones (Search.HandleVariantClick); right-click
-- opens a menu holding Remove from Favorites. A favorited variant follows
-- its item, and stands on its own when the item is not a favorite.
-------------------------------------------------------------------------------
function Search.InitFavorites(window)
  local f = CreateFrame("Frame", nil, window)
  f:SetPoint("TOPLEFT", 8, -58)
  f:SetPoint("BOTTOMRIGHT", Search.ContentEdge, "BOTTOMRIGHT", 0, 26)
  f:Hide()

  local list = Search.CreateItemList(f, { top = -4, indentVariants = true })

  f.EmptyText = f:CreateFontString(nil, "OVERLAY", Utilities.Fonts.BODY)
  f.EmptyText:SetPoint("CENTER")
  f.EmptyText:SetText("No favorites yet.\nRight-click any item or variant to add it to favorites.")
  f.EmptyText:SetTextColor(unpack(Utilities.Colors.DISABLED_GRAY))
  f.EmptyText:SetJustifyH("CENTER")

  function f:RefreshFavorites()
    local itemIDs, seen = {}, {}
    local favorites = COBYS_LINKEPEDIA_STATE and COBYS_LINKEPEDIA_STATE.favorites
    if favorites then
      for itemID in pairs(favorites) do
        itemIDs[#itemIDs + 1] = itemID
        seen[itemID] = true
      end
    end
    local variantsByItem = {}
    for _, v in ipairs(CobysLinkepedia.Variants.GetFavorites()) do
      if not variantsByItem[v.itemID] then
        variantsByItem[v.itemID] = {}
        if not seen[v.itemID] then
          itemIDs[#itemIDs + 1] = v.itemID
        end
      end
      table.insert(variantsByItem[v.itemID], v)
    end
    table.sort(itemIDs)

    local entries = {}
    for _, itemID in ipairs(itemIDs) do
      if seen[itemID] then entries[#entries + 1] = { id = itemID } end
      for _, v in ipairs(variantsByItem[itemID] or {}) do
        entries[#entries + 1] = Search.SavedVariantEntry(v)
      end
    end
    list:SetEntries(entries)
    self.EmptyText:SetShown(#entries == 0)
  end

  f:SetScript("OnShow", function(self) self:RefreshFavorites() end)

  -- One refresh per change, and only while the tab is visible
  CobysLinkepedia.EventBus:Register({ ReceiveEvent = function()
    if f:IsShown() then f:RefreshFavorites() end
  end }, { CobysLinkepedia.Events.FavoriteChanged, CobysLinkepedia.Events.SavedVariantsChanged })

  Search._favoritesFrame = f
end

Debug.Log("INIT", "Search favorites loaded")
