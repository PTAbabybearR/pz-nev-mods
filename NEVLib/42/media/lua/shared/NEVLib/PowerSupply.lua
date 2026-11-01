-- NEV Lib: power supply interface for the stand-alone accessory modules
-- (fridge, air filter; DESIGN 4 / 7.1). Accessories only talk to this table,
-- never to the battery or powertrain code, so they can later move into a
-- generic mod by installing a different provider (e.g. a vanilla 12 V battery).
--
-- A provider implements:
--   getSoc(vehicle)            -> 0..1 (0 when there is no battery)
--   drainKWh(vehicle, kWh)     -> removes energy, never below 0
--   kwhToSoc(vehicle, kWh)     -> the SOC fraction this energy represents
--   isPowered(vehicle)         -> powered on or camping (cabin systems live)
--   everPowered(vehicle)       -> optional: powered on at least once (#319: the fridge waits for that)
--   handles(vehicle)           -> true if this provider powers the vehicle
local PowerSupply = {}
NEVLib = NEVLib or {}
NEVLib.PowerSupply = PowerSupply

local providers = {}

function PowerSupply.addProvider(p)
    providers[#providers + 1] = p
end

function PowerSupply.forVehicle(vehicle)
    for i = #providers, 1, -1 do
        local p = providers[i]
        if p.handles(vehicle) then return p end
    end
    return nil
end

-- Tests only.
function PowerSupply.clear()
    providers = {}
end

return PowerSupply
