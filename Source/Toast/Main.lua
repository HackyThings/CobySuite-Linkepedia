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

local toast = CobySuite_CobysLinkepedia.UI.NewToast({
  maxVisible       = 3,
  width            = 260,
  height           = TOAST_HEIGHT,
  gap              = TOAST_GAP,
  defaultDuration  = 5,
  defaultAccentColor = Utilities.Colors.BRAND_TEAL,
  utilities        = Utilities,
  isEnabled = function()
    return Config.Get(Config.Options.CAPTURE_TOAST_ENABLED)
  end,
  position = function(t, index, height, gap)
    local yOffset = (index - 1) * (height + gap)
    t:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -200, 100 + yOffset)
  end,
})

function Toast.Show(title, message, icon)
  toast.Show({
    title = title or "Coby's Linkepedia",
    message = message or "",
    icon = icon,
  })
end

---------------------------------------------------------------------------
-- Listen for ITEM_CAPTURED events
---------------------------------------------------------------------------
local listener = { ReceiveEvent = function(_, eventName, itemID, itemName, link)
  if eventName ~= CobysLinkepedia.Events.ItemCaptured then return end

  local _, _, _, _, icon = C_Item.GetItemInfoInstant(itemID)
  Toast.Show("Variant Captured", itemName, icon)
end }

CobysLinkepedia.EventBus:Register(listener, { CobysLinkepedia.Events.ItemCaptured })

Debug.Log("INIT", "Toast module loaded")
