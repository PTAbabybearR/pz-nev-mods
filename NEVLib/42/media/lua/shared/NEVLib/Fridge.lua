-- NEV Lib: vehicle fridge (DESIGN 7.1). Stand-alone module: it only uses
-- NEVLib.PowerSupply for electricity, never the battery / powertrain code, so it
-- can become a generic mod later by swapping the provider.
--
-- Vanilla keeps food cold only in a fridge on a powered square, which a car
-- seat is not (M0-REPORT 6). Instead:
--   cold  : container custom temperature = vanilla fridge temperature (0.2)
--   fresh : age taken back by the vanilla fridge factor for the cold minutes
--   power : drawn per part update; long catch-ups after the area was
--           unloaded switch the fridge off at the cutoff mid-interval
--   modes : cool / freeze / heat, the same power (DESIGN 7.1 revision 15, #139 / I-231): freeze keeps its
--           own freezing progress on the food (vanilla thaws anything in a car: never a powered square);
--           heat holds the box at 1.5, under the 1.6 where food starts to cook (Food.java:418)
--   off-car: once the car is powered off the fridge works at most FridgeOffCarHours (24) more game hours,
--           then pauses (switch still on) until the next power-on; camping keeps the car powered
--   unused : a car never powered on (freshly spawned, #319) gets no fridge at all: paused from its first
--           update until the first power-on, whatever FridgeOffCarHours says
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/PowerSupply"

local Util, PowerSupply = NEVLib.Util, NEVLib.PowerSupply
local Fridge = {}
NEVLib.Fridge = Fridge

Fridge.PART_ID = "NEVFridge"
Fridge.TEMPERATURE = 0.2 -- ItemContainer.getTemperature() of a powered vanilla fridge
Fridge.CUTOFF = 0.10     -- DESIGN 7.1 / 20
Fridge.REOPEN = 0.15     -- a fridge switched off by low charge reopens here (DESIGN 7.1 revision 15, D3)
Fridge.MODES = { "cool", "freeze", "heat" }
Fridge.HEAT_TEMPERATURE = 1.5   -- hot food (> 1.3) stays hot; nothing cooks below 1.6 (Food.java:418-419)
Fridge.FREEZE_MINUTES = 240     -- a powered vanilla freezer freezes in 4 hours (Food.java freezingTime +100 / 4 h)
Fridge.OFF_CAR_HOURS = 24       -- default of the sandbox option FridgeOffCarHours (0 = no limit)

local function temperatureOf(mode)
    return mode == "heat" and Fridge.HEAT_TEMPERATURE or Fridge.TEMPERATURE
end
-- 1/6 of a vanilla single fridge's generator load (DESIGN 5.3, user 2026-10-10)
Fridge.DEFAULT_KW = NEVLib.Registry.DEFAULTS.fridgeKW

-- Sandbox "FridgeFactor" / "FoodRotSpeed" option values -> multipliers.
-- Copied from Food.getFridgeFactor / Food.getFoodRotSpeed (private in Java).
local FRIDGE_FACTOR = { [1] = 0.4, [2] = 0.3, [3] = 0.2, [4] = 0.1, [5] = 0.03, [6] = 0.0 }
local ROT_SPEED = { [1] = 1.7, [2] = 1.4, [3] = 1.0, [4] = 0.7, [5] = 0.4 }

function Fridge.fridgeFactor(option) return FRIDGE_FACTOR[option] or 0.2 end
function Fridge.rotSpeed(option) return ROT_SPEED[option] or 1.0 end

---------------------------------------------------------------------------
-- Pure
---------------------------------------------------------------------------

-- Runs the fridge for `minutes` from `soc`, drawing `drawPerMinute` (SOC
-- fraction) and switching off when SOC would fall below `cutoff`.
-- Returns socAfter, coldMinutes, stillOn.
function Fridge.step(soc, minutes, drawPerMinute, cutoff)
    if minutes <= 0 then return soc, 0, soc > cutoff end
    if soc <= cutoff then return soc, 0, false end
    if drawPerMinute <= 0 then return soc, minutes, true end
    local available = (soc - cutoff) / drawPerMinute
    if available >= minutes then
        return soc - minutes * drawPerMinute, minutes, true
    end
    return cutoff, available, false
end

-- Days of age to take back from food that spent `coldMinutes` cold.
function Fridge.ageRefund(coldMinutes, fridgeFactorOption, rotSpeedOption)
    if coldMinutes <= 0 then return 0 end
    local hours = coldMinutes / 60
    return hours * Fridge.rotSpeed(rotSpeedOption) / 24 * (1 - Fridge.fridgeFactor(fridgeFactorOption))
end

---------------------------------------------------------------------------
-- Game glue
---------------------------------------------------------------------------

function Fridge.part(vehicle)
    return vehicle:getPartById(Fridge.PART_ID)
end

function Fridge.isOn(part)
    return part ~= nil and part:getModData().on ~= false
end

-- Settle the fridge's pending minutes under its current on / off state before
-- it changes (Util.settlePart; M1 issue 12: switching on used to refund the
-- spoilage of the time before).
function Fridge.settle(vehicle, why)
    Util.settlePart(vehicle, Fridge.part(vehicle), Fridge.update, why)
end

function Fridge.setOn(vehicle, on)
    local part = Fridge.part(vehicle)
    if not part then return end
    Fridge.settle(vehicle, on and "fridgeOn" or "fridgeOff")
    part:getModData().on = on and true or false
    part:getModData().autoOff = nil   -- a switch by hand (or by power-off rules) is never reopened (D3)
    local c = part:getItemContainer()
    if c then c:setCustomTemperature((on and not Fridge.isPaused(part)) and temperatureOf(Fridge.mode(part)) or 0) end
    vehicle:transmitPartModData(part)
    if on then vehicle:setNeedPartsUpdate(true) end
    Util.log("FRIDGE", { event = "toggle", on = on and true or false })
end

-- Cool / freeze / heat (DESIGN 7.1 revision 15). Settles the minutes so far under the old mode first.
function Fridge.setMode(vehicle, mode)
    local part = Fridge.part(vehicle)
    if not part then return false end
    local known = false
    for _, k in ipairs(Fridge.MODES) do if k == mode then known = true end end
    if not known then return false end
    Fridge.settle(vehicle, "fridgeMode")
    part:getModData().mode = mode
    local c = part:getItemContainer()
    if c and Fridge.isOn(part) and not Fridge.isPaused(part) then c:setCustomTemperature(temperatureOf(mode)) end
    vehicle:transmitPartModData(part)
    vehicle:setNeedPartsUpdate(true)
    Util.log("FRIDGE", { event = "mode", mode = mode })
    return true
end

-- Front seats can reach it from inside; from outside through the driver's
-- door, which must be open or removed - vanilla's seat rule
-- (Vehicles.ContainerAccess.Seat; DESIGN 7.1, REVIEW 3.1-2). A locked door
-- needs no extra check: it cannot be opened.
function Fridge.access(vehicle, part, chr)
    if chr:getVehicle() == vehicle then
        local seat = vehicle:getSeat(chr)
        return seat == 0 or seat == 1
    end
    if chr:getVehicle() then return false end
    if not vehicle:isInArea(part:getArea(), chr) then return false end
    local doorPart = vehicle:getPassengerDoor(0)
    if doorPart and doorPart:getDoor() and doorPart:getInventoryItem() and not doorPart:getDoor():isOpen() then
        return false
    end
    return true
end

local function forEachFood(container, fn)
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        -- B42 milk and some drinks are not Food; vanilla fridges ignore them too (DESIGN 7.1)
        if instanceof(item, "Food") then fn(item) end
    end
end

local function nowHours()
    return getGameTime():getWorldAgeHours()
end

function Fridge.offCarHours()
    local h = NEVLib.Config and NEVLib.Config.get("FridgeOffCarHours")
    if h == nil then h = Fridge.OFF_CAR_HOURS end
    return h
end

function Fridge.mode(part)
    local m = part and part:getModData().mode
    for _, k in ipairs(Fridge.MODES) do if k == m then return m end end
    return "cool"   -- old saves have no mode: cool, as in v1.1
end

function Fridge.isPaused(part)
    return part ~= nil and part:getModData().paused == true
end

-- Minutes of this update the fridge may run: all of them while the car is powered (or camping); after a
-- power-off up to FridgeOffCarHours from the power-off point. The point is set by the first update that
-- sees the car off (an old save: its first update after loading), taken as the start of that interval.
-- A paused fridge gets no live updates (#253-2, Parts.needsLiveUpdates), so the first update after the next
-- power-on spans the whole pause: when the fridge was paused (`wasPaused`) that update is settled by the off-car
-- rule (nothing, the pause ran out long before) instead of counting the pause as powered; it then runs again.
-- A car never powered on (#319, supply.everPowered) gets nothing and is marked `unused`; the update that sees the
-- first power-on spans the unused time and gets nothing either, then the fridge runs from there.
-- Returns the minutes and whether the car is powered now.
local function allowedMinutes(vehicle, data, supply, elapsedMinutes, wasPaused)
    local powered = supply.isPowered and supply.isPowered(vehicle)
    -- asked while powered too: the provider writes the first power-on down
    local used = not supply.everPowered or supply.everPowered(vehicle)
    if data.unused then
        if not powered then return 0, false end
        data.unused, data.offAt = nil, nil
        return 0, true
    end
    if not used and not powered then
        data.unused = true
        return 0, false
    end
    if powered and not wasPaused then
        data.offAt = nil
        return elapsedMinutes, true
    end
    local start = nowHours() - elapsedMinutes / 60
    if data.offAt == nil then data.offAt = start end
    local h = Fridge.offCarHours()
    local minutes = elapsedMinutes
    if h and h > 0 then minutes = math.max(0, math.min(elapsedMinutes, (data.offAt + h - start) * 60)) end
    if powered then data.offAt = nil end
    return minutes, powered
end

-- Freeze mode: our own freezing progress (+100 per 4 cold hours), written back every update so vanilla's
-- thaw between updates never wins; dropped as soon as the food is not being frozen, then vanilla thaws it.
local function freezeFood(container, coldMinutes, freezing)
    forEachFood(container, function(food)
        if not food:canBeFrozen() then return end
        local md = food:getModData()
        if freezing and coldMinutes > 0 then
            local p = math.min(100, (md.nevFreeze or food:getFreezingTime()) + coldMinutes / Fridge.FREEZE_MINUTES * 100)
            food:setFreezingTime(p)
            md.nevFreeze = p
        elseif md.nevFreeze then
            md.nevFreeze = nil
        end
    end)
end

function Fridge.update(vehicle, part, elapsedMinutes)
    local container = part:getItemContainer()
    if not container then return end
    local data = part:getModData()
    if data.on == nil then data.on = true end
    local supply = PowerSupply.forVehicle(vehicle)
    -- D3: only a fridge the low charge switched off reopens, back at 15 % (a manual switch-off, or an old
    -- save's off fridge with no reason recorded, stays off)
    if not data.on and data.autoOff and supply and supply.getSoc(vehicle) >= Fridge.REOPEN then
        data.on, data.autoOff = true, nil
        if isServer and isServer() then vehicle:transmitPartModData(part) end
        Util.log("FRIDGE", { event = "reopen", soc = supply.getSoc(vehicle) })
        if Fridge.onReopen then Fridge.onReopen(vehicle) end
    end
    local mode = Fridge.mode(part)
    local coldMinutes = 0
    local wasPaused = data.paused == true
    data.paused = nil
    if data.on and supply then
        local minutes, powered = allowedMinutes(vehicle, data, supply, elapsedMinutes, wasPaused)
        local soc = supply.getSoc(vehicle)
        local kw = Fridge.kw(vehicle)
        local drawPerMinute = supply.kwhToSoc(vehicle, kw / 60)
        local socAfter, cold, stillOn = Fridge.step(soc, minutes, drawPerMinute, Fridge.CUTOFF)
        coldMinutes = cold
        if cold > 0 then supply.drainKWh(vehicle, cold * kw / 60) end
        if not stillOn then
            data.on, data.autoOff = false, true
            -- multiplayer: the switch-off reaches the clients (REVIEW 3.1-6)
            if isServer and isServer() then vehicle:transmitPartModData(part) end
            Util.log("FRIDGE", { event = "autoOff", soc = socAfter })
        elseif minutes < elapsedMinutes and not powered then
            data.paused = true
            if not wasPaused then Util.log("FRIDGE", { event = "offCarPause", hours = Fridge.offCarHours() }) end
        end
    elseif data.on then
        data.on = false
    end
    if (data.paused == true) ~= wasPaused and isServer and isServer() then vehicle:transmitPartModData(part) end
    local working = data.on and not data.paused
    container:setCustomTemperature(working and temperatureOf(mode) or 0)
    if coldMinutes > 0 and mode ~= "heat" then
        local refund = Fridge.ageRefund(coldMinutes, SandboxVars.FridgeFactor, SandboxVars.FoodRotSpeed)
        forEachFood(container, function(food)
            -- food ages lazily: bring it up to now before taking age back,
            -- otherwise a long catch-up clamps the refund at 0 (M0 V7)
            food:updateAge()
            food:setAge(math.max(0, food:getAge() - refund))
        end)
    end
    freezeFood(container, coldMinutes, mode == "freeze" and working)
    if elapsedMinutes >= 60 then
        Util.log("FRIDGE", { event = "catchUp", minutes = elapsedMinutes, coldMin = coldMinutes,
                             on = data.on == true, mode = mode, paused = data.paused == true })
    end
end

-- Power draw in kW: the model's configured value (if a registry is present)
-- times the accessory multiplier. Soft dependency only, see header.
function Fridge.kw(vehicle)
    local cfg = NEVLib.Registry and NEVLib.Registry.get(vehicle)
    local kw = (cfg and cfg.fridgeKW) or Fridge.DEFAULT_KW
    local mult = NEVLib.Config and NEVLib.Config.get("AccessoryEnergyUse") or 1
    return kw * mult
end

return Fridge
