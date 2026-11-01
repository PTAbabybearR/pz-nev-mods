-- NEV Lib: vehicle model registry (DESIGN 13.3). Model packs register their
-- configuration in shared/; every module asks the registry whether a vehicle
-- is one of ours and which features it has, never the vehicle name.
require "NEVLib/Util"

local Util = NEVLib.Util
local Registry = {}
NEVLib.Registry = Registry

local models = {}

-- Balance anchors (DESIGN 5.3, user 2026-10-10: balance against vanilla, not
-- real life). Vanilla has no electricity: appliances add "load" to a
-- generator, which burns load x GeneratorFuelConsumption (default 0.1) litres
-- per hour (IsoGenerator.update; constants IsoGenerator:105-111). One load
-- unit in kW = 0.1 L/h x the library exchange rate below.
Registry.FUEL_KWH_PER_L = 3.06          -- range extender; also the power station's size (10 L worth, DESIGN 6.4)
Registry.VANILLA_LOAD_KW = 0.1 * Registry.FUEL_KWH_PER_L
Registry.VANILLA_FRIDGE_LOAD = 0.08     -- IsoGenerator.SingleFridgeOrFreezerPowerConsumption
Registry.VANILLA_TV_LOAD = 0.03         -- IsoGenerator.TelevisionPowerConsumption
-- A generator only pays for appliances (DESIGN 6.3 revision 14, #158 / I-250,
-- user 2026-10-14): charging equipment is an appliance with a load, billed
-- load x GeneratorFuelConsumption per hour while it charges, whatever the kWh.
-- Home charger: the household load worked back from "a full generator lasts 15
-- days" (10 L / 360 h = 0.278, minus the generator's own 0.02 = 0.26) x 1/2,
-- plus a margin (user: 0.15). A power station charges like vanilla's battery
-- charger. Fast charging adds nothing: vanilla bills the pump itself (0.03).
Registry.CHARGER_LOAD = 0.15
Registry.STATION_CHARGER_LOAD = 0.05    -- IsoGenerator.BatteryChargerPowerConsumption

-- Defaults for anything a model pack does not specify. Energy figures are the
-- M1 placeholders (docs/archive/m1/M1-PLAN.md section 3); balance happens in M3.
Registry.DEFAULTS = {
    powertrain = false,          -- required: "BEV" | "EREV" (PHEV with the first plug-in hybrid)
    -- set by the library, not the pack (revision 17): the reference capacity = the powertrain's middle battery
    -- (Registry.refBatteryKWh); the car's draw is solved on it. The battery fitted has its own (batteryItemKWh).
    batteryKWh = false,
    idleKW = 0.6,                -- powered, standing still
    driveA = 0.08,               -- kW per km/h
    driveB = 0.0009,             -- kW per (km/h)^2
    heaterKW = 1.0,              -- heater / AC while active (powered)
    massKg = false,              -- required
    -- the top speed while driving forward on the throttle (DESIGN 5.5, #368 C4): the script maxSpeed is the steering
    -- reference (130, every NEV), this is set as the runtime top speed while the throttle is down (Parts.applyLimp),
    -- so the speed the car reaches stays the ruler's (game top = this + about 20). false = the script maxSpeed throughout
    driveMaxKmh = false,
    regenEfficiency = 0.6,
    rexKW = 0,                   -- range extender output (EREV)
    rexFuelKWhPerL = Registry.FUEL_KWH_PER_L, -- electricity per litre of fuel
    rexFuelPriorityFactor = 1.5, -- output multiplier in fuel-priority mode
    fridge = false,
    -- a car fridge = 1/6 of a vanilla single fridge (DESIGN 5.3 / 7.1); not
    -- scaled by the energy scale: it is anchored to vanilla already
    fridgeKW = Registry.VANILLA_FRIDGE_LOAD * Registry.VANILLA_LOAD_KW / 6,
    camping = true,
    campingKW = 1.5,
    airFilter = true,
    -- parts that must be installed, unbroken and closed for the air filter
    -- (DESIGN 7.3): a saloon's; hatchbacks / SUVs add their TrunkDoor
    cabinSealParts = { "DoorFrontLeft", "DoorFrontRight", "DoorRearLeft", "DoorRearRight",
                       "WindowFrontLeft", "WindowFrontRight", "WindowRearLeft", "WindowRearRight",
                       "Windshield", "WindshieldRear" },
    chargePortArea = "ChargePort", -- vehicle script area; chargers must be within 2 tiles of it
    chargePortSide = nil,          -- text key suffix for the hint, e.g. "RearRight"
    initialSocMin = 0.2,
    initialSocMax = 0.8,
    -- armour add-ons (PARTS-DESIGN 6.3 / 6.6, v1.3 #174): the ordered declaration NEVLib/Armor works from, and
    -- { [part id] = chance 0..1 } of an add-on coming with a spawned car
    armor = false,
    armorSpawn = false,
    -- where the car spawns (NEVLib/Spawns, #222): { [zone] = share of that zone table's cars } for the zones
    -- where it should be more common than the library's base share; every other ordinary-car zone gets the base
    spawn = false,
    -- part models hidden while a door is open (NEVLib/HideWhenOpen, #238): { { door = id, model = id, part = id? } }
    hideWhenOpen = false,
    -- skins (paint part of the texture name) in the rare tier (NEVLib/Paint, #228, DESIGN 10.1a): together
    -- Paint.RARE_SHARE of the spawns; false = vanilla's even pick
    rarePaints = false,
}

-- Energy scale (docs/design/energy/energy-balance-design.md, user 2026-10-08): model packs keep
-- real-car figures; the library multiplies every power figure by one scale.
-- DESIGN 5.1 revision 14 (#158, user 2026-10-14): an NEV's EV range = its real
-- car's CLTC EV km x one library factor, set by the L6 making 3 of the user's
-- trips (Rosewood - Haven Fall and back, fridge on 4 days) on a full battery;
-- an EREV's EV share of the combined range = its real car's. The value is
-- solved from the targets by tools/balance_model.py, and `--check` (part of
-- tests/run_tests.py) fails when this number drifts from them (revision 13
-- had 0.3123, from "combined = 1.10 x the vanilla SUV").
-- A model pack may set `energyScale` (e.g. a BEV solved for its own range).
-- Not scaled: batteryKWh (the reference capacity), rexFuelKWhPerL (the
-- range extender's fuel <-> electricity rate), massKg, and the
-- vanilla-anchored accessories (fridgeKW; the screen, Screen.KW).
Registry.ENERGY_SCALE = 0.5186
Registry.SCALED_KEYS = { "idleKW", "driveA", "driveB", "heaterKW", "rexKW", "campingKW" }

local function shortName(name)
    if not name then return nil end
    local dot = string.find(name, ".", 1, true)
    if dot then return string.sub(name, dot + 1) end
    return name
end

-- Traction batteries (DESIGN 5.1 revision 17, #215, user 2026-10-16): three powertrains x low / mid / high, the
-- capacity on the item, NEVLib.TractionBattery<kind>_<grade>. BEV mid = the real BEVs' median CLTC (about 600 km)
-- x the L6's draw (about 0.17 kWh / CLTC km); EREV x 0.5, PHEV x 0.2; low / high -+25 %. Every NEV of a powertrain
-- takes its three; its draw is solved on the middle one, so a car with the middle battery runs its ruler range
-- (5.1 revision 14) and low / high run 25 % shorter / further.
Registry.BATTERY_KINDS = { BEV = { 75, 100, 125 }, EREV = { 37.5, 50, 62.5 }, PHEV = { 15, 20, 25 } }
Registry.BATTERY_GRADES = { "Low", "Mid", "High" }
local batteryKWhOf = {}       -- full type -> kWh: the nine library items and the ones packs keep (old saves)
for kind, kwh in pairs(Registry.BATTERY_KINDS) do
    for i, g in ipairs(Registry.BATTERY_GRADES) do batteryKWhOf["NEVLib.TractionBattery" .. kind .. "_" .. g] = kwh[i] end
end

-- The three library battery items of a powertrain, low to high (nil for an unknown powertrain).
function Registry.batteryItems(kind)
    if not Registry.BATTERY_KINDS[kind] then return nil end
    local out = {}
    for _, g in ipairs(Registry.BATTERY_GRADES) do out[#out + 1] = "NEVLib.TractionBattery" .. kind .. "_" .. g end
    return out
end

-- kWh of a battery item by full type (nil: not a traction battery we know).
function Registry.batteryItemKWh(fullType)
    return fullType and batteryKWhOf[fullType] or nil
end

-- A pack's own battery item that stays usable (the v1.0-v1.2 L6 battery, 51 kWh): never spawned or made, but a
-- car that has it keeps working.
function Registry.registerBatteryItem(fullType, kwh)
    batteryKWhOf[fullType] = kwh
end

-- The reference capacity of a powertrain: its middle battery.
function Registry.refBatteryKWh(kind)
    local k = Registry.BATTERY_KINDS[kind]
    return k and k[2] or nil
end

-- Nominal kWh of the battery fitted to an NEV (its item's; an unknown item - debug, another mod - counts as the
-- reference). 0 without a battery.
function Registry.installedBatteryKWh(vehicle)
    local cfg = Registry.get(vehicle)
    local part = vehicle and vehicle:getPartById("Battery")
    local item = part and part:getInventoryItem()
    if not cfg or not item then return 0 end
    return Registry.batteryItemKWh(item:getFullType()) or cfg.batteryKWh
end

-- REVIEW 3.3-14: what a model pack must say itself (no silent library
-- default that is really one car's value), and every key it may use.
Registry.REQUIRED = { "powertrain", "massKg" }
Registry.POWERTRAINS = { BEV = true, EREV = true }
Registry.PORT_SIDES = { FrontLeft = true, FrontRight = true, RearLeft = true, RearRight = true }
Registry.EXTRA_KEYS = { energyScale = true, seatUIScaleX = true, chargePortSide = true } -- defaults that are nil

-- Problems of a registered model (list of strings, empty when fine).
function Registry.validate(full)
    local problems = {}
    for _, k in ipairs(full.missingRequired or {}) do problems[#problems + 1] = "missing " .. k end
    for _, k in ipairs(full.unknownKeys or {}) do problems[#problems + 1] = "unknown key " .. k end
    if not Registry.POWERTRAINS[full.powertrain] then problems[#problems + 1] = "powertrain " .. tostring(full.powertrain) end
    if type(full.batteryKWh) ~= "number" or full.batteryKWh <= 0 then problems[#problems + 1] = "batteryKWh" end
    if full.packBatteryKWh ~= nil then
        problems[#problems + 1] = "batteryKWh is the battery item's since revision 17 (the pack set " .. tostring(full.packBatteryKWh) .. ")"
    end
    if full.driveMaxKmh ~= false and (type(full.driveMaxKmh) ~= "number" or full.driveMaxKmh <= 0) then
        problems[#problems + 1] = "driveMaxKmh " .. tostring(full.driveMaxKmh)
    end
    if full.chargePortSide ~= nil and not Registry.PORT_SIDES[full.chargePortSide] then
        problems[#problems + 1] = "chargePortSide " .. tostring(full.chargePortSide)
    end
    if full.powertrain == "EREV" and not (full.real and full.real.rexKW and full.real.rexKW > 0) then
        problems[#problems + 1] = "EREV without rexKW"
    end
    if NEVLib.Spawns then
        for _, s in ipairs(NEVLib.Spawns.validate(full.spawn)) do problems[#problems + 1] = s end
    end
    if full.hideWhenOpen and NEVLib.HideWhenOpen then
        for _, s in ipairs(NEVLib.HideWhenOpen.validate(full.hideWhenOpen)) do problems[#problems + 1] = s end
    end
    if full.rarePaints and NEVLib.Paint then
        for _, s in ipairs(NEVLib.Paint.validate(full.rarePaints)) do problems[#problems + 1] = s end
    end
    if full.armor and NEVLib.Armor then
        for _, s in ipairs(NEVLib.Armor.validate(full.armor)) do problems[#problems + 1] = s end
    end
    return problems
end

function Registry.register(scriptName, cfg)
    local full = {}
    for k, v in pairs(Registry.DEFAULTS) do full[k] = v end
    full.missingRequired, full.unknownKeys = {}, {}
    for _, k in ipairs(Registry.REQUIRED) do
        if not cfg or cfg[k] == nil then full.missingRequired[#full.missingRequired + 1] = k end
    end
    for k, v in pairs(cfg or {}) do
        if Registry.DEFAULTS[k] == nil and not Registry.EXTRA_KEYS[k] then
            full.unknownKeys[#full.unknownKeys + 1] = k
        end
        full[k] = v
    end
    Util.sort(full.unknownKeys, function(a, b) return a < b end)
    full.packBatteryKWh = cfg and cfg.batteryKWh
    full.batteryKWh = Registry.refBatteryKWh(full.powertrain) or false
    full.energyScale = full.energyScale or Registry.ENERGY_SCALE
    full.real = {}
    for _, k in ipairs(Registry.SCALED_KEYS) do
        full.real[k] = full[k]
        full[k] = full[k] * full.energyScale
    end
    full.scriptName = scriptName
    local problems = Registry.validate(full)
    if #problems > 0 then
        Util.log("ERROR", { where = "Registry.register", model = scriptName, problems = table.concat(problems, "; ") })
    end
    models[shortName(scriptName)] = full
    return full
end

function Registry.getByName(scriptName)
    return models[shortName(scriptName)]
end

-- Config of an NEV vehicle, or nil for every other vehicle.
function Registry.get(vehicle)
    if not vehicle then return nil end
    return models[shortName(vehicle:getScriptName())]
end

function Registry.isNEV(vehicle)
    return Registry.get(vehicle) ~= nil
end

function Registry.all()
    return models
end

-- Tests only.
function Registry.clear()
    models = {}
end

return Registry
