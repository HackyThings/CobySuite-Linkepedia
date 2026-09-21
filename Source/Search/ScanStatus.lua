-- Scan Status: the Results tab's footer with scan controls, progress bar and
-- details (hidden on the other tabs)

local Search = CobysLinkepedia.Search
local Scanner = CobysLinkepedia.Scanner
local Utilities = CobysLinkepedia.Utilities
local Debug = CobysLinkepedia.Debug

local scanStatusFrame = nil
local FOOTER_H = 60

-------------------------------------------------------------------------------
-- Format ETA into human-readable string
-------------------------------------------------------------------------------
local FormatETA = CobysLinkepedia.Utilities.FormatDuration

-------------------------------------------------------------------------------
-- Build scan status footer
-------------------------------------------------------------------------------
function Search.InitScanStatus(window)
  local f = CreateFrame("Frame", nil, window, "BackdropTemplate")
  f:SetHeight(FOOTER_H)
  f:SetPoint("BOTTOMLEFT", 8, 34)
  f:SetPoint("BOTTOMRIGHT", Search.ContentEdge, "BOTTOMRIGHT", 0, 34)  -- left of detail pane
  f:SetBackdrop(Utilities.Backdrops.CONTENT)
  local bg = Utilities.Colors.BAR_BG
  f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])

  ---------------------------------------------------------------------------
  -- Row 1: Progress bar + buttons (top half)
  ---------------------------------------------------------------------------

  -- Progress bar background (stretches, leaves room for buttons)
  f.ProgressBg = f:CreateTexture(nil, "BACKGROUND")
  f.ProgressBg:SetHeight(14)
  f.ProgressBg:SetPoint("TOPLEFT", 8, -6)
  f.ProgressBg:SetPoint("RIGHT", -200, 0)
  f.ProgressBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)

  -- Progress bar fill
  f.ProgressBar = f:CreateTexture(nil, "ARTWORK")
  f.ProgressBar:SetHeight(14)
  f.ProgressBar:SetPoint("TOPLEFT", f.ProgressBg, "TOPLEFT")
  f.ProgressBar:SetColorTexture(0, 0.81, 0.82, 0.8)
  f.ProgressBar:SetWidth(1)

  -- Percentage overlay on the bar
  f.ProgressPct = f:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  f.ProgressPct:SetPoint("CENTER", f.ProgressBg, "CENTER")

  -- Buttons (right side, same row as progress bar). A modifier on Build or
  -- Expand picks the scan intensity: Shift for Boost, Ctrl+Shift for Max
  -- (see INTENSITY_CAPS in the scanner); a plain click follows the Scan
  -- speed setting.
  local function IntensityFromModifiers()
    if IsShiftKeyDown() then
      if IsControlKeyDown() then return "Max" end
      return "Boost"
    end
    return nil
  end

  local KEY = "FFD100"
  local function ScanTooltip(button, header, body)
    local W = CobySuite_CobysLinkepedia.Utilities.WrapColor
    CobySuite_CobysLinkepedia.UI.AddRichTooltip(button, header, {
      body,
      " ",
      W(KEY, "Click") .. ": Normal. Follows your Scan speed setting (50, 100 or 200 items per batch).",
      W(KEY, "Shift+Click") .. ": Boost. 500 items per batch. Faster, with stutter while it runs.",
      W(KEY, "Ctrl+Shift+Click") .. ": Max. 1,000 items per batch. Fastest, with heavy frame drops for the whole scan.",
      " ",
      { text = "Boost and Max cause significant performance problems while the scan runs. Use them when you can leave the game alone; Cancel stops the scan at any time.",
        color = Utilities.Colors.WARNING_RED },
    })
  end

  local buildBtn = Utilities.CreateButton(f, {
    text = "Build", size = { 55, 20 }, fontSize = 11,
    point = { "TOPRIGHT", f, "TOPRIGHT", -6, -3 },
    onClick = function() Scanner.StartBuild(nil, IntensityFromModifiers()) end,
  })
  ScanTooltip(buildBtn, "Build", "Wipes the database and re-scans every item ID from scratch. Use Expand to fill gaps instead.")

  local expandBtn = Utilities.CreateButton(f, {
    text = "Expand", size = { 55, 20 }, fontSize = 11,
    point = { "RIGHT", buildBtn, "LEFT", -4, 0 },
    onClick = function() Scanner.StartExpand(IntensityFromModifiers()) end,
  })
  ScanTooltip(expandBtn, "Expand", "Scans only item IDs not yet in the database; everything already stored is kept.")

  local cancelBtn = Utilities.CreateButton(f, {
    text = "Cancel", size = { 55, 20 }, fontSize = 11,
    point = { "RIGHT", expandBtn, "LEFT", -4, 0 },
    onClick = function() Scanner.Cancel() end,
    tooltip = "Stop the current scan. Items found so far are kept; Expand continues it later.",
  })

  f.BuildBtn = buildBtn
  f.ExpandBtn = expandBtn
  f.CancelBtn = cancelBtn

  -- Idle scan checkbox (visible only when not scanning)
  local Config = CobysLinkepedia.Config
  local idleCB = CobySuite_CobysLinkepedia.UI.CreateCheckbox(f, {
    size       = 22,
    point      = { "RIGHT", cancelBtn, "LEFT", -6, 0 },
    label      = "Idle Scan",
    labelSide  = "left",
    labelGap   = 2,
    labelColor = Utilities.Colors.LABEL_GRAY,
    tooltip    = "Enable slow background scanning of pending items while idle",
    initialValue = Config.Get(Config.Options.IDLE_SCAN_ENABLED) ~= false,
    -- Only writes the option; the scanner starts or stops its ticker from
    -- the ConfigChanged it fires (Scanner.ReconcileIdle)
    onChange = function(enabled)
      Config.Set(Config.Options.IDLE_SCAN_ENABLED, enabled)
    end,
  })
  f.IdleCB = idleCB

  -- Follow the option however it changes (slash, settings, Defaults)
  CobysLinkepedia.EventBus:Register({ ReceiveEvent = function(_, _, key)
    if key == nil or key == Config.Options.IDLE_SCAN_ENABLED then
      idleCB:SetChecked(Config.Get(Config.Options.IDLE_SCAN_ENABLED) ~= false)
    end
  end }, { CobysLinkepedia.Events.ConfigChanged })

  ---------------------------------------------------------------------------
  -- Row 2: Detail text + current item (bottom half)
  ---------------------------------------------------------------------------

  -- Detail line: state | position | items found | rate | ETA
  f.DetailText = f:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  f.DetailText:SetPoint("TOPLEFT", f.ProgressBg, "BOTTOMLEFT", 0, -4)
  f.DetailText:SetPoint("RIGHT", -8, 0)
  f.DetailText:SetJustifyH("LEFT")
  f.DetailText:SetTextColor(unpack(Utilities.Colors.LABEL_GRAY))

  -- Current item line
  f.ItemText = f:CreateFontString(nil, "OVERLAY", Utilities.Fonts.DATA)
  f.ItemText:SetPoint("TOPLEFT", f.DetailText, "BOTTOMLEFT", 0, -2)
  f.ItemText:SetPoint("RIGHT", -8, 0)
  f.ItemText:SetJustifyH("LEFT")
  f.ItemText:SetTextColor(unpack(Utilities.Colors.DISABLED_GRAY))

  ---------------------------------------------------------------------------
  -- Update display
  ---------------------------------------------------------------------------
  function f:UpdateDisplay()
    local status = Scanner.GetStatus()
    if not status then return end

    if status.isActive then
      local pct = status.position / math.max(status.upperBound, 1)
      local barWidth = f.ProgressBg:GetWidth()
      if barWidth > 0 then
        f.ProgressBar:SetWidth(math.max(pct * barWidth, 1))
      end
      f.ProgressPct:SetText(math.floor(pct * 100) .. "%")

      -- Build detail line
      local parts = {}
      if status.state == "PAUSED" then
        table.insert(parts, Utilities.WrapColor("FFD100", "Paused"))
      elseif status.state == "DISCOVER" then
        table.insert(parts, Utilities.WrapColor("00CCFF", "Discovering"))
      elseif status.state == "SCANNING" then
        table.insert(parts, Utilities.WrapColor("00FF00", "Scanning"))
      elseif status.state == "REFINE_WAIT" then
        table.insert(parts, Utilities.WrapColor("FFD100", "Waiting to refine"))
      elseif status.state == "REFINING" then
        table.insert(parts, Utilities.WrapColor("FF8800", "Refining"))
      else
        local mode = status.scanMode or "Scanning"
        table.insert(parts, mode:sub(1,1):upper() .. mode:sub(2))
      end
      if status.intensity and #parts > 0 then
        parts[#parts] = parts[#parts] .. " (" .. status.intensity .. ")"
      end
      table.insert(parts, string.format("%d / %d", status.position, status.upperBound))
      table.insert(parts, status.itemsFound .. " found")
      local rate = status.rate
      if rate > 0 then
        table.insert(parts, math.floor(rate) .. "/s")
        local eta = Scanner.GetETA()
        if eta then
          table.insert(parts, "ETA: " .. FormatETA(eta))
        end
      end
      f.DetailText:SetText(table.concat(parts, "  |  "))

      -- Last found item + phase hint
      local lastItem = ""
      if status.lastFoundName then
        lastItem = "Last: " .. status.lastFoundName .. "  (ID: " .. status.lastFoundID .. ")"
      end
      if status.state == "DISCOVER" then
        f.ItemText:SetText(lastItem ~= "" and lastItem or "Scanning item IDs for validity...")
        f.ItemText:SetTextColor(0.5, 0.7, 0.8)
      elseif status.state == "REFINE_WAIT" then
        f.ItemText:SetText(lastItem ~= "" and (lastItem .. "  |  Waiting for stragglers...") or "Waiting 5s for server stragglers...")
        f.ItemText:SetTextColor(0.7, 0.7, 0.5)
      elseif status.state == "REFINING" then
        f.ItemText:SetText(lastItem ~= "" and (lastItem .. "  |  Refining...") or "Re-querying missed items...")
        f.ItemText:SetTextColor(0.7, 0.5, 0.3)
      else
        f.ItemText:SetText(lastItem)
        f.ItemText:SetTextColor(0.5, 0.7, 0.5)
      end

      f.BuildBtn:Disable()
      f.ExpandBtn:Disable()
      f.CancelBtn:Enable()
      f.IdleCB:Hide()
    else
      f.ProgressBar:SetWidth(1)
      f.ProgressPct:SetText("")
      f.DetailText:SetText("Idle")
      f.DetailText:SetTextColor(unpack(Utilities.Colors.DISABLED_GRAY))
      if status.lastFoundName then
        f.ItemText:SetText("Last: " .. status.lastFoundName .. "  (ID: " .. status.lastFoundID .. ")")
        f.ItemText:SetTextColor(0.4, 0.5, 0.4)
      else
        f.ItemText:SetText("")
        f.ItemText:SetTextColor(unpack(Utilities.Colors.DISABLED_GRAY))
      end

      f.BuildBtn:Enable()
      f.ExpandBtn:Enable()
      f.CancelBtn:Disable()
      f.IdleCB:Show()
    end
  end

  -- Periodic refresh
  f:SetScript("OnUpdate", (CobySuite_CobysLinkepedia.Utilities.Throttle(0.5, function(self)
    self:UpdateDisplay()
  end)))

  scanStatusFrame = f
  Search._scanStatusFrame = f
end

Debug.Log("INIT", "Scan status panel loaded")
