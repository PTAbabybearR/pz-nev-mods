-- NEV Lib: the NEVs around the local player, found by one scan that the client modules share (#253-7).
-- 1.3.1 had three of its own: ArmorModels (31 x 31 every 60 frames - more often the higher the frame rate),
-- RexSound (31 x 31 every 500 ms) and ChargeUI (21 x 21 every 2 s). Now one scan every SCAN_MS of real time, and
-- each module gets the list (Nearby.onScan). #327: the scan walks the cell's vehicles (a Java Set: iterator(), no
-- get - DESIGN 13.5-2) and keeps the NEVs within RADIUS on the player's level - the same 61 x 61 square the
-- square scan covered, at about a third of its cost with 30 cars around; run by NEVLib/Schedule.
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/Schedule"

local Registry, Schedule = NEVLib.Registry, NEVLib.Schedule
local Nearby = {}
NEVLib.Nearby = Nearby

Nearby.RADIUS = 30
Nearby.SCAN_MS = 500
Nearby.NEAR = 10                                         -- #327 1d: the cars the armour fast check still looks at

local list = {}
local cfgs = {}                                          -- vehicle -> its Registry entry, for the last scan's list
local nears = {}                                         -- vehicle -> true: within NEAR of the player at the last scan
local listeners = {}

-- The NEVs of the last scan, each once.
function Nearby.list() return list end

-- fn(list, player) after every scan.
function Nearby.onScan(fn) listeners[#listeners + 1] = fn end

-- The Registry entry of a car in the last scan's list, read once by the scan (a listener asking Registry.get again
-- paid a Java call a car every scan, #327 5-6); any other car: Registry.get.
function Nearby.cfg(v) return cfgs[v] or Registry.get(v) end

-- Whether a car of the last scan's list was within NEAR (the same square box as RADIUS) of the player then (#327 1d:
-- read from the scan's own coordinates, no Java call).
function Nearby.near(v) return nears[v] == true end

function Nearby.scan(player)
    local cell = getCell()
    if not cell or not player then return list end
    local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
    local r = Nearby.RADIUS
    local near = Nearby.NEAR
    local found, cfgOf, nearOf = {}, {}, {}
    local it = cell:getVehicles():iterator()
    while it:hasNext() do
        local v = it:next()
        if math.floor(v:getZ()) == pz then
            local dx, dy = math.abs(v:getX() - px), math.abs(v:getY() - py)
            if dx <= r and dy <= r then
                local cfg = Registry.get(v)
                if cfg then
                    found[#found + 1] = v
                    cfgOf[v] = cfg
                    if dx <= near and dy <= near then nearOf[v] = true end
                end
            end
        end
    end
    list, cfgs, nears = found, cfgOf, nearOf
    for _, fn in ipairs(listeners) do fn(found, player) end
    return found
end

local function scanTask()
    local player = getPlayer()
    if player then Nearby.scan(player) end
end

-- tests: one client tick (the scan when it is due, with the other scheduled work)
Nearby.tick = Schedule.tick

-- Scan now (a charge started from the menu shows its bar at once, ChargeUI.rescan).
function Nearby.rescan()
    Schedule.restart("nearbyNEVs")
    scanTask()
end

-- tests
function Nearby.reset() list = {}; cfgs = {}; nears = {}; Schedule.reset() end

Schedule.every("nearbyNEVs", Nearby.SCAN_MS, scanTask)

return Nearby
