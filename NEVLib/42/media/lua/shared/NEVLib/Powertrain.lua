-- NEV Lib: powertrain logic without game objects (DESIGN 3.2, 3.4-3.6).
-- Units: SOC is a 0..1 fraction, power in kW, energy in kWh, time in game
-- minutes, speed in km/h (the value the game reports).
require "NEVLib/Util"
require "NEVLib/Config"

local Util, Config = NEVLib.Util, NEVLib.Config
local Powertrain = {}
NEVLib.Powertrain = Powertrain

Powertrain.REX_BASE_RADIUS = 60    -- "vanilla engine = 100 %" in tiles (DESIGN 3.6, M0 V5)
Powertrain.REGEN_GAME_FACTOR = 1   -- was 5 (show regen on the gauge); 1 since the energy
                                   -- balance (2026-10-08): with acceleration paid for, any
                                   -- factor above 1 / (0.6 * 0.9) would make braking a profit
Powertrain.HYBRID_MIN_SPEED = 40   -- km/h, DESIGN 3.5 / 20
Powertrain.HYSTERESIS = 0.02       -- SOC band that stops on/off flapping at a threshold
Powertrain.HOLD_BAND = 0.08        -- hold points (hybrid 20 % floor, fuel-priority hold, EV 3 %): the
                                   -- range extender stops this much above where it starts. With 2 % a parked
                                   -- car started it every ~5 real minutes for ~1 minute (I-051 -> 5 %);
                                   -- DESIGN revision 14 scaled the loads and the extender x 1.69 (#158), so
                                   -- 8 % keeps the I-051 rhythm (5 % would start 7 times a parked day)
Powertrain.CAMPING_EXIT_SOC = 0.15 -- DESIGN 7.2 / 20
Powertrain.EV_REX_SOC = 0.03       -- EV mode: range extender only below this (UI-DESIGN 18 W4)
Powertrain.MODE_EV_MIN_SOC = 0.20  -- EV mode may be picked at or above this
Powertrain.MODE_HYBRID_MIN_SOC = 0.03 -- below this only fuel priority
Powertrain.MAX_STEPS = 2000        -- cap on integration steps for long catch-ups
Powertrain.LIMP_RELEASE_SOC = 0.01 -- empty-battery speed limit ends at this charge (DESIGN 5.3 U2)
Powertrain.LIMP_MIN_SPEED = 5      -- km/h: the limit never goes below this

-- Vanilla only cuts the engine force above the vehicle's top speed and reaches
-- zero 20 km/h above it (CarController.java:603-609); Speed Demon cuts above
-- 1.15 x, Sunday Driver above 0.75 x (+ 20 each). So a limit of 81 set as the
-- top speed held the car at about 101 (M3-3 N-5, 2026-10-11). This returns the
-- top speed that makes vanilla's force reach zero at `capKmh`.
Powertrain.VANILLA_OVERSPEED_BAND = 20
function Powertrain.maxSpeedForCap(capKmh, speedDemon, sundayDriver)
    local m = capKmh - Powertrain.VANILLA_OVERSPEED_BAND
    if speedDemon then
        m = m / 1.15
    elseif sundayDriver then
        m = m / 0.75
    end
    return math.max(1, m)
end

-- Load speed limit (DESIGN 5.4, user 2026-10-19): the heavy P6 roll tiers make a loaded car spin when braking
-- and steering hard at speed, so the running mass (BaseVehicle.getMass: script + fitted part items + container
-- contents, people not counted) rounded up to the next 100 picks a top speed. getMass is the mass the physics
-- uses: vanilla refreshes it (updateTotalMass) when the car enters the world, a part item is fitted / removed or
-- a fluid amount changes, not when items go into a container - the limit follows the physics mass, which is what
-- the spin depends on (projectzomboid.jar: only BaseVehicle / VehiclePart call it). One table for every car; tiers
-- not listed (1600 and below) are not limited, above the last one the last one applies (full load cap 1900, P6).
-- Values from the live brake-and-steer runs 10-19 at each tier's top mass and roll (#226 roll-ruler-design 3.4):
-- at the cap, braking while steering 25 % yaws no more than vanilla's SUV at 90 km/h (60.7 deg); 1700 at 85 did not
-- (84-93 deg, one spin in 10), at 80 it did, with no margin (61.2 deg over 6 valid runs).
-- #368 C4 (user 2026-10-28 "both agreed", P8): the table is empty - a loaded car reaches the same top speed as an
-- empty one, like the vanilla / workshop cars. The mechanism stays as the fallback: tiers put back here apply again.
Powertrain.LOAD_CAP_STEP = 100
Powertrain.LOAD_CAPS = {}
Powertrain.LOAD_CAP_TOP = 1900
function Powertrain.loadCapKmh(massKg)
    if not massKg then return nil end
    local tier = math.ceil(math.floor(massKg + 0.5) / Powertrain.LOAD_CAP_STEP) * Powertrain.LOAD_CAP_STEP
    return Powertrain.LOAD_CAPS[math.min(tier, Powertrain.LOAD_CAP_TOP)]
end

---------------------------------------------------------------------------
-- Consumption and regeneration
---------------------------------------------------------------------------

-- Power drawn by driving at `speed` (includes the powered-on idle draw).
function Powertrain.driveKW(cfg, speed)
    local v = math.abs(speed or 0)
    local kw = cfg.idleKW + cfg.driveA * v + cfg.driveB * v * v
    return kw * Config.get("EnergyUse")
end

-- Empty battery, range extender running (DESIGN 5.3 U2, REVIEW 3.2-8): the
-- loads are capped at what it generates, like a real EREV's limp mode. The
-- speed at which driving draws `availKW` (generation minus the other loads):
-- solves idle + a v + b v^2 = availKW / EnergyUse.
function Powertrain.limpSpeed(cfg, availKW)
    local p = (availKW or 0) / Config.get("EnergyUse") - cfg.idleKW
    local v
    if p <= 0 then
        v = 0
    elseif cfg.driveB > 0 then
        v = (-cfg.driveA + math.sqrt(cfg.driveA * cfg.driveA + 4 * cfg.driveB * p)) / (2 * cfg.driveB)
    elseif cfg.driveA > 0 then
        v = p / cfg.driveA
    else
        v = 1e9
    end
    return math.max(Powertrain.LIMP_MIN_SPEED, v)
end

-- Kinetic energy difference in kWh between v1 and v2 (km/h).
local function kineticKWh(massKg, v1, v2)
    local a, b = v1 / 3.6, v2 / 3.6 -- m/s
    return 0.5 * massKg * math.abs(a * a - b * b) / 3600000
end

-- Energy to speed up from v1 to v2 (BALANCE-DESIGN 2-3: speed-only power
-- made acceleration free, so braking regen was pure profit). Paid at the
-- same energy scale as driving, through a drivetrain efficiency.
Powertrain.DRIVE_EFFICIENCY = 0.9
function Powertrain.accelKWh(cfg, v1, v2)
    v1, v2 = math.abs(v1 or 0), math.abs(v2 or 0)
    if v2 <= v1 then return 0 end
    return kineticKWh(cfg.massKg, v1, v2) / Powertrain.DRIVE_EFFICIENCY * (cfg.energyScale or 1)
        * Config.get("EnergyUse")
end

-- Energy recovered when slowing from v1 to v2 (km/h) without throttle. Never
-- more than accelerating cost (regenEfficiency < DRIVE_EFFICIENCY^-1 at the
-- default sandbox values), so stop-and-go cannot gain charge.
function Powertrain.regenKWh(cfg, v1, v2)
    v1, v2 = math.abs(v1 or 0), math.abs(v2 or 0)
    if v2 >= v1 then return 0 end
    return kineticKWh(cfg.massKg, v1, v2) * cfg.regenEfficiency * (cfg.energyScale or 1)
        * Powertrain.REGEN_GAME_FACTOR * Config.get("Regen")
end

-- Usable capacity: a worn battery holds less (M1-PLAN 2.2, placeholder curve). `kwh`: the nominal capacity of the
-- battery fitted (DESIGN 5.1 revision 17); default the car's reference (its powertrain's middle battery).
function Powertrain.capacityKWh(cfg, condition, kwh)
    local c = Util.clamp((condition or 100) / 100, 0, 1)
    return (kwh or cfg.batteryKWh) * (0.5 + 0.5 * c)
end

---------------------------------------------------------------------------
-- Range extender (DESIGN 3.5)
---------------------------------------------------------------------------

-- Should the range extender run? `wasOn` gives hysteresis.
--   mode: "ev" | "hybrid" | "fuel". "ev" is the former force-EV mode: the
--   range extender starts only below 3 % (UI-DESIGN 18 W4, user 2026-10-07;
--   which modes may be picked at which charge: NEVLib/EnergyMode).
--   holdSoc: fuel priority target captured when the mode was selected
function Powertrain.rexDecide(mode, soc, speed, wasOn, holdSoc)
    local function below(threshold, band)
        if wasOn then return soc < threshold + band end
        return soc < threshold
    end
    local hold = Powertrain.HOLD_BAND
    if mode == "fuel" then
        local target = Util.clamp(holdSoc or 0.8, 0.2, 0.8)
        return below(target, hold)
    end
    if mode == "hybrid" then
        if below(0.20, hold) then return true end -- after draining to 20 % it holds there
        local minSpeed = Powertrain.HYBRID_MIN_SPEED - (wasOn and 5 or 0)
        return math.abs(speed or 0) >= minSpeed and below(0.80, Powertrain.HYSTERESIS)
    end
    return below(Powertrain.EV_REX_SOC, hold)
end

-- Range extender noise in percent of the vanilla engine (DESIGN 3.6 / 20).
function Powertrain.rexNoisePercent(mode)
    if mode == "fuel" then return Config.get("RexNoiseFuel") end
    return Config.get("RexNoiseHybrid")
end

function Powertrain.rexNoiseRadius(mode)
    local pct = Powertrain.rexNoisePercent(mode) or 0
    if pct <= 0 then return 0 end
    return math.floor(Powertrain.REX_BASE_RADIUS * pct / 100 + 0.5)
end

function Powertrain.rexOutputKW(cfg, mode)
    if mode == "fuel" then return cfg.rexKW * cfg.rexFuelPriorityFactor end
    return cfg.rexKW
end

---------------------------------------------------------------------------
-- Energy integration over one part update (seconds of driving or a long
-- catch-up after the area was unloaded). Thresholds (range extender start /
-- stop, camping auto-exit, empty battery, full charge) are evaluated inside
-- the interval, not only at its end.
--
-- p = {
--   soc, capKWh, minutes,
--   driveKW,        -- while powered on (0 when off)
--   heaterKW,       -- heater/AC while powered
--   campingKW,      -- camping mode extra load (0 when not camping)
--   accessoryKW,    -- the screen while on (DESIGN 5.3)
--   chargeKW,       -- from a charger (0 when not charging)
--   chargeKWhMax,   -- nil = unlimited; else the most the charger can deliver
--                   -- (a generator's fuel left, DESIGN 6.3)
--   rex = nil | { mode, holdSoc, speed, wasOn, fuelL, kw, fuelKWhPerL, healthy, allowed }
-- }
-- returns { soc, rexOn, fuelUsedL, rexMinutes, campingExit, depleted, full,
--           chargedKWh,   -- what the charger put in (nothing past full)
--           limited, genKW } -- empty battery and the loads above generation
--                            -- (U2): the caller limits the speed
---------------------------------------------------------------------------
function Powertrain.simulate(p)
    local out = { soc = p.soc, rexOn = p.rex ~= nil and p.rex.wasOn or false, fuelUsedL = 0, rexMinutes = 0,
                  campingExit = false, depleted = false, full = false, chargedKWh = 0,
                  limited = false, genKW = 0 }
    local minutes = p.minutes or 0
    if minutes <= 0 or not p.capKWh or p.capKWh <= 0 then return out end
    local steps = math.min(Powertrain.MAX_STEPS, math.max(1, math.ceil(minutes)))
    local dt = minutes / steps
    local soc = p.soc
    local driveKW, heaterKW, campingKW, chargeKW = p.driveKW or 0, p.heaterKW or 0, p.campingKW or 0, p.chargeKW or 0
    local accessoryKW = p.accessoryKW or 0
    local rex = p.rex
    local fuel = rex and rex.fuelL or 0
    local rexOn = out.rexOn
    for _ = 1, steps do
        local gen = 0
        if rex and rex.allowed and rex.healthy and fuel > 0 then
            rexOn = Powertrain.rexDecide(rex.mode, soc, rex.speed, rexOn, rex.holdSoc)
        else
            rexOn = false
        end
        if rexOn then
            local kw = rex.kw
            local need = kw * dt / 60 / rex.fuelKWhPerL
            if need > fuel then
                kw = kw * fuel / need
                need = fuel
            end
            fuel = fuel - need
            out.fuelUsedL = out.fuelUsedL + need
            out.rexMinutes = out.rexMinutes + dt
            gen = kw
        end
        local load = driveKW + heaterKW + campingKW + accessoryKW
        local charged = chargeKW * dt / 60
        if p.chargeKWhMax and charged > p.chargeKWhMax - out.chargedKWh then
            charged = math.max(0, p.chargeKWhMax - out.chargedKWh)
        end
        soc = soc + ((gen - load) * dt / 60 + charged) / p.capKWh
        if soc >= 1 then
            -- what overflows came from the charger first (it is what fills it up)
            charged = math.max(0, charged - (soc - 1) * p.capKWh)
            soc = 1
            if chargeKW > 0 then out.full = true end
        end
        out.chargedKWh = out.chargedKWh + charged
        if soc <= 0 then
            soc = 0
            -- a running range extender keeps supplying the loads (series
            -- hybrid): only an empty battery with no generation is "depleted"
            if gen <= 0 then
                if driveKW > 0 or heaterKW > 0 or campingKW > 0 then out.depleted = true end
                driveKW, heaterKW, campingKW, accessoryKW = 0, 0, 0, 0
            elseif load > gen then
                -- what is missing is not drawn from nowhere: the speed comes down
                out.limited = true
                out.genKW = gen
            end
        end
        if campingKW > 0 and soc < Powertrain.CAMPING_EXIT_SOC then
            out.campingExit = true
            campingKW = 0
            -- the heater only stays on through camping when nobody powered the car
            if driveKW <= 0 then heaterKW = 0 end
        end
        if out.full then chargeKW = 0 end
    end
    out.soc = soc
    out.rexOn = rexOn
    return out
end

---------------------------------------------------------------------------
-- Range estimate (dashboard)
---------------------------------------------------------------------------

function Powertrain.defaultKwhPerKm(cfg)
    return Powertrain.driveKW(cfg, 60) / 60
end

-- "Recent consumption" for the range estimate (dashboard-design 2 ②): kWh per km averaged over about the last
-- RANGE_HORIZON_KM driven, weighted by distance (1 - e^(-km / horizon)), so the same drive gives the same reading
-- however often the part update ran (#305: a fixed 10 % per update followed the speed within seconds). With no
-- history yet it starts from the car's default (`cfg`), not from the first sample (#305: pulling away at walking
-- pace dropped a full car from 2072 to 1609 km).
Powertrain.RANGE_HORIZON_KM = 20
function Powertrain.updateKwhPerKm(prev, kwh, km, cfg)
    if km <= 0.001 then return prev end
    local sample = kwh / km
    prev = prev or (cfg and Powertrain.defaultKwhPerKm(cfg))
    if not prev then return sample end
    return prev + (sample - prev) * (1 - math.exp(-km / Powertrain.RANGE_HORIZON_KM))
end

-- km left on electricity, plus on fuel through the range extender.
function Powertrain.rangeKm(cfg, soc, capKWh, kwhPerKm, fuelL)
    local per = kwhPerKm or Powertrain.defaultKwhPerKm(cfg)
    if per <= 0 then return 0, 0 end
    local ev = soc * capKWh / per
    local fuelKm = 0
    if cfg.powertrain == "EREV" and fuelL and fuelL > 0 then
        fuelKm = fuelL * cfg.rexFuelKWhPerL / per
    end
    return ev, ev + fuelKm
end

return Powertrain
