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
--     utilities     = addonUtilities,  -- for Colors/Fonts/Backdrops
--     position      = function(toast, index, height, gap) ... end,
--     isAvailable   = function() return true end,
--     isEnabled     = function() return true end,
--     chatFallback  = function(title, message) end,
--   })
--
-- Returns: { Show(opts), DismissAll(), Suspend(), Resume(), GetCounts() }
--
-- Capacity: at most maxVisible toasts exist at once. A new one at capacity
-- releases the oldest at once (no fade), so a burst of any size never holds
-- more frames, and at most twice maxVisible idle frames are kept for reuse.
-- While suspended, new toasts wait (at most maxVisible; the oldest waiting
-- one gives way) and appear on Resume with their normal duration.
-- GetCounts() reports { active, visible, pooled, created, queued }.
---------------------------------------------------------------------------
local UI = CobySuite_CobysLinkepedia.UI

function UI.NewToast(opts)
  local MAX_VISIBLE     = opts.maxVisible or 5
  local TOAST_WIDTH     = opts.width or 280
  local TOAST_HEIGHT    = opts.height or 50
  local TOAST_GAP       = opts.gap or 4
  local DEFAULT_DURATION = opts.defaultDuration or 4
  local FADE_IN         = opts.fadeInDuration or 0.3
  local FADE_OUT        = opts.fadeOutDuration or 0.5
  local DEFAULT_ACCENT  = opts.defaultAccentColor or { 0.5, 0.5, 0.5 }
  local utils           = opts.utilities or CobySuite_CobysLinkepedia.Utilities
  local positionFn      = opts.position
  local isAvailableFn   = opts.isAvailable or function() return true end
  local isEnabledFn     = opts.isEnabled or function() return true end
  local chatFallbackFn  = opts.chatFallback

  local TC = utils.Colors or CobySuite_CobysLinkepedia.Utilities.Colors
  local Fonts = utils.Fonts or CobySuite_CobysLinkepedia.Utilities.Fonts
  local Backdrops = utils.Backdrops or CobySuite_CobysLinkepedia.Utilities.Backdrops

  local pool = {}
  local activeStack = {}
  local queue = {}          -- toasts requested while suspended
  local created = 0         -- frames ever created by this instance
  local POOL_MAX = MAX_VISIBLE * 2
  local isHovered = false
  local isSuspended = false

  -- Forward declarations
  local AcquireToast, ReleaseToast, RepositionStack, DismissToast, ForceRelease, ShowNow
  local FreezeTimers, ThawTimers
  -- inst is forward-declared so CreateToastFrame's right-click handler
  -- can reference it as an upvalue. Without this, Lua resolves `inst`
  -- inside the closure as a global lookup at compile time (since
  -- `local inst = {}` is later in the file), and right-clicking any
  -- toast crashes with "attempt to index global 'inst' (a nil value)".
  local inst

  -------------------------------------------------------------------------
  -- Timer management
  -------------------------------------------------------------------------
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
        toast._expireTime = GetTime() + toast._remainingTime
        toast._dismissTimer = C_Timer.NewTimer(toast._remainingTime, function()
          toast._dismissTimer = nil
          DismissToast(toast)
        end)
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
  -- Toast frame factory
  -------------------------------------------------------------------------
  local function CreateToastFrame()
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    created = created + 1
    f:SetSize(TOAST_WIDTH, TOAST_HEIGHT)
    f:SetBackdrop(Backdrops.CONTENT)
    local tbg = TC.TOAST_BG
    f:SetBackdropColor(tbg[1], tbg[2], tbg[3], tbg[4])
    local cbr = TC.CONTENT_BORDER
    f:SetBackdropBorderColor(cbr[1], cbr[2], cbr[3], cbr[4])
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)

    -- Accent strip
    f.accent = f:CreateTexture(nil, "OVERLAY")
    f.accent:SetPoint("TOPLEFT", 3, -3)
    f.accent:SetPoint("BOTTOMLEFT", 3, 3)
    f.accent:SetWidth(3)

    -- Icon
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(22, 22)
    f.icon:SetPoint("LEFT", f.accent, "RIGHT", 6, 0)

    -- Title
    f.title = f:CreateFontString(nil, "OVERLAY", Fonts.SMALL)
    f.title:SetJustifyH("LEFT")

    -- Message
    f.message = f:CreateFontString(nil, "OVERLAY", Fonts.DATA)
    f.message:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -2)
    f.message:SetPoint("RIGHT", f, "RIGHT", -22, 0)
    f.message:SetJustifyH("LEFT")
    local lg = TC.LIGHT_GRAY
    f.message:SetTextColor(lg[1], lg[2], lg[3])

    -- Close button
    f.closeBtn = CreateFrame("Button", nil, f)
    f.closeBtn:SetSize(14, 14)
    f.closeBtn:SetPoint("TOPRIGHT", -4, -4)
    f.closeBtn:SetPropagateMouseMotion(true)
    local closeText = f.closeBtn:CreateFontString(nil, "OVERLAY", Fonts.SMALL)
    closeText:SetAllPoints()
    closeText:SetText("\195\151")
    local dg = TC.DISABLED_GRAY
    closeText:SetTextColor(dg[1], dg[2], dg[3])
    f.closeBtn:SetScript("OnClick", function() DismissToast(f) end)
    f.closeBtn:SetScript("OnEnter", function() closeText:SetTextColor(1, 1, 1) end)
    f.closeBtn:SetScript("OnLeave", function() closeText:SetTextColor(dg[1], dg[2], dg[3]) end)

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
      elseif button == "LeftButton" and self._onClick then
        self._onClick()
        DismissToast(self)
      end
    end)

    f:Hide()
    return f
  end

  -------------------------------------------------------------------------
  -- Pool management
  -------------------------------------------------------------------------
  AcquireToast = function()
    return table.remove(pool) or CreateToastFrame()
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
    f._dismissing = nil
    f._expireTime = nil
    f._remainingTime = nil
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
  RepositionStack = function()
    for i, toast in ipairs(activeStack) do
      toast:ClearAllPoints()
      if positionFn then
        positionFn(toast, i, TOAST_HEIGHT, TOAST_GAP)
      end
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
    f.fadeInAG:Stop()
    f.fadeOutAG:Play()
  end

  -------------------------------------------------------------------------
  -- Public instance
  -------------------------------------------------------------------------
  -- Assignment, not redeclaration: `inst` is forward-declared above so
  -- CreateToastFrame's right-click handler resolves it as an upvalue.
  inst = {}

  function inst.Show(showOpts)
    if not isEnabledFn() then return end

    if not isAvailableFn() then
      if chatFallbackFn then
        chatFallbackFn(showOpts.title or "", showOpts.message or "")
      end
      return
    end

    if isSuspended then
      if #queue >= MAX_VISIBLE then table.remove(queue, 1) end
      queue[#queue + 1] = showOpts
      return
    end

    ShowNow(showOpts)
  end

  ShowNow = function(showOpts)
    -- At capacity the oldest goes at once, fading or not
    while #activeStack >= MAX_VISIBLE do
      ForceRelease(activeStack[#activeStack])
    end

    local toast = AcquireToast()

    -- Content
    toast.title:SetText(showOpts.title or "")
    toast.message:SetText(showOpts.message or "")

    -- Icon
    toast.title:ClearAllPoints()
    if showOpts.icon then
      toast.icon:SetTexture(showOpts.icon)
      toast.icon:Show()
      toast.title:SetPoint("TOPLEFT", toast.icon, "TOPRIGHT", 6, -4)
      toast.title:SetPoint("RIGHT", toast, "RIGHT", -22, 0)
    else
      toast.icon:Hide()
      toast.title:SetPoint("TOPLEFT", toast.accent, "TOPRIGHT", 8, -4)
      toast.title:SetPoint("RIGHT", toast, "RIGHT", -22, 0)
    end

    -- Accent color
    local color = showOpts.color or DEFAULT_ACCENT
    toast.accent:SetColorTexture(color[1], color[2], color[3], 1)
    toast.title:SetTextColor(color[1], color[2], color[3])

    -- Click handler
    toast._onClick = showOpts.onClick

    -- Duration and timer
    local duration = showOpts.duration or DEFAULT_DURATION
    toast._expireTime = GetTime() + duration
    toast._dismissing = false

    if not isHovered and not isSuspended then
      toast._dismissTimer = C_Timer.NewTimer(duration, function()
        toast._dismissTimer = nil
        DismissToast(toast)
      end)
    else
      toast._remainingTime = duration
    end

    -- Insert at top of stack
    table.insert(activeStack, 1, toast)

    -- Show and animate
    toast:SetAlpha(0)
    toast:Show()
    RepositionStack()
    toast.fadeInAG:Play()
  end

  function inst.DismissAll()
    wipe(queue)
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
      ShowNow(showOpts)
    end
  end

  function inst.GetCounts()
    local visible = 0
    for _, toast in ipairs(activeStack) do
      if toast:IsShown() then visible = visible + 1 end
    end
    return { active = #activeStack, visible = visible, pooled = #pool, created = created, queued = #queue }
  end

  return inst
end
