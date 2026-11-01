-- NEV Lib: sandbox options (DESIGN 10) with defaults. Everything reads options
-- through here so tests can inject values and a missing page never errors.
require "NEVLib/Util"

local Config = {}
NEVLib.Config = Config

Config.DEFAULTS = {
    SpawnRate = 1.0,          -- NEV spawn rate multiplier
    EnergyUse = 1.0,          -- driving / idle consumption multiplier
    Regen = 1.0,              -- regenerative braking multiplier
    FastChargeTime = 2.0,     -- fast charge 0 -> 100 % = vanilla full refuel x this (DESIGN 6.2)
    SlowChargeHours = 7.0,    -- home charger: game hours for the BEV reference (102.7 kWh) 0 -> 100 %; other cars by capacity (I-235)
    RexNoiseHybrid = 40,      -- range extender noise, % of vanilla engine (hybrid / EV-priority hold)
    RexNoiseFuel = 80,        -- range extender noise, % of vanilla engine (fuel priority)
    AccessoryEnergyUse = 1.0, -- fridge / camping consumption multiplier
    AirFilter = true,         -- cabin air filter
    InfotainmentTV = true,    -- infotainment screen shows TV / tapes (off: radio only, DESIGN 7.5)
    AllowFastCharge = true,   -- charging at gas pumps
    GeneratorFuelFactor = 1.0, -- x the charger / power station load, 0 - 10 (DESIGN 6.3 revision 14)
    ParkedRecharge = true,    -- a parked EREV below 3 % starts its range extender (DESIGN 3.5 revision 15, D2)
    FridgeOffCarHours = 24,   -- the fridge works this long after power-off, 0 = no limit (DESIGN 7.1 revision 15, C5)
}

Config.overrides = nil -- tests: table of option -> value

function Config.get(name)
    if Config.overrides and Config.overrides[name] ~= nil then
        return Config.overrides[name]
    end
    local page = SandboxVars and SandboxVars.NEVLib
    if page and page[name] ~= nil then return page[name] end
    return Config.DEFAULTS[name]
end

-- Vanilla sandbox option (top-level SandboxVars.X) with a default.
function Config.vanilla(name, default)
    if SandboxVars and SandboxVars[name] ~= nil then return SandboxVars[name] end
    return default
end

return Config
