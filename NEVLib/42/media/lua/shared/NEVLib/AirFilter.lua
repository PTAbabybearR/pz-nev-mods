-- NEV Lib: cabin air filter (DESIGN 7.3). Stand-alone module like the fridge:
-- it only asks NEVLib.PowerSupply whether the vehicle is powered.
--
-- Java (BodyDamage.UpdateIllness) adds corpse sickness rate * multiplier to
-- FOOD_SICKNESS every update and, while corpses are near, skips the natural
-- decrease. Inside an NEV with a sealed cabin (powered or not) we take back
-- what was just added and apply the natural decrease vanilla skipped.
require "NEVLib/Util"
require "NEVLib/Config"
require "NEVLib/PowerSupply"

local Config, PowerSupply = NEVLib.Config, NEVLib.PowerSupply
local AirFilter = {}
NEVLib.AirFilter = AirFilter

-- Vanilla defines.lua: ZomboidGlobals.FoodSicknessDecrease = 0.0015. Java
-- copies it from this Lua table at load (ZomboidGlobals.Load). M0 read the
-- lower-case Java field name and got nil (DESIGN 7.3 correction).
AirFilter.DEFAULT_DECREASE = 0.0015

function AirFilter.naturalDecrease()
    local g = ZomboidGlobals
    local v = type(g) == "table" and g.FoodSicknessDecrease or nil
    if type(v) == "number" then return v end
    return AirFilter.DEFAULT_DECREASE
end

-- Amount to remove this update. Returns 0 when Java added nothing.
function AirFilter.removal(rate, multiplier, naturalDecrease, poisonAtMinimum)
    if not rate or rate <= 0 then return 0 end
    local removal = rate * multiplier
    if poisonAtMinimum then
        removal = removal + naturalDecrease * multiplier
    end
    return removal
end

-- The first part of cfg.cabinSealParts that keeps the cabin from being
-- sealed - missing, broken (condition 0 / destroyed window) or open (door
-- open, window rolled down) - or nil when the cabin is sealed (DESIGN 7.3,
-- REVIEW D5, user 2026-10-07: installed, not broken and closed).
function AirFilter.unsealedPart(vehicle, cfg)
    for _, id in ipairs(cfg.cabinSealParts or {}) do
        local part = vehicle:getPartById(id)
        if not part or not part:getInventoryItem() or part:getCondition() <= 0 then return id end
        local door = part:getDoor()
        if door and door:isOpen() then return id end
        local window = part:getWindow()
        if window and (window:isOpen() or window:isDestroyed()) then return id end
    end
    return nil
end

-- "on" | "unsealed" | "off" (sandbox off, or the vehicle has no filter).
-- NEVs: powered or not (UI-DESIGN 18 W12, user 2026-10-07; whether it should
-- draw power is a v2 question), but only with a sealed cabin. Non-NEV
-- vehicles that registered a power supply (PowerSupply) keep the powered rule.
function AirFilter.state(vehicle)
    if not vehicle or not Config.get("AirFilter") then return "off" end
    local cfg = NEVLib.Registry and NEVLib.Registry.get(vehicle)
    if cfg then
        if cfg.airFilter == false then return "off" end
        return AirFilter.unsealedPart(vehicle, cfg) and "unsealed" or "on"
    end
    local supply = PowerSupply.forVehicle(vehicle)
    return (supply ~= nil and supply.isPowered(vehicle)) and "on" or "off"
end

-- What the per-tick / per-frame callers below use (#253-4: in 1.3.1 every server tick re-checked the 11 doors and
-- windows for every passenger, and the client every frame): the state of a car is kept SEAL_CACHE_MS of real time.
-- A door opened takes effect within that; the dashboard lamp asks AirFilter.state itself, uncached.
AirFilter.SEAL_CACHE_MS = 1000
local cache = setmetatable({}, { __mode = "k" })   -- vehicle -> { at, state }
AirFilter._cache = cache   -- tests
local any = false   -- #328: the cache may hold an entry (set on each store, cleared by a sweep that leaves none)
function AirFilter.cachedState(vehicle)
    if not vehicle then return "off" end
    local now = getTimestampMs()
    local c = cache[vehicle]
    if c and now >= c.at and now - c.at < AirFilter.SEAL_CACHE_MS then return c.state end
    local s = AirFilter.state(vehicle)
    cache[vehicle] = { at = now, state = s }
    any = true
    return s
end

-- #328: an entry is no use after SEAL_CACHE_MS, but the weak keys only let it go once the Java vehicle is collected -
-- F13 found the car A had sat in still there after it left the world. Drop every expired entry (or one from a clock
-- that went back), at most once per SEAL_CACHE_MS. Run from the per-frame / per-tick entries below, not on a cache
-- miss: once A was on foot no car was looked up again.
local swept = nil
function AirFilter.sweep(now)
    if swept and now >= swept and now - swept < AirFilter.SEAL_CACHE_MS then return end
    swept = now
    local left = false
    for v, c in pairs(cache) do
        if now < c.at or now - c.at >= AirFilter.SEAL_CACHE_MS then cache[v] = nil else left = true end
    end
    any = left
end

-- The entries' call. Nobody in a car leaves the cache empty: nothing to sweep, and no clock read every frame (F11
-- 10-22: reading it to throttle an empty sweep took airFilter from 806 to 978 us/s, standing among vanilla cars alike).
-- A flag, not next(): Kahlua has no next().
function AirFilter.sweepIfAny()
    if any then AirFilter.sweep(getTimestampMs()) end
end

function AirFilter.active(vehicle)
    return AirFilter.cachedState(vehicle) == "on"
end

-- Takes back what BodyDamage.UpdateIllness just added for this player (the corpse sickness rate x
-- the multiplier, plus the natural decrease vanilla skipped while corpses are near).
-- No corpses near (rate 0): Java added nothing and there is nothing to zero - return before the stats (#253-4: the
-- stats calls were half of the seated cost once the seal was cached).
function AirFilter.apply(player)
    local vehicle = player:getVehicle()
    if not vehicle then return end
    local rate = player:getCorpseSicknessRate()
    if not rate or rate <= 0 then return end
    if not AirFilter.active(vehicle) then return end
    local stats = player:getStats()
    local removal = AirFilter.removal(rate, getGameTime():getMultiplier(),
        AirFilter.naturalDecrease(), stats:get(CharacterStat.POISON) <= 0)
    if removal > 0 then
        local now = stats:get(CharacterStat.FOOD_SICKNESS)
        stats:remove(CharacterStat.FOOD_SICKNESS, math.min(removal, now))
    end
    player:setCorpseSicknessRate(0)
end

-- Like a full gas mask (user 2026-10-12, I-223): vanilla's noxious-smell moodle reads the corpse
-- sickness rate (Moodle.java NOXIOUS_SMELL) and a gas mask with a filter makes that rate 0, so the
-- moodle goes away. Measured in game: set in OnPlayerUpdate the moodle stays at 0 (M3-3, 2026-10-12).
function AirFilter.hideSmell(player)
    if AirFilter.active(player:getVehicle()) then player:setCorpseSicknessRate(0) end
end

-- Single player: OnPlayerUpdate. Multiplayer (M3-3 MP-11, I-053, 2026-10-12, read from both ends):
-- corpse sickness is settled on the server and the client only receives the value, and the server
-- never fires OnPlayerUpdate for players (IsoPlayer.update returns before it there) - so the
-- server runs the filter from OnTick for every online player, and a multiplayer client does
-- nothing (taking back what its own side never added; the server overwrites it anyway).
-- #327: the side is read on the first call and kept (it cannot change during a game; OnPlayerUpdate fires about 244
-- times a second). AirFilter.resetSide() for the tests that switch sides.
local side = nil                                         -- "server" / "client" / "single"
function AirFilter.resetSide() side = nil end
function AirFilter.onPlayerUpdate(player)
    if not side then side = isServer() and "server" or isClient() and "client" or "single" end
    if side == "server" then return end
    AirFilter.sweepIfAny()
    -- the multiplayer client computes its own moodles: hide the smell there, the server settles the value
    if side == "client" then return AirFilter.hideSmell(player) end
    AirFilter.apply(player)
end

function AirFilter.serverTick()
    if not isServer() then return end
    AirFilter.sweepIfAny()
    local players = getOnlinePlayers()
    for i = 0, players:size() - 1 do
        AirFilter.apply(players:get(i))
    end
end

-- (M3-3 2026-10-12: the registration had slipped inside naturalDecrease() and never ran in the
-- game; tests/unit/nev_airfilter_load_test.lua and tools/check_static.py event-placement guard it.)
-- guardKeep (v1.1, FINAL-REVIEW 2026-10-12 C2): one error (one player, one frame) must not switch the
-- filter off for everybody until the restart; errors are still logged, at most once a minute.
-- #327: the server part only on the dedicated server (isServer() is set before its Lua loads, GameServer.java:411 /
-- :1356); it returned at once every tick on a multiplayer client and in single player.
-- #327 (coordinator 10-23, option 2b): OnPlayerUpdate fires for every player every frame (246 a second in F11) and
-- has nothing to do for one on foot - 712 us/s standing among 30 L6. It is hooked only while a local player sits in a
-- vehicle (any vehicle: a non-NEV with a power supply has the filter too):
--   every frame  the client tick (client/NEVLib/Events.lua) passes getPlayer() and whether it sits in one, from the
--                vehicle it reads anyway - not OnEnterVehicle, which fires about 2.5 s after the game seats the
--                character; a game loaded with the player already seated is the first frame like any other;
--   every LOOK_MS  AirFilter.lookSeats: the list rebuilt from the local players (getPlayer() and the split-screen
--                ones) alive in a vehicle - the other split-screen players come in, a player no longer there (died,
--                replaced) goes.
-- Unhooked, the cache is emptied: the sweep (#328) ran from this callback. The dedicated server loads no client/ and
-- never fires OnPlayerUpdate for players: nothing hooks it there. guardKeep made once, so Remove finds it.
local onUpdate = NEVLib.Util.guardKeep("airFilter", AirFilter.onPlayerUpdate)
AirFilter.LOOK_MS = 500
local seated, nSeated, hooked = {}, 0, false   -- player -> true while in a vehicle; Kahlua has no next()
local function setSeated(player, inVehicle)
    if inVehicle then inVehicle = true else inVehicle = nil end
    if seated[player] == inVehicle then return end
    seated[player] = inVehicle
    nSeated = nSeated + (inVehicle and 1 or -1)
end
local function hook()
    if nSeated > 0 and not hooked then
        hooked = true
        Events.OnPlayerUpdate.Add(onUpdate)
    elseif nSeated == 0 and hooked then
        hooked = false
        Events.OnPlayerUpdate.Remove(onUpdate)
        for v in pairs(cache) do cache[v] = nil end
        any = false
    end
end
function AirFilter.seat(player, inVehicle)
    if player then setSeated(player, inVehicle) end
    hook()
end
function AirFilter.lookSeats()
    local now, n = {}, 0
    local function look(p)
        if p and not now[p] and not p:isDead() and p:getVehicle() then
            now[p] = true
            n = n + 1
        end
    end
    look(getPlayer())
    for i = 0, getNumActivePlayers() - 1 do look(getSpecificPlayer(i)) end
    seated, nSeated = now, n
    hook()
end
function AirFilter.hooked() return hooked end   -- tests
if isServer() then
    Events.OnTick.Add(NEVLib.Util.guardKeep("airFilterServer", AirFilter.serverTick))
end

return AirFilter
