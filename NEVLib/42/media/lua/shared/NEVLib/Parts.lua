-- NEV Lib: vehicle part Lua functions referenced from the vehicle scripts.
-- Java calls a part's update with the minutes since its last update; after
-- the area was unloaded that is one large catch-up value (M0-REPORT 1-6).
-- Vanilla Vehicles.* lives in server/ and is looked up at call time only
-- (DESIGN 13.5-1).
require "NEVLib/Util"
require "NEVLib/Config"
require "NEVLib/Registry"
require "NEVLib/State"
require "NEVLib/Battery"
require "NEVLib/Powertrain"
require "NEVLib/Power"
require "NEVLib/Charging"
require "NEVLib/Camping"
require "NEVLib/Fridge"
require "NEVLib/Screen"

local Util, Config, Registry, State, Battery, Powertrain, Power, Charging, Camping, Fridge =
    NEVLib.Util, NEVLib.Config, NEVLib.Registry, NEVLib.State, NEVLib.Battery, NEVLib.Powertrain, NEVLib.Power,
    NEVLib.Charging, NEVLib.Camping, NEVLib.Fridge
local Parts = {}
NEVLib.Parts = Parts

Parts.REX_ID = "NEVRangeExtender"
Parts.REX_WEAR_MINUTES = 120 -- one condition point per 2 running hours
Parts.LIVE_UPDATE_MAX = 5    -- minutes: longer intervals are catch-ups (no sound, no regen)

local function vanilla(kind, name)
    local t = Vehicles and Vehicles[kind]
    return t and t[name]
end

local function tellDriver(vehicle, key, bad)
    local chr = vehicle:getDriver()
    if chr then Power.tell(chr, key, bad) end
end
Parts.tellDriver = tellDriver
-- the fridge module stays standalone (DESIGN 4); the library tells the driver about a reopen (D3)
Fridge.onReopen = function(vehicle) tellDriver(vehicle, "IGUI_NEV_FridgeReopened") end

---------------------------------------------------------------------------
-- Traction battery: all energy flows of the vehicle are settled here
---------------------------------------------------------------------------

-- Uninstall test of the traction battery (DESIGN 9, REVIEW 3.1-3): vanilla's
-- rule (not while the engine runs, Vehicles.UninstallTest.Battery) plus not
-- while camping or charging - the parked car uses the battery then too.
-- Without the vanilla test (renamed in a game update) nothing is removable,
-- which shows up at once instead of silently allowing it.
function Parts.batteryUninstallTest(vehicle, part, chr)
    local base = vanilla("UninstallTest", "Battery")
    if not base or not base(vehicle, part, chr) then return false end
    local st = State.get(vehicle)
    return st.camping ~= true and st.charge == nil
end

-- The battery item is gone (debug uninstall, another player, ...) although
-- the test above forbids it while camping / charging: leave both states so
-- nothing keeps running on a missing battery. The settles inside are no-ops
-- here (the part's lastUpdated is already now, Util.settlePart).
function Parts.batteryGone(vehicle)
    local st = State.get(vehicle)
    if st.charge then Charging.stop(vehicle, "noBattery") end
    if st.camping then Camping.set(vehicle, false, "noBattery") end
end

Parts.createBattery = Battery.create

local function fuelOf(vehicle)
    local gas = vehicle:getPartById("GasTank")
    if not gas or not gas:getInventoryItem() then return 0, nil end
    return gas:getContainerContentAmount(), gas
end

local function rexHealthy(vehicle)
    local rp = vehicle:getPartById(Parts.REX_ID)
    return rp ~= nil and rp:getInventoryItem() ~= nil and rp:getCondition() > 0
end

-- Seat count for the "nobody inside" rule below. Replaceable only so the
-- server self test can drive a car on an empty server (no player to seat).
function Parts.occupantCount(vehicle)
    return Power.occupants(vehicle)
end

function Parts.updateBattery(vehicle, part, elapsedMinutes)
    -- vanilla Vehicles.Update.Battery also drives the lightbar; keep that
    local lightbar = vanilla("Update", "Lightbar")
    if lightbar then lightbar(vehicle, part, elapsedMinutes) end
    local cfg = Registry.get(vehicle)
    local item = part:getInventoryItem()
    if cfg and not item then Parts.batteryGone(vehicle) end
    if not cfg or not item or elapsedMinutes <= 0 then return end

    local st = State.get(vehicle)
    local sig0 = Parts.syncSignature(st)
    local live = elapsedMinutes <= Parts.LIVE_UPDATE_MAX
    local running = vehicle:isEngineRunning()
    local camping = st.camping == true and not running
    local speed = math.abs(vehicle:getCurrentSpeedKmHour())
    local cap = Powertrain.capacityKWh(cfg, part:getCondition(), Registry.installedBatteryKWh(vehicle))
    local heater = vehicle:getPartById("Heater")
    local hd = heater and heater:getModData()
    local heaterActive = hd ~= nil and hd.active == true
    local acc = Config.get("AccessoryEnergyUse")

    local chargeKW, stopReason = Charging.check(vehicle, cfg, cap)
    if stopReason then
        Charging.stop(vehicle, stopReason)
        chargeKW = 0
    end

    -- parked recharge (DESIGN 3.5 revision 15, #138 / I-230): powered off, not camping, not charging and
    -- below 3 % -> the range extender may run until its hold rule stops it (fuel priority 20 % + the band);
    -- only a start below 3 % counts, a car parked while its extender ran does not keep charging by itself
    -- with fuel and a working range extender only (DESIGN 3.5); without them the trigger set and cleared itself
    -- on every update and logged a start / end pair each time (#172, found reading the v1.0 save sample)
    local parked = cfg.powertrain == "EREV" and not running and not camping and st.charge == nil
        and Config.get("ParkedRecharge") ~= false and fuelOf(vehicle) > 0 and rexHealthy(vehicle)
    if not parked then
        st.parkedRex = nil
    elseif Battery.getSoc(vehicle) < Powertrain.EV_REX_SOC then
        if not st.parkedRex then Util.log("REX", { event = "parkedStart", soc = Battery.getSoc(vehicle) }) end
        st.parkedRex = true
    end

    local rex = nil
    local fuel, gas = 0, nil
    if cfg.powertrain == "EREV" then
        fuel, gas = fuelOf(vehicle)
        rex = { mode = st.mode, holdSoc = st.holdSoc, speed = speed,
                wasOn = st.rexOn == true, fuelL = fuel, kw = Powertrain.rexOutputKW(cfg, st.mode),
                fuelKWhPerL = cfg.rexFuelKWhPerL, healthy = rexHealthy(vehicle),
                allowed = running or camping or st.parkedRex == true }
    end

    local soc0 = Battery.getSoc(vehicle) -- the exact charge, not the item's whole steps (M3-3 N-1)
    -- energy-mode rules by charge (UI-DESIGN 18 W4): switch before the range
    -- extender decides, so it runs in the mode the charge allows
    if rex and NEVLib.EnergyMode then
        local m = NEVLib.EnergyMode.enforce(vehicle, soc0)
        if m then rex.mode = m; rex.holdSoc = st.holdSoc end
    end
    local driveKW = running and Powertrain.driveKW(cfg, speed) or 0
    local heaterKW = (running and heaterActive) and cfg.heaterKW * acc or 0
    local campingKW = camping and Camping.loadKW(cfg, heaterActive, hd and hd.temperature) or 0
    local screenKW = NEVLib.Screen.drawKW(vehicle) * acc
    -- a home charger on generator power runs while the generator's fuel lasts
    -- and pays its load for the time it charged (DESIGN 6.3 revision 14); a
    -- fast charge is vanilla's pump, which vanilla bills itself
    local generator, chargeKWhMax = nil, nil
    if chargeKW > 0 and st.charge and st.charge.kind == "slow" then
        generator = Charging.generatorFor(Charging.sourceSquare(st.charge))
        local hours = generator and Charging.hoursLeft(generator, Registry.CHARGER_LOAD)
        if hours then chargeKWhMax = hours * chargeKW end
    end
    local out = Powertrain.simulate({
        soc = soc0, capKWh = cap, minutes = elapsedMinutes,
        driveKW = driveKW, heaterKW = heaterKW, campingKW = campingKW, accessoryKW = screenKW,
        chargeKW = chargeKW, chargeKWhMax = chargeKWhMax, rex = rex,
    })

    local soc = out.soc
    if out.rexMinutes > 0 then st.rexRunPending = (st.rexRunPending or 0) + out.rexMinutes end
    local regen = 0
    if running and live and speed < (st.lastSpeed or 0) and not vehicle:isGasPedalPressed() then
        regen = Powertrain.regenKWh(cfg, st.lastSpeed, speed)
        soc = math.min(1, soc + regen / cap)
    elseif running and live and speed > (st.lastSpeed or 0) then
        -- speeding up costs the kinetic energy gained (BALANCE-DESIGN 2-3)
        soc = math.max(0, soc - Powertrain.accelKWh(cfg, st.lastSpeed or 0, speed) / cap)
    end
    Battery.setSoc(vehicle, soc)

    -- empty battery, range extender running: limit the speed to what it
    -- generates (DESIGN 5.3 U2); lifted once the charge is back above 1 %
    if running and out.limited then
        local limit = Powertrain.limpSpeed(cfg, out.genKW - heaterKW - screenKW)
        if not st.limpKmh then
            tellDriver(vehicle, "IGUI_NEV_LimpMode", true)
            Util.log("REX", { event = "limp", kmh = limit, gen = out.genKW })
        end
        st.limpKmh = math.floor(limit + 0.5)
    elseif st.limpKmh and (not running or soc >= Powertrain.LIMP_RELEASE_SOC) then
        st.limpKmh = nil
        Util.log("REX", { event = "limpEnd", soc = soc })
    end

    if gas and out.fuelUsedL > 0 then
        gas:setContainerContentAmount(math.max(0, fuel - out.fuelUsedL), false, true)
        vehicle:transmitPartModData(gas)
    end

    -- range extender state, fallback notice, noise (DESIGN 3.5 / 3.6)
    if rex then
        if out.rexOn ~= (st.rexOn == true) then
            Util.log("REX", { on = out.rexOn, mode = st.mode, soc = soc, fuel = fuel - out.fuelUsedL, speed = speed })
        end
        st.rexOn = out.rexOn
        if st.parkedRex and not out.rexOn then
            st.parkedRex = nil
            Util.log("REX", { event = "parkedEnd", soc = soc })
        end
        local wanted = rex.allowed and Powertrain.rexDecide(st.mode, soc, speed, false, st.holdSoc)
        if wanted and not out.rexOn and (not rex.healthy or fuel - out.fuelUsedL <= 0) then
            if not st.rexWarned then
                st.rexWarned = true
                tellDriver(vehicle, rex.healthy and "IGUI_NEV_RexNoFuel" or "IGUI_NEV_RexBroken", true)
                Util.log("REX", { event = "fallbackEV", healthy = rex.healthy, fuel = fuel })
            end
        else
            st.rexWarned = false
        end
        if out.rexOn and live then
            local r = Powertrain.rexNoiseRadius(st.mode)
            if r > 0 then
                addSound(vehicle, math.floor(vehicle:getX()), math.floor(vehicle:getY()), math.floor(vehicle:getZ()), r, r)
            end
        end
    end

    -- range estimate
    if running and live and speed > 5 then
        local km = speed * elapsedMinutes / 60
        st.kwhPerKm = Powertrain.updateKwhPerKm(st.kwhPerKm, driveKW * elapsedMinutes / 60, km, cfg)
    end
    st.lastSpeed = speed

    if generator then Charging.burnFuel(generator, out.chargedKWh / chargeKW, Registry.CHARGER_LOAD) end
    if out.full then Charging.stop(vehicle, "full") end
    if out.campingExit then
        Camping.set(vehicle, false, "lowCharge")
        Util.log("CAMPING", { event = "autoExit", soc = soc })
    end
    if out.depleted then Power.evaluate(vehicle, "depleted") end
    -- nobody inside but still powered: the driver died or was dragged out, and
    -- no OnExitVehicle reached us (M1-3 issue 1). Last one out -> off.
    if vehicle:isEngineRunning() and Parts.occupantCount(vehicle) == 0 then Power.evaluate(vehicle, "empty") end
    if not live then
        Util.log("CATCHUP", { minutes = elapsedMinutes, soc0 = soc0, soc = soc, charged = chargeKW > 0,
                              rexMin = out.rexMinutes, camping = camping })
    end
    -- multiplayer: what the server changed here reaches the clients (REVIEW 3.1-6)
    if isServer and isServer() and Parts.syncSignature(st) ~= sig0 then vehicle:transmitModData() end
end

-- Every game minute: keep part updates running for the loaded NEVs that have a fridge / charger / camping /
-- range extender working (vanilla's engine update switches them off, see updateMotor). #253 (v1.3.2, a dedicated
-- server of 20-50 players measured it): the 1.3.1 kick scanned 41 x 41 squares around every online player, about
-- 0.9 ms each, all in one tick; now the loaded NEVs are listed as they appear - a part init when the car is loaded
-- or spawned (VehicleParts.initParts, BaseVehicle.createPhysics: every load, server and single player; the screen
-- every NEV has, and the armour parts), every part update, and the actions that start something - and the kick
-- walks that list: its cost follows the NEVs, not players x squares. A car that left the world is dropped
-- (isRemovedFromWorld, as Armor.sweep; #336: not getMovingObjectIndex < 0, which is -1 in the frame a car is
-- loaded). needPartsUpdate is not saved (BaseVehicle has no field for it in save / load), so a car loaded while
-- charging / camping / with its fridge working is armed right at the init.
-- A multiplayer client runs no part Lua updates at all (VehicleParts.update returns after the signal devices on
-- a client), so it neither lists nor kicks.
local loaded = {}
Parts.loaded = loaded   -- tests
function Parts.track(vehicle)
    if not vehicle or (isClient and isClient()) or loaded[vehicle] then return end
    if not Parts.isRealVehicle(vehicle) or not Registry.isNEV(vehicle) then return end
    loaded[vehicle] = true
    if Parts.needsLiveUpdates(vehicle) then vehicle:setNeedPartsUpdate(true) end
end

function Parts.kickTracked()
    if isClient and isClient() then return end
    for v in pairs(loaded) do
        if v:isRemovedFromWorld() then
            loaded[v] = nil
        elseif Parts.needsLiveUpdates(v) then
            v:setNeedPartsUpdate(true)
        end
    end
end

-- The vehicle state fields clients show or act on; a change on the server
-- is transmitted (the charge level itself travels with the battery item).
-- kwhPerKm (the range estimate's consumption, set only here on the server) goes in rounded to 0.001 kWh/km
-- (10-21: the clients' copy stayed nil and their dashboard used the default consumption): a change below that
-- sends nothing, so it is not a packet per part update (#253) - steady driving moves it about once every few km.
function Parts.syncSignature(st)
    local c = st.charge
    local k = st.kwhPerKm
    return table.concat({ tostring(st.rexOn == true), tostring(st.mode), tostring(st.camping == true),
                          tostring(c and c.kind), tostring(st.holdSoc), tostring(st.limpKmh),
                          k and string.format("%.3f", k) or "nil" }, "|")
end

-- The empty-battery speed limit (DESIGN 5.3 U2) on the vehicle the physics
-- runs for: every frame on the client (single player too), from the synced
-- state. BaseVehicle.maxSpeed is set from the script when the vehicle enters
-- the world (BaseVehicle:881) and never saved; CarController cuts the engine
-- force above it (:600-613). The original value is kept here and put back.
-- Weak keys (v1.1, FINAL-REVIEW 2026-10-12 C4): a vehicle that leaves the world must not be kept alive
-- by this table. Reachable as Parts._scriptMax for the unit test only.
-- The load speed limit (DESIGN 5.4, Powertrain.loadCapKmh) rides on the same path: read from the running mass
-- every frame (no synced state, no message), the lower of the two applies. The steering clamp
-- (getSteeringClamp) reads the script's top speed, so it is unchanged; the steering rate follows the runtime
-- one (CarController:288) and gets slower - known.
-- The drive top speed (DESIGN 5.5, #368 C4, user 2026-10-28 "both agreed"): the script maxSpeed is 130 (the steering
-- of the user's reference car, Mustang UBC: the clamp and, off the throttle, the wheel rate). While the throttle is down
-- going forward the runtime top speed is the car's driveMaxKmh (90): the force cut-off (CarController:600-613), the gear
-- (control_ForwardNew: getMaxSpeed / gearRatioCount), 0-100 and the top speed (about 110) stay what they were. Braking,
-- coasting and reversing run on 130: the wheel turns as quickly as the Mustang's. isGasPedalPressed on the client is the
-- controller's isGas || isGasR of the last update (CarController:942); a car rolling back is reversing. The empty-battery
-- and load limits apply on top (the lower one).
local scriptMax = setmetatable({}, { __mode = "k" })
Parts._scriptMax = scriptMax
function Parts.applyLimp(vehicle)
    if not vehicle then return end
    local limit = State.get(vehicle).limpKmh
    local load = Powertrain.loadCapKmh(vehicle:getMass())
    if load and (not limit or load < limit) then limit = load end
    local cfg = Registry.get(vehicle)
    local drive = cfg and cfg.driveMaxKmh
    if drive and not (vehicle:isGasPedalPressed() and vehicle:getCurrentSpeedKmHour() >= 0) then drive = nil end
    local orig = scriptMax[vehicle]
    if limit or drive then
        if not orig then
            orig = vehicle:getMaxSpeed()
            scriptMax[vehicle] = orig
        end
        local want = orig
        if drive then want = math.min(want, drive) end
        if limit then
            local driver = vehicle:getDriver()
            local fast, slow = false, false
            if driver and driver.hasTrait and CharacterTrait then
                fast = driver:hasTrait(CharacterTrait.SPEED_DEMON) == true
                slow = driver:hasTrait(CharacterTrait.SUNDAY_DRIVER) == true
            end
            want = math.min(want, Powertrain.maxSpeedForCap(limit, fast, slow))
        end
        if math.abs(vehicle:getMaxSpeed() - want) > 0.5 then vehicle:setMaxSpeed(want) end
    elseif orig then
        vehicle:setMaxSpeed(orig)
        scriptMax[vehicle] = nil
    end
end

Battery.updateFn = Parts.updateBattery

---------------------------------------------------------------------------
-- Drive motor (the vanilla "Engine" part, DESIGN 3.1). Vanilla's engine
-- update switches all part updates off once the engine has cooled down with
-- nobody driving (Vehicles.Update.Engine -> setNeedPartsUpdate(false)). Our
-- fridge, charging and camping must keep running, so re-arm afterwards.
---------------------------------------------------------------------------

-- A paused fridge (off the car longer than FridgeOffCarHours) does nothing until the car is powered again, and
-- powering on starts the part updates by itself (the engine runs): it needs no live updates (#253-2; the first
-- update after the pause is settled as paused, Fridge.update).
function Parts.needsLiveUpdates(vehicle)
    local st = State.get(vehicle)
    if st.camping or st.charge or st.rexOn then return true end
    local fp = Fridge.part(vehicle)
    return Fridge.isOn(fp) and not Fridge.isPaused(fp)
end

function Parts.updateMotor(vehicle, part, elapsedMinutes)
    local engine = vanilla("Update", "Engine")
    if engine then engine(vehicle, part, elapsedMinutes) end
    if Parts.needsLiveUpdates(vehicle) then vehicle:setNeedPartsUpdate(true) end
end

---------------------------------------------------------------------------
-- Fuel tank (EREV): fuel is only used by the range extender. Vanilla burns
-- fuel whenever the engine "runs" (= powered on for us) and refuses to run
-- without fuel (Vehicles.CheckEngine.GasTank), so the tank gets no vanilla
-- update and no checkEngine (M1-PLAN 2.3).
---------------------------------------------------------------------------

function Parts.updateGasTank(vehicle, part, elapsedMinutes)
end

---------------------------------------------------------------------------
-- Range extender part (EREV)
---------------------------------------------------------------------------

function Parts.createRangeExtender(vehicle, part)
    VehicleUtils.createPartInventoryItem(part)
end

-- Wear counts the minutes the extender really ran, as integrated by the
-- battery update (out.rexMinutes), not this part's elapsed time: over a long
-- catch-up it may have run only part of it (REVIEW 3.2-7).
function Parts.updateRangeExtender(vehicle, part, elapsedMinutes)
    local st = State.get(vehicle)
    local ran = st.rexRunPending or 0
    st.rexRunPending = 0
    if ran <= 0 or not part:getInventoryItem() then return end
    local data = part:getModData()
    data.wear = (data.wear or 0) + ran
    if data.wear >= Parts.REX_WEAR_MINUTES then
        local points = math.floor(data.wear / Parts.REX_WEAR_MINUTES)
        data.wear = data.wear - points * Parts.REX_WEAR_MINUTES
        part:setCondition(math.max(0, part:getCondition() - points))
        vehicle:transmitPartCondition(part)
    end
end

---------------------------------------------------------------------------
-- Heater / AC: vanilla needs a hot combustion engine; ours works whenever the
-- cabin is powered (driving or camping), DESIGN 7.2 / M0 V9.
---------------------------------------------------------------------------

function Parts.updateHeater(vehicle, part, elapsedMinutes)
    local pc = vehicle:getPartById("PassengerCompartment")
    if not pc then return end
    local pcData = pc:getModData()
    if not tonumber(pcData.temperature) then pcData.temperature = 0.0 end
    local partData = part:getModData()
    if not tonumber(partData.temperature) then partData.temperature = 0 end
    local target = partData.temperature
    local before = pcData.temperature
    if partData.active and Battery.isPowered(vehicle) and target ~= 0 then
        local inc = 1.0 * elapsedMinutes
        if target > 0 then
            pcData.temperature = math.min(pcData.temperature + inc, target)
        else
            pcData.temperature = math.max(pcData.temperature - inc, target)
        end
    elseif pcData.temperature > 0 then
        pcData.temperature = math.max(pcData.temperature - 0.1 * elapsedMinutes, 0)
    elseif pcData.temperature < 0 then
        pcData.temperature = math.min(pcData.temperature + 0.1 * elapsedMinutes, 0)
    end
    if before ~= pcData.temperature then
        vehicle:transmitPartModData(pc)
    end
end

---------------------------------------------------------------------------
-- Fridge (stand-alone module, DESIGN 7.1)
---------------------------------------------------------------------------

Parts.fridgeAccess = Fridge.access

-- Fridge part create (DESIGN 9 revision 17): the library fridge NEVLib.Fridge (first in the part's itemType), never
-- the vanilla glove box the v1.0-v1.2 cars have, which the part still takes so old saves keep their fridge.
function Parts.createFridge(vehicle, part)
    Util.createFirstItem(part)
end
Parts.updateFridge = Fridge.update

---------------------------------------------------------------------------
-- B42 keeps updating the parts of an unloaded vehicle whose engine runs
-- (VirtualVehicleManager, VirtualVehicle.shouldUpdateInMeta); the owner the
-- part update receives is then a VirtualVehicle, which has no getModData /
-- getPartById (VehicleParts.java:388, VirtualVehicle.java:107-130). Our part
-- updates only work on a real BaseVehicle: anything else is left alone
-- (M1-3 issue 2; vanilla sees no NEV logic for that time, like a parked car).
---------------------------------------------------------------------------

function Parts.isRealVehicle(vehicle)
    return instanceof(vehicle, "BaseVehicle")
end

Parts.UPDATE_FUNCTIONS = { "updateBattery", "updateMotor", "updateGasTank", "updateRangeExtender",
                           "updateHeater", "updateFridge" }
for _, name in ipairs(Parts.UPDATE_FUNCTIONS) do
    local fn = Parts[name]
    Parts[name] = function(vehicle, part, elapsedMinutes)
        if not Parts.isRealVehicle(vehicle) then return end
        if not loaded[vehicle] then Parts.track(vehicle) end
        return fn(vehicle, part, elapsedMinutes)
    end
end
Battery.updateFn = Parts.updateBattery

return Parts
