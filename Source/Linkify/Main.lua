-- Linkify: turns [Item Name] and item tokens into item links in outgoing chat
--
-- Runs once per message, at send. ChatFrameEditBoxBaseMixin:SendText calls
-- ParseText(1), then OnPreSendText, then reads the text to send; by then a
-- chat-type command such as /p or /w Name has already been taken off the
-- text. The draft is never rewritten while it is typed, so the caret stays
-- put and a qualifier stays editable until the message goes out.
--
-- Two kinds of edit box reach that point. The chat frames' boxes
-- (ChatFrameEditBoxMixin) raise the ChatFrame.OnEditBoxPreSendText event
-- there. Every chat line a macro sends goes through one private box built on
-- the base mixin, whose OnPreSendText is an empty stub; a hooksecurefunc
-- post-hook on that stub covers macros.
--
-- Typed chat converts [Item Name] (autoLinkifyOnSend) and item tokens
-- (expandItemTokens, Tokens.lua). Macros convert item tokens only: a macro
-- is written once and pressed often, so it names its item exactly. The
-- Chat Lab (Tests/ChatLab.lua) watches both paths through a send observer
-- that exists only while the lab is open.
--
-- Qualifiers: [Name~R2] asks for the rank 2 variant, [Name~450] for the item
-- level 450 variant, and both may be given. A qualifier that matches no
-- captured variant leaves the brackets as typed; only an unqualified name
-- takes the default (the best captured variant, else the base item).

local Linkify = CobysLinkepedia.Linkify
local Database = CobysLinkepedia.Database
local Config = CobysLinkepedia.Config
local Debug = CobysLinkepedia.Debug

local strfind, strsub, strmatch, strupper, gmatch = string.find, string.sub, string.match, string.upper, string.gmatch
local tconcat = table.concat

-- The longest message the chat API sends; links that would push a message
-- past it are not made
local MAX_MESSAGE_BYTES = 255

-- Commands whose argument is Lua or a console line, never chat
local SCRIPT_COMMANDS = { ["/RUN"] = true, ["/SCRIPT"] = true, ["/DUMP"] = true, ["/CONSOLE"] = true }

-------------------------------------------------------------------------------
-- Qualifiers
-------------------------------------------------------------------------------

-- Splits bracket content into the item name and its qualifiers. Returns
-- name, rank, itemLevel, qualified. Every part after the first "~" must be
-- R<n> or <n>, each at most once; otherwise the whole content is the name
-- and nothing is qualified.
function Linkify.ParseQualifiers(content)
  if type(content) ~= "string" then return nil, nil, nil, false end
  local name, rest = strmatch(content, "^([^~]*)~(.*)$")
  if not name then
    return strtrim(content), nil, nil, false
  end

  local rank, ilvl
  for part in gmatch(rest .. "~", "([^~]*)~") do
    part = strtrim(part)
    local r = tonumber(strmatch(part, "^[Rr](%d+)$"))
    local level = strmatch(part, "^(%d+)$")
    if r and r >= 1 and not rank then
      rank = r
    elseif level and not ilvl then
      ilvl = tonumber(level)
    else
      return strtrim(content), nil, nil, false
    end
  end
  return strtrim(name), rank, ilvl, true
end

-------------------------------------------------------------------------------
-- Command guard
-------------------------------------------------------------------------------

-- True when the text is a secure command or a script command, which are
-- never rewritten. At pre-send those have normally run and cleared the box
-- already; this is a second line of defence.
function Linkify.IsExcludedCommand(text)
  if type(text) ~= "string" then return false end
  local token = strmatch(text, "^(/%S+)")
  if not token then return false end
  if SCRIPT_COMMANDS[strupper(token)] then return true end
  return CobysLinkepedia.Utilities.IsSecureCommand(text)
end

-------------------------------------------------------------------------------
-- Bracket resolution
-------------------------------------------------------------------------------

-- The link for an item id under the parsed qualifiers, or nil: the matching
-- captured variant, else (unqualified only) the base item once it is loaded.
-- Shared by brackets and item tokens.
function Linkify.LinkForItem(itemID, rank, ilvl, qualified)
  local variant = Database.MatchVariant(itemID, rank, ilvl)
  if variant then return variant end
  -- An explicit qualifier that matched nothing never falls back to another item
  if qualified then return nil end
  local _, link = C_Item.GetItemInfo(itemID)
  return link
end

-- The link for one [bracketed] name and its item id, or nil
local function ResolveBracket(content)
  local name, rank, ilvl, qualified = Linkify.ParseQualifiers(content)
  if not name or name == "" then return nil end

  local item = Database.GetExact(name)
  if not item then return nil end

  local link = Linkify.LinkForItem(item.itemID, rank, ilvl, qualified)
  if link then return link, item.itemID end
  return nil
end

-------------------------------------------------------------------------------
-- Message transform
-------------------------------------------------------------------------------

-- Replaces every [bracketed] name that resolve(content) turns into a link.
-- A hyperlink already in the text is consumed as one token: from |H to the
-- |h that ends its address, then the |h that ends its text, then an
-- optional |r. It is copied verbatim and bracket scanning resumes after it,
-- so the [Text] inside a link is never mistaken for a name. Brackets whose
-- content holds a "[" or an escape sequence are not names either. A second
-- pass over the output changes nothing. resolve defaults to the database
-- lookup; the Linkify suite passes its own.
function Linkify.TransformMessage(text, resolve)
  if type(text) ~= "string" or text == "" then return text end
  -- Most messages hold no bracket at all; one plain find settles that
  if not strfind(text, "[", 1, true) then return text end
  resolve = resolve or ResolveBracket

  local parts, n = {}, 0
  local pos, len = 1, #text

  while pos <= len do
    local bracket = strfind(text, "[", pos, true)
    if not bracket then
      n = n + 1; parts[n] = strsub(text, pos)
      break
    end

    local linkStart = strfind(text, "|H", pos, true)
    if linkStart and linkStart < bracket then
      local addressEnd = strfind(text, "|h", linkStart + 2, true)
      local textEnd = addressEnd and strfind(text, "|h", addressEnd + 2, true)
      if not textEnd then
        -- An unterminated hyperlink: leave the rest of the message alone
        n = n + 1; parts[n] = strsub(text, pos)
        break
      end
      local stop = textEnd + 1
      if strsub(text, stop + 1, stop + 2) == "|r" then stop = stop + 2 end
      n = n + 1; parts[n] = strsub(text, pos, stop)
      pos = stop + 1
    else
      n = n + 1; parts[n] = strsub(text, pos, bracket - 1)
      local close = strfind(text, "]", bracket + 1, true)
      if not close then
        n = n + 1; parts[n] = strsub(text, bracket)
        break
      end
      local content = strsub(text, bracket + 1, close - 1)
      if strfind(content, "[", 1, true) or strfind(content, "|", 1, true) then
        -- Not a name: keep this "[" and look again just after it
        n = n + 1; parts[n] = "["
        pos = bracket + 1
      else
        local link = resolve(content)
        n = n + 1; parts[n] = link or strsub(text, bracket, close)
        pos = close + 1
      end
    end
  end

  return tconcat(parts)
end

-------------------------------------------------------------------------------
-- Pre-send rewrite
-------------------------------------------------------------------------------

-- A macro can repeat a line every second, so on that path the too-long
-- warning shows at most once in this many seconds
local MACRO_WARNING_SECONDS = 10

-- Rewrites the edit box text in place before it is sent. fromMacro marks the
-- macro box, where only item tokens convert. resolve(content) returns the
-- link and item id for one bracket and resolveToken(token) the link, item id
-- and fallback text for one token; both default to the database lookups and
-- the Linkify suite passes its own. Brackets go first: a token's fallback
-- "[Name]" must never be looked up again as a bracket. Returns "linked",
-- "too long", or nil when the text was left alone for any other reason.
function Linkify.LinkOutgoing(editBox, fromMacro, resolve, resolveToken)
  local brackets = not fromMacro and Config.Get(Config.Options.AUTO_LINKIFY_ON_SEND)
  local tokens = Config.Get(Config.Options.EXPAND_ITEM_TOKENS)
  if not brackets and not tokens then return nil end
  if not editBox or not editBox.GetText then return nil end

  local text = editBox:GetText()
  if not text or text == "" or Linkify.IsExcludedCommand(text) then return nil end

  local linkedIDs = {}
  local transformed = text
  if brackets then
    resolve = resolve or ResolveBracket
    transformed = Linkify.TransformMessage(transformed, function(content)
      local link, itemID = resolve(content)
      if link then linkedIDs[#linkedIDs + 1] = itemID end
      return link
    end)
  end
  if tokens then
    resolveToken = resolveToken or Linkify.ResolveToken
    transformed = Linkify.ExpandTokens(transformed, function(token)
      local link, itemID, fallback = resolveToken(token)
      if link then linkedIDs[#linkedIDs + 1] = itemID end
      return link, itemID, fallback
    end)
  end
  if transformed == text then return nil end

  if #transformed > MAX_MESSAGE_BYTES then
    local now = GetTime()
    local last = Linkify._lastMacroWarning
    if not fromMacro or not last or now - last >= MACRO_WARNING_SECONDS then
      if fromMacro then Linkify._lastMacroWarning = now end
      CobysLinkepedia.Utilities.Message.Warn("The links would make that message longer than chat allows, so it was sent as typed.")
    end
    return "too long"
  end

  editBox:SetText(transformed)
  -- History records links actually sent
  local Search = CobysLinkepedia.Search
  if Search and Search.AddToHistory then
    for _, itemID in ipairs(linkedIDs) do
      Search.AddToHistory(itemID)
    end
  end
  Debug.Log("LINKIFY", "Linked %d item(s) in an outgoing %s", #linkedIDs, fromMacro and "macro line" or "message")
  return "linked"
end

-- A send observer for the Chat Lab (Tests/ChatLab.lua). Set, it is called
-- after each pre-send rewrite with { before, after, result, fromMacro,
-- chatType, channelTarget, time }; an error in it is swallowed. Unset (the
-- normal case) the pre-send path is exactly LinkOutgoing and nothing is read
-- or recorded.
local sendObserver = nil

function Linkify.SetSendObserver(fn)
  local previous = sendObserver
  sendObserver = fn
  return previous
end

-- A text for the observer; a secret value is never kept as it is
local function Observable(value)
  if issecretvalue and issecretvalue(value) then return "(secret)" end
  return value
end

local function PreSend(editBox, fromMacro)
  local observer = sendObserver
  if not observer then
    return Linkify.LinkOutgoing(editBox, fromMacro)
  end
  local okBefore, before = pcall(editBox.GetText, editBox)
  local result = Linkify.LinkOutgoing(editBox, fromMacro)
  pcall(function()
    local after = editBox:GetText()
    observer({
      before = okBefore and Observable(before) or nil,
      after = Observable(after),
      result = result,
      fromMacro = fromMacro,
      chatType = editBox.GetChatType and Observable(editBox:GetChatType()) or nil,
      channelTarget = editBox.GetChannelTarget and Observable(editBox:GetChannelTarget()) or nil,
      time = GetTime(),
    })
  end)
  return result
end

local function OnPreSendText(_, editBox)
  PreSend(editBox, false)
end

function Linkify.InstallHook()
  if Linkify._hookInstalled then return end
  Linkify._hookInstalled = true
  EventRegistry:RegisterCallback("ChatFrame.OnEditBoxPreSendText", OnPreSendText, Linkify)
  Debug.Log("LINKIFY", "Pre-send handler registered")
end

-------------------------------------------------------------------------------
-- Macros
--
-- MacroExecutionManager.lua keeps the macro box in its own table, so it has
-- no global name. It is the only edit box that is anonymous, parentless, not
-- a chat frame's, and still carries both the base mixin's SendText and its
-- empty OnPreSendText stub (the chat frames' boxes override the stub).
--
-- hooksecurefunc keeps the hook's taint off the macro's own execution.
-- Checked in the 12.1 client on 2026-09-16: hooked /s and whisper lines
-- linked, the /target and /cleartarget lines after them still ran, nothing
-- was blocked, and no Blizzard field was left tainted.
-------------------------------------------------------------------------------
function Linkify.IsMacroEditBox(frame)
  local base = ChatFrameEditBoxBaseMixin
  if not base or type(frame) ~= "table" then return false end
  -- Two table reads rule out nearly every frame before any widget call
  if frame.OnPreSendText ~= base.OnPreSendText or frame.SendText ~= base.SendText then return false end
  if not frame.GetObjectType or frame:GetObjectType() ~= "EditBox" then return false end
  return frame:GetName() == nil and frame:GetParent() == nil and frame.chatFrame == nil
end

function Linkify.FindMacroEditBox()
  local frame = EnumerateFrames()
  while frame do
    if Linkify.IsMacroEditBox(frame) then return frame end
    frame = EnumerateFrames(frame)
  end
  return nil
end

-- Hooks the macro box once. editBox defaults to FindMacroEditBox(); the
-- Linkify suite passes a fake. Returns whether a box is hooked.
function Linkify.InstallMacroHook(editBox)
  if Linkify._macroHookInstalled then return true end
  editBox = editBox or Linkify.FindMacroEditBox()
  if not editBox then
    Debug.Warn("LINKIFY", "Macro edit box not found; macro chat lines are sent as typed")
    return false
  end
  hooksecurefunc(editBox, "OnPreSendText", function(box)
    PreSend(box, true)
  end)
  Linkify._macroHookInstalled = true
  Debug.Log("LINKIFY", "Macro edit box found and hooked")
  return true
end

Debug.Log("INIT", "Linkify module loaded")
