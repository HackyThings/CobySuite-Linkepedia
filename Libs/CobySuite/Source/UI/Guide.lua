---------------------------------------------------------------------------
-- CobySuite.UI.CreateGuideWindow / CreateHelpButton: an addon's feature guide
--
-- A guide is a window of sections, one per part of the addon. Each section
-- is a header (icon, title, a one-line summary, and at its right edge the
-- plus and minus buttons of Blizzard's objective tracker, which its housing
-- dashboard also uses for collapsible lists) that opens and closes a body:
-- paragraphs of text, then "Try it" lines in the slash help colours
-- (U.FormatCommandLine). It is not a walkthrough: the player opens whatever
-- they are curious about.
--
--   local guide = CobySuite.UI.CreateGuideWindow({
--     name       = "MyAddonGuideWindow",   -- optional global name; Escape closes a named guide
--     title      = "My Addon Guide",
--     intro      = "A line above the sections.",           -- optional
--     width = 580, height = 620,                           -- the defaults
--     persist    = { svTable = function() return MY_STATE end, key = "guide" },  -- optional
--     singleOpen = false,                  -- true: opening a section closes the others
--     expanded   = { "search" },           -- keys open at first; default the first section
--     sections   = {
--       { key = "search", title = "Searching",
--         icon    = "Interface\\Icons\\INV_Misc_Spyglass_03",   -- a texture path or file ID,
--         atlas   = "common-search-magnifyingglass",            -- or an atlas
--         summary = "One line, shown open or closed",
--         body    = { "A paragraph.", "Another." },             -- a string or a list
--         try     = { { "/ma show", "Open the search window" }, { "Shift-click", "Link it" } },
--       },
--     },
--   })
--   guide:Toggle()                 -- the CreateWindow shell's own
--   guide:OpenSection("search")    -- shows the guide with that section open, scrolled to it
--   guide:SetExpanded("search", true)   guide:IsExpanded("search")   guide:GetContentHeight()
--
-- Everything is built at once, so create a guide out of combat (at load or
-- login); showing and hiding it later is safe in combat. It is a CreateWindow
-- shell at DIALOG strata that the player can move and resize; the text
-- reflows with the width.
--
--   local help = CobySuite.UI.CreateHelpButton(window, {
--     onClick = function() guide:Toggle() end,
--     tooltip = "My Addon guide",         -- default "Guide"
--     tooltipAnchor = "ANCHOR_TOP",       -- the default
--     name    = "MyAddonHelpButton",      -- optional
--     size    = 24,                       -- the default, to match the close button
--     point   = { "TOPRIGHT", -30, -2 },   -- default: left of window.CloseButton
--   })
--
-- The help button is a gold question mark in the title font, 24 px square by
-- default to match the close button beside it, white under the mouse.
---------------------------------------------------------------------------
local UI = CobySuite_CobysLinkepedia.UI
local U = CobySuite_CobysLinkepedia.Utilities

local HEADER_HEIGHT = 46
local ICON_SIZE = 32
local PAD = 10                             -- inside a section
local GAP = 4                              -- between sections
local BODY_LEFT = PAD + ICON_SIZE + PAD    -- body text lines up with the title
local INSET_LEFT, INSET_RIGHT = 12, 32     -- the scroll area inside the window (its bar on the right)
local TOP = 30                             -- below the title bar
-- Self-contained square buttons. The Options list's arrow is the right cap
-- of a three-part bar and has no left border of its own.
local ARROW_CLOSED = "ui-questtrackerbutton-expand-all"
local ARROW_OPEN = "ui-questtrackerbutton-collapse-all"

---------------------------------------------------------------------------
-- CreateHelpButton
---------------------------------------------------------------------------
function UI.CreateHelpButton(parent, opts)
  opts = opts or {}
  local size = opts.size or 24
  local btn = CreateFrame("Button", opts.name, parent)
  btn:SetSize(size, size)
  if opts.point then
    btn:SetPoint(unpack(opts.point))
  elseif parent.CloseButton then
    btn:SetPoint("RIGHT", parent.CloseButton, "LEFT", 0, 0)
  else
    btn:SetPoint("TOPRIGHT", -4, -2)
  end

  local glyph = btn:CreateFontString(nil, "OVERLAY", U.Fonts.TITLE)
  glyph:SetPoint("CENTER")
  glyph:SetText("?")
  btn.Glyph = glyph

  local function Paint(over)
    local c = over and U.Colors.HIGHLIGHT_WHITE or U.Colors.STATUS_GOLD
    glyph:SetTextColor(c[1], c[2], c[3])
  end
  Paint(false)

  UI.AddTooltip(btn, opts.tooltip or "Guide", opts.tooltipAnchor or "ANCHOR_TOP")
  btn:HookScript("OnEnter", function() Paint(true) end)
  btn:HookScript("OnLeave", function() Paint(false) end)
  btn:SetScript("OnMouseDown", function() glyph:SetPoint("CENTER", 1, -1) end)
  btn:SetScript("OnMouseUp", function() glyph:SetPoint("CENTER", 0, 0) end)
  btn:SetScript("OnClick", function(self, button)
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    if opts.onClick then opts.onClick(self, button) end
  end)
  return btn
end

---------------------------------------------------------------------------
-- CreateGuideWindow
---------------------------------------------------------------------------
local GuideMixin = {}

local function Paragraphs(body)
  if type(body) == "table" then return table.concat(body, "\n\n") end
  return body or ""
end

local function BuildSection(guide, def)
  local child = guide.Child
  local s = { key = def.key, def = def, expanded = false }

  local header = CreateFrame("Button", nil, child)
  header:SetHeight(HEADER_HEIGHT)
  local bg = header:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  local c = U.Colors.CONTENT_BG
  bg:SetColorTexture(c[1], c[2], c[3], c[4])
  UI.AddHoverHighlight(header)

  local icon = header:CreateTexture(nil, "ARTWORK")
  icon:SetSize(ICON_SIZE, ICON_SIZE)
  icon:SetPoint("LEFT", PAD, 0)
  if def.atlas then
    icon:SetAtlas(def.atlas)
  else
    icon:SetTexture(def.icon)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)   -- the icon border
  end

  local arrow = header:CreateTexture(nil, "ARTWORK")
  arrow:SetPoint("RIGHT", -PAD, 0)
  arrow:SetAtlas(ARROW_CLOSED, true)
  -- Brightens with the header under the mouse, as the housing dashboard's does
  local arrowGlow = header:CreateTexture(nil, "HIGHLIGHT")
  arrowGlow:SetAllPoints(arrow)
  arrowGlow:SetBlendMode("ADD")
  arrowGlow:SetAlpha(0.3)
  arrowGlow:SetAtlas(ARROW_CLOSED)
  s.arrowGlow = arrowGlow

  local title = header:CreateFontString(nil, "OVERLAY", U.Fonts.TITLE)
  title:SetPoint("TOPLEFT", icon, "TOPRIGHT", PAD, -1)
  title:SetPoint("RIGHT", arrow, "LEFT", -PAD, 0)
  title:SetJustifyH("LEFT")
  title:SetWordWrap(false)
  title:SetText(def.title or def.key)

  local summary = header:CreateFontString(nil, "OVERLAY", U.Fonts.DATA)
  summary:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
  summary:SetPoint("RIGHT", arrow, "LEFT", -PAD, 0)
  summary:SetJustifyH("LEFT")
  summary:SetWordWrap(false)
  local gray = U.Colors.LABEL_GRAY
  summary:SetTextColor(gray[1], gray[2], gray[3])
  summary:SetText(def.summary or "")

  header:SetScript("OnClick", function()
    local open = not s.expanded
    PlaySound(open and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    guide:SetExpanded(s.key, open)
  end)

  local body = CreateFrame("Frame", nil, child)
  local bodyBg = body:CreateTexture(nil, "BACKGROUND")
  bodyBg:SetAllPoints()
  local a = U.Colors.ALT_ROW_BG
  bodyBg:SetColorTexture(a[1], a[2], a[3], a[4])

  local text = body:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
  text:SetPoint("TOPLEFT", BODY_LEFT, -PAD)
  text:SetJustifyH("LEFT")
  text:SetJustifyV("TOP")
  text:SetSpacing(2)
  text:SetText(Paragraphs(def.body))

  if def.try and #def.try > 0 then
    local label = body:CreateFontString(nil, "OVERLAY", U.Fonts.SMALL)
    label:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -10)
    label:SetText("Try it")
    local lines = {}
    for _, entry in ipairs(def.try) do
      lines[#lines + 1] = U.FormatCommandLine(entry[1], entry[2])
    end
    local try = body:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
    try:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
    try:SetJustifyH("LEFT")
    try:SetJustifyV("TOP")
    try:SetSpacing(4)
    try:SetText(table.concat(lines, "\n"))
    s.tryLabel, s.try = label, try
  end
  body:Hide()

  s.header, s.icon, s.arrow, s.title, s.summary = header, icon, arrow, title, summary
  s.body, s.text = body, text
  return s
end

-- The body's height for a content width
local function MeasureBody(s, width)
  local textWidth = width - BODY_LEFT - PAD
  s.text:SetWidth(textWidth)
  local h = PAD + s.text:GetStringHeight()
  if s.try then
    s.try:SetWidth(textWidth)
    h = h + 10 + s.tryLabel:GetStringHeight() + 4 + s.try:GetStringHeight()
  end
  return math.ceil(h + PAD)
end

function GuideMixin:Relayout()
  local width = self:GetWidth() - INSET_LEFT - INSET_RIGHT
  if width <= 0 then return end

  local top = TOP
  if self.Intro then
    self.Intro:SetWidth(width)
    top = top + self.Intro:GetStringHeight() + 8
  end
  self.Scroll:ClearAllPoints()
  self.Scroll:SetPoint("TOPLEFT", INSET_LEFT, -top)
  self.Scroll:SetPoint("BOTTOMRIGHT", -INSET_RIGHT, 12)
  self.Child:SetWidth(width)

  local y = 0
  for _, s in ipairs(self.sections) do
    s.top = y
    s.header:ClearAllPoints()
    s.header:SetPoint("TOPLEFT", self.Child, "TOPLEFT", 0, -y)
    s.header:SetPoint("RIGHT", self.Child, "RIGHT", 0, 0)
    s.arrow:SetAtlas(s.expanded and ARROW_OPEN or ARROW_CLOSED, true)
    s.arrowGlow:SetAtlas(s.expanded and ARROW_OPEN or ARROW_CLOSED)
    y = y + HEADER_HEIGHT
    if s.expanded then
      local h = MeasureBody(s, width)
      s.body:ClearAllPoints()
      s.body:SetPoint("TOPLEFT", self.Child, "TOPLEFT", 0, -y)
      s.body:SetPoint("RIGHT", self.Child, "RIGHT", 0, 0)
      s.body:SetHeight(h)
      s.body:Show()
      y = y + h
    else
      s.body:Hide()
    end
    y = y + GAP
  end
  self.contentHeight = y
  self.Child:SetHeight(math.max(1, y))
  self.Scroll:UpdateScrollChildRect()
end

function GuideMixin:IsExpanded(key)
  local s = self.byKey[key]
  return s ~= nil and s.expanded
end

function GuideMixin:SetExpanded(key, expanded)
  local s = self.byKey[key]
  if not s then return end
  if expanded and self.singleOpen then
    for _, other in ipairs(self.sections) do other.expanded = false end
  end
  s.expanded = expanded and true or false
  self:Relayout()
end

function GuideMixin:GetContentHeight()
  return self.contentHeight or 0
end

function GuideMixin:OpenSection(key)
  if not self:IsShown() then
    self:RestoreState()
    self:Show()
  end
  local s = self.byKey[key]
  if not s then return end
  self:SetExpanded(key, true)
  local range = self.Scroll:GetVerticalScrollRange()
  self.Scroll:SetVerticalScroll(math.max(0, math.min(s.top or 0, range)))
end

function UI.CreateGuideWindow(opts)
  opts = opts or {}
  local f = UI.CreateWindow({
    name         = opts.name,
    title        = opts.title,
    width        = opts.width or 580,
    height       = opts.height or 620,
    strata       = "DIALOG",
    resizable    = { minWidth = 440, minHeight = 320, maxWidth = 1000, maxHeight = 1100 },
    escapeCloses = opts.name ~= nil,
    persist      = opts.persist,
    point        = not opts.persist and { "CENTER", UIParent, "CENTER", 0, 40 } or nil,
    mixin        = GuideMixin,
  })
  f.singleOpen = opts.singleOpen and true or false

  if opts.intro then
    local intro = f:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
    intro:SetPoint("TOPLEFT", INSET_LEFT + 2, -TOP)
    intro:SetJustifyH("LEFT")
    intro:SetSpacing(2)
    intro:SetText(opts.intro)
    f.Intro = intro
  end

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  -- The template's bar is the old slider, without ScrollBarMixin's
  -- SetHideIfUnscrollable. scrollBarHideable makes the template's range
  -- handler (ScrollFrame_OnScrollRangeChanged) hide the bar while there is
  -- nothing to scroll and show it again when there is. The template's OnLoad
  -- ran before the flag was set, so the bar starts hidden here.
  scroll.scrollBarHideable = true
  if scroll.ScrollBar then scroll.ScrollBar:Hide() end
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(1, 1)
  scroll:SetScrollChild(child)
  f.Scroll, f.Child = scroll, child

  f.sections, f.byKey = {}, {}
  for _, def in ipairs(opts.sections or {}) do
    local s = BuildSection(f, def)
    f.sections[#f.sections + 1] = s
    f.byKey[def.key] = s
  end

  local open = opts.expanded or (f.sections[1] and { f.sections[1].key } or {})
  for _, key in ipairs(open) do
    if f.byKey[key] then f.byKey[key].expanded = true end
  end

  f:RestoreState()
  f:SetScript("OnSizeChanged", function(self) self:Relayout() end)
  f:HookScript("OnShow", function(self) self:Relayout() end)
  f:Relayout()
  return f
end
