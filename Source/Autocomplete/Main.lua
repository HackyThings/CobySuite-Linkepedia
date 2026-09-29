-- Autocomplete: item suggestions while typing [ in a chat edit box
--
-- A session starts when the text before the caret has an open bracket with
-- at least one character typed after it ("Buying [He" with the caret after
-- the e). It holds the edit box, the bracket's byte position, the caret, the
-- query (bracket to caret) and a text revision, plus the generation it
-- belongs to; Cancel bumps the generation. Every delayed step (the debounced
-- search, the item load a selection starts) carries the generation and
-- revision it was started for and does nothing once either has moved, so an
-- old result never lands in a newer draft. The rows on screen belong to one
-- revision and are hidden as soon as the text or the caret moves. A link
-- replaces exactly the bracket-to-caret span; the text after the caret is
-- kept.
--
-- Keys while the list is open:
--   Tab      inserts the highlighted row (the first when none is), through
--            ChatEdit_CustomTabPressed, Blizzard's hook for addon tab
--            completion. Linkepedia goes first while the list is open, so
--            Tab never cycles the whisper target then; with the list closed
--            the previous hook runs as it did before.
--   Up/Down  move the highlight (the dropdown frame keeps them away from the
--            movement bindings, Dropdown.lua).
--   Enter    stays Blizzard's: it sends the message as typed, never inserts.
--   Escape   closes the list; Blizzard's handler clears the draft on the
--            same key, as it always has.
-- A click outside the list and the chat boxes closes it as well. Programmatic
-- text changes, turning the option off, focus loss and a bare "[" all end
-- the session.

local Autocomplete = CobysLinkepedia.Autocomplete
local Config = CobysLinkepedia.Config
local Database = CobysLinkepedia.Database
local Utilities = CobysLinkepedia.Utilities
local Debug = CobysLinkepedia.Debug
local strbyte, strsub = string.byte, string.sub

local BYTE_OPEN, BYTE_CLOSE = 91, 93   -- "[" and "]"
local LOAD_TIMEOUT = 3

local session = nil       -- { generation, editBox, triggerStart, cursor, query, revision }
local generation = 0
local cancelLoad = nil    -- cancels the item load a selection started
local cancelSearch = nil  -- cancels the search the debounced call started
local cancelling = false
local hookedEditBoxes = {}

local function Enabled()
  return Config.Get(Config.Options.AUTOCOMPLETE_ENABLED) ~= false
end

-- Debounced search; the delay is a config option, re-read per change
local searchDebounce = CobySuite_CobysLinkepedia.Utilities.Debounce(0.25, function(gen, revision)
  Autocomplete.DoSearch(gen, revision)
end)

local function StopLoad()
  if cancelLoad then
    local cancel = cancelLoad
    cancelLoad = nil
    cancel()
  end
end

local function StopSearch()
  if cancelSearch then
    local cancel = cancelSearch
    cancelSearch = nil
    cancel()
  end
end

-------------------------------------------------------------------------------
-- Draft parsing (the Autocomplete suite checks these directly)
-------------------------------------------------------------------------------

-- The open bracket the caret is completing: its byte position and the query
-- between it and the caret, or nil. cursor is the edit box's caret position,
-- the number of bytes before the caret. The scan runs back from the caret and
-- stops at a closing bracket; a bracket that opens a hyperlink's text (right
-- after |h) is not a trigger. Neither bracket byte occurs inside a multi-byte
-- UTF-8 sequence, so the byte compares are safe on any text.
function Autocomplete.FindTrigger(text, cursor)
  if type(text) ~= "string" then return nil end
  cursor = math.min(cursor or #text, #text)
  for i = cursor, 1, -1 do
    local b = strbyte(text, i)
    if b == BYTE_CLOSE then return nil end
    if b == BYTE_OPEN then
      if i >= 3 and strsub(text, i - 2, i - 1) == "|h" then return nil end
      return i, strsub(text, i + 1, cursor)
    end
  end
  return nil
end

-- The text with the span from triggerStart through cursor replaced by link,
-- and the caret position just after the link. Everything after the caret is
-- kept, except a "]" right at the caret, which closed this bracket.
function Autocomplete.ReplaceSpan(text, triggerStart, cursor, link)
  local before = strsub(text, 1, triggerStart - 1)
  local after = strsub(text, cursor + 1)
  if strsub(after, 1, 1) == "]" then after = strsub(after, 2) end
  return before .. link .. after, #before + #link
end

-------------------------------------------------------------------------------
-- Session
-------------------------------------------------------------------------------
function Autocomplete.Cancel()
  if cancelling then return end
  cancelling = true
  generation = generation + 1
  session = nil
  searchDebounce:Cancel()
  StopSearch()
  StopLoad()
  Autocomplete.HideDropdown()
  cancelling = false
end

-- True for a draft that never gets suggestions: a secure or script command,
-- the same guard Linkify applies at send (Linkify loads after this file, so
-- it is looked up per call)
function Autocomplete.IsExcludedText(text)
  return CobysLinkepedia.Linkify.IsExcludedCommand(text)
end

-- Re-reads the draft after its text or caret moved, and updates, starts or
-- ends the session to match
local function Evaluate(editBox)
  if not Enabled() then
    if session then Autocomplete.Cancel() end
    return
  end

  local text = editBox:GetText()
  if not text or text == "" or Autocomplete.IsExcludedText(text) then
    if session then Autocomplete.Cancel() end
    return
  end

  local cursor = editBox:GetCursorPosition()
  local triggerStart, query = Autocomplete.FindTrigger(text, cursor)
  if not triggerStart or query == "" then
    -- No open bracket before the caret, or a bare "[" with nothing after it
    if session then Autocomplete.Cancel() end
    return
  end

  local s = session
  if s and s.editBox == editBox and s.triggerStart == triggerStart and s.cursor == cursor and s.query == query then
    return   -- nothing moved (the caret event that follows a keystroke)
  end

  if not s or s.editBox ~= editBox or s.triggerStart ~= triggerStart then
    if s then Autocomplete.Cancel() end
    s = { generation = generation, editBox = editBox, triggerStart = triggerStart, revision = 0 }
    session = s
  end
  s.cursor = cursor
  s.query = query
  s.revision = s.revision + 1

  -- The rows on screen, any load a click on them started and a search still
  -- running answered the previous revision
  StopSearch()
  StopLoad()
  Autocomplete.HideDropdown(true)

  searchDebounce:SetDelay(Config.Get(Config.Options.AUTOCOMPLETE_DELAY) or 0.25)
  searchDebounce:Call(s.generation, s.revision)
end

-- Whether the empty-database line went out this session (it goes once)
local nudged = false

-- With an empty item database autocomplete has nothing to suggest. The first
-- try in a session says why, in chat at the "always" level, and later tries
-- stay quiet. An index a combat script limit cut off is not an empty
-- database (Database.IsIndexComplete), so nothing is said then. sink(text,
-- level) prints, Utilities.Message by default (the Autocomplete suite passes
-- its own). Returns true when the database is empty, so the caller shows no
-- list.
function Autocomplete.NudgeIfEmpty(sink)
  if Database.GetCount() > 0 or not Database.IsIndexComplete() then return false end
  if not nudged then
    nudged = true
    local Scanner = CobysLinkepedia.Scanner
    local scanning = Scanner and Scanner.GetStatus and Scanner.GetStatus().isActive
    local text = scanning
      and "The item database is still being built; suggestions appear as items are stored."
      or "No item database yet, so autocomplete has nothing to suggest. Run /lp build to create it."
    local say = sink or Utilities.Message
    say(text, "always")
  end
  return true
end

-- For the Autocomplete suite: sets whether the line went out this session
-- and returns what it was
function Autocomplete.SetNudged(value)
  local was = nudged
  nudged = value and true or false
  return was
end

function Autocomplete.DoSearch(gen, revision)
  local s = session
  if not s or s.generation ~= gen or s.revision ~= revision then return end
  if not Enabled() then
    Autocomplete.Cancel()
    return
  end

  -- The draft can change without an event this module saw
  local editBox = s.editBox
  local triggerStart, query = Autocomplete.FindTrigger(editBox:GetText() or "", editBox:GetCursorPosition())
  if triggerStart ~= s.triggerStart or query ~= s.query then return end

  if Autocomplete.NudgeIfEmpty() then
    Autocomplete.HideDropdown(true)
    return
  end

  -- The search runs over frames (a short one ends in this one); its rows go
  -- up only if the session, revision and draft still match when it ends
  local maxResults = Config.Get(Config.Options.MAX_DROPDOWN_RESULTS) or 10
  StopSearch()
  local finished = false
  local cancel = Database.SearchAsync(s.query, maxResults, nil, function(results)
    finished = true
    cancelSearch = nil
    if session ~= s or s.generation ~= gen or s.revision ~= revision then return end
    local nowStart, nowQuery = Autocomplete.FindTrigger(editBox:GetText() or "", editBox:GetCursorPosition())
    if nowStart ~= s.triggerStart or nowQuery ~= s.query then return end
    if #results == 0 then
      Autocomplete.HideDropdown(true)
      return
    end
    Autocomplete.ShowDropdown(editBox, results, revision)
  end)
  if not finished then cancelSearch = cancel end
end

-- A row was chosen. revision is the one the rows on screen were built for;
-- a stale one does nothing.
function Autocomplete.SelectItem(item, revision)
  local s = session
  if not s or not item then return end
  if revision and revision ~= s.revision then return end

  StopLoad()
  local gen, rev = s.generation, s.revision
  local itemID = item.itemID
  local cancel = Utilities.LoadItemThen(itemID, {
    timeout = LOAD_TIMEOUT,
    onReady = function(link)
      cancelLoad = nil
      if session ~= s or s.generation ~= gen or s.revision ~= rev then return end
      Autocomplete.InsertLink(s, link, itemID)
    end,
    onFail = function(reason)
      cancelLoad = nil
      Debug.Warn("AUTOCOMPLETE", "No link for item %d (%s)", itemID, tostring(reason))
    end,
  })
  -- A cached item has been inserted already and the session is gone
  if session == s then cancelLoad = cancel end
end

-- Puts link over the session's span, if the draft still holds that span
function Autocomplete.InsertLink(s, link, itemID)
  local editBox = s.editBox
  local text = editBox:GetText() or ""
  if strsub(text, s.triggerStart, s.cursor) ~= "[" .. s.query then
    Autocomplete.Cancel()
    return
  end

  local newText, newCursor = Autocomplete.ReplaceSpan(text, s.triggerStart, s.cursor, link)
  -- End the session before SetText, which is a programmatic change
  Autocomplete.Cancel()
  editBox:SetText(newText)
  editBox:SetCursorPosition(newCursor)

  -- A row click took keyboard focus from the chat box; give it back so the
  -- player carries on typing after the link. Nothing is sent here.
  if not editBox:HasFocus() then
    editBox:SetFocus()
  end

  local Search = CobysLinkepedia.Search
  if itemID and Search and Search.AddToHistory then
    Search.AddToHistory(itemID)
  end
end

-- The chat box the open session belongs to, for the dropdown's handlers
function Autocomplete.GetActiveEditBox()
  return session and session.editBox
end

-------------------------------------------------------------------------------
-- Edit box hooks
-------------------------------------------------------------------------------
local function HookEditBox(editBox)
  if not editBox or hookedEditBoxes[editBox] then return false end
  hookedEditBoxes[editBox] = true

  editBox:HookScript("OnTextChanged", function(self, userInput)
    if userInput then
      Evaluate(self)
    elseif session and session.editBox == self then
      -- A programmatic change (Blizzard's chat-type switch, another addon)
      Autocomplete.Cancel()
    end
  end)

  -- Arrow keys and clicks move the caret without changing the text
  editBox:HookScript("OnCursorChanged", function(self)
    if session and session.editBox == self and self:GetCursorPosition() ~= session.cursor then
      Evaluate(self)
    end
  end)

  editBox:HookScript("OnKeyDown", function(_, key)
    if not session then return end
    if key == "ESCAPE" then
      Autocomplete.Cancel()
    elseif key == "UP" or key == "DOWN" then
      Autocomplete.NavigateKey(key)
    end
  end)

  -- A mouse-down on a dropdown row takes keyboard focus from the chat box
  -- before the row's click arrives, so the session survives that one focus
  -- loss: the click inserts the link and hands focus back. Any other focus
  -- loss ends the session.
  editBox:HookScript("OnEditFocusLost", function()
    if Autocomplete.IsDropdownUnderMouse() then return end
    Autocomplete.Cancel()
  end)
  return true
end

local function HookChatFrameEditBoxes()
  local hooked = 0
  for i = 1, Constants.ChatFrameConstants.MaxChatWindows do
    if HookEditBox(_G["ChatFrame" .. i .. "EditBox"]) then
      hooked = hooked + 1
    end
  end
  return hooked
end

-- Pop-out whisper and conversation windows (ChatFrame11 and up) are built
-- the first time one opens, so their boxes are hooked after each
-- FCF_OpenTemporaryWindow; a reused window is already hooked
local function HookTemporaryEditBoxes()
  for _, name in pairs(CHAT_FRAMES or {}) do
    local frame = _G[name]
    local editBox = frame and frame.editBox
    if editBox and HookEditBox(editBox) then
      Autocomplete.AddDropdownOwner(editBox)
    end
  end
end

-------------------------------------------------------------------------------
-- Tab completion
--
-- ChatFrameEditBoxMixin:OnTabPressed calls the global ChatEdit_CustomTabPressed
-- through securecall before its own SecureTabPressed (the whisper-target
-- cycling), and Blizzard's source leaves that global as the hook for addon tab
-- completion. Returning true consumes the Tab.
-------------------------------------------------------------------------------
local tabHookInstalled = false

local function InstallTabHook()
  if tabHookInstalled then return end
  tabHookInstalled = true

  local previous = ChatEdit_CustomTabPressed
  ChatEdit_CustomTabPressed = function(editBox)
    if session and editBox == session.editBox and Autocomplete.IsDropdownShown()
        and Autocomplete.GetDisplayedRevision() == session.revision then
      Autocomplete.SelectCurrent(true)
      return true
    end
    if previous then
      return previous(editBox)
    end
    return false
  end
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------
local temporaryHookInstalled = false

function Autocomplete.HookAllEditBoxes()
  local hooked = HookChatFrameEditBoxes()
  InstallTabHook()
  Autocomplete.EnsureDropdown()
  HookTemporaryEditBoxes()
  if not temporaryHookInstalled and FCF_OpenTemporaryWindow then
    temporaryHookInstalled = true
    hooksecurefunc("FCF_OpenTemporaryWindow", HookTemporaryEditBoxes)
  end
  Debug.Log("AUTOCOMPLETE", "Hooked %d chat edit boxes", hooked)
end

-- Turning the option off ends a session in progress
CobysLinkepedia.EventBus:Register({ ReceiveEvent = function(_, _, key)
  if session and (key == nil or key == Config.Options.AUTOCOMPLETE_ENABLED) and not Enabled() then
    Autocomplete.Cancel()
  end
end }, { CobysLinkepedia.Events.ConfigChanged })

-- Dropdown control stubs (implemented by Dropdown.lua)
function Autocomplete.ShowDropdown(editBox, results, revision) end
function Autocomplete.HideDropdown(keepSession) end
function Autocomplete.IsDropdownShown() return false end
function Autocomplete.GetDisplayedRevision() return nil end
function Autocomplete.NavigateUp() end
function Autocomplete.NavigateDown() end
function Autocomplete.NavigateKey(key) end
function Autocomplete.SelectCurrent(fallbackToFirst) end
function Autocomplete.GetSelectedIndex() return 0 end
function Autocomplete.IsDropdownUnderMouse() return false end
function Autocomplete.EnsureDropdown() end
function Autocomplete.AddDropdownOwner(editBox) end

-------------------------------------------------------------------------------
-- New chat tabs create new edit boxes (HookEditBox is idempotent per box)
-------------------------------------------------------------------------------
local rehookFrame = CreateFrame("Frame")
rehookFrame:RegisterEvent("UPDATE_CHAT_WINDOWS")
rehookFrame:SetScript("OnEvent", HookChatFrameEditBoxes)

Debug.Log("INIT", "Autocomplete module loaded")
