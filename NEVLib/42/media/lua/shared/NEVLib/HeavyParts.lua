-- NEV Lib: a heavy part uninstalled from an NEV (the range extender, tagged
-- base:heavyitem like the vanilla generator) is carried in both hands, as
-- vanilla does when a generator is picked up. Vanilla's uninstall action puts
-- every part into the main inventory regardless of the tag
-- (ISUninstallVehiclePart.complete), which left 25 kg in a 14 kg backpack
-- (M1 fix test, issue 18).
--
-- Equipping queues vanilla timed actions (ISInventoryPaneContextMenu.
-- equipHeavyItem, a client function); single player only for now - on a
-- dedicated server the part stays in the inventory as in vanilla.
require "NEVLib/Util"
require "NEVLib/Registry"
require "Vehicles/TimedActions/ISUninstallVehiclePart"

local Util, Registry = NEVLib.Util, NEVLib.Registry
local HeavyParts = {}
NEVLib.HeavyParts = HeavyParts

-- Called after the vanilla uninstall finished. Returns true when the item
-- is now being equipped in both hands.
function HeavyParts.afterUninstall(vehicle, item, chr)
    if not vehicle or not item or not chr or not Registry.isNEV(vehicle) then return false end
    if not item:hasTag(ItemTag.HEAVY_ITEM) then return false end
    if not chr:getInventory():contains(item) then return false end -- dropped on the floor: vanilla
    local menu = ISInventoryPaneContextMenu
    if not menu or not menu.equipHeavyItem then return false end
    menu.equipHeavyItem(chr, item)
    Util.log("PART", { event = "heavyEquipped", item = item:getFullType() })
    return true
end

local afterGuarded = Util.guard("heavyParts", HeavyParts.afterUninstall)

local origComplete = ISUninstallVehiclePart.complete
function ISUninstallVehiclePart:complete()
    local item = self.part and self.part:getInventoryItem()
    local r = origComplete(self)
    if item and self.part:getInventoryItem() == nil then afterGuarded(self.vehicle, item, self.character) end
    return r
end

return HeavyParts
