-- NEV Lib: traction battery. It occupies the vanilla "Battery" part (DESIGN
-- 3.1), so the game's own lights / radio / dashboard read it through
-- getBatteryCharge(). The item must be drainable; the part script must say
-- specificItem = false (DESIGN 13.5-3).
require "NEVLib/Util"
require "NEVLib/State"
require "NEVLib/Registry"
require "NEVLib/Powertrain"
require "NEVLib/PowerSupply"

local Util, Registry, Powertrain = NEVLib.Util, NEVLib.Registry, NEVLib.Powertrain
local Battery = {}
NEVLib.Battery = Battery

function Battery.part(vehicle)
    return vehicle:getPartById("Battery")
end

-- Item weight of a traction battery of `kwh`: capacity x 0.8, rounded, plus the
-- heavy-item tag (DESIGN 9, REVIEW D4). The weight itself lives in the item
-- scripts; tools/balance_model.py and the self test check them against this.
Battery.WEIGHT_PER_KWH = 0.8
-- At most the heaviest carryable vanilla item (DESIGN 5.3 / 9, REVIEW U8:
-- generator and anvil, 40, both heavy items).
Battery.MAX_WEIGHT = 40

function Battery.itemWeight(kwh)
    return math.min(Battery.MAX_WEIGHT, math.floor(kwh * Battery.WEIGHT_PER_KWH + 0.5))
end

-- The item stores its charge in whole UseDelta steps (0.00001 of the battery):
-- setUsedDelta rounds to the nearest one, so a small load settled every game
-- minute (a parked fridge: 1.3e-6) was rounded away and ran free forever
-- (M3-3 N-1, 2026-10-11). The exact value is kept on the item (it travels with
-- the battery) and used while the item still shows its rounding; a change by
-- anyone else (vanilla, another mod, a debug edit) moves the item further than
-- half a step, and then the item wins.
Battery.EXACT_KEY = "nevSocExact"

local function stepOf(item)
    local q = item.getUseDelta and item:getUseDelta() or 0
    if not q or q <= 0 then q = 0.00001 end
    return q
end

-- SOC 0..1 and the part (nil, nil without a battery item).
function Battery.getSoc(vehicle)
    local part = Battery.part(vehicle)
    local item = part and part:getInventoryItem()
    if not item then return 0, nil end
    local shown = item:getCurrentUsesFloat()
    local exact = item:getModData()[Battery.EXACT_KEY]
    if exact and math.abs(exact - shown) <= stepOf(item) * 0.5 + 1e-9 then return exact, part end
    return shown, part
end

function Battery.setSoc(vehicle, soc)
    local part = Battery.part(vehicle)
    local item = part and part:getInventoryItem()
    if not item then return end
    local v = Util.clamp(soc, 0, 1)
    local md = item:getModData()
    if math.abs(Battery.getSoc(vehicle) - v) < 1e-12 then return end
    local before = item:getCurrentUsesFloat()
    item:setUsedDelta(v)
    md[Battery.EXACT_KEY] = v
    if math.abs(item:getCurrentUsesFloat() - before) > 1e-9 then vehicle:transmitPartUsedDelta(part) end
end

-- Nominal kWh of the battery fitted (DESIGN 5.1 revision 17: the capacity is the item's), 0 without one.
function Battery.nominalKWh(vehicle)
    return Registry.installedBatteryKWh(vehicle)
end

-- Usable kWh now: the fitted battery's, less for a worn one.
function Battery.capacityKWh(vehicle)
    local cfg = Registry.get(vehicle)
    local part = Battery.part(vehicle)
    if not cfg or not part or not part:getInventoryItem() then return 0 end
    return Powertrain.capacityKWh(cfg, part:getCondition(), Battery.nominalKWh(vehicle))
end

function Battery.kwhToSoc(vehicle, kwh)
    local cap = Battery.capacityKWh(vehicle)
    if cap <= 0 then return 0 end
    return kwh / cap
end

function Battery.drainKWh(vehicle, kwh)
    local soc = Battery.getSoc(vehicle)
    Battery.setSoc(vehicle, soc - Battery.kwhToSoc(vehicle, kwh))
end

-- Settle the battery before a state change that alters its energy flows
-- (charging, power on, camping; Util.settlePart). The battery update lives in
-- NEVLib.Parts, which requires this module; Parts registers it here.
Battery.updateFn = nil

function Battery.settle(vehicle, why)
    Util.settlePart(vehicle, Battery.part(vehicle), Battery.updateFn, why)
end

function Battery.isPowered(vehicle)
    local part = Battery.part(vehicle)
    if not part or not part:getInventoryItem() then return false end -- REVIEW 3.1-3
    if vehicle:isEngineRunning() then return true end
    return NEVLib.State.get(vehicle).camping == true
end

-- Part "create": one of the car's powertrain's three batteries at random (DESIGN 5.1 revision 17, like the vanilla
-- gas tanks) with a random initial charge. Made here, not by VehicleUtils.createPartInventoryItem: that picks any
-- entry of the part's itemType list, which also names the old batteries kept for old saves (never spawned).
function Battery.create(vehicle, part)
    local cfg = Registry.get(vehicle) or Registry.DEFAULTS
    local types = Registry.batteryItems(cfg.powertrain)
    local item = types and instanceItem(types[ZombRand(#types) + 1])
    if not item then
        Util.log("BATTERY", { event = "createFailed", script = vehicle:getScriptName() })
        return
    end
    part:setRandomCondition(item)
    part:setInventoryItem(item)
    local lo, hi = cfg.initialSocMin, cfg.initialSocMax
    local soc = lo
    if ZombRandFloat then soc = ZombRandFloat(lo, hi) end
    item:setUsedDelta(soc)
end

-- #319: powered on at least once. Set at every power-on (Power enter); a car powered before this field existed
-- (old saves) left a trace: the devices remembered at its last power-off (State.snap, cleared only by the next
-- power-on) or its range estimate (State.kwhPerKm, set while driving). A freshly spawned car has neither. What is
-- found (or powered now) is written down, so the answer stays once the trace is gone.
function Battery.everPowered(vehicle)
    local st = NEVLib.State.get(vehicle)
    if st.poweredOnce == true then return true end
    if st.snap ~= nil or st.kwhPerKm ~= nil or Battery.isPowered(vehicle) then
        st.poweredOnce = true
        return true
    end
    return false
end

NEVLib.PowerSupply.addProvider({
    handles = function(vehicle) return Registry.isNEV(vehicle) end,
    getSoc = function(vehicle) return (Battery.getSoc(vehicle)) end,
    drainKWh = Battery.drainKWh,
    kwhToSoc = Battery.kwhToSoc,
    isPowered = Battery.isPowered,
    everPowered = Battery.everPowered,
})

return Battery
