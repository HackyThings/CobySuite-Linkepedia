-------------------------------------------------------------------------------
-- CobySuite.UI tabs: CreateTabs and CreateBottomTabs
--
-- A row of tabs over a page (CreateTabs) or hanging under a window's bottom
-- edge (CreateBottomTabs). Split out of Dashboard.lua (Task #382), so an
-- addon that shows tabs carries only this file in its release, not the
-- sidebar, banner and copy box. Build them out of combat: each makes its
-- frames when it is called, and SetTabs reuses the buttons it has and only
-- makes more for a longer list.
--
--   local tabs = CobySuite.UI.CreateTabs(parent, {
--     point = { "TOPLEFT", banner, "BOTTOMLEFT", 0, -4 },
--     tabs = { { key = "steps", text = "Steps" }, { key = "results", text = "Results", tooltip = "..." } },
--     onSelect = function(key) ... end,
--   })
--   tabs:Select("results")  tabs:SetBadge("results", "3")  tabs:SetEnabled("results", false)
--
--   local pages = CobySuite.UI.CreateBottomTabs(window, {     -- the same tabs, hanging under a window
--     tabs = { { key = "tests", text = "Tests" }, { key = "verify", text = "Verify" } },
--     onSelect = function(key) ... end,
--   })
--
-- Tabs: Blizzard's PanelTopTabButtonTemplate, sized with
-- PanelTemplates_TabResize and marked with PanelTemplates_SetTab, as the
-- Verify panel and Recollect's curator dashboard did by hand. The tabs frame
-- is the holder PanelTemplates needs (its Tabs list and numTabs), so the
-- caller anchors it like any frame. A disabled tab cannot be selected. The
-- first tab starts selected, without calling onSelect. opts.template and
-- opts.gap pick another tab template and the space between tabs; opts.name
-- names the holder (each button is <name>Tab<i>), else CobySuiteTabs<n>.
--
-- Bottom tabs: CreateBottomTabs is CreateTabs with Blizzard's
-- PanelTabButtonTemplate, the tabs hanging under the window's bottom edge
-- (their tops inside its border strip, as Blizzard's own windows and
-- Linkepedia's search window do). The window's bottom border is moved onto
-- an overlay above the tabs, so it covers their tops; the overlay holds
-- nothing else and takes no mouse input. Same methods as CreateTabs.
-------------------------------------------------------------------------------
local UI = CobySuite_CobysLinkepedia.UI

local TABS_H, TAB_GAP = 32, 4
local tabsMade = 0

local Tabs = {}

-- The tab's text with its badge: "Failures (3)"
local function TabText(tab)
  if tab.badge ~= nil and tab.badge ~= "" then return tab.label .. " (" .. tab.badge .. ")" end
  return tab.label
end

function Tabs:IndexOf(key)
  for i, tab in ipairs(self.Tabs) do
    if tab:IsShown() and tab.key == key then return i end
  end
end

function Tabs:Paint(i)
  local tab = self.Tabs[i]
  tab:SetText(TabText(tab))
  PanelTemplates_TabResize(tab, 0)
end

-- Sets the tab buttons in a row and the holder's width to fit them
function Tabs:Layout()
  local previous, width = nil, 0
  for i = 1, self.numTabs do
    local tab = self.Tabs[i]
    tab:ClearAllPoints()
    if previous then
      tab:SetPoint("LEFT", previous, "RIGHT", self.gap, 0)
      width = width + self.gap
    else
      tab:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
    end
    width = width + tab:GetWidth()
    previous = tab
  end
  self:SetWidth(math.max(1, width))
end

-- SetTabs(list): { { key, text, tooltip? }, ... }. The buttons are reused;
-- the selected key stays selected when it is still listed, else the first tab
-- is selected and onSelect hears it. Out of combat, as the buttons are made
-- when the list is longer than any before.
function Tabs:SetTabs(list)
  list = list or {}
  local before = self.selected
  for i, def in ipairs(list) do
    local tab = self.Tabs[i]
    if not tab then
      tab = CreateFrame("Button", self.name .. "Tab" .. i, self, self.template)
      tab:SetID(i)
      tab:SetScript("OnClick", function(button) self:Select(button.key) end)
      self.Tabs[i] = tab
    end
    tab.key, tab.label, tab.badge, tab.enabled = def.key, def.text or def.key, nil, true
    tab.isDisabled = nil
    tab:Show()
    if def.tooltip then
      UI.AddTooltip(tab, def.tooltip)
      tab.hasTip = true
    elseif tab.hasTip then
      tab:SetScript("OnEnter", nil)
      tab:SetScript("OnLeave", nil)
      tab.hasTip = false
    end
    self:Paint(i)
  end
  for i = #list + 1, #self.Tabs do
    self.Tabs[i].key = nil
    self.Tabs[i]:Hide()
  end
  self.numTabs = #list
  self:Layout()
  self.selected = nil
  if before and self:IndexOf(before) then
    self:Select(before, true, true)
  elseif #list > 0 then
    self:Select(list[1].key, true, before == nil)
  end
end

-- Select(key, force): false for a key that is not listed or whose tab is
-- disabled, or already selected (unless force); else true after the tab is
-- marked and, unless quiet, onSelect(key) has run
function Tabs:Select(key, force, quiet)
  local i = self:IndexOf(key)
  if not i or not self.Tabs[i].enabled then return false end
  if self.selected == key and not force then return false end
  self.selected = key
  PanelTemplates_SetTab(self, i)
  if not quiet and self.opts.onSelect then self.opts.onSelect(key) end
  return true
end

function Tabs:GetSelected() return self.selected end

function Tabs:SetEnabled(key, enabled)
  local i = self:IndexOf(key)
  if not i then return false end
  local tab = self.Tabs[i]
  tab.enabled = enabled and true or false
  -- the look only (Select and a click read tab.enabled); looked up per use, and
  -- skipped where a client has no such template function
  local mark = tab.enabled and PanelTemplates_EnableTab or PanelTemplates_DisableTab
  if mark then mark(self, i) end
  return true
end

-- SetBadge(key, text): "3" reads "Failures (3)"; nil or "" removes it
function Tabs:SetBadge(key, text)
  local i = self:IndexOf(key)
  if not i then return false end
  self.Tabs[i].badge = text ~= nil and tostring(text) or nil
  self:Paint(i)
  self:Layout()
  return true
end

function UI.CreateTabs(parent, opts)
  opts = opts or {}
  tabsMade = tabsMade + 1
  local f = CreateFrame("Frame", opts.name, parent)
  Mixin(f, Tabs)
  f.opts = opts
  f.name = opts.name or ("CobySuiteTabs" .. tabsMade)
  f.template = opts.template or "PanelTopTabButtonTemplate"
  f.gap = opts.gap or TAB_GAP
  f.Tabs, f.numTabs = {}, 0
  f:SetHeight(TABS_H)
  if opts.point then f:SetPoint(unpack(opts.point)) end
  f:SetTabs(opts.tabs)
  return f
end

-- The tabs under a window (see the header): opts as CreateTabs takes them,
-- placed under the window's bottom-left corner unless opts.point says
function UI.CreateBottomTabs(window, opts)
  local o = {}
  for k, v in pairs(opts or {}) do o[k] = v end
  o.template = o.template or "PanelTabButtonTemplate"
  o.gap = o.gap or 0
  o.point = o.point or { "TOPLEFT", window, "BOTTOMLEFT", 15, 3 }
  local f = UI.CreateTabs(window, o)
  local level = f:GetFrameLevel()
  for _, tab in ipairs(f.Tabs) do level = math.max(level, tab:GetFrameLevel()) end
  local overlay = CreateFrame("Frame", nil, window)
  overlay:SetAllPoints(window)
  overlay:SetFrameLevel(level + 1)
  -- the left corner and the edge; the right corner stays with the resize grip
  if window.BotLeftCorner then window.BotLeftCorner:SetParent(overlay) end
  if window.BottomBorder then window.BottomBorder:SetParent(overlay) end
  f.Overlay = overlay
  return f
end
