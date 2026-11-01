-- NEV Lib: energy modes of range-extended cars (DESIGN 3.5, UI-DESIGN 18 W4,
-- user decision 2026-10-07).
--   Three modes: "ev" (range extender only below 3 %), "hybrid", "fuel".
--   Which can be picked depends on the charge:
--     20 % and above : ev, hybrid, fuel
--     3 % to 20 %    : hybrid, fuel
--     below 3 %      : fuel only
--   When the charge falls below a threshold the mode changes on its own and
--   the driver is told (ev -> hybrid below 20 %, anything -> fuel below 3 %).
--   Charging back up does not switch back: the player picks again.
-- Picking a mode is the Net action "setMode", so dashboard buttons and the
-- radial submenu run it the same way as every other state change.
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/State"
require "NEVLib/Battery"
require "NEVLib/Powertrain"
require "NEVLib/Net"

local Util, Registry, State, Battery, Powertrain, Net =
    NEVLib.Util, NEVLib.Registry, NEVLib.State, NEVLib.Battery, NEVLib.Powertrain, NEVLib.Net
local EnergyMode = {}
NEVLib.EnergyMode = EnergyMode

EnergyMode.ORDER = { "ev", "hybrid", "fuel" }

function EnergyMode.valid(mode)
    for _, m in ipairs(EnergyMode.ORDER) do
        if m == mode then return true end
    end
    return false
end

-- Can `mode` be picked at this charge? Returns true, or false + reason
-- ("needSoc20" | "needSoc3" | "notSupported").
function EnergyMode.allowed(mode, soc)
    if not EnergyMode.valid(mode) then return false, "notSupported" end
    soc = soc or 0
    if mode == "ev" and soc < Powertrain.MODE_EV_MIN_SOC then return false, "needSoc20" end
    if mode == "hybrid" and soc < Powertrain.MODE_HYBRID_MIN_SOC then return false, "needSoc3" end
    return true
end

-- The mode the car must be in at this charge: the current one when allowed,
-- else hybrid (below 20 %) or fuel (below 3 %). Pure.
function EnergyMode.required(mode, soc)
    if EnergyMode.allowed(mode, soc) then return mode end
    if EnergyMode.allowed("hybrid", soc) then return "hybrid" end
    return "fuel"
end

local function apply(vehicle, st, mode, soc, via)
    st.mode = mode
    if mode == "fuel" then st.holdSoc = soc end
    Util.log("MODE", { mode = mode, holdSoc = st.holdSoc or -1, via = via, soc = soc })
end

-- Picks `mode`. Returns ok, reason. Selecting the current mode again changes
-- nothing (in particular it does not re-capture the fuel-priority hold).
function EnergyMode.set(vehicle, mode)
    if not EnergyMode.valid(mode) then return false, "notSupported" end
    local st = State.get(vehicle)
    if st.mode == mode then return true end
    local soc = Battery.getSoc(vehicle)
    local ok, why = EnergyMode.allowed(mode, soc)
    if not ok then return false, why end
    apply(vehicle, st, mode, soc, "select")
    return true
end

local AUTO_TEXT = { hybrid = "IGUI_NEV_ModeAutoHybrid", fuel = "IGUI_NEV_ModeAutoFuel" }

-- Called from the battery update with the new charge (EREV only): switches
-- to the required mode and tells the driver. Returns the new mode when it
-- changed.
function EnergyMode.enforce(vehicle, soc)
    local cfg = Registry.get(vehicle)
    if not cfg or cfg.powertrain ~= "EREV" then return nil end
    local st = State.get(vehicle)
    local need = EnergyMode.required(st.mode or "ev", soc)
    if need == st.mode then return nil end
    apply(vehicle, st, need, soc, "auto")
    local driver = vehicle:getDriver()
    if driver and NEVLib.Power and NEVLib.Power.tell then
        NEVLib.Power.tell(driver, AUTO_TEXT[need], false)
    end
    return need
end

Net.actions.setMode = function(vehicle, args)
    return EnergyMode.set(vehicle, args and args.mode)
end

return EnergyMode
