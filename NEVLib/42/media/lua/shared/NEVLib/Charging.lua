-- NEV Lib: charging (DESIGN 6). Fast charging at a powered gas pump, slow
-- charging at a placed home charger. Charging runs in the background: the
-- battery part update adds the energy, so the player may walk away.
--
-- Charging stops when the battery is full, the source loses power or is
-- gone, or the vehicle moved more than MOVE_LIMIT tiles from where charging
-- started (DESIGN 6.1). After the area was unloaded, the elapsed time is
-- charged if the source is powered at the moment the vehicle loads again
-- (DESIGN 6.1: no back-dating of an outage).
require "NEVLib/Util"
require "NEVLib/Config"
require "NEVLib/Registry"
require "NEVLib/State"

local Util, Config, Registry, State = NEVLib.Util, NEVLib.Config, NEVLib.Registry, NEVLib.State
local Charging = {}
NEVLib.Charging = Charging

Charging.CHARGER_MOVEABLE_ITEM = "NEVLib.HomeCharger2"     -- v1.10: placed as a Moveable tile object
Charging.CHARGER_TILESET = "nev_charger_01_"            -- its sprites (art/items/gen_tiles.py)
Charging.MOVE_LIMIT = 3          -- tiles the car may move before charging stops
Charging.START_RANGE = 6         -- tiles between car centre and source (models without a port area)
Charging.PORT_RANGE = 2          -- tiles between charging port and source, like vanilla refuelling
-- Vanilla's default GeneratorFuelConsumption (SandboxOptions): the fuel per
-- kWh scales with the server's value relative to it (DESIGN 6.3).
Charging.VANILLA_GEN_CONSUMPTION = 0.1

---------------------------------------------------------------------------
-- Pure
---------------------------------------------------------------------------

-- Charging time (DESIGN 6.2, "megawatt flash charging"): a 0 -> 100 % fast
-- charge takes a vanilla full refuel (49 L at 0.277 game min/L, M0 V11) times
-- the sandbox multiplier, scaled by battery size against a 75 kWh pack.
-- Home charger (I-235, user 2026-10-12): one charger power for every car,
-- set so the BEV reference (Li MEGA, 102.7 kWh) fills in the sandbox hours
-- (default 7: one vanilla sleep on an ordinary bed when gone to bed within an
-- hour of the tired moodle, 7-8 h); smaller batteries fill sooner, like real
-- cars (L6 51 kWh about 3.5 h).
Charging.REFUEL_FULL_MINUTES = 13.6
Charging.REFERENCE_KWH = 75
Charging.SLOW_REFERENCE_KWH = 102.7

-- the home charger's power in kW (the same for every car)
function Charging.slowKW()
    return Charging.SLOW_REFERENCE_KWH / Config.get("SlowChargeHours")
end

-- `kwh`: the nominal capacity of the battery fitted (DESIGN 6.2 revision 17: the time follows the battery);
-- default the car's reference (its powertrain's middle battery).
function Charging.fullMinutes(cfg, kind, kwh)
    kwh = kwh or (cfg and cfg.batteryKWh)
    if not cfg or not kwh or kwh <= 0 then return nil end
    local fast = Charging.REFUEL_FULL_MINUTES * Config.get("FastChargeTime") * kwh / Charging.REFERENCE_KWH
    if kind == "fast" then return fast end
    return kwh / Charging.slowKW() * 60
end

-- Charging power in kW. Fast: 0 -> 100 % of the actual (possibly worn)
-- capacity takes fullMinutes. Slow: the charger's fixed power (a worn battery
-- holds less, so it fills sooner).
function Charging.rateKW(cfg, kind, capKWh, kwh)
    if kind == "slow" then
        if not cfg or not cfg.batteryKWh or cfg.batteryKWh <= 0 or not capKWh or capKWh <= 0 then return 0 end
        return Charging.slowKW()
    end
    local minutes = Charging.fullMinutes(cfg, kind, kwh)
    if not minutes or minutes <= 0 or not capKWh or capKWh <= 0 then return 0 end
    return capKWh / (minutes / 60)
end

-- Minutes left until full at the current rate.
function Charging.minutesLeft(soc, capKWh, kw)
    if kw <= 0 then return nil end
    return (1 - soc) * capKWh / kw * 60
end

---------------------------------------------------------------------------
-- World helpers
---------------------------------------------------------------------------

-- Same rule as the vanilla "refuel from pump" menu (ISVehicleMenu): grid
-- power, or a generator when exterior generators are allowed.
function Charging.squarePowered(sq)
    if not sq then return false end
    if sq:hasGridPower() then return true end
    return Config.vanilla("AllowExteriorGenerator", true) and sq:haveElectricity()
end

local function eachSquare(x, y, z, radius, fn)
    local cell = getCell()
    for dy = -radius, radius do
        for dx = -radius, radius do
            local sq = cell:getGridSquare(math.floor(x) + dx, math.floor(y) + dy, z)
            if sq then
                local r = fn(sq)
                if r ~= nil then return r end
            end
        end
    end
    return nil
end

-- A gas pump object: its sprite has the fuelAmount property (IsoObject.
-- getPipedFuelAmount:2382, DESIGN 13.5-20). Not getPipedFuelAmount() > 0 as
-- in ISVehiclePartMenu.getNearbyFuelPump: that is the fuel left (0 once
-- pumped dry, -1 unpowered and never read), and fast charging does not use
-- the pump's fuel (DESIGN 6.1; REVIEW 3.1-1: empty pumps could not charge).
local function isPump(obj)
    local sprite = obj:getSprite()
    return sprite ~= nil and sprite:getProperties():has(IsoPropertyType.FUEL_AMOUNT)
end

local function pumpOn(sq)
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if isPump(obj) then return obj end
    end
    return nil
end

-- A home charger on the square: the Moveable tile object (v1.10, by sprite
-- name - the Moveable flow keeps no item type on the object). The old placed
-- world item NEVLib.HomeCharger was never released and is gone (REVIEW
-- 3.3-13), and with it the scan of the square's world items.
local function isChargerTile(obj)
    local sprite = obj:getSprite()
    local name = sprite and sprite:getName()
    return name ~= nil and string.sub(name, 1, #Charging.CHARGER_TILESET) == Charging.CHARGER_TILESET
end
Charging.isChargerTile = isChargerTile

local function chargerOn(sq)
    local tiles = sq:getObjects()
    for i = 0, tiles:size() - 1 do
        local obj = tiles:get(i)
        if isChargerTile(obj) then return obj end
    end
    return nil
end
Charging.isPump = isPump
Charging.pumpOn = pumpOn
Charging.chargerOn = chargerOn

---------------------------------------------------------------------------
-- Charging port (user rule 2026-10-07, via session B's UI design): the
-- charger must be within PORT_RANGE squares of the vehicle's charging port
-- area centre - the same rule as vanilla refuelling, where the pump must be
-- within 2 squares of the GasTank area centre (ISVehiclePartMenu.
-- getNearbyFuelPump). Models without that area fall back to START_RANGE
-- squares around the vehicle centre.
---------------------------------------------------------------------------

-- World position (floats) of the port area centre, or nil (getAreaCenter
-- returns null for an unknown area, BaseVehicle:7531).
local function portPoint(vehicle)
    local cfg = Registry.get(vehicle)
    local area = cfg and cfg.chargePortArea
    if not area then return nil end
    local c = vehicle:getAreaCenter(area)
    if not c then return nil end
    return c:getX(), c:getY()
end

-- Square coordinates of the port area centre, or nil (format agreed with
-- session B's dashboard: two integers).
function Charging.portCenter(vehicle)
    local x, y = portPoint(vehicle)
    if not x then return nil end
    return math.floor(x), math.floor(y)
end

-- With a port: the square box of PORT_RANGE around the port centre's
-- square, exactly like vanilla refuelling (ISVehiclePartMenu.
-- getNearbyFuelPump; user decision 2026-10-07 - v1 follows vanilla, the
-- one-sided feel comes from walking to the port, see Menu.beginCharge).
-- Without a port area: the box of START_RANGE around the vehicle centre.
function Charging.portReaches(vehicle, sq)
    local px, py = Charging.portCenter(vehicle)
    local r = Charging.PORT_RANGE
    if not px then
        px, py, r = math.floor(vehicle:getX()), math.floor(vehicle:getY()), Charging.START_RANGE
    end
    return math.abs(sq:getX() - px) <= r and math.abs(sq:getY() - py) <= r
end

-- A source of `kind` for this vehicle: one the port reaches if there is one,
-- else the nearest one around the vehicle (so the menu can grey it out and
-- say "the port is too far" instead of showing nothing).
function Charging.findSourceFor(vehicle, kind)
    local finder = kind == "fast" and pumpOn or chargerOn
    local z = math.floor(vehicle:getZ())
    local px, py = Charging.portCenter(vehicle)
    if px then
        local hit = eachSquare(px, py, z, Charging.PORT_RANGE, finder)
        if hit then return hit end
    end
    return eachSquare(vehicle:getX(), vehicle:getY(), z, Charging.START_RANGE, finder)
end

function Charging.findPumpNear(x, y, z, radius)
    return eachSquare(x, y, z, radius or Charging.START_RANGE, pumpOn)
end

function Charging.findChargerNear(x, y, z, radius)
    return eachSquare(x, y, z, radius or Charging.START_RANGE, chargerOn)
end

local function sourceOn(sq)
    local pump = pumpOn(sq)
    if pump then return { kind = "fast", obj = pump } end
    local charger = chargerOn(sq)
    if charger then return { kind = "slow", obj = charger } end
    return nil
end

-- Orthogonal neighbours first, then diagonal ones.
local NEIGHBOURS = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 }, { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }

-- The charging source a right-click meant: on one of the clicked squares,
-- else on a square next to one (M1 issue 10: the placed charger is drawn
-- high in its tile, so the click often lands on the neighbour).
-- Returns { kind, obj } or nil.
function Charging.sourceAt(squares)
    for _, sq in ipairs(squares) do
        local hit = sourceOn(sq)
        if hit then return hit end
    end
    local cell = getCell()
    for _, sq in ipairs(squares) do
        for _, d in ipairs(NEIGHBOURS) do
            local n = cell:getGridSquare(sq:getX() + d[1], sq:getY() + d[2], sq:getZ())
            local hit = n and sourceOn(n)
            if hit then return hit end
        end
    end
    return nil
end

-- The source object recorded in the charge state, if it still exists.
function Charging.sourceSquare(charge)
    return getCell():getGridSquare(charge.x, charge.y, charge.z)
end

function Charging.findSource(charge, sq)
    if not sq then return nil end
    if charge.kind == "fast" then return pumpOn(sq) end
    return chargerOn(sq)
end

---------------------------------------------------------------------------
-- Start / stop / per-update check
---------------------------------------------------------------------------

function Charging.isCharging(vehicle)
    return State.get(vehicle).charge ~= nil
end

-- Why charging could not start (nil = can start).
function Charging.cannotStart(vehicle, kind, sourceObj)
    local cfg = Registry.get(vehicle)
    if not cfg then return "notNEV" end
    if kind == "fast" and not Config.get("AllowFastCharge") then return "fastDisabled" end
    if not sourceObj then return "noSource" end
    local soc, part = NEVLib.Battery.getSoc(vehicle)
    if not part then return "noBattery" end
    if soc >= 0.999 then return "full" end
    if not Charging.portReaches(vehicle, sourceObj:getSquare()) then return "portFar" end
    if not Charging.squarePowered(sourceObj:getSquare()) then return "noPower" end
    return nil
end

function Charging.start(vehicle, kind, sourceObj)
    local why = Charging.cannotStart(vehicle, kind, sourceObj)
    if why then return false, why end
    -- the parked time before this moment is not charging time (M1 issue 12)
    NEVLib.Battery.settle(vehicle, "chargeStart")
    local sq = sourceObj:getSquare()
    local st = State.get(vehicle)
    -- t0 / ms0: game hours and real milliseconds at the start, so the stop
    -- line shows both durations (measures game vs real time, M1-FIX-PLAN F8;
    -- ms is meaningless after a save / load)
    st.charge = { kind = kind, x = sq:getX(), y = sq:getY(), z = sq:getZ(),
                  sx = vehicle:getX(), sy = vehicle:getY(),
                  t0 = getGameTime():getWorldAgeHours(), ms0 = getTimestampMs() }
    vehicle:setNeedPartsUpdate(true)
    Util.log("CHARGE", { event = "start", kind = kind, soc = (NEVLib.Battery.getSoc(vehicle)),
                         fullMin = Charging.fullMinutes(Registry.get(vehicle), kind, Registry.installedBatteryKWh(vehicle)) })
    return true
end

function Charging.stop(vehicle, reason)
    local st = State.get(vehicle)
    if not st.charge then return end
    NEVLib.Battery.settle(vehicle, "chargeStop") -- no-op when called from the battery update
    if not st.charge then return end          -- the settle itself ended it (full)
    local c = st.charge
    Util.log("CHARGE", { event = "stop", kind = c.kind, reason = reason or "?",
                         soc = (NEVLib.Battery.getSoc(vehicle)),
                         gameMin = c.t0 and (getGameTime():getWorldAgeHours() - c.t0) * 60 or -1,
                         realMs = c.ms0 and getTimestampMs() - c.ms0 or -1 })
    st.charge = nil
    st.chargeStopReason = reason
end

-- Called from the battery update. Returns the charging power in kW (0 when
-- not charging or paused) and, when charging must end, a stop reason.
function Charging.check(vehicle, cfg, capKWh)
    local st = State.get(vehicle)
    local charge = st.charge
    if not charge then return 0, nil end
    if Util.dist(vehicle:getX(), vehicle:getY(), charge.sx, charge.sy) > Charging.MOVE_LIMIT then
        return 0, "moved"
    end
    local sq = Charging.sourceSquare(charge)
    if not sq then return 0, nil end -- source square not loaded: pause
    if not Charging.findSource(charge, sq) then return 0, "noSource" end
    if not Charging.squarePowered(sq) then return 0, "noPower" end
    return Charging.rateKW(cfg, charge.kind, capKWh, Registry.installedBatteryKWh(vehicle)), nil
end

---------------------------------------------------------------------------
-- Generator fuel (DESIGN 6.3 revision 14, #158): a generator only pays for
-- appliances. While a home charger (Registry.CHARGER_LOAD) or a power station
-- (STATION_CHARGER_LOAD) charges on generator power it burns its load x the
-- vanilla generator consumption x the sandbox factor per hour, whatever the
-- kWh; fast charging adds nothing (vanilla bills the pump). Grid power is
-- free. Placed items never join the generator's own consumer list (13.5-18),
-- so we take the fuel ourselves.
---------------------------------------------------------------------------

-- The nearest running generator whose area covers `sq`: within
-- GeneratorTileRange, on the same level or up to GeneratorVerticalPowerRange
-- levels above / below (IsoGenerator.isPoweringSquare:671; REVIEW 3.2-7: only
-- the same level was searched). Where areas overlap vanilla has no single
-- "the" generator; the nearest one pays. Other levels are only searched when
-- none is on this one (each level is a 41 x 41 square scan).
-- Its fuel and on / off reach the clients by themselves: IsoGenerator.setFuel
-- and setActivated sync() on a server (:482-489, :495-522).
local function scanGenerator(sq, range, vertical)
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local function onLevel(level)
        local best, bestD = nil, 1e9
        eachSquare(x, y, level, range, function(s)
            local gen = s:getGenerator()
            if gen and gen:isActivated() then
                local d = Util.dist(x, y, s:getX(), s:getY())
                if d <= range and d < bestD then best, bestD = gen, d end
            end
            return nil
        end)
        return best
    end
    local best = onLevel(z)
    if best then return best end
    for dz = 1, vertical do
        best = onLevel(z - dz) or onLevel(z + dz)
        if best then return best end
    end
    return nil
end

-- v1.1 (FINAL-REVIEW 2026-10-12 C1): the scan above runs up to 7 levels of 41 x 41 squares, and a power
-- station charging on a generator asked for it twice a frame. The generator found is remembered per
-- square and only re-checked (still running, still standing on its square, still in range); a full scan
-- again when that fails and every GEN_RESCAN_MS, so the nearest one still pays when another is started.
Charging.GEN_RESCAN_MS = 5000
local genMemo, genMemoSize = {}, 0
local function stillPowers(gen, sq, range, vertical)
    if not gen:isActivated() then return false end
    local gs = gen:getSquare()
    if not gs or gs:getGenerator() ~= gen then return false end
    if math.abs(gs:getZ() - sq:getZ()) > vertical then return false end
    return Util.dist(sq:getX(), sq:getY(), gs:getX(), gs:getY()) <= range
end

local function findGenerator(sq)
    local range = Config.vanilla("GeneratorTileRange", 20)
    local vertical = Config.vanilla("GeneratorVerticalPowerRange", 3)
    local key = sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()
    local now = getTimestampMs and getTimestampMs() or 0
    local m = genMemo[key]
    if m and now - m.at < Charging.GEN_RESCAN_MS and stillPowers(m.gen, sq, range, vertical) then return m.gen end
    local gen = scanGenerator(sq, range, vertical)
    if not m then
        if genMemoSize >= 256 then genMemo, genMemoSize = {}, 0 end   -- bounded: a few charging spots at a time
        genMemoSize = genMemoSize + 1
    end
    genMemo[key] = gen and { gen = gen, at = now } or { gen = nil, at = -math.huge }
    return gen
end
Charging.findGenerator = findGenerator

-- Litres of generator fuel per hour for an appliance of `load` (vanilla's own
-- formula, IsoGenerator.update: load x GeneratorFuelConsumption) x the sandbox factor.
function Charging.fuelPerHour(load)
    return load * Config.vanilla("GeneratorFuelConsumption", Charging.VANILLA_GEN_CONSUMPTION)
        * Config.get("GeneratorFuelFactor")
end

-- The generator powering a source square, or nil (grid power, or none).
function Charging.generatorFor(sq)
    if not sq or sq:hasGridPower() then return nil end
    return findGenerator(sq)
end

-- Hours a generator's fuel still runs an appliance of `load` (nil = no limit:
-- free fuel setting).
function Charging.hoursLeft(generator, load)
    local per = Charging.fuelPerHour(load)
    if per <= 0 then return nil end
    return math.max(0, generator:getFuel()) / per
end

-- Take the fuel for `kwh` charged; never below 0. Emptied here -> switch it
-- off ourselves, as vanilla does when its own consumption empties it: vanilla
-- only looks at the fuel when the game hour changes (IsoGenerator.update,
-- IsoGenerator.java:217-237), so an emptied generator kept powering the area
-- for up to an hour (M1-3 issue 4). Off -> the square loses power ->
-- charging stops with noPower.
function Charging.burnFuel(generator, hours, load)
    if not generator or not hours or hours <= 0 then return end
    local left = math.max(0, generator:getFuel() - hours * Charging.fuelPerHour(load))
    generator:setFuel(left)
    if left <= 0 and generator:isActivated() then
        generator:setActivated(false)
        Util.log("CHARGE", { event = "generatorEmpty" })
    end
end

-- Charging load on `generator` right now, for its info window: the number of
-- vehicles on home chargers it powers and their fuel use in litres per hour
-- (the charger's load; a fast charge is vanilla's pump, listed by vanilla). The vanilla window lists only map objects (IsoGenerator.
-- setSurroundingElectricity), so chargers / pumps powering our cars are found
-- here (M1 issue 15). A vehicle stands within START_RANGE of its source and
-- the source within the generator range.
function Charging.generatorLoad(generator)
    local gsq = generator and generator:getSquare()
    if not gsq then return 0, 0 end
    local cell = getCell()
    local r = Config.vanilla("GeneratorTileRange", 20) + Charging.START_RANGE
    local seen, n, lph = {}, 0, 0
    for dy = -r, r, 2 do
        for dx = -r, r, 2 do
            local sq = cell:getGridSquare(gsq:getX() + dx, gsq:getY() + dy, gsq:getZ())
            local v = sq and sq:getVehicleContainer()
            if v and not seen[v] then
                seen[v] = true
                local charge = Registry.isNEV(v) and State.get(v).charge
                if charge and charge.kind == "slow" and Charging.generatorFor(Charging.sourceSquare(charge)) == generator then
                    n = n + 1
                    lph = lph + Charging.fuelPerHour(Registry.CHARGER_LOAD)
                end
            end
        end
    end
    return n, lph
end

return Charging
