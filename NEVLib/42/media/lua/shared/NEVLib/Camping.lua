-- NEV Lib: camping mode (DESIGN 7.2). Cabin stays powered after everybody
-- left; the engine is off so there is no engine noise. Turning it off (by
-- hand or automatically below 15 %) re-runs the power decision (13.5-8).
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/State"
require "NEVLib/Battery"
require "NEVLib/Power"
require "NEVLib/Powertrain"

local Util, Registry, State, Battery, Power, Powertrain =
    NEVLib.Util, NEVLib.Registry, NEVLib.State, NEVLib.Battery, NEVLib.Power, NEVLib.Powertrain
local Camping = {}
NEVLib.Camping = Camping

Camping.MAX_SPEED = 1 -- km/h, "vehicle stopped"

-- Why camping cannot be switched on (nil = it can).
function Camping.cannotStart(vehicle)
    local cfg = Registry.get(vehicle)
    if not cfg or not cfg.camping then return "notSupported" end
    if math.abs(vehicle:getCurrentSpeedKmHour()) > Camping.MAX_SPEED then return "moving" end
    local soc, part = Battery.getSoc(vehicle)
    if not part then return "noBattery" end
    if soc <= Powertrain.CAMPING_EXIT_SOC then return "lowCharge" end
    return nil
end

function Camping.set(vehicle, on, why)
    local st = State.get(vehicle)
    Battery.settle(vehicle, on and "campingOn" or "campingOff") -- before the flag changes (13.5-16)
    local before = Power.current(vehicle)
    if on then
        local blocker = Camping.cannotStart(vehicle)
        if blocker then return false, blocker end
        st.camping = true
        vehicle:setNeedPartsUpdate(true)
    else
        st.camping = false
    end
    Util.log("CAMPING", { on = st.camping, why = why or "menu", soc = (Battery.getSoc(vehicle)) })
    Power.evaluate(vehicle, on and "campingOn" or "campingOff", before)
    return true
end

-- Sleeping comfort (user decision 2026-10-07, M1 issue 16): with camping on,
-- the seats are folded flat like a real NEV's, so sleeping counts as an
-- ordinary bed ("averageBed") instead of vanilla's car seat ("badBed",
-- ISWorldObjectContextMenu.getBedQuality). A pillow suffix is kept.
Camping.BED = "averageBed"

function Camping.bedType(vanillaType, vehicle)
    if type(vanillaType) ~= "string" or not vehicle or not Registry.isNEV(vehicle) then return vanillaType end
    if not State.get(vehicle).camping then return vanillaType end
    if string.sub(vanillaType, 1, 6) ~= "badBed" then return vanillaType end
    return Camping.BED .. string.sub(vanillaType, 7)
end

-- Extra load while camping: base plus heater / AC effort (|target| offset).
function Camping.loadKW(cfg, heaterActive, heaterTarget)
    local kw = cfg.campingKW
    if heaterActive then kw = kw * (1 + math.abs(heaterTarget or 0) / 20) end
    return kw * NEVLib.Config.get("AccessoryEnergyUse")
end

return Camping
