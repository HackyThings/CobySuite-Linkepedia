---------------------------------------------------------------------------
-- CobySuite Shared Toast Notification Constructor
--
-- Usage:
--   local toast = CobySuite.UI.NewToast({
--     maxVisible    = 5,
--     width         = 280,
--     height        = 50,
--     gap           = 4,
--     defaultDuration = 4,
--     fadeInDuration  = 0.3,
--     fadeOutDuration = 0.5,
--     defaultAccentColor = { r, g, b },
--     utilities     = addonUtilities,  -- for Colors/Fonts
--     position      = function(toast, index, height, gap, offset) ... end,
--     isAvailable   = function() return true end,
--     isEnabled     = function() return true end,
--     chatFallback  = function(title, message) end,
--   })
--   toast.Show({
--     title, message, icon, color, duration,
--     onClick   = function() end,  -- a click on the toast (ignored with buttons)
--     buttons   = { { text, onClick, width, side = "right" }, ... },
--     countdown = true,            -- a bar draining over the time left
--     onExpire  = function() end,  -- only when it times out
--   })
--
-- Returns: { Show(opts), DismissAll(), Suspend(), Resume(), GetCounts(), Visible() }
-- Show returns the toast's frame when it shows at once (nil when it waits
-- or goes to chat); Visible() lists the toast frames on screen, newest first
-- (read only: for a Verify scene to outline one).
--
-- Look (Task #245): the suite's dialog shell (CreateWindow: title bar with
-- the icon and the title in the toast's color, Blizzard's close X, the solid
-- window background), the message in the body font, then the buttons as
-- CreateClickPrompt lays them out (left ones from the bottom-left corner,
-- side = "right" ones from the bottom-right; 110 wide or as wide as the
-- label needs), then the countdown bar with the seconds left. In the DIALOG
-- layer, as a toast may be.
--
-- Buttons: a click dismisses the toast, then runs its onClick; with buttons
-- a click on the body does nothing. The X dismisses and answers nothing;
-- right-click dismisses every toast. onExpire runs only on a timeout.
--
-- Hover: the mouse over any toast freezes every toast of the instance
-- (their bars too) until it leaves them all; one shown meanwhile starts
-- frozen.
--
-- Combat: frames are never made in combat. A toast that needs a new frame,
-- or more buttons than the frame it would reuse has, waits (at most
-- maxVisible, the oldest giving way) and shows when combat ends.
--
-- Capacity: at most maxVisible toasts exist at once. A new one at capacity
-- releases the oldest at once (no fade), so a burst of any size never holds
-- more frames, and at most twice maxVisible idle frames are kept for reuse.
-- While suspended, new toasts wait (at most maxVisible; the oldest waiting
-- one gives way) and appear on Resume with their normal duration.
-- GetCounts() reports { active, visible, pooled, created, queued } (queued
-- counts the toasts waiting for Resume and for combat's end).
--
-- height is the least height: the toast grows to fit its message, buttons
-- and bar, so position stacks on offset (the toasts before it plus gaps),
-- not index.
---------------------------------------------------------------------------
local UI = CobySuite_CobysLinkepedia.UI

-- Layout: the body under the title bar, then the buttons' row, then the
-- bar's row, each with its gap (in the click prompt's spacing)
local L = {
  PAD = 12, BODY_TOP = 32, BOTTOM = 10, ROW_GAP = 8,
  BUTTON_W = 110, BUTTON_GAP = 8, BUTTON_TEXT_ROOM = 32,
  BAR_H = 4, BAR_ROW = 12, LABEL_W = 28,
}

function UI.NewToast(opts)
  local MAX_VISIBLE     = opts.maxVisible or 5
  local TOAST_WIDTH     = opts.width or 280
  local TOAST_HEIGHT    = opts.height or 50
  local TOAST_GAP       = opts.gap or 4
  local DEFAULT_DURATION = opts.defaultDuration or 4
  local FADE_IN         = opts.fadeInDuration or 0.3
  local FADE_OUT        = opts.fadeOutDuration or 0.5
  local utils           = opts.utilities or CobySuite_CobysLinkepedia.Utilities
  local positionFn      = opts.position
  local isAvailableFn   = opts.isAvailable or function() return true end
  local isEnabledFn     = opts.isEnabled or function() return true end
  local chatFallbackFn  = opts.chatFallback

  local TC = utils.Colors or CobySuite_CobysLinkepedia.Utilities.Colors
  local Fonts = utils.Fonts or CobySuite_CobysLinkepedia.Utilities.Fonts
  local BUTTON_H = CobySuite_CobysLinkepedia.Utilities.ButtonSize.MEDIUM.height
  local DEFAULT_ACCENT = opts.defaultAccentColor or TC.STATUS_GOLD

  local pool = {}
  local activeStack = {}
  local queue = {}          -- toasts requested while suspended
  local combatQueue = {}    -- toasts that need frames, waiting for combat's end
  local created = 0         -- frames ever created by this instance
  local POOL_MAX = MAX_VISIBLE * 2
  local isHovered = false
  local isSuspended = false

  -- Forward declarations
  local AcquireToast, ReleaseToast, RepositionStack, DismissToast, ForceRelease, ShowNow
  local FreezeTimers, ThawTimers, StartTimer
  -- inst is forward-declared so CreateToastFrame's right-click handler
  -- can reference it as an upvalue. Without this, Lua resolves `inst`
  -- inside the closure as a global lookup at compile time (since
  -- `local inst = {}` is later in the file), and right-clicking any
  -- toast crashes with "attempt to index global 'inst' (a nil value)".
  local inst

  -------------------------------------------------------------------------
  -- Timer management
  -------------------------------------------------------------------------
  -- A timeout runs the toast's onExpire, then fades it
  StartTimer = function(toast, seconds)
    toast._expireTime = GetTime() + seconds
    toast._dismissTimer = C_Timer.NewTimer(seconds, function()
      toast._dismissTimer = nil
      local onExpire = toast._onExpire
      DismissToast(toast)
      if onExpire then onExpire() end
    end)
  end

  FreezeTimers = function()
    for _, toast in ipairs(activeStack) do
      if toast._dismissTimer then
        toast._remainingTime = math.max(0.1, (toast._expireTime or 0) - GetTime())
        toast._dismissTimer:Cancel()
        toast._dismissTimer = nil
      end
    end
  end

  ThawTimers = function()
    for _, toast in ipairs(activeStack) do
      if toast._remainingTime and toast._remainingTime > 0 then
        StartTimer(toast, toast._remainingTime)
        toast._remainingTime = nil
      end
    end
  end

  local function PauseAll()
    if isHovered then return end
    isHovered = true
    FreezeTimers()
  end

  local function ResumeAll()
    if not isHovered then return end
    isHovered = false
    if not isSuspended then
      ThawTimers()
    end
  end

  -------------------------------------------------------------------------
  -- Countdown bar
  -------------------------------------------------------------------------
  -- The time left: from the running timer, or the frozen remainder while
  -- hovered or suspended
  local function Remaining(f)
    if f._dismissTimer then return math.max(0, (f._expireTime or 0) - GetTime()) end
    return f._remainingTime or 0
  end

  local function PaintBar(f)
    local duration = f._duration or 0
    if duration <= 0 then return end
    local left = Remaining(f)
    local trackWidth = TOAST_WIDTH - 2 * L.PAD - L.LABEL_W
    -- a texture at width 0 can draw at its natural size
    f.barFill:SetWidth(math.max(0.01, trackWidth * math.min(1, left / duration)))
    local seconds = math.ceil(left)
    if seconds ~= f._barSeconds then
      f._barSeconds = seconds
      f.barLabel:SetText(seconds .. "s")
    end
  end

  -------------------------------------------------------------------------
  -- Toast frame factory
  -------------------------------------------------------------------------
  -- Hovering a child (the X, a button) must not count as leaving the toast
  local function KeepHover(child)
    if child.SetPropagateMouseMotion then child:SetPropagateMouseMotion(true) end
  end

  local function CreateToastFrame()
    -- the icon is set per toast; passing one makes the title bar's icon
    local f = UI.CreateWindow({
      width = TOAST_WIDTH, height = TOAST_HEIGHT, strata = "DIALOG",
      movable = false, toplevel = false, icon = 134400, title = "",
    })
    created = created + 1
    f.buttons = {}

    -- Message
    f.message = f:CreateFontString(nil, "OVERLAY", Fonts.BODY)
    f.message:SetPoint("TOPLEFT", f, "TOPLEFT", L.PAD, -L.BODY_TOP)
    f.message:SetWidth(TOAST_WIDTH - 2 * L.PAD)
    f.message:SetJustifyH("LEFT")
    f.message:SetWordWrap(true)

    -- The X dismisses without answering
    if f.CloseButton then
      f.CloseButton:SetScript("OnClick", function() DismissToast(f) end)
      KeepHover(f.CloseButton)
    end

    -- Countdown: a track in the bar gray, the fill in the toast's color,
    -- the seconds left at its right
    f.barTrack = f:CreateTexture(nil, "ARTWORK")
    f.barTrack:SetHeight(L.BAR_H)
    f.barTrack:SetWidth(TOAST_WIDTH - 2 * L.PAD - L.LABEL_W)
    local bg = TC.BAR_BG
    f.barTrack:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    f.barFill = f:CreateTexture(nil, "OVERLAY")
    f.barFill:SetPoint("TOPLEFT", f.barTrack, "TOPLEFT", 0, 0)
    f.barFill:SetPoint("BOTTOMLEFT", f.barTrack, "BOTTOMLEFT", 0, 0)
    f.barLabel = f:CreateFontString(nil, "OVERLAY", Fonts.DATA)
    f.barLabel:SetJustifyH("RIGHT")
    local lg = TC.LABEL_GRAY
    f.barLabel:SetTextColor(lg[1], lg[2], lg[3])
    f.barTrack:Hide()
    f.barFill:Hide()
    f.barLabel:Hide()

    -- Fade in animation (alpha + slide from right)
    f.fadeInAG = f:CreateAnimationGroup()
    local fadeIn = f.fadeInAG:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(FADE_IN)
    fadeIn:SetSmoothing("OUT")
    local slideIn = f.fadeInAG:CreateAnimation("Translation")
    slideIn:SetOffset(-20, 0)
    slideIn:SetDuration(FADE_IN)
    slideIn:SetSmoothing("OUT")
    f.fadeInAG:SetScript("OnFinished", function() f:SetAlpha(1) end)

    -- Fade out animation
    f.fadeOutAG = f:CreateAnimationGroup()
    local fadeOut = f.fadeOutAG:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(FADE_OUT)
    fadeOut:SetSmoothing("IN")
    f.fadeOutAG:SetScript("OnFinished", function()
      -- A toast released early (evicted at capacity) is already back in the
      -- pool, and may be showing something else by now
      if not f._dismissing then return end
      f:SetAlpha(0)
      f:Hide()
      ReleaseToast(f)
    end)

    -- Mouse interaction
    f:SetScript("OnEnter", function() PauseAll() end)
    f:SetScript("OnLeave", function(self)
      if not self:IsMouseOver() then
        ResumeAll()
      end
    end)
    f:SetScript("OnMouseDown", function(self, button)
      if button == "RightButton" then
        inst.DismissAll()
      elseif button == "LeftButton" and self._onClick and not self._dismissing then
        self._onClick()
        DismissToast(self)
      end
    end)

    f:Hide()
    return f
  end

  -- The frame's buttons: made only as needed (never in combat: Place holds
  -- the toast until combat ends when it needs more than a frame has), reused with new text and click
  local function ButtonOnClick(button)
    local f = button:GetParent()
    if f._dismissing then return end
    local onClick = button._onClick
    DismissToast(f)
    if onClick then onClick() end
  end

  local function EnsureButtons(f, count)
    for i = #f.buttons + 1, count do
      local button = UI.CreateButton(f, { size = { L.BUTTON_W, BUTTON_H }, onClick = ButtonOnClick })
      KeepHover(button)
      button:Hide()
      f.buttons[i] = button
    end
  end

  -- Lays out the buttons in CreateClickPrompt's order at the given height
  -- above the bottom edge
  local function LayoutButtons(f, defs, y)
    local lastLeft, lastRight
    for i, def in ipairs(defs) do
      local button = f.buttons[i]
      button:SetText(def.text or "")
      local width = def.width
      if not width then
        width = L.BUTTON_W
        local label = button:GetFontString()
        local needed = label and label:GetStringWidth()
        if type(needed) == "number" and needed + L.BUTTON_TEXT_ROOM > width then width = needed + L.BUTTON_TEXT_ROOM end
      end
      button:SetSize(width, BUTTON_H)
      button:ClearAllPoints()
      if def.side == "right" then
        if lastRight then button:SetPoint("RIGHT", lastRight, "LEFT", -L.BUTTON_GAP, 0)
        else button:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -L.PAD, y) end
        lastRight = button
      else
        if lastLeft then button:SetPoint("LEFT", lastLeft, "RIGHT", L.BUTTON_GAP, 0)
        else button:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", L.PAD, y) end
        lastLeft = button
      end
      button._onClick = def.onClick
      button:Show()
    end
  end

  -------------------------------------------------------------------------
  -- Pool management
  -------------------------------------------------------------------------
  AcquireToast = function()
    return table.remove(pool) or CreateToastFrame()
  end

  -- Whether showing a toast with this many buttons would make a frame:
  -- ShowNow reuses the pool's last frame, or at capacity the oldest toast's
  local function NeedsNewFrames(buttonCount)
    local f = pool[#pool]
    if not f and #activeStack >= MAX_VISIBLE then f = activeStack[#activeStack] end
    return not f or #f.buttons < buttonCount
  end

  ReleaseToast = function(f)
    for i, toast in ipairs(activeStack) do
      if toast == f then
        table.remove(activeStack, i)
        break
      end
    end
    if f._dismissTimer then
      f._dismissTimer:Cancel()
      f._dismissTimer = nil
    end
    f._onClick = nil
    f._onExpire = nil
    f._duration = nil
    f._barSeconds = nil
    f._dismissing = nil
    f._expireTime = nil
    f._remainingTime = nil
    f:SetScript("OnUpdate", nil)
    f.barTrack:Hide()
    f.barFill:Hide()
    f.barLabel:Hide()
    for _, button in ipairs(f.buttons) do
      button._onClick = nil
      button:Hide()
    end
    f.fadeInAG:Stop()
    f.fadeOutAG:Stop()
    f:Hide()
    f:ClearAllPoints()
    -- Frames cannot be destroyed; one past the pool cap simply stays hidden
    if #pool < POOL_MAX then
      table.insert(pool, f)
    end
    RepositionStack()
  end

  -- Releases a toast now, without its fade
  ForceRelease = function(f)
    if f._dismissTimer then
      f._dismissTimer:Cancel()
      f._dismissTimer = nil
    end
    f:SetAlpha(0)
    ReleaseToast(f)
  end

  -------------------------------------------------------------------------
  -- Stack positioning
  -------------------------------------------------------------------------
  -- offset is how far the toasts before this one reach, gaps included
  -- (toasts grow for long messages, so index * height can overlap)
  RepositionStack = function()
    local offset = 0
    for i, toast in ipairs(activeStack) do
      toast:ClearAllPoints()
      if positionFn then
        positionFn(toast, i, TOAST_HEIGHT, TOAST_GAP, offset)
      end
      offset = offset + toast:GetHeight() + TOAST_GAP
    end
  end

  -------------------------------------------------------------------------
  -- Dismiss
  -------------------------------------------------------------------------
  DismissToast = function(f)
    if f._dismissing then return end
    f._dismissing = true
    if f._dismissTimer then
      f._dismissTimer:Cancel()
      f._dismissTimer = nil
    end
    f._remainingTime = nil
    f:SetScript("OnUpdate", nil)
    f.fadeInAG:Stop()
    f.fadeOutAG:Play()
  end

  -------------------------------------------------------------------------
  -- Public instance
  -------------------------------------------------------------------------
  inst = {}

  -- A full waiting list gives up its oldest toast
  local function Enqueue(list, showOpts)
    if #list >= MAX_VISIBLE then table.remove(list, 1) end
    list[#list + 1] = showOpts
  end

  -- Shows a toast now, or keeps it for Resume or for combat's end
  local Place
  local function FlushCombatQueue()
    local waiting = combatQueue
    combatQueue = {}
    for _, showOpts in ipairs(waiting) do
      Place(showOpts)
    end
  end

  Place = function(showOpts)
    if isSuspended then
      Enqueue(queue, showOpts)
      return
    end
    if InCombatLockdown() and NeedsNewFrames(showOpts.buttons and #showOpts.buttons or 0) then
      Enqueue(combatQueue, showOpts)
      CobySuite_CobysLinkepedia.Utilities.RunOutOfCombat(FlushCombatQueue, inst)
      return
    end
    return ShowNow(showOpts)
  end

  function inst.Show(showOpts)
    if not isEnabledFn() then return end

    if not isAvailableFn() then
      if chatFallbackFn then
        chatFallbackFn(showOpts.title or "", showOpts.message or "")
      end
      return
    end

    return Place(showOpts)
  end

  -- The title bar: the icon (hidden without one) and the title in the color
  local function PaintTitle(toast, showOpts, color)
    if toast.TitleText then
      toast.TitleText:SetText(showOpts.title or "")
      toast.TitleText:SetTextColor(color[1], color[2], color[3])
    end
    if toast.TitleIcon then
      if showOpts.icon then
        toast.TitleIcon:SetTexture(showOpts.icon)
        toast.TitleIcon:Show()
      else
        toast.TitleIcon:Hide()
      end
    end
  end

  -- Lays out the buttons and the bar from the bottom edge up and sizes the
  -- toast to fit them under the message (never below the least height)
  local function LayoutBody(toast, showOpts, color)
    local bottom = L.BOTTOM
    if showOpts.countdown then
      toast.barTrack:ClearAllPoints()
      toast.barTrack:SetPoint("BOTTOMLEFT", toast, "BOTTOMLEFT", L.PAD, bottom + (L.BAR_ROW - L.BAR_H) / 2)
      toast.barLabel:ClearAllPoints()
      toast.barLabel:SetPoint("RIGHT", toast, "BOTTOMRIGHT", -L.PAD, bottom + L.BAR_ROW / 2)
      toast.barFill:SetColorTexture(color[1], color[2], color[3], 1)
      toast.barTrack:Show()
      toast.barFill:Show()
      toast.barLabel:Show()
      bottom = bottom + L.BAR_ROW + L.ROW_GAP
    end
    local defs = showOpts.buttons
    if defs and #defs > 0 then
      EnsureButtons(toast, #defs)
      LayoutButtons(toast, defs, bottom)
      bottom = bottom + BUTTON_H + L.ROW_GAP
    end
    local needed = L.BODY_TOP + toast.message:GetStringHeight() + bottom
    toast:SetHeight(math.max(TOAST_HEIGHT, math.ceil(needed)))
  end

  ShowNow = function(showOpts)
    -- At capacity the oldest goes at once, fading or not
    while #activeStack >= MAX_VISIBLE do
      ForceRelease(activeStack[#activeStack])
    end

    local toast = AcquireToast()
    local color = showOpts.color or DEFAULT_ACCENT
    local hasButtons = showOpts.buttons and #showOpts.buttons > 0

    PaintTitle(toast, showOpts, color)
    toast.message:SetText(showOpts.message or "")
    LayoutBody(toast, showOpts, color)

    -- With buttons the answer is a button, so a stray click chooses nothing
    toast._onClick = not hasButtons and showOpts.onClick or nil
    toast._onExpire = showOpts.onExpire

    -- Duration and timer
    local duration = showOpts.duration or DEFAULT_DURATION
    toast._duration = duration
    toast._dismissing = false

    if not isHovered and not isSuspended then
      StartTimer(toast, duration)
    else
      toast._expireTime = GetTime() + duration
      toast._remainingTime = duration
    end

    if showOpts.countdown then
      toast._barSeconds = nil
      PaintBar(toast)
      toast:SetScript("OnUpdate", PaintBar)   -- DismissToast clears it
    end

    -- Insert at top of stack
    table.insert(activeStack, 1, toast)

    -- Show and animate
    toast:SetAlpha(0)
    toast:Show()
    RepositionStack()
    toast.fadeInAG:Play()
    return toast
  end

  function inst.DismissAll()
    wipe(queue)
    wipe(combatQueue)
    for i = #activeStack, 1, -1 do
      DismissToast(activeStack[i])
    end
  end

  function inst.Suspend()
    isSuspended = true
    FreezeTimers()
    for _, toast in ipairs(activeStack) do
      toast:Hide()
    end
  end

  function inst.Resume()
    isSuspended = false
    for _, toast in ipairs(activeStack) do
      toast:Show()
    end
    RepositionStack()
    if not isHovered then
      ThawTimers()
    end
    local waiting = queue
    queue = {}
    for _, showOpts in ipairs(waiting) do
      Place(showOpts)
    end
  end

  function inst.GetCounts()
    local visible = 0
    for _, toast in ipairs(activeStack) do
      if toast:IsShown() then visible = visible + 1 end
    end
    return { active = #activeStack, visible = visible, pooled = #pool, created = created, queued = #queue + #combatQueue }
  end

  function inst.Visible()
    local list = {}
    for _, toast in ipairs(activeStack) do
      if toast:IsShown() then list[#list + 1] = toast end
    end
    return list
  end

  return inst
end
