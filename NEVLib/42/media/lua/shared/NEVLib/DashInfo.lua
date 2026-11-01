-- NEV Lib: what the NEV dashboard shows (docs/design/ui/dashboard-design.md 2-4), without any
-- drawing, so the unit tests cover it. Dashboard.lua (client) draws it.
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/State"
require "NEVLib/Battery"
require "NEVLib/Powertrain"
require "NEVLib/Charging"

local Util, Registry, State, Battery, Powertrain, Charging =
    NEVLib.Util, NEVLib.Registry, NEVLib.State, NEVLib.Battery, NEVLib.Powertrain, NEVLib.Charging
local DashInfo = {}
NEVLib.DashInfo = DashInfo

DashInfo.SOC_WARN = 0.15      -- battery bar / light turn yellow
DashInfo.SOC_CRIT = 0.05      -- ... red and flashing
DashInfo.FUEL_WARN = 0.15
DashInfo.FUEL_CRIT = 0.05
-- Range number yellow / red: NIO ET5's 60 / 10 km, divided by the car's own
-- energy scale (its range is the real one / scale; REVIEW 6.1-2: a BEV with
-- its own scale must not use the L6's 190 / 32). balance_model.py checks them.
DashInfo.RANGE_WARN_REAL_KM = 60
DashInfo.RANGE_CRIT_REAL_KM = 10
DashInfo.MOVING_KMH = 0.5     -- below this the car counts as standing still
DashInfo.REGEN_MIN_KMH = 2    -- no regen indication while creeping

---------------------------------------------------------------------------
-- Gear (UI-DESIGN 4): display only, derived from the driving state. The
-- game's own gear value drops to N whenever no pedal is held
-- (CarController.control_NoControl), so it cannot be shown as is.
---------------------------------------------------------------------------

-- running: powered on; speed: signed km/h (negative = backwards);
-- letter: BaseVehicle:getTransmissionNumberLetter() ("R", "N", "1".."8");
-- gas: throttle held.
function DashInfo.gearFor(running, speed, letter, gas)
    speed = speed or 0
    if not running then
        if math.abs(speed) > DashInfo.MOVING_KMH * 2 then return "N" end -- towed / pushed
        return "P"
    end
    if speed > DashInfo.MOVING_KMH then return "D" end
    if speed < -DashInfo.MOVING_KMH then return "R" end
    if letter == "R" then return "R" end
    if gas then return "D" end
    return "P"
end

function DashInfo.gear(vehicle)
    return DashInfo.gearFor(vehicle:isEngineRunning(), vehicle:getCurrentSpeedKmHour(),
        vehicle:getTransmissionNumberLetter(), vehicle:isGasPedalPressed())
end

---------------------------------------------------------------------------
-- Levels and colours
---------------------------------------------------------------------------

-- "ok" | "warn" | "crit"
function DashInfo.level(value, warn, crit)
    if value < crit then return "crit" end
    if value < warn then return "warn" end
    return "ok"
end

function DashInfo.socLevel(soc) return DashInfo.level(soc, DashInfo.SOC_WARN, DashInfo.SOC_CRIT) end
function DashInfo.fuelLevel(frac) return DashInfo.level(frac, DashInfo.FUEL_WARN, DashInfo.FUEL_CRIT) end
function DashInfo.rangeThresholds(cfg)
    local scale = (cfg and cfg.energyScale) or Registry.ENERGY_SCALE
    return DashInfo.RANGE_WARN_REAL_KM / scale, DashInfo.RANGE_CRIT_REAL_KM / scale
end
function DashInfo.rangeLevel(km, cfg)
    local warn, crit = DashInfo.rangeThresholds(cfg)
    return DashInfo.level(km, warn, crit)
end

DashInfo.COLORS = {
    text = { r = 0.92, g = 0.94, b = 0.96 },
    dim = { r = 0.55, g = 0.58, b = 0.62 },
    ok = { r = 0.35, g = 0.85, b = 0.55 },
    warn = { r = 1.00, g = 0.78, b = 0.20 },
    crit = { r = 1.00, g = 0.30, b = 0.28 },
    fuel = { r = 0.95, g = 0.72, b = 0.30 },
    regen = { r = 0.31, g = 0.85, b = 1.00 }, -- cyan blue: clearly not the battery green (W3)
    charge = { r = 0.62, g = 0.95, b = 1.00 },
    accent = { r = 0.49, g = 0.88, b = 0.76 }, -- style B accent (UI-DESIGN 20)
    seg = { r = 0.18, g = 0.21, b = 0.23 },    -- unlit bar segment
    camping = { r = 0.35, g = 0.60, b = 1.00 },
    orange = { r = 1.00, g = 0.60, b = 0.24 }, -- hacked car computer
    off = { r = 0.35, g = 0.36, b = 0.38 },
    panel = { r = 0.07, g = 0.08, b = 0.09 },
    track = { r = 0.20, g = 0.21, b = 0.23 },
    -- visual v5, A cockpit cards (UI-DESIGN 23.1)
    panelA = { r = 0.039, g = 0.047, b = 0.059 },   -- #0a0c0f
    border = { r = 0.169, g = 0.192, b = 0.220 },   -- #2b3138
    card = { r = 0.090, g = 0.102, b = 0.122 },     -- #171a1f
    segBg = { r = 0.051, g = 0.059, b = 0.071 },    -- #0d0f12
    segSel = { r = 0.165, g = 0.227, b = 0.200 },   -- #2a3a33
    barTrack = { r = 0.165, g = 0.184, b = 0.212 }, -- #2a2f36
    iconDim = { r = 0.604, g = 0.635, b = 0.671 },  -- #9aa2ab
}

---------------------------------------------------------------------------
-- Energy
---------------------------------------------------------------------------

function DashInfo.fuel(vehicle)
    local gas = vehicle:getPartById("GasTank")
    if not gas or not gas:getInventoryItem() then return 0, 0 end
    return gas:getContainerContentAmount(), gas:getContainerCapacity()
end

-- One combined range figure (UI-DESIGN 2.3 (2)): battery + fuel for EREV,
-- battery only for BEV.
function DashInfo.rangeKm(vehicle)
    local cfg = Registry.get(vehicle)
    local st = State.get(vehicle)
    local fuel = DashInfo.fuel(vehicle)
    local ev, total = Powertrain.rangeKm(cfg, Battery.getSoc(vehicle), Battery.capacityKWh(vehicle), st.kwhPerKm, fuel)
    if cfg.powertrain == "EREV" then return total end
    return ev
end

-- Range extender light: nil (no range extender) | "idle" | "on" | "noFuel" | "broken"
function DashInfo.rexLamp(vehicle)
    local cfg = Registry.get(vehicle)
    if not cfg or cfg.powertrain ~= "EREV" then return nil end
    local rp = vehicle:getPartById("NEVRangeExtender")
    if not rp or not rp:getInventoryItem() or rp:getCondition() <= 0 then return "broken" end
    if DashInfo.fuel(vehicle) <= 0 then return "noFuel" end
    if State.get(vehicle).rexOn then return "on" end
    return "idle"
end

-- Regen indication: powered, slowing down, no throttle (same rule as
-- Parts.updateBattery, which books the energy).
function DashInfo.regenActive(running, prevSpeed, speed, gas)
    if not running or gas or prevSpeed == nil then return false end
    local a, b = math.abs(prevSpeed), math.abs(speed or 0)
    return b < a and a >= DashInfo.REGEN_MIN_KMH
end

-- Charging summary or nil: { kind = "fast"|"slow", minutes = n }
function DashInfo.charging(vehicle)
    local st = State.get(vehicle)
    if not st.charge then return nil end
    local cfg = Registry.get(vehicle)
    local soc = Battery.getSoc(vehicle)
    local cap = Battery.capacityKWh(vehicle)
    local left = Charging.minutesLeft(soc, cap, Charging.rateKW(cfg, st.charge.kind, cap, Battery.nominalKWh(vehicle))) or 0
    return { kind = st.charge.kind, minutes = math.floor(left + 0.5) }
end

-- Screens and the daily-info block are lit while the car has power:
-- powered on, or camping (UI-DESIGN 2.3).
function DashInfo.powered(vehicle)
    return vehicle:isEngineRunning() or State.get(vehicle).camping == true
end

-- Which side of the car a port is on: "left" | "right" | nil.
function DashInfo.portSide(side)
    if type(side) ~= "string" then return nil end
    if string.find(side, "Right", 1, true) then return "right" end
    if string.find(side, "Left", 1, true) then return "left" end
    return nil
end

function DashInfo.chargePortSide(vehicle)
    local cfg = Registry.get(vehicle)
    return cfg and DashInfo.portSide(cfg.chargePortSide) or nil
end

function DashInfo.fuelPortSide(vehicle)
    if vehicle:leftSideFuel() then return "left" end
    if vehicle:rightSideFuel() then return "right" end
    return nil
end

-- Infotainment screen (UI-DESIGN 13): the "Radio" part holds a television
-- item (NEVLib.InfotainmentScreen). Old saves may still carry a radio there.
function DashInfo.hasScreen(vehicle)
    local part = vehicle:getPartById("Radio")
    if not part or not part:getInventoryItem() then return false end
    local dd = part:getDeviceData()
    return dd ~= nil and dd:getIsTelevision() == true
end

---------------------------------------------------------------------------
-- Daily info (UI-DESIGN 2.3 (5)): clock, date, temperatures
---------------------------------------------------------------------------

-- timeOfDay: hours as a float (GameTime:getTimeOfDay()).
function DashInfo.clockText(timeOfDay, h24)
    local total = math.floor((timeOfDay or 0) * 60 + 0.5) % (24 * 60) -- kahlua-mod-ok: operands never negative
    local h, m = math.floor(total / 60), total % 60 -- kahlua-mod-ok: operands never negative
    if h24 then return string.format("%02d:%02d", h, m) end
    local suffix = h < 12 and "AM" or "PM"
    local h12 = h % 12 -- kahlua-mod-ok: operands never negative
    if h12 == 0 then h12 = 12 end
    return string.format("%d:%02d %s", h12, m, suffix)
end

-- month, day: 0-based like GameTime:getMonth() / getDay().
function DashInfo.dateText(month, day)
    return Util.text("IGUI_NEV_Dash_Date", tostring((month or 0) + 1), tostring((day or 0) + 1))
end

-- Short date "7/12" (V2): month / day, 1-based, ASCII only.
function DashInfo.shortDate(month, day)
    return string.format("%d/%d", (month or 0) + 1, (day or 0) + 1)
end

-- Whole degrees like a car display (vanilla Temperature.getTemperatureString
-- has a decimal, too wide for the dashboard); the unit follows the game's
-- Celsius / Fahrenheit option. The degree sign comes from the translation
-- file: non-ASCII characters in Lua source are mangled by the game (V5).
function DashInfo.tempText(celsius, asCelsius)
    local v = asCelsius and celsius or (celsius * 9 / 5 + 32)
    return Util.text(asCelsius and "IGUI_NEV_Dash_TempC" or "IGUI_NEV_Dash_TempF", tostring(math.floor(v + 0.5)))
end

-- Temperatures (W2): inside = what the player's watch shows in the car
-- (ClimateManager.getAirTemperatureForCharacter: the cabin, insulation and
-- heater included); outside = the air on the car's square without the car.
-- vehicle:getInsideTemperature() is only the heater's offset, not a temperature.
function DashInfo.temperatures(vehicle, player)
    local cm = getClimateManager()
    local sq = vehicle:getSquare()
    local outside = sq and cm:getAirTemperatureForSquare(sq) or cm:getTemperature()
    local inside = (player and player:getVehicle() == vehicle) and cm:getAirTemperatureForCharacter(player, false) or outside
    return outside, inside
end

-- Daily block (V2): "7/12 14:35" and "18°C / 22°C"; the tooltip spells out
-- the full date and which temperature is which.
function DashInfo.daily(vehicle, player)
    local gt = getGameTime()
    local core = getCore()
    local c = core:getOptionDisplayAsCelsius()
    local outside, inside = DashInfo.temperatures(vehicle, player)
    local clock = DashInfo.clockText(gt:getTimeOfDay(), core:getOptionClock24Hour())
    local outT, inT = DashInfo.tempText(outside, c), DashInfo.tempText(inside, c)
    return {
        line1 = DashInfo.shortDate(gt:getMonth(), gt:getDay()) .. " " .. clock,
        line2 = outT .. " / " .. inT,
        tip = Util.text("IGUI_NEV_Dash_DailyTip", DashInfo.dateText(gt:getMonth(), gt:getDay()), clock, outT, inT),
    }
end

-- Vehicle access badge (UI-DESIGN 19): "hacked" | "key" | "none". A key on
-- the player (phone-key style), a key left in the ignition or the easy-use
-- sandbox option = "key" - the same cases Power.driverCanPower accepts
-- (REVIEW 3.2-9: the car powered on with the key in the ignition while the
-- badge said "no key").
function DashInfo.access(vehicle, player)
    if vehicle:isHotwired() then return "hacked" end
    if vehicle:isKeysInIgnition() then return "key" end
    if SandboxVars and SandboxVars.VehicleEasyUse then return "key" end
    if player and player:getInventory():haveThisKeyId(vehicle:getKeyId()) ~= nil then return "key" end
    return "none"
end

-- Range split for the tooltip (W6): battery km, fuel km (EREV), kWh / 100 km.
function DashInfo.rangeParts(vehicle)
    local cfg = Registry.get(vehicle)
    local st = State.get(vehicle)
    local fuel = DashInfo.fuel(vehicle)
    local ev, total = Powertrain.rangeKm(cfg, Battery.getSoc(vehicle), Battery.capacityKWh(vehicle), st.kwhPerKm, fuel)
    local per100 = (st.kwhPerKm or Powertrain.defaultKwhPerKm(cfg)) * 100
    return ev, cfg.powertrain == "EREV" and math.max(0, total - ev) or 0, per100
end

return DashInfo
