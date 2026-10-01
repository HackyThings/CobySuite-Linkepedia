-- Item tokens: ${i=ID}, ${n=text} and ${v=N}, expanded into item links at send
--
--   ${i=6948}        that exact item id, whether or not the database has it
--   ${n=hearth}      the item whose name is exactly the text; with none, the
--                    first result the search (and so autocomplete) would list
--   ${i=191234~R2}   i= and n= take the bracket qualifiers, ~R<n> and ~<n>
--   ${v=12}          saved variant 12 (Variants/Store.lua), its exact link;
--                    no qualifiers
--
-- Keys are one letter, either case, and spaces around the key, the "=" and
-- the value are ignored. Anything else that starts with "${" is not a token
-- and is sent as typed.
--
-- A token whose item is known but not loaded yet goes out as its plain
-- [Name] and asks the client for the item, so the next send links. A token
-- whose qualifier matches no captured variant also goes out as [Name], and
-- this fallback asks for no load (matching the qualifier may still load a
-- variant's details; brackets keep such a qualifier as typed). One whose
-- item cannot be found at all, or a saved variant that was deleted, goes
-- out as typed. An n= token's item
-- is looked up once per database generation, so a macro pressed every
-- second searches once.

local Linkify = CobysLinkepedia.Linkify
local Database = CobysLinkepedia.Database

local strfind, strsub, strmatch, strlower = string.find, string.sub, string.match, string.lower
local tconcat = table.concat

-------------------------------------------------------------------------------
-- Parsing
-------------------------------------------------------------------------------

-- The token for the text between "${" and "}", or nil when it is not one
local function ParseToken(inner)
  if strfind(inner, "[{|]") then return nil end
  local key, value = strmatch(inner, "^%s*(%a)%s*=(.*)$")
  if not key then return nil end
  key = strlower(key)

  if key == "v" then
    local id = strmatch(value, "^%s*(%d+)%s*$")
    if not id then return nil end
    return { key = "v", variantID = tonumber(id) }
  end

  local main, rank, ilvl, qualified = Linkify.ParseQualifiers(value)
  if key == "i" then
    if not strmatch(main, "^%d+$") then return nil end
    return { key = "i", itemID = tonumber(main), rank = rank, ilvl = ilvl, qualified = qualified }
  elseif key == "n" then
    if main == "" then return nil end
    return { key = "n", query = main, rank = rank, ilvl = ilvl, qualified = qualified }
  end
  return nil
end

-- Every token in text, in order: { start, stop, text, key, itemID (i=),
-- query (n=) or variantID (v=), rank, ilvl, qualified }, with start and stop
-- as byte offsets
function Linkify.FindTokens(text)
  local tokens = {}
  if type(text) ~= "string" then return tokens end
  local pos = 1
  while true do
    local start = strfind(text, "${", pos, true)
    if not start then break end
    local close = strfind(text, "}", start + 2, true)
    if not close then break end
    local token = ParseToken(strsub(text, start + 2, close - 1))
    if token then
      token.start, token.stop, token.text = start, close, strsub(text, start, close)
      tokens[#tokens + 1] = token
      pos = close + 1
    else
      -- Not a token: look again just after this "${"
      pos = start + 2
    end
  end
  return tokens
end

-- The exact token for an item id, with the qualifiers given
function Linkify.FormatToken(itemID, rank, ilvl)
  local parts = { "${i=", tostring(itemID) }
  if rank then parts[#parts + 1] = "~R" .. rank end
  if ilvl then parts[#parts + 1] = "~" .. ilvl end
  parts[#parts + 1] = "}"
  return tconcat(parts)
end

-- The token for saved variant id
function Linkify.FormatVariantToken(id)
  return "${v=" .. tostring(id) .. "}"
end

-------------------------------------------------------------------------------
-- Resolution
-------------------------------------------------------------------------------

local nameCache = {}
local nameCacheGeneration = nil

-- The item id a token names, or nil. i= is its own id; v= is its saved
-- variant's base item; n= is the exact name when one exists (highest
-- quality, then lowest id, as brackets pick), else the first search result,
-- remembered until the database changes.
function Linkify.ResolveTokenItem(token)
  if token.key == "i" then return token.itemID end
  if token.key == "v" then
    local variant = CobysLinkepedia.Variants.Get(token.variantID)
    return variant and variant.itemID
  end

  local generation = Database.GetGeneration()
  if generation ~= nameCacheGeneration then
    wipe(nameCache)
    nameCacheGeneration = generation
  end

  local key = strlower(token.query)
  local cached = nameCache[key]
  if cached == nil then
    local item = Database.GetExact(token.query)
    if not item then
      local results = Database.Search(token.query, 1)
      item = results and results[1]
    end
    cached = item and item.itemID or false
    nameCache[key] = cached
  end
  return cached or nil
end

-- The link, item id and fallback text for one token. Without a link, the
-- fallback is the plain [Name] when the name is known; nil sends the token
-- as typed.
function Linkify.ResolveToken(token)
  if token.key == "v" then
    local variant = CobysLinkepedia.Variants.Get(token.variantID)
    if not variant then return nil end
    return variant.link, variant.itemID
  end

  local itemID = Linkify.ResolveTokenItem(token)
  if not itemID then return nil end

  local link = Linkify.LinkForItem(itemID, token.rank, token.ilvl, token.qualified)
  if link then return link, itemID end

  if not token.qualified then
    C_Item.RequestLoadItemDataByID(itemID)
  end
  local item = Database.GetItem(itemID)
  local name = item and item.name or C_Item.GetItemNameByID(itemID)
  return nil, itemID, name and ("[" .. name .. "]") or nil
end

-------------------------------------------------------------------------------
-- Expansion
-------------------------------------------------------------------------------

-- text with every token replaced by resolve(token)'s link, else its fallback,
-- else the token as typed. resolve defaults to Linkify.ResolveToken; the
-- Linkify suite passes its own.
function Linkify.ExpandTokens(text, resolve)
  if type(text) ~= "string" or not strfind(text, "${", 1, true) then return text end
  local tokens = Linkify.FindTokens(text)
  if #tokens == 0 then return text end
  resolve = resolve or Linkify.ResolveToken

  local parts, n, pos = {}, 0, 1
  for _, token in ipairs(tokens) do
    n = n + 1; parts[n] = strsub(text, pos, token.start - 1)
    local link, _, fallback = resolve(token)
    n = n + 1; parts[n] = link or fallback or token.text
    pos = token.stop + 1
  end
  n = n + 1; parts[n] = strsub(text, pos)
  return tconcat(parts)
end
