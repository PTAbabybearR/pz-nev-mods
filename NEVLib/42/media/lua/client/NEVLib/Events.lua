-- NEV Lib: client event wiring - seat changes drive power on / off (DESIGN
-- 3.3), the air filter runs per player update (7.3), and loaded NEVs that
-- have something running (fridge, charging, camping, range extender) are kept
-- updating (see Parts.updateMotor / Parts.kickTracked).
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/Power"
require "NEVLib/Parts"
require "NEVLib/AirFilter"
require "NEVLib/Net"
require "NEVLib/Schedule"

local Util, Registry, Power, Parts, AirFilter, Net =
    NEVLib.Util, NEVLib.Registry, NEVLib.Power, NEVLib.Parts, NEVLib.AirFilter, NEVLib.Net
local Events_ = {}
NEVLib.ClientEvents = Events_

local lastVehicle = {} -- character -> vehicle it was last seated in (OnExitVehicle fires after unseating)

-- Multiplayer client: the server owns the power state (REVIEW 3.1-6), so seat
-- changes, the 1 s check and the gas pedal are reported to it; single player
-- and the host decide right here as before.
local function mpClient() return isClient and isClient() end
local function report(vehicle, chr, why, running)
    Net.run("evaluatePower", vehicle, { why = why, running = running }, chr)
end

local function onEnter(chr)
    local vehicle = chr:getVehicle()
    if not vehicle or not Registry.isNEV(vehicle) then return end
    lastVehicle[chr] = vehicle
    if mpClient() then return report(vehicle, chr, "enter") end
    Power.onSeated(vehicle, chr, "enter")
end

local function onSwitchSeat(chr)
    local vehicle = chr:getVehicle()
    if vehicle and Registry.isNEV(vehicle) then
        lastVehicle[chr] = vehicle
        if mpClient() then return report(vehicle, chr, "switchSeat") end
        Power.onSeated(vehicle, chr, "switchSeat")
    end
end

local function onExit(chr)
    local vehicle = lastVehicle[chr]
    lastVehicle[chr] = nil
    if vehicle then
        if mpClient() then return report(vehicle, chr, "exit") end
        local target, blocker = Power.evaluate(vehicle, "exit")
        Power.seatLog("exit", vehicle, chr, { target = target, blocker = blocker or "none" })
    end
end

-- Every frame: the vehicle the local player sits in is watched for vanilla's
-- gas-pedal start (Power.onFrame). The game seats the character about 2.5 s
-- before OnEnterVehicle fires (the event waits for the enter animation; M1
-- fix test, issue 17), so the first frame in a new vehicle counts as sitting
-- down (why=seated). Once a second it is re-decided, so hotwiring, picking
-- up the key or a recharged battery power the car without re-seating.
local nextCheck = 0
local frameMem, memUsed = {}, false
local seatPlayer, seatIn = nil, nil   -- #327 (2): what AirFilter.seat was last told
local function onTick()
    local player = getPlayer()
    local vehicle = player and player:getVehicle()
    -- #327: hooks the filter (AirFilter.seat), told only when the player or its seated state changed (every frame it
    -- took powerTick from ~200 to ~430 us / s, F11 10-24)
    local inVehicle = vehicle ~= nil and not player:isDead()
    if player ~= seatPlayer or inVehicle ~= seatIn then
        seatPlayer, seatIn = player, inVehicle
        AirFilter.seat(player, inVehicle)
    end
    if not vehicle or not Registry.isNEV(vehicle) then
        if memUsed then frameMem, memUsed = {}, false end   -- #327: not a new table every frame on foot
        return
    end
    memUsed = true
    local seatedNow = frameMem.vehicle ~= vehicle
    lastVehicle[player] = vehicle
    Parts.applyLimp(vehicle)   -- empty-battery speed limit (DESIGN 5.3 U2), physics runs here
    local now = getTimestampMs()
    if mpClient() then
        -- pedal: vanilla's start request reached the server; ask it to power on
        if seatedNow then frameMem.vehicle = vehicle end
        if vehicle:isEngineStarted() and not vehicle:isEngineRunning() and now >= (frameMem.nextPedal or 0) then
            frameMem.nextPedal = now + 500
            report(vehicle, player, "pedal")
        end
        if seatedNow then
            report(vehicle, player, "seated")
            nextCheck = now + 1000
        elseif now >= nextCheck then
            nextCheck = now + 1000
            -- #382: what this client sees; the server re-sends the engine state when it differs (Net.resyncEngine)
            report(vehicle, player, "tick", vehicle:isEngineRunning())
        end
        return
    end
    Power.onFrame(vehicle, frameMem)
    if seatedNow then
        Power.onSeated(vehicle, player, "seated")
        nextCheck = now + 1000
        return
    end
    if now < nextCheck then return end
    nextCheck = now + 1000
    Power.evaluate(vehicle, "tick")
end

-- Every game minute in single player: the part-update kick over the loaded NEVs (Parts.kickTracked; the server does
-- it on a server, server/NEVLib/Server.lua). A multiplayer client runs no part updates, so it does nothing (#253).
Events_.kick = function() if not mpClient() then Parts.kickTracked() end end

local function everyMinute() Events_.kick() end

local guard = Util.guard
Events.OnEnterVehicle.Add(guard("onEnter", onEnter))
Events.OnSwitchVehicleSeat.Add(guard("onSwitchSeat", onSwitchSeat))
Events.OnExitVehicle.Add(guard("onExit", onExit))
-- core: keeps running after an error, logged at most once a minute (REVIEW 3.3-15)
Events.OnTick.Add(NEVLib.Util.guardKeep("powerTick", onTick))
Events.EveryOneMinute.Add(guard("kick", everyMinute))
-- airFilter: shared/NEVLib/AirFilter.lua (REVIEW 3.2-3); hooked while a local player sits in a vehicle (#327: the
-- tick above, and this look for the other split-screen players)
NEVLib.Schedule.every("airFilterSeats", AirFilter.LOOK_MS, AirFilter.lookSeats)

return Events_
