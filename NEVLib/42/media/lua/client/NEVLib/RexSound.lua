-- NEV Lib: what the player hears from an NEV (DESIGN 3.6, LEGACY-ISSUES 1,
-- user 2026-10-08 D1). The engine sound is silent (NEVLibSilent in the
-- vehicle script); while a range extender runs, the vanilla generator loop
-- plays on the vehicle's own emitter, with the vanilla start / stop sounds
-- at the edges. Client only and local only (playSoundImpl / stopSoundLocal):
-- every client decides from the vehicle's state, nothing is networked here.
-- Zombies hear the extender through the world sound in Parts (DESIGN 3.6),
-- not through this.
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/State"
require "NEVLib/Nearby"

local Util, Registry, State, Nearby = NEVLib.Util, NEVLib.Registry, NEVLib.State, NEVLib.Nearby
local RexSound = {}
NEVLib.RexSound = RexSound

RexSound.LOOP = "GeneratorLoop"
RexSound.START = "GeneratorStarting"
RexSound.STOP = "GeneratorStopping"

local playing = {}   -- vehicle -> loop handle (0 / nil = not playing)

-- One vehicle: start / keep / stop the loop to match its range extender.
-- A car that left the world (chunk unloaded, removed with permanentlyRemove)
-- may still report a square while its emitter has none, and playSoundImpl
-- then throws (FMODSoundEmitter:1029); the guard around tick logged that every
-- scan (M3-3, 2026-10-12: 195 errors in one drive). Every emitter call is
-- protected; a car whose emitter fails is forgotten quietly, no stop sound.
-- The square is passed explicitly: playSoundImpl(name, nil) is resolved by
-- Kahlua to the (String, IsoGridSquare) overload first, which throws on the nil
-- square and logs a NullPointerException before the IsoObject overload plays
-- the sound - every extender start / stop logged an error since M1 (found
-- 2026-10-12, M3-3; the pcall cannot keep the Java log line out).
local function call(e, fn, ...)
    local ok, r = pcall(fn, e, ...)
    if ok then return true, r end
    return false
end

local function forget(vehicle, e, h)
    if e and h and h ~= 0 then pcall(e.stopSoundLocal, e, h) end
    playing[vehicle] = nil
end

function RexSound.updateVehicle(vehicle, wanted)
    -- off and not playing: nothing to start or stop (most cars around; their emitter and square were two Java calls
    -- a car every scan, #327 5-6)
    if not wanted and playing[vehicle] == nil then return end
    local e = vehicle:getEmitter()
    if not e then return end
    local h = playing[vehicle]
    if not vehicle:getSquare() then return forget(vehicle, e, h) end
    if wanted then
        if h == nil and not call(e, e.playSoundImpl, RexSound.START, vehicle:getSquare()) then return forget(vehicle, e, h) end
        local alive = h and h ~= 0 and select(2, call(e, e.isPlaying, h))
        if not alive then
            local ok, nh = call(e, e.playSoundImpl, RexSound.LOOP, vehicle:getSquare())
            if not ok then return forget(vehicle, e, h) end
            playing[vehicle] = nh or 0
        end
    elseif h ~= nil then
        if h ~= 0 then call(e, e.stopSoundLocal, h) end
        call(e, e.playSoundImpl, RexSound.STOP, vehicle:getSquare())
        playing[vehicle] = nil
    end
end

-- After every shared scan (NEVLib.Nearby, every 500 ms; #253-7): the cars around follow their extender, the ones
-- no longer around (out of range, removed) are stopped.
function RexSound.onScan(found)
    local seen = {}
    for _, v in ipairs(found) do
        seen[v] = true
        RexSound.updateVehicle(v, State.get(v).rexOn == true)
    end
    for v in pairs(playing) do
        if not seen[v] then RexSound.updateVehicle(v, false) end
    end
end
Nearby.onScan(Util.guard("rexSound", RexSound.onScan))

-- The scan's own tick (tests drive it through here, as before)
RexSound.tick = Nearby.tick

-- tests
function RexSound.playing() return playing end
function RexSound.reset() playing = {}; Nearby.reset() end

return RexSound
