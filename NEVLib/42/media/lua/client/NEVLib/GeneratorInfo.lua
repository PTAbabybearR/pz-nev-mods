-- NEV Lib: NEV charging in the vanilla generator info window (M1 issue 15,
-- DESIGN 6.3). The window's "power consumption" list comes from map objects
-- only (IsoGenerator.setSurroundingElectricity); a placed home charger is an
-- item, and the fuel of every charge on generator power (home charger or
-- pump) is taken per kWh by NEVLib.Charging.burnFuel. This only adds the line
-- and the total to the text - the fuel accounting stays as it is. A power
-- station charging on the generator gets its own line (round 4).
require "NEVLib/Util"
require "ISUI/ISGeneratorInfoWindow"
require "NEVLib/Charging"
require "NEVLib/PowerStation"

local Util, Charging, PowerStation = NEVLib.Util, NEVLib.Charging, NEVLib.PowerStation
local GeneratorInfo = {}
NEVLib.GeneratorInfo = GeneratorInfo

GeneratorInfo.CACHE_MS = 1000 -- the window rebuilds its text every frame

-- Java DecimalFormat "#.#### L/h" (IsoGenerator.decimalFormat).
function GeneratorInfo.litresPerHour(v)
    local s = string.format("%.4f", v):gsub("0+$", ""):gsub("%.$", "")
    return s .. " L/h"
end

local cache = {}
-- Vehicles charging on `generator` and their fuel use in L/h (cached).
function GeneratorInfo.load(generator)
    local now = getTimestampMs()
    local c = cache[generator]
    if c and now < c.expires then return c.n, c.lph end
    local n, lph = Charging.generatorLoad(generator)
    cache[generator] = { n = n, lph = lph, expires = now + GeneratorInfo.CACHE_MS }
    return n, lph
end

-- Inserts "NEV charging xN (… L/h)" and "Power station charging xN (… L/h)"
-- before the generator's own line and adds the load to the total. Returns the
-- new text, or nil to keep vanilla's.
function GeneratorInfo.amend(object, displayStats, text)
    if not displayStats or not object:isActivated() then return nil end
    local n, carLoad = GeneratorInfo.load(object)
    local ns, stationLoad = PowerStation.generatorLoad(object)
    if n <= 0 and ns <= 0 then return nil end
    local load = carLoad + stationLoad
    local line = ""
    if n > 0 then
        line = line .. "   " .. Util.text("IGUI_NEV_GenCharger") .. " x" .. n
            .. " (" .. GeneratorInfo.litresPerHour(carLoad) .. ") <LINE> "
    end
    if ns > 0 then
        line = line .. "   " .. Util.text("IGUI_NEV_GenStation") .. " x" .. ns
            .. " (" .. GeneratorInfo.litresPerHour(stationLoad) .. ") <LINE> "
    end
    local own = getText("IGUI_Generator_TypeGas") .. " (" .. object:getBasePowerConsumptionString() .. ")"
    local at = string.find(text, own, 1, true)
    if at then
        text = string.sub(text, 1, at - 1) .. line .. string.sub(text, at)
    else
        text = text .. " <LINE> " .. line
    end
    local total = getText("IGUI_Total") .. ": " .. object:getTotalPowerUsingString()
    local t = string.find(text, total, 1, true)
    if t then
        local newTotal = getText("IGUI_Total") .. ": " .. GeneratorInfo.litresPerHour(object:getTotalPowerUsing() + load)
        text = string.sub(text, 1, t - 1) .. newTotal .. string.sub(text, t + #total)
    end
    return text
end

local amendGuarded = Util.guard("generatorInfo", function(object, displayStats, text)
    return GeneratorInfo.amend(object, displayStats, text)
end)

local origRichText = ISGeneratorInfoWindow.getRichText
function ISGeneratorInfoWindow.getRichText(object, displayStats)
    local text = origRichText(object, displayStats)
    return amendGuarded(object, displayStats, text) or text
end

return GeneratorInfo
