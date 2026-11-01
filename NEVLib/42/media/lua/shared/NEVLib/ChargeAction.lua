-- NEV Lib: "plug in the charger" (DESIGN 6.1, user decision 2026-10-07).
-- Like vanilla refuelling (ISVehiclePartMenu.onPumpGasoline): the character
-- first walks to the vehicle's charging port area, then does a short action
-- there, and only then charging starts. The one-sided feel of vanilla
-- refuelling comes from this walk; the distance rule itself is the same box.
--
-- A B42 network timed action (M1-3 issue 6): an action table with complete()
-- is run by the server in multiplayer - the client's start() hands it over
-- (ActionManager.createNetTimedAction) and the server rebuilds it by calling
-- new() with the client's fields named like new()'s parameters
-- (NetTimedAction.set). So the class lives in shared/, new() takes only
-- values that travel (no callback), and complete() does the real work:
-- on the server in multiplayer, right after perform() in single player
-- (IsoGameCharacter: perform(); if not client then complete()).
require "NEVLib/Util"
require "NEVLib/Net"
require "TimedActions/ISBaseTimedAction"

local Util = NEVLib.Util

NEVConnectChargerAction = ISBaseTimedAction:derive("NEVConnectChargerAction")

NEVConnectChargerAction.TIME = 60 -- action time units (vanilla car battery uninstall: 100)

function NEVConnectChargerAction:isValid()
    return self.vehicle ~= nil and self.vehicle:isInArea(self.area, self.character)
end

function NEVConnectChargerAction:waitToStart()
    self.character:faceThisObject(self.vehicle)
    return self.character:shouldBeTurning()
end

function NEVConnectChargerAction:update()
    self.character:faceThisObject(self.vehicle)
end

function NEVConnectChargerAction:start()
    self:setActionAnim("VehicleWorkOnMid")
end

-- Client side: the charge bar picks the vehicle up at once.
function NEVConnectChargerAction:perform()
    if NEVLib.ChargeUI then pcall(NEVLib.ChargeUI.rescan) end
    ISBaseTimedAction.perform(self)
end

function NEVConnectChargerAction:chargeArgs()
    return { kind = self.kind, x = self.sx, y = self.sy, z = self.sz }
end

-- Server (multiplayer) / single player: start charging. The server checks
-- the same rules as the startCharge client command (Net.allowed).
function NEVConnectChargerAction:complete()
    local Net = NEVLib.Net
    local args = self:chargeArgs()
    if isServer and isServer() then
        local ok, why = Net.allowed("startCharge", self.character, self.vehicle, args)
        if not ok then
            Util.log("NET", { event = "refused", command = "startCharge", why = why, via = "action" })
            return false
        end
    end
    local ok, err = pcall(Net.actions.startCharge, self.vehicle, args, self.character)
    if not ok then Util.log("ERROR", { where = "connectCharger", msg = tostring(err) }) end
    if isServer and isServer() then self.vehicle:transmitModData() end
    return true
end

function NEVConnectChargerAction:getDuration()
    return NEVConnectChargerAction.TIME
end

-- kind: "fast" | "slow"; sx, sy, sz: the charging source's square.
function NEVConnectChargerAction:new(character, vehicle, area, kind, sx, sy, sz)
    local o = ISBaseTimedAction.new(self, character)
    o.vehicle = vehicle
    o.area = area
    o.kind = kind
    o.sx, o.sy, o.sz = sx, sy, sz
    o.maxTime = o:getDuration()
    return o
end

return NEVConnectChargerAction
