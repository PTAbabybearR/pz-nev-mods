-- Copyright (c) 2026 熊叔
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.

-- NEV Lib: vehicle-to-load (#180, docs/design/energy/v2l-design.md). A parked NEV powers the area around it from
-- its traction battery: an invisible vanilla generator (item NEVLib.V2LGenerator, transparent tile nev_v2l_01_0) on
-- the car's square, with vanilla's range and vanilla's per-appliance loads. Players only see the car's menu
-- ("unlock" once with a vanilla generator in the car, then "start" / "stop"); the generator's own menu is removed
-- (client/NEVLib/Menu.lua) and the server refuses the vanilla generator actions on it (below).
--
-- Accounting (3.5): vanilla burns the generator's fuel by the hour (load x GeneratorFuelConsumption, catch-up after a
-- reload included); every battery update takes what it burnt since the last write, x K kWh, off the battery and
-- writes the fuel again. More fuel than written (nobody can add any: refused below) counts as 0.
-- The small tank (3.10.1, r15): the fuel written is the charge above the cutoff, (charge - cutoff) x capacity / K
-- litres, but never more than about 2 hours at the present load (1.9 h x getTotalPowerUsing). With the mod gone
-- nobody refills it, and vanilla switches the left-over generator off within about 2 game hours. So that a chunk
-- away for hours does not run dry on its return, the settlement is noted on the generator (its modData, saved with
-- it): nevT (world hours), nevLoad (the load), nevCap (litres the battery can pay), nevAdd (litres the load-time
-- top-up put in, charged at the next settlement). On load the tank is topped up for the hours away; when vanilla
-- still ran it dry, the hours not paid come off the battery (and the tank while the range extender supplies) and the
-- generator is switched on again if all is paid and the charge is above the cutoff.
--
-- The state lives in the vehicle's NEVLib state: v2l = { unlocked, wearK, on, gx, gy, gz, fuelW, kw, stop }
-- (add-only field, an old save has none = locked). Everything runs on the server (single player: here); a
-- multiplayer client only sends Net commands.
require "NEVLib/Util"
require "NEVLib/Config"
require "NEVLib/Registry"
require "NEVLib/State"
require "NEVLib/Battery"
require "NEVLib/Charging"
require "NEVLib/Power"
-- the vanilla actions refused on our generator (3.9) and the battery uninstall (3.1)
require "TimedActions/ISActivateGenerator"
require "TimedActions/ISPlugGenerator"
require "TimedActions/ISTakeGenerator"
require "TimedActions/ISAddFuel"
require "TimedActions/ISFixGenerator"
require "TimedActions/ISDestroyStuffAction"
require "Vehicles/TimedActions/ISUninstallVehiclePart"

local Util, Config, Registry, State, Battery, Charging, Power =
    NEVLib.Util, NEVLib.Config, NEVLib.Registry, NEVLib.State, NEVLib.Battery, NEVLib.Charging, NEVLib.Power
local V2L = {}
NEVLib.V2L = V2L

V2L.ITEM = Charging.V2L_ITEM
V2L.SPRITE = Charging.V2L_SPRITE
V2L.SHELL = Charging.V2L_SHELL
V2L.MAX_FUEL = 10              -- vanilla clamps the fuel to 0 - 10 (IsoGenerator.setFuel)
V2L.START_MARGIN = 0.01        -- start only 1 point above the cutoff (U4)
V2L.REX_MARGIN = 0.03          -- the range extender starts 3 points above the cutoff while powering (3.1)
V2L.REX_MIN_FUEL = 0.05        -- litres kept in while the range extender supplies, so vanilla does not stop it
                               -- (never above the ceiling, 3.10.1 / review 40.4)
V2L.FUEL_WRITE_EPS = 0.01      -- litres: smaller raises are not written (each setFuel is a packet on a server)
V2L.CAP_HOURS = 1.9            -- the ceiling: hours of the present load (3.10.1; 2 h sits on vanilla's hour boundary)
V2L.CAP_FLOOR = 0.001          -- litres, the ceiling only when the load is 0 (fuel consumption 0: never 0 fuel)
V2L.FUEL_DOWN_EPS = 1e-6       -- litres: more fuel than the target by this is written down (no step, review 41.3);
                               -- above float32 noise (vanilla stores the fuel as a float, review 49.3)
V2L.PAID_EPS = 1e-9            -- kWh still owed that counts as paid (3.10.1 fallback)
V2L.SOC_EPS = 1e-6             -- the charge must be this far above the cutoff to switch on again (not float noise)
V2L.MAX_SPEED = 1              -- km/h: "stopped", as camping (Camping.MAX_SPEED)
V2L.SKILL = 3                  -- Electrical, the vanilla generator rule (ISWorldObjectContextMenuLogic.java:1448)
V2L.VANILLA_LOWER_CHANCE = 30  -- the vanilla generator's ConditionLowerChanceOneIn: wear factor 1
V2L.DEFAULT_LOWER_CHANCE = 10  -- an item script without the line (Item.conditionLowerChance default)
V2L.WEAR_PER_HOUR = 0.05       -- battery condition points per game hour at the reference load (3.4, U8)
V2L.REF_LOAD = 0.278           -- one household's load before the fuel factor (10 L / 360 h at 0.1 L per load)
V2L.RECHECK_TICKS = 30         -- a generator tile loaded: look for its car this many ticks later (3.10)

function V2L.data(vehicle)
    return State.get(vehicle).v2l
end

function V2L.isOn(vehicle)
    local d = State.get(vehicle).v2l
    return d ~= nil and d.on == true
end

function V2L.isUnlocked(vehicle)
    local d = State.get(vehicle).v2l
    return d ~= nil and d.unlocked == true
end

-- The cutoff as 0..1 (sandbox NEVLib.V2LCutoff, 15 - 80 %).
function V2L.cutoff()
    local pct = tonumber(Config.get("V2LCutoff")) or Config.DEFAULTS.V2LCutoff
    return Util.clamp(pct, 15, 80) / 100
end

V2L.isOurs = Charging.isV2LGenerator

---------------------------------------------------------------------------
-- Pure arithmetic (unit tested)
---------------------------------------------------------------------------

-- Litres the charge above the cutoff is worth, for `soc` of a battery holding `capKWh`.
function V2L.chargeFuel(soc, capKWh, cutoff)
    local l = (soc - cutoff) * capKWh / Registry.V2L_KWH_PER_L
    return Util.clamp(l, 0, V2L.MAX_FUEL)
end

-- The fuel ceiling at `using` (getTotalPowerUsing, L/h): 1.9 h of it; CAP_FLOOR only when that is 0 (3.10.1).
function V2L.fuelCap(using)
    local c = V2L.CAP_HOURS * (tonumber(using) or 0)
    if c <= 0 then return V2L.CAP_FLOOR end
    return math.min(c, V2L.MAX_FUEL)
end

-- Litres to keep in the generator: the charge's, at least the range extender's floor while it supplies, never above
-- the ceiling - the floor included: min(REX_MIN_FUEL, ceiling) while it supplies (3.10.1, review 40.4).
function V2L.fuelFor(soc, capKWh, cutoff, using, rexSupplying)
    local l = V2L.chargeFuel(soc, capKWh, cutoff)
    if rexSupplying then l = math.max(l, V2L.REX_MIN_FUEL) end
    return math.min(V2L.fuelCap(using), l)
end

-- Litres the battery can pay for (nevCap): the charge's; at least the ceiling while the range extender supplies (it
-- keeps the charge near the cutoff, review 40.4).
function V2L.payable(soc, capKWh, cutoff, using, rexSupplying)
    local l = V2L.chargeFuel(soc, capKWh, cutoff)
    if rexSupplying then l = math.max(l, V2L.fuelCap(using)) end
    return math.min(l, V2L.MAX_FUEL)
end

-- Write `target` over `now`? Down at once (a lower load lowers the ceiling, review 41.3); up only by
-- min(FUEL_WRITE_EPS, ceiling / 3) (each setFuel is a packet; the ceiling at the base load is below 0.01 L).
function V2L.shouldWrite(now, target, ceiling)
    if now > target + V2L.FUEL_DOWN_EPS then return true end
    return target - now >= math.min(V2L.FUEL_WRITE_EPS, ceiling / 3)
end

-- The hours vanilla burns between two world ages: whole hours passed, (int)now - lastHour (IsoGenerator.update:186).
function V2L.wholeHours(fromH, toH)
    if not fromH or not toH then return 0 end
    return math.max(0, math.floor(toH) - math.floor(fromH))
end

local function worldHours()
    return getGameTime():getWorldAgeHours()
end

-- kWh to take for the generator going from `written` to `now` litres (more fuel than written: nothing).
function V2L.drawKWh(written, now)
    local used = (written or 0) - (now or 0)
    if used <= 0 then return 0 end
    return used * Registry.V2L_KWH_PER_L
end

-- Wear factor of the generator used to unlock: 30 / its ConditionLowerChanceOneIn (3.4).
function V2L.wearFactor(lowerChance)
    local c = tonumber(lowerChance)
    if not c or c <= 0 then c = V2L.DEFAULT_LOWER_CHANCE end
    return V2L.VANILLA_LOWER_CHANCE / c
end

-- Battery condition points for `hours` at `powerUsing` (getTotalPowerUsing: load x GeneratorFuelConsumption).
-- The sandbox fuel factor only changes the fuel: it is taken out again, so the wear follows the load (3.4).
function V2L.wearPoints(wearK, powerUsing, consumption, hours)
    if not consumption or consumption <= 0 or not hours or hours <= 0 then return 0 end
    return V2L.WEAR_PER_HOUR * (wearK or 1) * (powerUsing / consumption) / V2L.REF_LOAD * hours
end

-- Hours left at `kw` (the menu's "about y hours"; nil without a load).
function V2L.hoursLeft(soc, capKWh, cutoff, kw)
    if not kw or kw <= 0 then return nil end
    return math.max(0, (soc - cutoff) * capKWh / kw)
end

-- The range extender's floor while powering: thresholds below it are raised to it (3.1).
function V2L.rexFloor(cutoff)
    return cutoff + V2L.REX_MARGIN
end

---------------------------------------------------------------------------
-- The generator
---------------------------------------------------------------------------

local function squareAt(x, y, z)
    if x == nil then return nil end
    local cell = getCell()
    return cell and cell:getGridSquare(x, y, z)
end

-- The car's generator, if it still stands where the state says.
function V2L.generator(vehicle)
    local d = V2L.data(vehicle)
    if not d or not d.on then return nil end
    local sq = squareAt(d.gx, d.gy, d.gz)
    local gen = sq and sq:getGenerator()
    if gen and V2L.isOurs(gen) then return gen end
    return nil
end

-- The settlement noted on the generator (3.10.1; its modData is saved with it): now, the load, the litres the battery
-- can pay. Written after the fuel, also right after switching on again (nevT is then that moment).
function V2L.note(gen, using, payable)
    local md = gen:getModData()
    md.nevT = worldHours()
    md.nevLoad = using
    md.nevCap = payable
end

-- Off first, then removed (G9: switching off recomputes the power around it and clears the building's toxicity).
local function removeGenerator(gen)
    if not gen then return end
    if gen:isActivated() then gen:setActivated(false) end
    gen:remove()
end
V2L.removeGenerator = removeGenerator

---------------------------------------------------------------------------
-- Unlock (3.0)
---------------------------------------------------------------------------

-- The vanilla rule for connecting a generator.
function V2L.canWire(chr)
    if not chr then return false end
    if chr:getPerkLevel(Perks.Electricity) >= V2L.SKILL then return true end
    return chr:isRecipeActuallyKnown("Generator") == true
end

-- The first generator in the car's containers (part order, then container order); ours never counts.
function V2L.findGenerator(vehicle)
    for i = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(i)
        local c = part and part:getItemContainer()
        local items = c and c:getItems()
        for j = 0, (items and items:size() or 0) - 1 do
            local it = items:get(j)
            if it:hasTag(ItemTag.GENERATOR) and it:getFullType() ~= V2L.ITEM then return it, c end
        end
    end
    return nil, nil
end

function V2L.cannotUnlock(vehicle, chr)
    if not Registry.isNEV(vehicle) then return "notSupported" end
    if V2L.isUnlocked(vehicle) then return "v2lUnlocked" end
    if not V2L.findGenerator(vehicle) then return "v2lNoItem" end
    if not V2L.canWire(chr) then return "v2lSkill" end
    return nil
end

function V2L.unlock(vehicle, chr)
    local why = V2L.cannotUnlock(vehicle, chr)
    if why then return false, why end
    local item, c = V2L.findGenerator(vehicle)
    local k = V2L.wearFactor(item:getConditionLowerChance())
    local typ = item:getFullType()
    -- the server removes it, vanilla tells the clients (ISMultiStageBuild.lua:114 does the same)
    if sendRemoveItemFromContainer then sendRemoveItemFromContainer(c, item) end
    c:Remove(item)
    local st = State.get(vehicle)
    st.v2l = st.v2l or {}
    st.v2l.unlocked = true
    st.v2l.wearK = k
    Util.log("V2L", { event = "unlock", item = typ, wearK = k, player = chr and chr:getUsername() or "?" })
    if chr then Power.tell(chr, "IGUI_NEV_V2LUnlocked", false) end
    return true
end

---------------------------------------------------------------------------
-- Start / stop (3.1)
---------------------------------------------------------------------------

function V2L.cannotStart(vehicle)
    if not Registry.isNEV(vehicle) then return "notSupported" end
    local d = V2L.data(vehicle)
    if not d or not d.unlocked then return "v2lLocked" end
    if d.on then return "v2lOn" end
    if math.abs(vehicle:getCurrentSpeedKmHour()) > V2L.MAX_SPEED then return "moving" end
    local soc, part = Battery.getSoc(vehicle)
    if not part then return "noBattery" end
    if soc <= V2L.cutoff() + V2L.START_MARGIN then return "v2lLowCharge" end
    if State.get(vehicle).charge then return "v2lCharging" end
    local sq = vehicle:getSquare()
    if not sq or sq:getGenerator() then return "v2lNoSquare" end
    return nil
end

-- Vehicles powering right now, for the per-tick toxicity check (3.3): vehicle -> true. Weak keys: a car that left
-- the world is not kept alive by it.
local active = setmetatable({}, { __mode = "k" })
V2L.active = active   -- tests
local otherMemo = {}  -- building -> { hour, found }: another running vanilla generator in it (3.3)
V2L.otherMemo = otherMemo

function V2L.start(vehicle, chr)
    local why = V2L.cannotStart(vehicle)
    if why then return false, why end
    Battery.settle(vehicle, "v2lStart")   -- the time before is not powering time (13.5-16)
    why = V2L.cannotStart(vehicle)
    if why then return false, why end
    local sq = vehicle:getSquare()
    local soc, part = Battery.getSoc(vehicle)
    local cap = Battery.capacityKWh(vehicle)
    local gen = IsoGenerator.new(instanceItem(V2L.ITEM), getCell(), sq)
    -- the spriteName field too (3.10.1 (7)): IsoGenerator(item, ...) sets only the sprite, whose tile a load without
    -- the mod cannot find. IsoObject.save writes the field as a number when the world dictionary or a loaded sprite
    -- knows the name (DictionaryData.getIdForSpriteName), as text otherwise: our tile's own name would go as its
    -- number and be lost without the mod, V2L.SHELL names no tile and stays text through any number of saves. Once
    -- the mod is back the load callback (MapObjects.loadGridSquare:176 in 42.21 and 42.22 falls back to the field, Server.lua registers
    -- both names) and isOurs (the item mark) find it. setSprite(String) sets the field and a texture-only sprite
    -- (IsoObject:1920 in 42.21, :2004 in 42.22), setSprite(IsoSprite) puts the tile back and leaves the field.
    local tile = gen:getSprite()
    gen:setSprite(V2L.SHELL)
    gen:setSprite(tile)
    gen:setConnected(true)
    gen:setCondition(100)
    -- on first: switching on works the load out (IsoGenerator.setSurroundingElectricity:253), the ceiling needs it;
    -- vanilla burns nothing before the next hour (setActivated:469 sets lastHour to this one)
    gen:setActivated(true)
    local using = gen:getTotalPowerUsing()
    gen:setFuel(V2L.fuelFor(soc, cap, V2L.cutoff(), using, false))
    local d = V2L.data(vehicle)
    d.on = true
    d.gx, d.gy, d.gz = sq:getX(), sq:getY(), sq:getZ()
    d.fuelW = gen:getFuel()
    V2L.note(gen, using, V2L.payable(soc, cap, V2L.cutoff(), using, false))
    d.kw = nil
    d.stop = nil
    active[vehicle] = true
    otherMemo[sq:getBuilding() or false] = nil
    vehicle:setNeedPartsUpdate(true)
    Util.log("V2L", { event = "start", soc = soc, cap = cap, fuel = d.fuelW, x = d.gx, y = d.gy, z = d.gz,
                      indoor = sq:getBuilding() ~= nil, player = chr and chr:getUsername() or "?" })
    -- a powered car powers off: driving is blocked while powering (Power.decide, blocker v2l)
    Power.evaluate(vehicle, "v2lOn")
    return true
end

-- Back to driving mode: the generator (and its fuel) is gone. `reason`: manual | cutoff | moved | gone | noBattery.
function V2L.stop(vehicle, reason)
    if not V2L.isOn(vehicle) then return false, "v2lOff" end
    Battery.settle(vehicle, "v2lStop")   -- no-op from inside the battery update
    if not V2L.isOn(vehicle) then return true end   -- the settle itself ended it
    local d = V2L.data(vehicle)
    local gen = V2L.generator(vehicle)
    removeGenerator(gen)
    Util.log("V2L", { event = "stop", reason = reason or "?", soc = (Battery.getSoc(vehicle)), hadGenerator = gen ~= nil,
                      x = d.gx, y = d.gy, z = d.gz })
    d.on = false
    d.gx, d.gy, d.gz = nil, nil, nil
    d.fuelW = nil
    d.kw = nil
    d.stop = reason
    active[vehicle] = nil
    return true
end

---------------------------------------------------------------------------
-- Battery update (called from Parts.updateBattery on the server / single player)
---------------------------------------------------------------------------

local function moved(vehicle, d)
    if math.abs(vehicle:getCurrentSpeedKmHour()) > V2L.MAX_SPEED then return true end
    local sq = vehicle:getSquare()
    return not sq or sq:getX() ~= d.gx or sq:getY() ~= d.gy or sq:getZ() ~= d.gz
end

-- Before the energy integration: what vanilla burnt since the last write (with the load-time top-up), in kWh, and the
-- generator. Ends the mode (moved, generator gone) and returns 0, nil then. Third value, `emptied`: vanilla switched
-- it off - a number when it ran out of fuel (the litres the hours since the last settlement should have burnt at the
-- noted load and did not, for the fallback in afterUpdate), true when it was off with fuel left (ends at the cutoff).
function V2L.beforeUpdate(vehicle)
    local d = V2L.data(vehicle)
    if not d or not d.on then return 0, nil end
    active[vehicle] = true   -- loaded from a save while on
    if moved(vehicle, d) then
        V2L.stop(vehicle, "moved")
        return 0, nil
    end
    local gen = V2L.generator(vehicle)
    if not gen then
        V2L.stop(vehicle, "gone")
        return 0, nil
    end
    local md = gen:getModData()
    local written = (d.fuelW or 0) + (tonumber(md.nevAdd) or 0)   -- the top-up's litres count as written (3.10.1)
    local kwh = V2L.drawKWh(written, gen:getFuel())
    local burnt = math.max(0, written - gen:getFuel())
    d.fuelW = gen:getFuel()
    md.nevAdd = nil   -- settled
    if not gen:isActivated() then
        if gen:getFuel() <= 0 then
            -- vanilla stops it at 0 fuel (IsoGenerator.update:199-202): what it burnt is taken first; the hours it
            -- could not burn for lack of fuel are still owed (whole hours, as vanilla counts them)
            local owed = V2L.wholeHours(md.nevT, worldHours()) * (tonumber(md.nevLoad) or 0) - burnt
            return kwh, gen, math.max(0, owed)
        end
        return kwh, gen, true
    end
    if gen:getCondition() < 100 then gen:setCondition(100) end   -- never backfires / burns (3.4)
    return kwh, gen, false
end

-- The generator ran out of fuel with the mode on (3.10.1 fallback: the top-up came too late, the hours away were more
-- than the battery could pay, or the load jumped just before the hour). `owedL` litres (the hours not burnt, at the
-- noted load) are paid: off the battery down to the cutoff, the rest off the car's tank at its range extender's
-- kWh per litre while the extender supplies. All paid and the charge above the cutoff, or the extender supplying:
-- switched on again (true). Otherwise the mode ends at the cutoff (nil). Returns the charge after paying.
function V2L.payBack(vehicle, gen, soc, capKWh, cutoff, rexSupplying, owedL)
    local owedKWh = owedL * Registry.V2L_KWH_PER_L
    local fromBattery = math.min(owedKWh, math.max(0, (soc - cutoff) * capKWh))
    if fromBattery > 0 then
        soc = soc - fromBattery / capKWh
        Battery.setSoc(vehicle, soc)
    end
    local rest = owedKWh - fromBattery
    local tankL = 0
    if rest > V2L.PAID_EPS and rexSupplying then
        local cfg = Registry.get(vehicle)
        local perL = cfg and tonumber(cfg.rexFuelKWhPerL) or 0
        local gas = vehicle:getPartById("GasTank")
        local have = (gas and gas:getInventoryItem()) and gas:getContainerContentAmount() or 0
        if perL > 0 and have > 0 then
            tankL = math.min(rest / perL, have)
            gas:setContainerContentAmount(have - tankL, false, true)
            vehicle:transmitPartModData(gas)
            rest = math.max(0, rest - tankL * perL)
        end
    end
    local again = rest <= V2L.PAID_EPS and (soc > cutoff + V2L.SOC_EPS or rexSupplying == true)
    Util.log("V2L", { event = "payBack", owedL = owedL, batteryKWh = fromBattery, tankL = tankL, unpaidKWh = rest,
                      soc = soc, again = again })
    if again then
        gen:setActivated(true)   -- vanilla sets lastHour to this hour (IsoGenerator.setActivated:469)
        return soc, true
    end
    V2L.stop(vehicle, "cutoff")
    return soc, nil
end

-- After it: the cutoff, the fuel written for the new charge, the settlement noted, the shown load, the battery wear.
-- rexSupplying: the range extender ran at the end and still has fuel (it keeps the mode on at the cutoff, 3.1).
function V2L.afterUpdate(vehicle, gen, part, soc, capKWh, rexSupplying, elapsedMinutes, emptied)
    local d = V2L.data(vehicle)
    if not gen or not d or not d.on then return end
    local cutoff = V2L.cutoff()
    local again = false
    if type(emptied) == "number" then
        soc, again = V2L.payBack(vehicle, gen, soc, capKWh, cutoff, rexSupplying, emptied)
        if not again then return end
    elseif emptied or (soc <= cutoff and not rexSupplying) then
        V2L.stop(vehicle, "cutoff")
        return
    end
    local using = gen:getTotalPowerUsing()
    local fuel = V2L.fuelFor(soc, capKWh, cutoff, using, rexSupplying)
    if again or V2L.shouldWrite(gen:getFuel(), fuel, V2L.fuelCap(using)) then
        gen:setFuel(fuel)
        d.fuelW = gen:getFuel()
    end
    -- after the fuel (and after switching on again): nevT is this moment (review 44)
    V2L.note(gen, using, V2L.payable(soc, capKWh, cutoff, using, rexSupplying))
    d.kw = math.floor(using * Registry.V2L_KWH_PER_L * 100 + 0.5) / 100
    -- battery wear by load (3.4, U8), counted on the battery part like the range extender's
    local pts = V2L.wearPoints(d.wearK, using, Config.vanilla("GeneratorFuelConsumption", Charging.VANILLA_GEN_CONSUMPTION),
                               elapsedMinutes / 60)
    if part and pts > 0 then
        local md = part:getModData()
        md.v2lWear = (md.v2lWear or 0) + pts
        if md.v2lWear >= 1 then
            local n = math.floor(md.v2lWear)
            md.v2lWear = md.v2lWear - n
            part:setCondition(math.max(0, part:getCondition() - n))
            vehicle:transmitPartCondition(part)
            Util.log("V2L", { event = "wear", points = n, condition = part:getCondition() })
        end
    end
end

---------------------------------------------------------------------------
-- Indoors: vanilla makes the whole building toxic when it starts and every hour (G3); a car's generator must not
-- (U1). Every server tick over the powering cars (usually none: returns at once), cleared unless another running
-- vanilla generator stands in the same building - looked for once per game hour, and again after a vanilla
-- generator was switched on there (ISActivateGenerator below).
---------------------------------------------------------------------------

local function otherGenerator(building, gx, gy, gz)
    local def = building:getDef()
    if not def then return false end
    local cell = getCell()
    for z = def:getMinLevel(), def:getMaxLevel() do
        for x = def:getX(), def:getX2() - 1 do
            for y = def:getY(), def:getY2() - 1 do
                local sq = cell:getGridSquare(x, y, z)
                if sq and sq:getBuilding() == building then
                    local g = sq:getGenerator()
                    if g and g:isActivated() and not V2L.isOurs(g) then return true end
                end
            end
        end
    end
    return false
end
V2L.otherGenerator = otherGenerator

local function hourNow()
    return math.floor(getGameTime():getWorldAgeHours())
end

function V2L.detox()
    for vehicle in pairs(active) do
        local d = nil   -- not "removed and nil or data": that is always data
        if not vehicle:isRemovedFromWorld() then d = V2L.data(vehicle) end
        if not d or not d.on then
            active[vehicle] = nil
        else
            local sq = squareAt(d.gx, d.gy, d.gz)
            local b = sq and sq:getBuilding()
            if b and b:isToxic() then
                local m = otherMemo[b]
                local h = hourNow()
                if not m or m.hour ~= h then
                    m = { hour = h, found = otherGenerator(b, d.gx, d.gy, d.gz) }
                    otherMemo[b] = m
                end
                if not m.found then b:setToxic(false) end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Left-overs (3.10): a generator tile loaded without its car (the car was deleted / towed while unloaded, a crash).
-- MapObjects.OnLoadWithSprite (server/NEVLib/Server.lua) notes the square; RECHECK_TICKS later the car must stand
-- around it (+-2 squares: P3, the car is on its squares at that moment, not yet in the cell's vehicle list) powering
-- with this square, else the generator goes.
---------------------------------------------------------------------------

local pending = {}
V2L.pending = pending   -- tests
local tick = 0

-- Load-time top-up (3.10.1): vanilla is about to catch up the whole hours the chunk was away at the saved load
-- (IsoGenerator.update:186-203); the small tank would run dry. Filled to the ceiling plus those hours, at most what
-- the battery could pay (nevCap, the car did not run while away); the litres put in are noted (nevAdd) and charged
-- at the next settlement. An orphan's extra fuel goes with it RECHECK_TICKS later.
function V2L.topUp(gen)
    if not V2L.isOurs(gen) or not gen:isActivated() then return end
    local md = gen:getModData()
    local load, payable = tonumber(md.nevLoad), tonumber(md.nevCap)
    if not md.nevT or not load or not payable then return end   -- started before 3.10.1: as before
    local hours = V2L.wholeHours(md.nevT, worldHours())
    local want = math.min(payable, V2L.fuelCap(load) + hours * load, V2L.MAX_FUEL)
    local before = gen:getFuel()
    if want <= before then return end
    gen:setFuel(want)
    md.nevAdd = (tonumber(md.nevAdd) or 0) + (gen:getFuel() - before)
    Util.log("V2L", { event = "topUp", hours = hours, load = load, before = before, fuel = gen:getFuel(), add = md.nevAdd })
end

function V2L.onLoadGenerator(obj)
    local sq = obj and obj:getSquare()
    if not sq then return end
    pending[#pending + 1] = { x = sq:getX(), y = sq:getY(), z = sq:getZ(), at = tick + V2L.RECHECK_TICKS }
    V2L.topUp(obj)   -- after: a failing top-up still leaves the orphan check registered
end

local function ownerAround(x, y, z)
    for dx = -2, 2 do
        for dy = -2, 2 do
            local q = squareAt(x + dx, y + dy, z)
            local v = q and q:getVehicleContainer()
            if v and Registry.isNEV(v) then
                local d = V2L.data(v)
                if d and d.on and d.gx == x and d.gy == y and d.gz == z then return v end
            end
        end
    end
    return nil
end

function V2L.recheck(p)
    local sq = squareAt(p.x, p.y, p.z)
    if not sq then return end   -- unloaded again: next load looks again
    local gen = sq:getGenerator()
    if not gen or not V2L.isOurs(gen) then return end
    local owner = ownerAround(p.x, p.y, p.z)
    if owner then
        active[owner] = true
        return
    end
    removeGenerator(gen)
    Util.log("V2L", { event = "orphanRemoved", x = p.x, y = p.y, z = p.z })
end

-- Server / single player, every tick.
function V2L.onTick()
    tick = tick + 1
    if #pending > 0 then
        local keep = {}
        for _, p in ipairs(pending) do
            if tick >= p.at then V2L.recheck(p) else keep[#keep + 1] = p end
        end
        for i = #pending, 1, -1 do pending[i] = nil end
        for i, p in ipairs(keep) do pending[i] = p end
    end
    V2L.detox()
end

---------------------------------------------------------------------------
-- Vanilla actions on our generator (3.9): the server runs only complete() (42.21: NetTimedAction / ActionManager
-- never call isValid there), so complete() is where they are refused - nothing changes, no item is made. isValid
-- is wrapped as well, only so the bar stops at once on the client. A check that throws refuses (refusingOnError).
-- Also: a vanilla generator switched on clears the "other generator" memo (3.3), and the traction battery of a
-- powering car is not uninstalled (3.1; Parts.batteryUninstallTest greys the menu, this is the server side).
---------------------------------------------------------------------------

V2L.GENERATOR_ACTIONS = { "ISActivateGenerator", "ISPlugGenerator", "ISTakeGenerator", "ISAddFuel", "ISFixGenerator",
                          "ISDestroyStuffAction" }
-- The field holding the world object an action works on; "generator" unless listed. The sledgehammer's target is
-- self.item (review 18, note 1: it would smash the hidden generator and drop its fuel).
V2L.ACTION_TARGET = { ISDestroyStuffAction = "item" }
V2L.REFUSE_LOG_MS = 60000   -- a failing refusal check logs at most once a minute

-- A refusal check that fails towards refusing (review 18, must-fix 1). Util.guard would switch it off for good after
-- one error and let every action through - the hidden generator taken with its fuel, the battery pulled while
-- powering. Here each call is its own pcall; an error counts as "refuse" (the action is refused, a vanilla generator's
-- too, until it stops failing) and is logged as ERROR with a count, at most once per REFUSE_LOG_MS (as guardKeep).
local function refusingOnError(name, fn)
    return function(...)
        local ok, r = pcall(fn, ...)
        if ok then return r end
        local e = Util.keepErrors[name] or { count = 0, nextLog = 0 }
        Util.keepErrors[name] = e
        e.count = e.count + 1
        local now = getTimestampMs and getTimestampMs() or 0
        if now >= e.nextLog then
            e.nextLog = now + V2L.REFUSE_LOG_MS
            Util.log("ERROR", { where = name, msg = tostring(r), count = e.count, refused = true })
        end
        return true
    end
end
V2L.refusingOnError = refusingOnError   -- tests

local isOursGuarded = refusingOnError("v2lIsOurs", function(action, field)
    local obj = action ~= nil and action[field] or nil
    return obj ~= nil and V2L.isOurs(obj)
end)

local function wrapAction(name)
    local cls = _G[name]
    if type(cls) ~= "table" or cls.nevV2LWrapped then return false end
    cls.nevV2LWrapped = true
    local field = V2L.ACTION_TARGET[name] or "generator"
    local origComplete, origValid = cls.complete, cls.isValid
    cls.complete = function(self, ...)
        if isOursGuarded(self, field) then
            Util.log("V2L", { event = "refused", action = name,
                              player = self.character and self.character:getUsername() or "?" })
            return false
        end
        if name == "ISActivateGenerator" and self.activate and self.generator then
            local b = self.generator:getSquare() and self.generator:getSquare():getBuilding()
            if b then otherMemo[b] = nil end
        end
        return origComplete(self, ...)
    end
    if origValid then
        cls.isValid = function(self, ...)
            if isOursGuarded(self, field) then return false end
            return origValid(self, ...)
        end
    end
    return true
end

local batteryLockedGuarded = refusingOnError("v2lUninstall", function(action)
    local part, vehicle = action.part, action.vehicle
    return vehicle ~= nil and part ~= nil and part:getId() == "Battery" and Registry.isNEV(vehicle) and V2L.isOn(vehicle)
end)

local function wrapUninstall()
    local cls = ISUninstallVehiclePart
    if type(cls) ~= "table" or cls.nevV2LWrapped then return false end
    cls.nevV2LWrapped = true
    local origComplete = cls.complete
    cls.complete = function(self, ...)
        if batteryLockedGuarded(self) then
            Util.log("V2L", { event = "refused", action = "ISUninstallVehiclePart",
                              player = self.character and self.character:getUsername() or "?" })
            return false
        end
        return origComplete(self, ...)
    end
    return true
end

function V2L.wrapActions()
    for _, name in ipairs(V2L.GENERATOR_ACTIONS) do wrapAction(name) end
    wrapUninstall()
end
V2L.wrapActions()

return V2L
