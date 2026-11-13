-- Copyright (c) 2026 熊叔
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.

-- NEV Lib: part names in the mechanics window (DESIGN 9). The vanilla
-- "Engine" part is our drive motor and "Battery" is the traction battery.
-- Their translation keys are shared by every vehicle, so the names are
-- replaced only for NEVs, after vanilla built the list.
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/Armor"
require "NEVLib/RexRepairAction"
require "Vehicles/ISUI/ISVehicleMechanics"

local Util, Registry, Armor = NEVLib.Util, NEVLib.Registry, NEVLib.Armor
local Mechanics = {}
NEVLib.Mechanics = Mechanics

Mechanics.RENAME = {
    Engine = "IGUI_NEV_PartMotor",
    Battery = "IGUI_NEV_PartTractionBattery",
    Radio = "IGUI_NEV_PartScreen", -- infotainment screen (docs/design/cabin/tv-design.md)
}

-- `vehicle` (optional): its armour declaration's own part names win (Armor.nameKey; the pickup's door plates, #273)
function Mechanics.rename(vehicleParts, vehicle)
    for _, cat in pairs(vehicleParts or {}) do
        for _, entry in ipairs(cat.parts or {}) do
            local id = entry.part and entry.part:getId()
            local key = id and ((vehicle and Armor.nameKey(vehicle, id)) or Mechanics.RENAME[id])
            if key then entry.name = Util.text(key) end
        end
    end
end

local orig = ISVehicleMechanics.initParts
local renameGuarded = Util.guard("mechanicsNames", function(self)
    if self.vehicle and Registry.isNEV(self.vehicle) then Mechanics.rename(self.vehiclePart, self.vehicle) end
end)
function ISVehicleMechanics:initParts()
    orig(self)
    renameGuarded(self)
end

-- Besides the list (initParts), the vanilla window names a part by getText("IGUI_VehiclePart" .. id) in the part
-- tooltip of the car overlay (renderCarOverlayTooltip, ISVehicleMechanics.lua:1076) and in the "remove / install /
-- empty X first" lines of an option's tooltip (doMenuTooltip, :809 / :814 / :821; the Cybertruck's windows require
-- the door plates uninstalled). While those two run for a car whose armour names parts itself (declaration `name`,
-- #273 review R1), that key answers the car's own name; every other key, and every other car, is untouched.
local PART_KEY = "IGUI_VehiclePart"

function Mechanics.ownNames(vehicle)
    if not (vehicle and Registry.isNEV(vehicle)) then return nil end
    local own
    for _, a in ipairs(Armor.declOf(vehicle) or {}) do
        if a.name then
            own = own or {}
            own[PART_KEY .. a.part] = a.name
        end
    end
    return own
end

function Mechanics.withOwnNames(vehicle, fn, ...)
    local own = getText and Mechanics.ownNames(vehicle)
    if not own then return fn(...) end
    local shared = getText
    getText = function(key, ...)
        return shared(own[key] or key, ...)
    end
    local ok, result = pcall(fn, ...)
    getText = shared
    if not ok then error(result, 0) end
    return result
end

for _, method in ipairs({ "doMenuTooltip", "renderCarOverlayTooltip" }) do
    local vanilla = ISVehicleMechanics[method]
    if vanilla then
        ISVehicleMechanics[method] = function(self, ...)
            return Mechanics.withOwnNames(self.vehicle, vanilla, self, ...)
        end
    end
end

-- Range extender repair (LEGACY-ISSUES 2 option A, user 2026-10-08 D2):
-- vanilla only offers "Repair Engine" for the part named "Engine"
-- (ISVehicleMechanics.lua:324-340). The same option, with the same conditions,
-- is added for our range extender: engine parts, wrench, Mechanics >= the
-- car's engineRepairLevel, condition < 100. Clicking it does what vanilla's
-- onRepairEngine does, with the library's own action (RexRepairAction.lua):
-- since 42.22 vanilla ISRepairEngine repairs the part named "Engine" only.
Mechanics.REX_PART = NEVRepairRangeExtenderAction.PART

function Mechanics.rexRepairState(chr, part, wrench)
    if not part or part:getId() ~= Mechanics.REX_PART or not part:getInventoryItem() then return nil end
    if VehicleUtils and VehicleUtils.RequiredKeyNotFound and VehicleUtils.RequiredKeyNotFound(part, chr) then
        return nil
    end
    local ok = part:getCondition() < 100
        and chr:getInventory():getNumberOfItem("EngineParts", false, true) > 0
        and chr:getPerkLevel(Perks.Mechanics) >= part:getVehicle():getScript():getEngineRepairLevel()
        and wrench ~= nil
    return ok
end

-- vanilla ISVehicleMechanics.onRepairEngine (42.21 and 42.22 alike: get out, wrench and engine parts to the main
-- inventory, walk to the part, open the hood around the action), queuing the library's action instead
function Mechanics.onRepairRangeExtender(playerObj, part)
    if playerObj:getVehicle() then
        ISVehicleMenu.onExit(playerObj)
    end
    local _, tagToItem = VehicleUtils.getItems(playerObj:getPlayerNum())
    local item = tagToItem[ItemTag.WRENCH][1]
    ISVehiclePartMenu.toPlayerInventory(playerObj, item)
    local parts = playerObj:getInventory():getFirstTypeRecurse("EngineParts")
    ISVehiclePartMenu.toPlayerInventory(playerObj, parts)
    local vehicle = part:getVehicle()
    ISTimedActionQueue.add(ISPathFindAction:pathToVehicleArea(playerObj, vehicle, part:getArea()))
    local engineCover = nil
    local doorPart = vehicle:getPartById("EngineDoor")
    if doorPart and doorPart:getDoor() and doorPart:getInventoryItem() and not doorPart:getDoor():isOpen() then
        engineCover = doorPart
    end
    local time = 300
    if engineCover then
        if engineCover:getDoor():isLocked() and VehicleUtils.RequiredKeyNotFound(engineCover, playerObj) then
            ISTimedActionQueue.add(ISUnlockVehicleDoor:new(playerObj, engineCover))
        end
        ISTimedActionQueue.add(ISOpenVehicleDoor:new(playerObj, vehicle, engineCover))
        ISTimedActionQueue.add(NEVRepairRangeExtenderAction:new(playerObj, part, item, time))
        ISTimedActionQueue.add(ISCloseVehicleDoor:new(playerObj, vehicle, engineCover))
    else
        ISTimedActionQueue.add(NEVRepairRangeExtenderAction:new(playerObj, part, item, time))
    end
end

local origMenu = ISVehicleMechanics.doPartContextMenu
local addRexRepair = Util.guard("rexRepairMenu", function(self, part)
    if not (self.vehicle and Registry.isNEV(self.vehicle)) then return end
    -- vanilla returned early in these cases and built no menu
    if UIManager.getSpeedControls():getCurrentGameSpeed() == 0 then return end
    local playerObj = getSpecificPlayer(self.playerNum)
    if playerObj:getVehicle() ~= nil and not (isDebugEnabled() or (isClient() and (isAdmin() or getAccessLevel() == "moderator"))) then
        return
    end
    local ok = Mechanics.rexRepairState(self.chr, part, ISVehicleMechanics:getWrench(self.chr))
    if ok == nil or not self.context then return end
    local option = self.context:addOption(Util.text("IGUI_NEV_RepairRangeExtender"), playerObj,
        Mechanics.onRepairRangeExtender, part)
    self:doMenuTooltip(part, option, "repairengine")
    if not ok then option.notAvailable = true end
end)
-- I-251 (DESIGN 6.4 revision 15): "charge from the power station" on the traction battery and the gas tank,
-- where vanilla offers its refuelling (user 10-14: "next to the gas tank")
Mechanics.STATION_PARTS = { Battery = true, GasTank = true }
local addStationGive = Util.guard("stationGiveMenu", function(self, part)
    if not (self.vehicle and Registry.isNEV(self.vehicle) and part and Mechanics.STATION_PARTS[part:getId()]) then return end
    if not self.context or not NEVLib.Menu then return end
    NEVLib.Menu.addCarStationOption(self.context, getSpecificPlayer(self.playerNum), self.vehicle)
end)
function ISVehicleMechanics:doPartContextMenu(part, x, y)
    origMenu(self, part, x, y)
    addRexRepair(self, part)
    addStationGive(self, part)
end

return Mechanics
