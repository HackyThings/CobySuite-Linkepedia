-- Macro tokens, editor side: stages item token changes to the macro that
-- Blizzard's macro window has selected and applies them through one secure
-- click, offers a one-click token for an item Shift-clicked into a chat line,
-- and asks the client to load every item the saved macros name so their first
-- press links.
--
-- Why a secure click. A macro cannot be changed cleanly from addon code while
-- the window shows it: EditMacro fires UPDATE_MACROS inside the call, so
-- MacroFrame's refill runs in the addon's taint and leaves textChanged, the
-- list's selected index and its data provider tainted (measured in game,
-- 2026-09-16). The next SaveMacro reads them, including from inside the panel
-- manager when the window closes. So addon code only stages a change (the new
-- body, where the cursor goes, a message), and one hardware click on the
-- apply button (an InsecureActionButtonTemplate the panel lays over whichever
-- action button the mouse is on) runs this macro, line by line:
--
--   /click MacroExitButton             Blizzard closes the window; its OnHide saves the player's typing
--   /click CobysLinkepediaMacroWrite   EditMacro with the window closed: nothing listens, nothing refills
--   /macro                             Blizzard reopens it on its own path, every field clean
--   /click MacroFrameTab2              only for a character macro
--   /click CobysLinkepediaMacroAim     aims the select delegate at the macro's button in the list
--   /click CobysLinkepediaMacroSelect  clicks that button: Blizzard's own selection
--
-- Each macro line starts a fresh execution, so our two steps cannot taint the
-- lines after them. Reopening scrolls the list to the top: a macro further
-- down than the visible buttons is saved but not reselected, and the status
-- line says so. The apply button does nothing in combat, where EditMacro is
-- refused anyway. /lp test MacroTokens covers the staging, the closed-window
-- write and (with one prompted click) the whole sequence.

local MacroTokens = CobysLinkepedia.MacroTokens
local Linkify = CobysLinkepedia.Linkify
local Database = CobysLinkepedia.Database
local Config = CobysLinkepedia.Config
local Utilities = CobysLinkepedia.Utilities
local Debug = CobysLinkepedia.Debug

local strfind, strsub, strmatch = string.find, string.sub, string.match

local MAX_MACRO_CHARS = 255
local PENDING_SECONDS = 3
local PRELOAD_DELAY = 1

local APPLY_BUTTON = "CobysLinkepediaMacroApply"
local WRITE_BUTTON = "CobysLinkepediaMacroWrite"
local AIM_BUTTON = "CobysLinkepediaMacroAim"
local SELECT_BUTTON = "CobysLinkepediaMacroSelect"

-- The change a click is applying: { index, body, cursor, message, created,
-- step = "staged" | "written" | "aimed" }
local pending = nil

local function MaxAccountMacros()
  return Constants.MacroConsts.MAX_ACCOUNT_MACROS
end

local function Status(text, ok)
  if MacroTokens.SetStatus and text then MacroTokens.SetStatus(text, ok) end
end

-------------------------------------------------------------------------------
-- The macro being edited
-------------------------------------------------------------------------------

-- The selected macro's index and the editor's text and cursor, or nil and a
-- sentence saying why no change can be made now
function MacroTokens.GetEditTarget()
  local frame = MacroFrame
  if not frame or not frame:IsShown() then
    return nil, "Open the macro window first."
  end
  if InCombatLockdown() then
    return nil, "Macros can't be changed in combat."
  end
  if MacroPopupFrame and MacroPopupFrame:IsShown() then
    return nil, "Finish the name and icon change first."
  end
  if pending then
    if GetTime() - pending.created <= PENDING_SECONDS then
      return nil, "Still saving the last change; try again."
    end
    pending = nil
  end
  local selected = frame:GetSelectedIndex()
  local index = selected and frame:GetMacroDataIndex(selected)
  if not index or not GetMacroInfo(index) then
    return nil, "Select a macro first."
  end
  return index, MacroFrameText:GetText() or "", MacroFrameText:GetCursorPosition() or 0
end

local function Change(index, body, cursor, message)
  if #body > MAX_MACRO_CHARS then
    return false, "Not enough room: a macro holds 255 characters."
  end
  return true, { index = index, body = body, cursor = cursor, message = message }
end

-------------------------------------------------------------------------------
-- Text changes, as pure functions of the editor's text and cursor (a cursor
-- is the number of characters before the caret)
-------------------------------------------------------------------------------

-- The text with tokenText at the cursor, after a space when the cursor
-- follows other text on its line, and the cursor after it
function MacroTokens.InsertAt(text, cursor, tokenText)
  local before = strsub(text, cursor, cursor)
  if cursor > 0 and before ~= "" and not strfind(before, "%s") then
    tokenText = " " .. tokenText
  end
  return strsub(text, 1, cursor) .. tokenText .. strsub(text, cursor + 1), cursor + #tokenText
end

-- The text with a token (as FindTokens returned it) replaced by replacement,
-- and the cursor kept in its place relative to the text around it; nil when
-- the token is no longer where it was. An empty replacement removes the
-- token and one space beside it, so no double space or stray leading space
-- is left behind.
function MacroTokens.ReplaceToken(text, cursor, token, replacement)
  local start, stop = token.start, token.stop
  if strsub(text, start, stop) ~= token.text then return nil end

  if replacement == "" then
    local before, after = strsub(text, start - 1, start - 1), strsub(text, stop + 1, stop + 1)
    if before == " " and (after == " " or after == "" or after == "\n") then
      start = start - 1
    elseif (before == "" or before == "\n") and after == " " then
      stop = stop + 1
    end
  end

  local body = strsub(text, 1, start - 1) .. replacement .. strsub(text, stop + 1)
  if cursor >= stop then
    cursor = cursor + #replacement - (stop - start + 1)
  elseif cursor >= start then
    cursor = start - 1 + #replacement
  end
  return body, cursor
end

-------------------------------------------------------------------------------
-- Staging. Each Stage function reads the editor and returns true and a
-- change, true and nil when there is nothing to change, or false and the
-- reason. Nothing is written until the apply click.
-------------------------------------------------------------------------------

function MacroTokens.StageInsertToken(tokenText)
  local index, text, cursor = MacroTokens.GetEditTarget()
  if not index then return false, text end
  local body, newCursor = MacroTokens.InsertAt(text, cursor, tokenText)
  return Change(index, body, newCursor, "Added " .. tokenText .. ".")
end

function MacroTokens.StageInsertItem(itemID)
  if not itemID then return true, nil end
  return MacroTokens.StageInsertToken(Linkify.FormatToken(itemID))
end

function MacroTokens.StageInsertVariant(id)
  if not id then return true, nil end
  return MacroTokens.StageInsertToken(Linkify.FormatVariantToken(id))
end

-- A token (as FindTokens returned it from the editor's text) replaced
local function StageReplace(token, replacement, message)
  local index, text, cursor = MacroTokens.GetEditTarget()
  if not index then return false, text end
  local body, newCursor = MacroTokens.ReplaceToken(text, cursor, token, replacement)
  if not body then return false, "The macro changed; try again." end
  return Change(index, body, newCursor, message)
end

-- An n= token as the exact i= token for the item it links today, keeping its
-- qualifiers
function MacroTokens.StagePin(token)
  if not token then return true, nil end
  local itemID = Linkify.ResolveTokenItem(token)
  if not itemID then
    return false, "Nothing matches " .. token.text .. "."
  end
  local pinned = Linkify.FormatToken(itemID, token.rank, token.ilvl)
  return StageReplace(token, pinned, "Pinned as " .. pinned .. ".")
end

function MacroTokens.StageRemove(token)
  if not token then return true, nil end
  return StageReplace(token, "", "Removed " .. token.text .. ".")
end

-- The token text typed input stands for: a whole token as typed, an item id
-- (with qualifiers) as ${i=...}, anything else as ${n=...}. "" for empty
-- input, nil when it cannot be a token.
function MacroTokens.NormalizeTokenInput(input)
  local text = strtrim(input or "")
  if text == "" then return "" end
  for _, candidate in ipairs({ text, "${i=" .. text .. "}", "${n=" .. text .. "}" }) do
    local tokens = Linkify.FindTokens(candidate)
    if #tokens == 1 and tokens[1].start == 1 and tokens[1].stop == #candidate then
      return candidate
    end
  end
  return nil
end

-- A token replaced with what the player typed in its place; clearing it
-- removes the token
function MacroTokens.StageEdit(token, input)
  if not token then return true, nil end
  local replacement = MacroTokens.NormalizeTokenInput(input)
  if not replacement then
    return false, "Not a token: type ${i=ID}, ${n=name}, ${v=N}, an item ID or a name."
  end
  if replacement == "" then return MacroTokens.StageRemove(token) end
  if replacement == token.text then return true, nil end
  return StageReplace(token, replacement, "Changed to " .. replacement .. ".")
end

-------------------------------------------------------------------------------
-- Applying
-------------------------------------------------------------------------------
-- The apply macro for a change to macro index
function MacroTokens.ApplyMacroText(index)
  local click = SLASH_CLICK1 or "/click"
  local lines = {
    click .. " MacroExitButton",
    click .. " " .. WRITE_BUTTON,
    SLASH_MACRO1 or "/macro",
  }
  if index > MaxAccountMacros() then
    lines[#lines + 1] = click .. " MacroFrameTab2"
  end
  lines[#lines + 1] = click .. " " .. AIM_BUTTON
  lines[#lines + 1] = click .. " " .. SELECT_BUTTON
  return table.concat(lines, "\n")
end

-- Saves body into macro index while the macro window is closed, so no refill
-- runs in this call. Returns whether it wrote.
function MacroTokens.WriteClosed(index, body)
  if InCombatLockdown() or (MacroFrame and MacroFrame:IsShown()) then return false end
  EditMacro(index, nil, nil, body)
  return true
end

-- The write step of the apply macro
local function WritePending()
  local change = pending
  if not change or change.step ~= "staged" then return end
  if not MacroTokens.WriteClosed(change.index, change.body) then
    -- The window did not close; writing now would refill it in our taint
    pending = nil
    Status("The macro window did not close, so nothing was changed.", false)
    return
  end
  change.step = "written"
  Debug.Log("UI", "Macro %d saved with the window closed", change.index)
end

-- The aim step: point the select delegate at the macro's list button, which
-- exists only while it is in view
local selectDelegate
local function AimPending()
  selectDelegate:SetAttribute("clickbutton", nil)
  local change = pending
  if not change or change.step ~= "written" then return end
  if not MacroFrame or not MacroFrame:IsShown() then
    pending = nil
    Status(change.message .. " Open the macro window to see it.", true)
    return
  end

  local selection = change.index
  if selection > MaxAccountMacros() then selection = selection - MaxAccountMacros() end
  for button in MacroFrame.MacroSelector:EnumerateButtons() do
    if button.selectionIndex == selection and button:IsVisible() then
      selectDelegate:SetAttribute("clickbutton", button)
      change.step = "aimed"
      return
    end
  end
  pending = nil
  Status(change.message .. " Select the macro again to keep editing.", true)
end

-- The secure buttons the apply macro clicks. Created once at load: /click
-- resolves a name to the first frame registered under it.
local applyButton = CreateFrame("Button", APPLY_BUTTON, UIParent, "InsecureActionButtonTemplate")
applyButton:RegisterForClicks("LeftButtonUp")
applyButton:SetAttribute("useOnKeyDown", false)
applyButton:Hide()

local writeButton = CreateFrame("Button", WRITE_BUTTON, UIParent)
writeButton:SetScript("OnClick", WritePending)

local aimButton = CreateFrame("Button", AIM_BUTTON, UIParent)
aimButton:SetScript("OnClick", AimPending)

selectDelegate = CreateFrame("Button", SELECT_BUTTON, UIParent, "InsecureActionButtonTemplate")
selectDelegate:SetSize(1, 1)
selectDelegate:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
selectDelegate:SetAlpha(0)
selectDelegate:RegisterForClicks("LeftButtonUp")
selectDelegate:SetAttribute("useOnKeyDown", false)
selectDelegate:SetAttribute("type", "click")

-- PreClick stages the hovered button's change and arms the macro; a refused
-- change leaves the button without an action, so the click does nothing
applyButton:SetScript("PreClick", function(self)
  self:SetAttribute("type", nil)
  local target = self.target
  local stage = target and target._secureStage
  if not stage then return end
  local ok, change = stage(target)
  if not ok then
    Status(change, false)
    return
  end
  if not change then return end
  change.step, change.created = "staged", GetTime()
  pending = change
  self:SetAttribute("macrotext", MacroTokens.ApplyMacroText(change.index))
  self:SetAttribute("type", "macro")
  Status(change.message, true)
end)

-- Mouse feedback and tooltips pass through to the button underneath
local function Forward(script)
  return function(self, ...)
    local target = self.target
    local handler = target and target:GetScript(script)
    if handler then handler(target, ...) end
  end
end
applyButton:SetScript("OnEnter", Forward("OnEnter"))
applyButton:SetScript("OnLeave", function(self, ...)
  local target = self.target
  if target then
    local handler = target:GetScript("OnLeave")
    if handler then handler(target, ...) end
    if target.UnlockHighlight then target:UnlockHighlight() end
    if target.SetButtonState then target:SetButtonState("NORMAL") end
  end
  self.target = nil
  self:Hide()
end)
applyButton:SetScript("OnMouseDown", function(self)
  local target = self.target
  if target and target.SetButtonState then target:SetButtonState("PUSHED") end
end)
applyButton:SetScript("OnMouseUp", function(self)
  local target = self.target
  if target and target.SetButtonState then target:SetButtonState("NORMAL") end
end)

-- Makes button a secure apply button: while the mouse is on it the apply
-- button lies over it, and a click stages stage(button)'s change and applies
-- it. stage returns what a Stage function returns.
function MacroTokens.AttachSecureApply(button, stage)
  button._secureStage = stage
  button:HookScript("OnEnter", function(self)
    if applyButton.target == self and applyButton:IsShown() then return end
    applyButton.target = self
    applyButton:SetParent(self)
    applyButton:ClearAllPoints()
    applyButton:SetAllPoints(self)
    applyButton:SetFrameLevel(self:GetFrameLevel() + 10)
    applyButton:Show()
    if self.LockHighlight then self:LockHighlight() end
  end)
end

-------------------------------------------------------------------------------
-- Shift-click into a chat line
-------------------------------------------------------------------------------

-- True when a macro line sends chat: not a #showtooltip-style directive and
-- not a secure or script command
function MacroTokens.IsChatLine(line)
  local trimmed = strtrim(line or "")
  if strsub(trimmed, 1, 1) == "#" then return false end
  return not Linkify.IsExcludedCommand(trimmed)
end

-- Where the text just inserted before the cursor starts, when it is there and
-- on a chat line; nil otherwise
function MacroTokens.FindInsertedName(text, cursor, inserted)
  if type(text) ~= "string" or type(inserted) ~= "string" or inserted == "" then return nil end
  local start = cursor - #inserted + 1
  if start < 1 or strsub(text, start, cursor) ~= inserted then return nil end
  local lineStart = 1
  local pos = strfind(text, "\n", 1, true)
  while pos and pos < start do
    lineStart = pos + 1
    pos = strfind(text, "\n", pos + 1, true)
  end
  local lineEnd = (pos or #text + 1) - 1
  if not MacroTokens.IsChatLine(strsub(text, lineStart, lineEnd)) then return nil end
  return start
end

-- The crafted rank a link carries, when a captured variant of the item has
-- that rank (reagent ranks are separate item ids and need no qualifier)
local function LinkRank(link, itemID)
  if not C_TradeSkillUI then return nil end
  local ok, quality = pcall(C_TradeSkillUI.GetItemCraftedQualityByItemInfo, link)
  if not ok or type(quality) ~= "number" then
    ok, quality = pcall(C_TradeSkillUI.GetItemReagentQualityByItemInfo, link)
  end
  if not ok or type(quality) ~= "number" or (issecretvalue and issecretvalue(quality)) then return nil end
  if quality > 0 and Database.MatchVariant(itemID, quality, nil) then return quality end
  return nil
end

-- A suggestion stays good while the inserted name is still where it was. A
-- variant suggestion saves its link first (or finds it saved) and uses that
-- saved variant's token.
function MacroTokens.StageSuggestion(suggestion)
  if not suggestion then return true, nil end
  local index, text, cursor = MacroTokens.GetEditTarget()
  if not index then return false, text end
  local span = { start = suggestion.start, stop = suggestion.stop, text = suggestion.inserted }
  if index ~= suggestion.index or strsub(text, span.start, span.stop) ~= span.text then
    return false, "The macro changed since that Shift-click."
  end
  local token = suggestion.token
  local body, newCursor = MacroTokens.ReplaceToken(text, cursor, span, token)
  if suggestion.variantLink then
    -- The offer's token carries the number the variant has or will get, so a
    -- macro with no room refuses before anything is saved
    local ok, reason = Change(index, body, newCursor, "")
    if not ok then return false, reason end
    local id
    id, reason = CobysLinkepedia.Variants.Save(suggestion.variantLink, { source = "captured" })
    if not id then return false, reason end
    token = Linkify.FormatVariantToken(id)
    body, newCursor = MacroTokens.ReplaceToken(text, cursor, span, token)
  end
  return Change(index, body, newCursor, "Replaced " .. suggestion.inserted .. " with " .. token .. ".")
end

-- ChatFrameUtil.InsertLink post-hook. With the macro editor focused,
-- Blizzard has just inserted the item's name at the cursor (or "/use Name" on
-- an empty line, which is left alone). On a chat line the panel offers the
-- item's token in its place; nothing changes until that is clicked. Crafted
-- gear with a quality and gear on an upgrade track get a saved-variant token
-- (${v=N}, saved when the offer is taken), since only the exact link names
-- that one variant; everything else gets ${i=ID}, with ~R<n> for a reagent
-- rank a captured variant has.
local function OnInsertLink(link)
  if not MacroFrameText or not MacroFrameText:HasFocus() then return end
  if type(link) ~= "string" or not strfind(link, "item:", 1, true) then return end
  if not Config.Get(Config.Options.EXPAND_ITEM_TOKENS) then return end

  local itemID = tonumber(strmatch(link, "item:(%d+)"))
  local index, text, cursor = MacroTokens.GetEditTarget()
  if not itemID or not index then return end

  local inserted = C_Item.GetItemInfo(link) or link
  local start = MacroTokens.FindInsertedName(text, cursor, inserted)
  if not start then return end

  if not MacroTokens.OnSuggestion then return end
  local offer = { index = index, start = start, stop = cursor, inserted = inserted }
  local Variants = CobysLinkepedia.Variants
  local info = Variants.ReadLinkInfo(link)
  if info and (info.kind == "crafted" or info.kind == "track") and Variants.IsGear(itemID) then
    local saved = Variants.FindByLink(link)
    offer.variantLink = link
    offer.newVariant = saved == nil
    offer.token = Linkify.FormatVariantToken(saved and saved.id or Variants.PeekNextID())
  else
    offer.token = Linkify.FormatToken(itemID, LinkRank(link, itemID))
  end
  MacroTokens.OnSuggestion(offer)
end

-------------------------------------------------------------------------------
-- Blizzard's macro window
-------------------------------------------------------------------------------

local function IsSelected(index)
  local selected = MacroFrame:GetSelectedIndex()
  return selected ~= nil and MacroFrame:GetMacroDataIndex(selected) == index
end

-- SelectMacro post-hook: once the apply macro has reselected the changed
-- macro, the change is done and the cursor goes back; then the panel reads
-- the new text. The reselecting click selects the macro up to three times
-- (its save refills the window and reselects), and each one puts the text
-- back, so the cursor is placed once the click is over.
local function OnSelectMacro(frame)
  local change = pending
  if change and change.step == "aimed" and IsSelected(change.index) then
    pending = nil
    Status(change.message, true)
    C_Timer.After(0, function()
      if not frame:IsShown() or not IsSelected(change.index) then return end
      MacroFrameText:SetCursorPosition(math.min(change.cursor, #(MacroFrameText:GetText() or "")))
    end)
  end
  if MacroTokens.OnMacroChanged then MacroTokens.OnMacroChanged() end
end

local function OnMacroUILoaded()
  hooksecurefunc(MacroFrame, "SelectMacro", OnSelectMacro)
  if MacroTokens.AttachPanel then MacroTokens.AttachPanel() end
  Debug.Log("INIT", "Macro window hooked for item tokens")
end

-------------------------------------------------------------------------------
-- Preloading the items saved macros name
-------------------------------------------------------------------------------
function MacroTokens.PreloadMacroItems()
  local numAccount, numCharacter = GetNumMacros()
  local characterBase = MaxAccountMacros()
  local requested = {}

  local function Scan(index)
    local body = GetMacroBody(index)
    if not body or not strfind(body, "${", 1, true) then return end
    for _, token in ipairs(Linkify.FindTokens(body)) do
      local itemID = Linkify.ResolveTokenItem(token)
      if itemID and not requested[itemID] then
        requested[itemID] = true
        C_Item.RequestLoadItemDataByID(itemID)
      end
    end
  end

  for i = 1, numAccount do Scan(i) end
  for i = characterBase + 1, characterBase + numCharacter do Scan(i) end
  Debug.Log("UI", "Requested %d item(s) named by macro tokens", Utilities.TableCount(requested))
end

-------------------------------------------------------------------------------
-- Setup (PLAYER_LOGIN)
-------------------------------------------------------------------------------
local preload = Utilities.Debounce(PRELOAD_DELAY, function() MacroTokens.PreloadMacroItems() end)
local macroWatcher = CreateFrame("Frame")
macroWatcher:SetScript("OnEvent", function() preload:Call() end)

function MacroTokens.Initialize()
  if MacroTokens._initialized then return end
  MacroTokens._initialized = true

  hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsertLink)

  macroWatcher:RegisterEvent("UPDATE_MACROS")
  preload:Call()

  if MacroTokens.EnsurePanel then MacroTokens.EnsurePanel() end
  EventUtil.ContinueOnAddOnLoaded("Blizzard_MacroUI", OnMacroUILoaded)
end

-- For the MacroTokens suite: whether a change is still being applied
function MacroTokens.IsApplying()
  return pending ~= nil
end

Debug.Log("INIT", "Macro tokens editor loaded")
