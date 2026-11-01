-- NEV Lib: portable power station (DESIGN 6.4, M1 issue 28 plan A): the
-- vanilla "hose + petrol can" for electric cars. A drainable item holding a
-- petrol can's worth of energy; charged on a powered square (generator power costs fuel per kWh,
-- DESIGN 6.3), emptied into a car's traction battery at its charging port.
-- The timed actions (shared/NEVLib/PowerStationActions.lua) move energy in
-- steps through PowerStation.chargeStep / toCarStep.
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/Battery"
require "NEVLib/Charging"

local Util, Registry, Battery, Charging = NEVLib.Util, NEVLib.Registry, NEVLib.Battery, NEVLib.Charging
local PowerStation = {}
NEVLib.PowerStation = PowerStation

PowerStation.ITEM = "NEVLib.PortablePowerStation"
-- Balance (DESIGN 5.3 / 6.4, user 2026-10-10: "it does what the vanilla
-- petrol can does: charging time = filling time, weight = full weight,
-- energy = fuel"): the vanilla PetrolCan holds 10 L (11.6 full: B42 fluids
-- weigh 1 per litre), ISTakeFuel fills it at 50 action units per litre and
-- ISAddGasolineToVehicle pours it at 25 per litre. Its energy is those 10 L
-- at the range extender's exchange rate; a car receives it 1 : 1 (DESIGN 6.4
-- revision 14: one generator rate for every car, so going through a station
-- costs the same fuel per kWh as charging the car on the generator).
-- Timed action units per game minute: vanilla pump refuelling takes 50 units
-- per litre (ISRefuelFromGasPump) and measured 0.277 game minutes per litre
-- (M0 V11, DESIGN 6.2), so about 180 units per game minute.
PowerStation.TICKS_PER_MINUTE = 50 / 0.277
PowerStation.FUEL_L = 10
PowerStation.CAPACITY_KWH = PowerStation.FUEL_L * Registry.FUEL_KWH_PER_L                    -- 30.6
PowerStation.CHARGE_MINUTES = PowerStation.FUEL_L * 50 / PowerStation.TICKS_PER_MINUTE     -- 2.77: empty -> full
PowerStation.DISCHARGE_MINUTES = PowerStation.FUEL_L * 25 / PowerStation.TICKS_PER_MINUTE  -- 1.39: full -> into a car
PowerStation.SPAWN_MAX = 0.5          -- found with 0 - 50 % charge
PowerStation.FULL_EPS = 0.001         -- kWh: "full" tolerance (stored in 1 / 100000 steps)
PowerStation.STEP = 0.00001           -- drainable storage step (UseDelta of the station and the traction battery)

function PowerStation.isStation(item)
    return item ~= nil and item:getFullType() == PowerStation.ITEM
end

-- Carried by `player`: in the main inventory or in a bag he carries
-- (REVIEW 3.2-9: ItemContainer.contains does not look into bags, so a
-- station in a backpack had no menu). Vanilla walks up the same way
-- (ISInventoryTransferAction: getOutermostContainer).
function PowerStation.carriedBy(player, item)
    local inv = player and player:getInventory()
    if not inv or not item then return false end
    if inv:contains(item) then return true end
    local c = item:getContainer()
    return c ~= nil and c:getOutermostContainer() == inv
end

-- The station an action works on (#321). A placed one is taken from the
-- object on the ground: a multiplayer server rebuilds the action from what the
-- client sent (NetTimedAction.parse), and an item argument travels as
-- "container + id" - for a ground item the client's loot-pane floor list,
-- which only holds the 3 x 3 squares around the player, so a station further
-- away arrived as nil. The object travels by square + index, like vanilla's
-- ground actions. nil when the object holds no station (picked up meanwhile).
function PowerStation.actionItem(item, worldObj)
    if worldObj == nil then return item end
    if not instanceof(worldObj, "IsoWorldInventoryObject") then return nil end
    local placed = worldObj:getItem()
    if PowerStation.isStation(placed) then return placed end
    return nil
end

function PowerStation.kwh(item)
    return item:getCurrentUsesFloat() * PowerStation.CAPACITY_KWH
end

function PowerStation.setKwh(item, kwh)
    item:setUsedDelta(Util.clamp(kwh / PowerStation.CAPACITY_KWH, 0, 1))
end

-- Adds `delta` kWh to what the item holds now, in whole storage steps.
-- Reading the current value every time keeps two players working on one
-- station from overwriting each other (REVIEW 3.2-1: writing "start +-
-- moved" did). What does not make a whole step is kept on the item and
-- added next time: a car battery's steps are not whole station steps, and
-- rounding every transfer the same way lost 0.13 kWh per full station.
-- Returns the kWh really added (negative when taken).
function PowerStation.addWhole(item, delta)
    local q = PowerStation.CAPACITY_KWH * PowerStation.STEP
    local md = item:getModData()
    local want = delta + (md.nevStepCarry or 0)
    local cur = PowerStation.kwh(item)
    local new = Util.clamp(cur + math.floor(want / q + 0.5) * q, 0, PowerStation.CAPACITY_KWH)
    PowerStation.setKwh(item, new)
    md.nevStepCarry = Util.clamp(want - (new - cur), -q, q)
    return new - cur
end

-- Found in loot with a random charge, once per item. Called from the
-- OnFillContainer event (server/NEVLib/Distributions.lua): an item script
-- OnCreate runs inside ScriptItem.InstanceItem, and
-- InventoryItemFactory.createItemInternal sets drainables to full (useDelta
-- 1.0) right after it; vanilla loot then randomizes 40 % of them
-- (ItemPickerJava.rollItem) and keeps shop stock full.
function PowerStation.onFound(item)
    if not item then return false end
    local md = item:getModData()
    if md.nevFound then return false end
    md.nevFound = true
    item:setUsedDelta(ZombRandFloat(0, PowerStation.SPAWN_MAX))
    return true
end

---------------------------------------------------------------------------
-- Charging the station (user 2026-10-07, after the first game test: like the
-- vanilla car battery charger - it must be placed on the ground, and the grid
-- only counts indoors; a generator powers it inside or outside)
---------------------------------------------------------------------------

-- Vanilla IsoCarBatteryCharger.update:161: haveElectricity() (generator) or
-- grid power in a room.
function PowerStation.squarePowered(sq)
    return sq ~= nil and (sq:haveElectricity() or (sq:hasGridPower() and sq:getRoom() ~= nil))
end

-- The generator paying for it, or nil (grid power in a room: free). Outdoors
-- before the shutoff the grid does not count, so a generator nearby pays.
function PowerStation.generatorFor(sq)
    if not sq or (sq:hasGridPower() and sq:getRoom() ~= nil) then return nil end
    if not sq:haveElectricity() then return nil end
    return Charging.findGenerator(sq)
end

-- Why it cannot be charged on `sq` (nil = it can); `sq` is where it is placed.
function PowerStation.cannotCharge(item, sq)
    if not PowerStation.isStation(item) then return "notSupported" end
    if PowerStation.kwh(item) >= PowerStation.CAPACITY_KWH - PowerStation.FULL_EPS then return "full" end
    if not PowerStation.squarePowered(sq) then return "stationNoPower" end
    local gen = PowerStation.generatorFor(sq)
    if gen then
        local left = Charging.hoursLeft(gen, Registry.STATION_CHARGER_LOAD)
        if left and left <= 0 then return "stationNoPower" end
    end
    return nil
end

-- Minutes to fill it from its current charge.
function PowerStation.minutesToFull(item)
    local missing = PowerStation.CAPACITY_KWH - PowerStation.kwh(item)
    return math.max(0, missing / PowerStation.CAPACITY_KWH * PowerStation.CHARGE_MINUTES)
end

-- Put up to `kwh` in, limited by room and a generator's fuel (it pays a
-- vanilla battery charger's load for the time it takes, DESIGN 6.4 revision 14). Whole storage steps only (addWhole): adding slivers
-- to the rounded stored value drifted (first game test 7-4). Returns the kWh
-- actually charged.
function PowerStation.chargeStep(item, sq, kwh)
    if kwh <= 0 or PowerStation.cannotCharge(item, sq) then return 0 end
    local cur = PowerStation.kwh(item)
    local room = PowerStation.CAPACITY_KWH - cur
    local add = math.min(kwh, room)
    local gen = PowerStation.generatorFor(sq)
    if gen then
        local hours = Charging.hoursLeft(gen, Registry.STATION_CHARGER_LOAD)
        if hours then add = math.min(add, hours * PowerStation.chargeKW()) end
    end
    if add <= 0 then return 0 end
    add = PowerStation.addWhole(item, add)
    if gen and add > 0 then Charging.burnFuel(gen, add / PowerStation.chargeKW(), Registry.STATION_CHARGER_LOAD) end
    return add
end

---------------------------------------------------------------------------
-- Giving its energy to a car
---------------------------------------------------------------------------

-- Why it cannot charge `vehicle` (nil = it can).
function PowerStation.cannotGive(item, vehicle)
    if not PowerStation.isStation(item) or not Registry.isNEV(vehicle) then return "notSupported" end
    if PowerStation.kwh(item) <= PowerStation.FULL_EPS then return "stationEmpty" end
    local soc, part = Battery.getSoc(vehicle)
    if not part then return "noBattery" end
    if soc >= 0.999 then return "full" end
    return nil
end

-- Station kWh this transfer will take: what it has and the car can hold.
function PowerStation.transferable(item, vehicle)
    local soc, part = Battery.getSoc(vehicle)
    if not part then return 0 end
    local room = (1 - soc) * Battery.capacityKWh(vehicle)
    return math.max(0, math.min(PowerStation.kwh(item), room))
end

function PowerStation.minutesToGive(kwh)
    return kwh / PowerStation.CAPACITY_KWH * PowerStation.DISCHARGE_MINUTES
end

-- Move up to `kwh` (station kWh) into the car's battery. The battery's
-- pending minutes are settled first (DESIGN 13.5-16). The battery also holds
-- its charge in 1 / 100000 steps and other loads change it meanwhile, so only
-- whole battery steps are moved, and the station gives whole steps of its own
-- (addWhole); what does not fit stays with the caller for the next call.
-- Returns the station kWh taken.
function PowerStation.toCarStep(item, vehicle, kwh)
    if kwh <= 0 or PowerStation.cannotGive(item, vehicle) then return 0 end
    Battery.settle(vehicle, "powerStation")
    local cap = Battery.capacityKWh(vehicle)
    local q = cap * PowerStation.STEP
    local move = math.min(kwh, PowerStation.transferable(item, vehicle))
    move = math.floor(move / q + 1e-6) * q
    if move <= 0 then return 0 end
    local soc = Battery.getSoc(vehicle)
    Battery.setSoc(vehicle, soc + move / cap)
    return -PowerStation.addWhole(item, -move)
end

local function stationOn(sq)
    local objects = sq:getWorldObjects()
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if PowerStation.isStation(obj:getItem()) then return obj end
    end
    return nil
end

-- Orthogonal neighbours first, then diagonal ones (same as Charging.sourceAt).
local NEIGHBOURS = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 }, { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }

-- A power station placed on one of `squares` (IsoWorldInventoryObject), else
-- on a square next to one, or nil. A placed 3D item is often drawn across the
-- edge of its tile, so the right-click lands on the neighbour (second game
-- test 2026-10-07; the home charger had the same, M1 issue 10).
function PowerStation.worldAt(squares)
    for _, sq in ipairs(squares) do
        local hit = stationOn(sq)
        if hit then return hit end
    end
    local cell = getCell()
    for _, sq in ipairs(squares) do
        for _, d in ipairs(NEIGHBOURS) do
            local n = cell:getGridSquare(sq:getX() + d[1], sq:getY() + d[2], sq:getZ())
            local hit = n and stationOn(n)
            if hit then return hit end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Generator info window (round 4, user 2026-10-08): a station charging on a
-- generator is listed like a charging car. The window only knows map
-- objects, so the charge actions register here while they run.
---------------------------------------------------------------------------

PowerStation.STALE_MS = 3000 -- an action not seen for this long is gone (cancelled without stop)
PowerStation.charging = {}

function PowerStation.chargeSeen(key, sq)
    PowerStation.charging[key] = { square = sq, seen = getTimestampMs() }
end

function PowerStation.chargeEnded(key)
    PowerStation.charging[key] = nil
end

-- Charging power while an action runs: the full capacity in CHARGE_MINUTES.
function PowerStation.chargeKW()
    return PowerStation.CAPACITY_KWH / (PowerStation.CHARGE_MINUTES / 60)
end

-- Stations charging on `generator` and their fuel use in L/h.
function PowerStation.generatorLoad(generator)
    local now, n = getTimestampMs(), 0
    for key, c in pairs(PowerStation.charging) do
        if now - c.seen > PowerStation.STALE_MS then
            PowerStation.charging[key] = nil
        elseif generator and PowerStation.generatorFor(c.square) == generator then
            n = n + 1
        end
    end
    return n, n * Charging.fuelPerHour(Registry.STATION_CHARGER_LOAD)
end

function PowerStation.log(fields)
    Util.log("POWERSTATION", fields)
end

return PowerStation
