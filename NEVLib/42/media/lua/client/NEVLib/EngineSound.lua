-- Copyright (c) 2026 熊叔
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.

-- NEV Lib: the simulated engine sound heard inside an NEV (DESIGN 3.6 revision 49, #236, design
-- docs/design/cabin/engine-sound-design.md). User 11-03: everybody in the car hears it, on by default, it follows
-- the speed and the pedal, the vanilla sports car sound (event Vehicle/Sport/Engine); 11-04, after listening: way B
-- (an emitter of its own, fed from Lua). Client only and local only: every client plays it for the car its own
-- players sit in, nothing is networked, no world sound (zombies hear the noise of DESIGN 3.6, not this).
--
-- The emitter is taken from the world and owned (design 3.2): a free emitter stays in IsoWorld.currentEmitters,
-- which the world ticks every 30 ms and, once empty, clears and hands to the next caller (IsoWorld:3090-3101); a
-- stale reference would then move someone else's sound. Like the vanilla generator (IsoGenerator:719-720, :441-442):
-- takeOwnershipOfEmitter right away, tick it ourselves, returnOwnershipOfEmitter when done.
-- Not the car's own emitter: BaseVehicle.updateSounds overwrites the parameters every frame. No setPitch: it does
-- nothing to an FMOD event and changes every sound on the emitter.
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/Schedule"
require "NEVLib/State"

local Util, Registry, Schedule, State = NEVLib.Util, NEVLib.Registry, NEVLib.Schedule, NEVLib.State
local EngineSound = {}
NEVLib.EngineSound = EngineSound

EngineSound.SOUND = "VehicleEngineSportsCar"   -- event:/Vehicle/Sport/Engine
-- The feed the user listened to and picked on 11-04 (the in-game probe of way B): 800 at
-- rest, linear to 6000 at 120 km/h and above, no gear shifts. Changing these changes the approved sound: back to
-- the user first (procedure 5.3).
EngineSound.RPM_IDLE = 800
EngineSound.RPM_SPAN = 5200
EngineSound.RPM_FULL_KMH = 120
EngineSound.CHECK_MS = 250                       -- start / restart check while nothing has to be fed every frame

local playing = {}   -- vehicle -> { e = owned emitter, h = sound handle }
local count = 0      -- entries in playing

function EngineSound.rpm(kmh)
    return EngineSound.RPM_IDLE + math.min(math.abs(kmh) / EngineSound.RPM_FULL_KMH, 1) * EngineSound.RPM_SPAN
end

-- VehicleLoad, 0 or 1 like the approved feed (design 3.5). Cruise control on: 1 (the car holds its own throttle,
-- 0.5, CarController:249-252), the same for driver and passengers. A local driver: the pedal (isGas || isGasR of
-- this client's keys). A passenger's client has no keys of the driver, but the throttle comes with the vehicle
-- physics packet (VehiclePhysicsPacket:180, VehicleManager:268): a ramp, +-multiplier/30 a frame, 1 -> 0 in about
-- 0.62 s (CarController:241-255), so not "above 0" but its trend (M2 design review, review log 34.3-1): up = 1,
-- down or 0 = 0, unchanged = the last Load (an interpolation buffer that ran dry holds a middle value,
-- VehicleInterpolation:239). s = this car's entry in playing: the last throttle read (s.thr) and Load (s.load); no
-- last read (just started, just moved from the driver's seat, cruise just off) = "above 0" once. The driver's and
-- the cruise branch neither read nor keep it.
function EngineSound.load(vehicle, driverHere, s)
    if vehicle:isRegulator() then s.thr = nil; return 1 end
    if driverHere then s.thr = nil; return vehicle:isGasPedalPressed() and 1 or 0 end
    local thr, last = vehicle:getThrottle(), s.thr
    local load
    if thr <= 0 then load = 0
    elseif last == nil then load = 1
    elseif thr > last then load = 1
    elseif thr < last then load = 0
    else load = s.load end
    s.thr, s.load = thr, load
    return load
end

-- The switch in the vehicle settings (design 4; user 11-05: on the car, every car remembers its own, the same for
-- everybody in it). Read only: State.get would write the table on this client, and nil (a save from before #236)
-- is on, the default (user 11-03).
function EngineSound.isOff(vehicle)
    local st = vehicle:getModData()[State.KEY]
    return type(st) == "table" and st.engineSoundOff == true
end

-- Should this local player's car sound? Seated in a registered NEV that is powered for driving, the switch on, and
-- the player awake and alive; not while towed (the car is not driving itself) or out of the world (design 2-2).
function EngineSound.wanted(player, vehicle)
    return Registry.get(vehicle) ~= nil and vehicle:isEngineRunning() and not player:isDead() and not player:isAsleep()
        and vehicle:getVehicleTowedBy() == nil and vehicle:getSquare() ~= nil and not EngineSound.isOff(vehicle)
end

-- vehicle -> true when a local player drives it, false when only passengers; one sound a car for split screen
local function wantedCars()
    local cars = nil
    for n = 0, getNumActivePlayers() - 1 do
        local p = getSpecificPlayer(n)
        local v = p and p:getVehicle()
        if v and EngineSound.wanted(p, v) then
            cars = cars or {}
            cars[v] = cars[v] or v:getDriver() == p
        end
    end
    return cars
end

local function call(e, fn, ...)
    local ok, r = pcall(fn, e, ...)
    if ok then return true, r end
    return false
end

-- the OnTick while something plays (EngineSound.tick below)
local tickFn = Util.guardKeep("engineSoundTick", function() EngineSound.tick() end)

-- Stop and give the emitter back. A failed stopSoundLocal could leave the loop running: try stopAll once and log.
local function stop(vehicle)
    local s = playing[vehicle]
    if not s then return end
    playing[vehicle] = nil
    count = count - 1
    if s.h and not call(s.e, s.e.stopSoundLocal, s.h) then
        Util.log("ENGINESOUND", { event = "stopFailed", stopAll = (call(s.e, s.e.stopAll)) })
    end
    local world = getWorld()
    call(world, world.returnOwnershipOfEmitter, s.e)
    -- removing the running OnTick from inside it is safe: Event.trigger steps back when its closure is gone
    if count == 0 then Events.OnTick.Remove(tickFn) end
end

local function start(vehicle)
    local world = getWorld()
    local ok, e = call(world, world.getFreeEmitter, vehicle:getX(), vehicle:getY(), vehicle:getZ())
    if not ok or not e then return end
    call(world, world.takeOwnershipOfEmitter, e)
    local played, h = call(e, e.playSoundImpl, EngineSound.SOUND, vehicle:getSquare())
    if count == 0 then Events.OnTick.Add(tickFn) end
    playing[vehicle] = { e = e }
    count = count + 1
    if not played or not h or h == 0 then return stop(vehicle) end
    playing[vehicle].h = h
end

local function feed(vehicle, s, driverHere)
    local e, h = s.e, s.h
    local kmh = vehicle:getCurrentSpeedKmHour()
    return call(e, e.tick) and call(e, e.setPos, vehicle:getX(), vehicle:getY(), vehicle:getZ())
        and (isGamePaused() or (call(e, e.setParameterValueByName, h, "VehicleRPM", EngineSound.rpm(kmh))
            and call(e, e.setParameterValueByName, h, "VehicleLoad", EngineSound.load(vehicle, driverHere, s))
            and call(e, e.setParameterValueByName, h, "VehicleSpeed", math.floor(math.abs(kmh)))))
end

-- Every frame while something plays: stop what is no longer wanted the same frame, feed the rest. Paused: no new
-- values (design 2-2: as a vanilla car sounds while paused; checked against one in L3).
-- (stops are collected first: playing is not changed while pairs walks it, Kahlua's table gives no guarantee)
function EngineSound.tick()
    local cars, gone = wantedCars(), nil
    for v, s in pairs(playing) do
        local driverHere = cars and cars[v]
        if driverHere == nil or not feed(v, s, driverHere) then gone = gone or {}; gone[#gone + 1] = v end
    end
    if gone then for _, v in ipairs(gone) do stop(v) end end
end

-- Every CHECK_MS: start what is wanted; a sound the event ended by itself is started again (owned, the emitter is
-- not reclaimed, and feeding a dead handle would go on for ever).
function EngineSound.check()
    local cars, gone = wantedCars(), nil
    for v, s in pairs(playing) do
        if not (cars and cars[v] ~= nil) or not select(2, call(s.e, s.e.isPlaying, s.h)) then
            gone = gone or {}; gone[#gone + 1] = v
        end
    end
    if gone then for _, v in ipairs(gone) do stop(v) end end
    if cars then
        for v in pairs(cars) do
            if not playing[v] then start(v) end
        end
    end
end
Schedule.every("engineSound", EngineSound.CHECK_MS, EngineSound.check)

-- tests
EngineSound.tickFn = tickFn
function EngineSound.playing() return playing end
function EngineSound.reset()
    local all = {}
    for v in pairs(playing) do all[#all + 1] = v end
    for _, v in ipairs(all) do stop(v) end
end

return EngineSound
