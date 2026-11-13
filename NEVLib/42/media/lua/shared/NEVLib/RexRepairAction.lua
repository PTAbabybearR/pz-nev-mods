-- Copyright (c) 2026 熊叔
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.
-- Parts of this file reuse Project Zomboid content, (c) The Indie Stone; those
-- parts are not covered by this licence. See NOTICE.txt.

-- NEV Lib: "Repair range extender" (DESIGN 9, LEGACY-ISSUES 2 option A, user 2026-10-08 D2), the library's own
-- action since 42.22. Until 42.21 the mechanics menu queued vanilla ISRepairEngine on our NEVRangeExtender part:
-- its complete() repaired whatever part it was given. 42.22 added
--   if not self.part or self.part:getId() ~= "Engine" then print('no such part Engine') return false end
-- (ISRepairEngine.lua:39), so on the range extender the bar ran to the end and nothing changed (#372 item 1).
-- This action is vanilla's in every other respect: it derives from ISRepairEngine (start / update / duration /
-- animation and new() are vanilla's) and complete() is vanilla's 42.21 / 42.22 body (lines 37-89, the same in both
-- builds except the part check) for our part: condition per Engine Parts item 1 + (Mechanics - engineRepairLevel) / 2,
-- at most 5, up to 100; the parts used are taken; XP and the mechanics-item records as vanilla.
--
-- A B42 network timed action, like NEVConnectChargerAction: in multiplayer the server rebuilds it from the client's
-- fields named like new()'s parameters (character, part, item, maxTimeInit: vanilla's new(), inherited) and runs
-- complete() there; in single player complete() runs right after perform(). So it lives in shared/ under a global
-- name. 42.22 also requires the action's character to be the sending player (NetTimedActionPacket.processServer):
-- the menu passes the clicking player, as vanilla.
require "TimedActions/ISBaseTimedAction"
require "Vehicles/TimedActions/ISRepairEngine"
require "NEVLib/Parts"

NEVRepairRangeExtenderAction = ISRepairEngine:derive("NEVRepairRangeExtenderAction")

NEVRepairRangeExtenderAction.PART = NEVLib.Parts.REX_ID

function NEVRepairRangeExtenderAction:complete()
    if not self.vehicle then
        print("NEV: no such vehicle id=", self.vehicle)
        return false
    end
    if not self.part or self.part:getId() ~= NEVRepairRangeExtenderAction.PART then
        print("NEV: no such part " .. NEVRepairRangeExtenderAction.PART)
        return false
    end

    local skill = self.character:getPerkLevel(Perks.Mechanics) - self.vehicle:getScript():getEngineRepairLevel()
    local numberOfParts = self.character:getInventory():getNumberOfItem("EngineParts", false, true)
    local giveXP = self.character:getMechanicsItem(self.part:getVehicle():getMechanicalID() .. "2") == nil

    local condPerPart = 1 + (skill / 2)
    if condPerPart > 5 then condPerPart = 5 end
    local done = 0
    for _ = 1, numberOfParts do
        self.part:setCondition(self.part:getCondition() + condPerPart)
        done = done + 1
        if self.part:getCondition() >= 100 then
            self.part:setCondition(100)
            break
        end
    end
    if done > 0 then
        if giveXP then
            addXp(self.character, Perks.Mechanics, done)
        end
        local itemsToRemove = self.character:getInventory():getSomeTypeRecurse("EngineParts", done)
        for i = 0, itemsToRemove:size() - 1 do
            local item = itemsToRemove:get(i)
            local container = item:getContainer()
            if item and container then
                container:DoRemoveItem(item)
                sendRemoveItemFromContainer(container, item)
            end
        end
        self.vehicle:transmitPartCondition(self.part)
    else
        addXp(self.character, Perks.Mechanics, 1)
    end
    self.character:sendObjectChange(IsoObjectChange.MECHANIC_ACTION_DONE, { success = (done > 0) })
    if done > 0 then
        self.character:addMechanicsItem(self.item:getID() .. self.vehicle:getMechanicalID() .. "1", self.part,
            getGameTime():getCalender():getTimeInMillis())
    else
        addXp(self.character, Perks.Mechanics, 1)
    end
    self.character:addMechanicsItem(self.part:getVehicle():getMechanicalID() .. "2", self.part,
        getGameTime():getCalender():getTimeInMillis())
    return true
end

return NEVRepairRangeExtenderAction
