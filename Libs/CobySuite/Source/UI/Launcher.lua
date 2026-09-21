---------------------------------------------------------------------------
-- CobySuite.UI.CreateLauncher: the ways into an addon from outside its own
-- windows, all routed to the same actions and the same branded tooltip:
--
--   * a minimap button (the tracking-border ring with the addon's icon),
--     dragged around the minimap with its angle saved to the addon's table;
--   * a LibDataBroker launcher, when LibDataBroker-1.1 is loaded;
--   * handlers for the addon compartment, which the TOC's global
--     AddonCompartmentFunc / FuncOnEnter / FuncOnLeave functions call.
--
--   local launcher = CobySuite.UI.CreateLauncher({
--     name    = "MyAddon",                    -- LDB object name; the button is <name>MinimapButton
--     label   = "My Addon",                   -- LDB label (default name)
--     icon    = "Interface\\Icons\\INV_Misc_Book_09",
--     tooltip = { brandColor = "00CFD0", title = "My Addon", body = ..., keys = ... },
--                                             -- PopulateBrandedTooltip opts, or a function returning them
--     onLeftClick  = function(button) end,    -- also a compartment click with no button name
--     onRightClick = function(button) end,
--     persist = { svTable = function() return MY_ADDON_WINDOW_STATE end,   -- or the table
--                 key = "minimapAngle", defaultAngle = 220 },               -- degrees
--     isShown = function() return Config.Get("showMinimapButton") ~= false end,  -- default: always
--     minimapButton = true,                   -- false: no minimap button
--     broker        = true,                   -- false: no LibDataBroker object
--     radius        = 80,                     -- button centre from the minimap centre
--     buttonTooltipAnchor      = "ANCHOR_LEFT",
--     compartmentTooltipAnchor = "ANCHOR_RIGHT",
--   })
--
--   launcher:Initialize()          -- at PLAYER_LOGIN or later; safe to call again
--   launcher:RefreshShown()        -- re-reads isShown (after a settings change)
--   launcher:SetAngle(degrees)     -- moves the button and saves the angle
--   launcher:OnCompartmentClick(buttonName)
--   launcher:OnCompartmentEnter(menuItem)
--   launcher:OnCompartmentLeave()
--   launcher.Button                -- the minimap button, once initialised
--   launcher.DataObject            -- the LDB object, when registered
--
-- The TOC globals stay in the addon (their names are the addon's), each a
-- one-line call:
--   function MyAddon_OnAddonCompartmentClick(_, button) launcher:OnCompartmentClick(button) end
--   function MyAddon_OnAddonCompartmentEnter(_, menuItem) launcher:OnCompartmentEnter(menuItem) end
--   function MyAddon_OnAddonCompartmentLeave() launcher:OnCompartmentLeave() end
--
-- Nothing is created until Initialize, so building the launcher at file
-- load is free; Initialize is expected outside combat, like any frame
-- creation in the suite.
---------------------------------------------------------------------------
local UI = CobySuite_CobysLinkepedia.UI

local BUTTON_SIZE = 32
local DEFAULT_RADIUS = 80
local DEFAULT_ANGLE = 220
local BORDER_TEXTURE = "Interface\\Minimap\\MiniMap-TrackingBorder"
local HIGHLIGHT_TEXTURE = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"

local LauncherMixin = {}

local function ResolveSV(persist)
  local sv = persist and persist.svTable
  if type(sv) == "function" then sv = sv() end
  return type(sv) == "table" and sv or nil
end

local IsFiniteNumber = CobySuite_CobysLinkepedia.Utilities.IsFiniteNumber

-- The branded tooltip opts for one showing, with an owner when given; a
-- copy, so the consumer's table never gains an owner
function LauncherMixin:TooltipOpts(owner, anchor)
  local source = self._opts.tooltip
  if type(source) == "function" then source = source() end
  local opts = {}
  if type(source) == "table" then
    for k, v in pairs(source) do opts[k] = v end
  end
  opts.owner = owner
  opts.anchor = anchor
  return opts
end

function LauncherMixin:Click(button)
  local opts = self._opts
  if button == "RightButton" then
    if opts.onRightClick then opts.onRightClick(button) end
  elseif button == "LeftButton" or button == nil then
    if opts.onLeftClick then opts.onLeftClick(button) end
  end
end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------
function LauncherMixin:GetAngle()
  local persist = self._opts.persist
  local sv = ResolveSV(persist)
  local saved = sv and sv[persist.key or "minimapAngle"]
  if IsFiniteNumber(saved) then return saved end
  local default = persist and persist.defaultAngle
  return IsFiniteNumber(default) and default or DEFAULT_ANGLE
end

function LauncherMixin:PositionButton(angle)
  local button = self.Button
  if not button then return end
  local radius = self._opts.radius or DEFAULT_RADIUS
  local rads = math.rad(angle)
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(rads) * radius, math.sin(rads) * radius)
end

function LauncherMixin:SetAngle(angle)
  if not IsFiniteNumber(angle) then return end
  self:PositionButton(angle)
  local persist = self._opts.persist
  local sv = ResolveSV(persist)
  if sv then sv[persist.key or "minimapAngle"] = angle end
end

local function AngleFromCursor()
  local cx, cy = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  local mx, my = Minimap:GetCenter()
  return math.deg(math.atan2(cy - my * scale, cx - mx * scale))
end

function LauncherMixin:CreateButton()
  if self.Button then return self.Button end
  local launcher = self
  local opts = self._opts

  local btn = CreateFrame("Button", opts.buttonName or (opts.name .. "MinimapButton"), Minimap)
  btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)
  btn:SetClampedToScreen(true)

  local border = btn:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetTexture(BORDER_TEXTURE)
  border:SetPoint("TOPLEFT")

  local icon = btn:CreateTexture(nil, "BACKGROUND")
  icon:SetSize(20, 20)
  icon:SetTexture(opts.icon)
  icon:SetPoint("CENTER", -1, 1)
  btn.Icon = icon

  local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetSize(24, 24)
  highlight:SetTexture(HIGHLIGHT_TEXTURE)
  highlight:SetBlendMode("ADD")
  highlight:SetPoint("CENTER")

  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:SetScript("OnClick", function(_, button) launcher:Click(button) end)

  local anchor = opts.buttonTooltipAnchor or "ANCHOR_LEFT"
  btn:SetScript("OnEnter", function(frame)
    UI.PopulateBrandedTooltip(GameTooltip, launcher:TooltipOpts(frame, anchor))
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Drag around the minimap; the angle is saved as it moves
  btn:RegisterForDrag("LeftButton")
  btn:SetScript("OnDragStart", function(frame)
    frame.isDragging = true
    frame:SetScript("OnUpdate", function() launcher:SetAngle(AngleFromCursor()) end)
  end)
  btn:SetScript("OnDragStop", function(frame)
    frame.isDragging = false
    frame:SetScript("OnUpdate", nil)
    launcher:SetAngle(AngleFromCursor())
  end)

  self.Button = btn
  return btn
end

function LauncherMixin:RefreshShown()
  if not self.Button then return end
  local isShown = self._opts.isShown
  self.Button:SetShown(isShown == nil or isShown() ~= false)
end

---------------------------------------------------------------------------
-- LibDataBroker
---------------------------------------------------------------------------
function LauncherMixin:RegisterBroker()
  if self.DataObject then return self.DataObject end
  local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
  if not LDB then return nil end
  local launcher = self
  local opts = self._opts
  self.DataObject = LDB:NewDataObject(opts.name, {
    type = "launcher",
    label = opts.label or opts.name,
    icon = opts.icon,
    OnClick = function(_, button) launcher:Click(button) end,
    OnTooltipShow = function(tooltip)
      UI.PopulateBrandedTooltip(tooltip, launcher:TooltipOpts())
    end,
  })
  return self.DataObject
end

---------------------------------------------------------------------------
-- Lifecycle and the addon compartment
---------------------------------------------------------------------------
function LauncherMixin:Initialize()
  local opts = self._opts
  if opts.minimapButton ~= false then
    self:CreateButton()
    self:PositionButton(self:GetAngle())
    self:RefreshShown()
  end
  if opts.broker ~= false then
    self:RegisterBroker()
  end
end

function LauncherMixin:OnCompartmentClick(button)
  self:Click(button)
end

function LauncherMixin:OnCompartmentEnter(menuItem)
  local anchor = self._opts.compartmentTooltipAnchor or "ANCHOR_RIGHT"
  UI.PopulateBrandedTooltip(GameTooltip, self:TooltipOpts(menuItem, anchor))
end

function LauncherMixin:OnCompartmentLeave()
  GameTooltip:Hide()
end

function UI.CreateLauncher(opts)
  assert(opts and opts.name, "CreateLauncher needs opts.name")
  return Mixin({ _opts = opts }, LauncherMixin)
end
