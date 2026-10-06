---------------------------------------------------------------------------
-- CobysLinkepedia Toast: uses shared CobySuite.UI.NewToast constructor
-- Keeps addon-specific event listener for ItemCaptured
---------------------------------------------------------------------------
local Toast = CobysLinkepedia.Toast
local Config = CobysLinkepedia.Config
local Debug = CobysLinkepedia.Debug
local Utilities = CobysLinkepedia.Utilities

local TOAST_HEIGHT = 44
local TOAST_GAP = 4

-- True only while ShowSample shows its one notice, so the settings
-- window's sample appears whatever the notices setting says
local showingSample = false

local toast = CobySuite_CobysLinkepedia.UI.NewToast({
  maxVisible       = 3,
  width            = 260,
  height           = TOAST_HEIGHT,
  gap              = TOAST_GAP,
  defaultDuration  = 5,
  defaultAccentColor = Utilities.Colors.BRAND_TEAL,
  utilities        = Utilities,
  isEnabled = function()
    return showingSample or Config.Get(Config.Options.CAPTURE_TOAST_ENABLED)
  end,
  position = function(t, index, height, gap, offset)
    t:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -200, 100 + offset)
  end,
})

-- Returns the notice's frame, or nil when none went up (notices off, or it
-- waits for combat to end)
function Toast.Show(title, message, icon)
  return toast.Show({
    title = title or "Coby's Linkepedia",
    message = message or "",
    icon = icon,
  })
end

-- One notice now, whatever the notices setting says (the settings window's
-- Show sample notice button); returns its frame, as Show does
function Toast.ShowSample(title, message, icon)
  showingSample = true
  local ok, frame = pcall(Toast.Show, title, message, icon)
  showingSample = false
  if not ok then error(frame, 0) end
  return frame
end

function Toast.DismissAll()
  toast.DismissAll()
end

---------------------------------------------------------------------------
---------------------------------------------------------------------------
local listener = { ReceiveEvent = function(_, _, itemID, itemName)
  local _, _, _, _, icon = C_Item.GetItemInfoInstant(itemID)
  Toast.Show("Variant Captured", itemName, icon)
end }

CobysLinkepedia.EventBus:Register(listener, { CobysLinkepedia.Events.ItemCaptured })

Debug.Log("INIT", "Toast module loaded")
