-- Autocomplete Dropdown: visual popup anchored to chat edit boxes
-- Shows matching items with icons, quality-colored names, and a count of captured variants

local Autocomplete = CobysLinkepedia.Autocomplete
local Utilities = CobysLinkepedia.Utilities
local Database = CobysLinkepedia.Database
local Debug = CobysLinkepedia.Debug

local ROW_HEIGHT = 22
local ICON_SIZE = 18
local MAX_VISIBLE_ROWS = 10

-- Dropdown frame and rows
local dropdown = nil
local rows = {}
local currentResults = {}
local selectedIndex = 0
local displayedRevision = nil   -- the session revision the rows were built for
local keepSessionOnHide = false

-- Forward declaration
local UpdateSelectionVisuals

-------------------------------------------------------------------------------
-- Row creation
-------------------------------------------------------------------------------
local function CreateRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(ROW_HEIGHT)
  row:SetPoint("TOPLEFT", 4, -(index - 1) * ROW_HEIGHT - 4)
  row:SetPoint("TOPRIGHT", -4, -(index - 1) * ROW_HEIGHT - 4)

  -- Highlight texture
  row.Highlight = CobySuite_CobysLinkepedia.UI.AddHoverHighlight(row, { 1, 1, 1, 0.1 })

  -- Selection texture
  row.Selection = row:CreateTexture(nil, "BACKGROUND")
  row.Selection:SetAllPoints()
  row.Selection:SetColorTexture(0.3, 0.6, 1, 0.2)
  row.Selection:Hide()

  -- Icon
  row.Icon = row:CreateTexture(nil, "ARTWORK")
  row.Icon:SetSize(ICON_SIZE, ICON_SIZE)
  row.Icon:SetPoint("LEFT", 4, 0)

  -- Variant count, right-aligned; empty for an item with none
  row.VariantText = row:CreateFontString(nil, "OVERLAY", Utilities.Fonts.SMALL)
  row.VariantText:SetPoint("RIGHT", -6, 0)
  row.VariantText:SetTextColor(unpack(Utilities.Colors.LABEL_GRAY))

  -- Item name
  row.Name = row:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  row.Name:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)
  row.Name:SetPoint("RIGHT", row.VariantText, "LEFT", -6, 0)
  row.Name:SetJustifyH("LEFT")

  -- Substring indicator (dimmed)
  row.SubstringDivider = row:CreateTexture(nil, "ARTWORK")
  row.SubstringDivider:SetHeight(1)
  row.SubstringDivider:SetPoint("TOPLEFT", 0, 0)
  row.SubstringDivider:SetPoint("TOPRIGHT", 0, 0)
  row.SubstringDivider:SetColorTexture(0.4, 0.4, 0.4, 0.3)
  row.SubstringDivider:Hide()

  -- Click handler
  row:SetScript("OnClick", function()
    if row.itemData then
      Autocomplete.SelectItem(row.itemData, displayedRevision)
    end
  end)

  -- Tooltip on hover (also drives selection visual via the ID resolver)
  CobySuite_CobysLinkepedia.UI.AddItemTooltip(row, function(self)
    if not self.itemData then return nil end
    selectedIndex = index
    UpdateSelectionVisuals()
    return self.itemData.itemID
  end, "ANCHOR_RIGHT", CobysLinkepedia.Search.ItemTooltipOptions)

  return row
end

-------------------------------------------------------------------------------
-- Selection visuals
-------------------------------------------------------------------------------
UpdateSelectionVisuals = function()
  for i, row in ipairs(rows) do
    if row.Selection then
      row.Selection:SetShown(i == selectedIndex)
    end
  end
end

-- The chat boxes a click in does not close the list: the numbered chat
-- windows' boxes, then each pop-out window's as Main.lua hooks it (the
-- click-outside helper reads this table on every click)
local dropdownOwners = {}

function Autocomplete.AddDropdownOwner(editBox)
  if not editBox then return end
  for _, owner in ipairs(dropdownOwners) do
    if owner == editBox then return end
  end
  dropdownOwners[#dropdownOwners + 1] = editBox
end

-- Keyboard navigation shows the highlighted row's tooltip by running the
-- row's own hover script, so it has the same options (Shift comparison) as
-- hovering does
local function ShowSelectionTooltip()
  local row = rows[selectedIndex]
  if not (row and row:IsShown() and row.itemData) then return end
  local onEnter = row:GetScript("OnEnter")
  if onEnter then onEnter(row, false) end
end

-------------------------------------------------------------------------------
-- Dropdown frame creation (lazy)
-------------------------------------------------------------------------------
local function GetOrCreateDropdown()
  if dropdown then return dropdown end
  -- No frames in combat. EnsureDropdown builds this at
  -- login, so this guard only matters after a /reload during a fight.
  if InCombatLockdown() then return nil end

  dropdown = CreateFrame("Frame", "CobysLinkepediaAutocompleteDropdown", UIParent, "BackdropTemplate")
  dropdown:SetBackdrop(Utilities.Backdrops.MENU)
  local wbg = Utilities.Colors.WINDOW_BG
  dropdown:SetBackdropColor(wbg[1], wbg[2], wbg[3], wbg[4])
  -- The backdrop's texture is see-through by itself, and the list sits over
  -- chat text: a solid layer inside the border keeps the names readable
  local solid = dropdown:CreateTexture(nil, "BACKGROUND", nil, -8)
  solid:SetPoint("TOPLEFT", 4, -4)
  solid:SetPoint("BOTTOMRIGHT", -4, 4)
  solid:SetColorTexture(wbg[1], wbg[2], wbg[3], 1)
  -- Layering: the chat edit box's own strata (DIALOG) at a frame level below
  -- the box's (chat frame level + 1). Keyboard events visit frames in
  -- layering order, so the focused chat box always sees a key before this
  -- frame does and the list only ever receives what the box lets through.
  -- Not toplevel for the same reason: a click must not raise it above the box.
  dropdown:SetFrameStrata("DIALOG")
  dropdown:SetFrameLevel(0)
  dropdown:SetClampedToScreen(true)
  dropdown:EnableMouse(true)
  dropdown:Hide()

  -- Arrow keys. The chat box ignores plain arrows by template (ignoreArrows)
  -- and lets them fall through to the key bindings, which is why Up and Down
  -- turned the character while the list was open. A visible keyboard-enabled
  -- frame that does not propagate keeps keys from the bindings, so while the
  -- list is open the arrows navigate it instead. The flag is set once, here,
  -- out of combat: SetPropagateKeyboardInput is protected in combat, and it
  -- is never touched again. Hidden, the frame has no effect on anything.
  dropdown:EnableKeyboard(true)
  dropdown:SetPropagateKeyboardInput(false)
  dropdown:SetScript("OnKeyDown", function(_, key)
    if key == "UP" or key == "DOWN" then
      Autocomplete.NavigateKey(key)
    elseif key == "ESCAPE" then
      Autocomplete.Cancel()
    else
      local editBox = Autocomplete.GetActiveEditBox()
      if not (editBox and editBox:HasFocus()) then
        -- No chat box has focus (a press on the list's background took it),
        -- so this frame is swallowing every key. Close the list; the next
        -- press reaches the bindings again.
        Autocomplete.Cancel()
      end
    end
  end)

  -- A press on the list's background takes focus from the chat box; hand it
  -- back on release so typing carries on where it was.
  dropdown:SetScript("OnMouseUp", function()
    local editBox = Autocomplete.GetActiveEditBox()
    if editBox and not editBox:HasFocus() then
      editBox:SetFocus()
    end
  end)

  -- Create row pool
  for i = 1, MAX_VISIBLE_ROWS do
    rows[i] = CreateRow(dropdown, i)
  end

  -- The list owns its visibility. A click anywhere outside it and outside
  -- the chat boxes hides it (the shared helper, the way Blizzard menus
  -- close), and hiding it for any reason ends the autocomplete session, so
  -- no session outlives a list the player can no longer see.
  for i = 1, Constants.ChatFrameConstants.MaxChatWindows do
    Autocomplete.AddDropdownOwner(_G["ChatFrame" .. i .. "EditBox"])
  end
  CobySuite_CobysLinkepedia.UI.HideOnClickOutside(dropdown, { owners = dropdownOwners })
  dropdown:SetScript("OnHide", function()
    local owner = GameTooltip:GetOwner()
    if owner and owner:GetParent() == dropdown then GameTooltip:Hide() end
    if not keepSessionOnHide then Autocomplete.Cancel() end
  end)

  return dropdown
end

-- Built at login so the frame, and its keyboard flag, exist before the first
-- search. A /reload in combat waits for the lockdown to lift.
function Autocomplete.EnsureDropdown()
  if dropdown then return end
  if InCombatLockdown() then
    EventUtil.RegisterOnceFrameEventAndCallback("PLAYER_REGEN_ENABLED", function()
      GetOrCreateDropdown()
    end)
    return
  end
  GetOrCreateDropdown()
end

-- Up or Down from either source. The chat box's key hook and this frame's
-- OnKeyDown can both see the same press (the box ignores plain arrows, so the
-- key falls through to the list), and both run within one frame: the second
-- call for the same key in the same frame is dropped.
local lastNavKey, lastNavTime = nil, nil

function Autocomplete.NavigateKey(key)
  if not (dropdown and dropdown:IsShown()) then return end
  local now = GetTime()
  if lastNavKey == key and lastNavTime == now then return end
  lastNavKey, lastNavTime = key, now
  if key == "UP" then
    Autocomplete.NavigateUp()
  else
    Autocomplete.NavigateDown()
  end
end

-------------------------------------------------------------------------------
-- Public API: called by Autocomplete/Main.lua
-------------------------------------------------------------------------------
function Autocomplete.ShowDropdown(editBox, results, revision)
  if not editBox or not results or #results == 0 then
    Autocomplete.HideDropdown(true)
    return
  end

  local dd = GetOrCreateDropdown()
  if not dd then return end   -- not yet built (reload in combat)
  currentResults = results
  selectedIndex = 0
  displayedRevision = revision

  local numRows = math.min(#results, MAX_VISIBLE_ROWS)
  local ddHeight = numRows * ROW_HEIGHT + 8
  local ddWidth = math.max(editBox:GetWidth(), 250)

  dd:SetSize(ddWidth, ddHeight)

  -- Anchor below the edit box, flip above if near screen bottom
  dd:ClearAllPoints()
  local editBoxBottom = editBox:GetBottom()
  if editBoxBottom and editBoxBottom < ddHeight + 20 then
    dd:SetPoint("BOTTOMLEFT", editBox, "TOPLEFT", 0, 2)
  else
    dd:SetPoint("TOPLEFT", editBox, "BOTTOMLEFT", 0, -2)
  end

  -- Track first substring result for divider
  local firstSubstringIdx = nil

  -- Populate rows
  for i = 1, MAX_VISIBLE_ROWS do
    local row = rows[i]
    if i <= #results then
      local item = results[i]
      row.itemData = item

      -- Icon from the client's instant item data (records keep no icon)
      local icon = select(5, C_Item.GetItemInfoInstant(item.itemID))
      row.Icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
      row.Icon:Show()

      -- Name colored by quality
      local qualityColor = ITEM_QUALITY_COLORS[item.quality or 1]
      row.Name:SetText(item.name)
      if qualityColor then
        row.Name:SetTextColor(qualityColor.r, qualityColor.g, qualityColor.b)
      end

      -- A plain count of captured variants. The row stands for the base
      -- item: its tooltip and the link a selection inserts are the base
      -- item's, so no rank is shown for it.
      local variantCount = Database.GetVariantCount(item.itemID)
      if variantCount > 0 then
        row.VariantText:SetText(variantCount == 1 and "1 variant" or (variantCount .. " variants"))
      else
        row.VariantText:SetText("")
      end

      -- Substring divider
      if item.isSubstring and not firstSubstringIdx then
        firstSubstringIdx = i
        row.SubstringDivider:Show()
      else
        row.SubstringDivider:Hide()
      end

      row.Selection:Hide()
      row:Show()
    else
      row:Hide()
      row.itemData = nil
    end
  end

  dd:Show()
end

-- keepSession: the session carries on and only its rows were out of date.
-- Any other hide (Escape, a click outside, Cancel) ends the session.
function Autocomplete.HideDropdown(keepSession)
  currentResults = {}
  selectedIndex = 0
  displayedRevision = nil
  if dropdown and dropdown:IsShown() then
    keepSessionOnHide = keepSession and true or false
    dropdown:Hide()
    keepSessionOnHide = false
  end
end

-- The session revision the rows on screen were built for; nil while hidden
function Autocomplete.GetDisplayedRevision()
  if dropdown and dropdown:IsShown() then return displayedRevision end
  return nil
end

function Autocomplete.IsDropdownShown()
  return dropdown and dropdown:IsShown()
end

function Autocomplete.NavigateDown()
  if not currentResults or #currentResults == 0 then return end
  selectedIndex = selectedIndex + 1
  if selectedIndex > math.min(#currentResults, MAX_VISIBLE_ROWS) then
    selectedIndex = 1
  end
  UpdateSelectionVisuals()
  ShowSelectionTooltip()
end

function Autocomplete.NavigateUp()
  if not currentResults or #currentResults == 0 then return end
  selectedIndex = selectedIndex - 1
  if selectedIndex < 1 then
    selectedIndex = math.min(#currentResults, MAX_VISIBLE_ROWS)
  end
  UpdateSelectionVisuals()
  ShowSelectionTooltip()
end

-- Inserts the highlighted row. With fallbackToFirst (Tab with nothing
-- highlighted yet) the first row is taken, as tab completion does elsewhere.
function Autocomplete.SelectCurrent(fallbackToFirst)
  local index = selectedIndex
  if index < 1 and fallbackToFirst and #currentResults > 0 then
    index = 1
  end
  if index > 0 and index <= #currentResults then
    Autocomplete.SelectItem(currentResults[index], displayedRevision)
  end
end

function Autocomplete.GetSelectedIndex()
  return selectedIndex
end

-- True while the list is open with the cursor over it: the chat box loses
-- focus on the mouse-down of a row click, and Main.lua keeps the session
-- alive through that loss only in this case.
function Autocomplete.IsDropdownUnderMouse()
  return dropdown ~= nil and dropdown:IsShown() and dropdown:IsMouseOver()
end

Debug.Log("INIT", "Autocomplete dropdown loaded")
