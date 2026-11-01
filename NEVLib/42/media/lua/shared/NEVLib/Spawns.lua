-- NEV Lib: where NEVs spawn (DESIGN 10.1, #222, user 2026-10-16).
-- Every registered NEV spawns wherever vanilla spawns ordinary cars (ZONES), as a SHARE of the cars each zone
-- table spawns: the weight is worked out from the table's final total, so other vehicle mods (KI5 adds 1-5 per
-- car to the same tables) cannot dilute it away. Every car gets BASE everywhere (parking stalls - roadside, homes,
-- shop and gas station lots - are 3/4 of the map's vehicle zones); a model pack may set more for a zone in
-- `spawn` (the L6: good / medium). x the sandbox SpawnRate, the NEVs of one table capped at CAP together.
-- The tables are written when the world is set up and again once the save's sandbox values are loaded
-- (OnLoadMapZones): OnInitWorld fires before vanilla loads them (IsoWorld.init), so a continued save saw the
-- default 1 there (v1.0-v1.2, #222).
require "NEVLib/Util"
require "NEVLib/Config"
require "NEVLib/Registry"

local Util, Config, Registry = NEVLib.Util, NEVLib.Config, NEVLib.Registry
local Spawns = {}
NEVLib.Spawns = Spawns

-- vanilla's ordinary-car tables (shared/VehicleZoneDefinition.lua, B42): parking stalls (unnamed zones), trailer
-- parks, poor / middle / rich areas, sports cars, junkyards, the road traffic jams (one table shared by the four
-- directions; random jams use them too). Themed lots (police, Spiffo ...) spawn parking stall cars most of the
-- time (chanceToSpawnNormal); story-only tables (trades, evacuee ...) are not map zones.
Spawns.ZONES = { "parkingstall", "trailerpark", "bad", "medium", "good", "sport", "junkyard",
                 "trafficjamw", "trafficjame", "trafficjamn", "trafficjams" }
Spawns.BASE = 0.02     -- share of each table's cars, every NEV, SpawnRate 1
Spawns.CAP = 0.5       -- all NEVs of one table together, after SpawnRate

local zoneSet = {}
for _, z in ipairs(Spawns.ZONES) do zoneSet[z] = true end

-- Problems of a model's `spawn` declaration ({ zone = share }), for Registry.validate.
function Spawns.validate(spawn)
    local problems = {}
    if spawn == nil or spawn == false then return problems end
    if type(spawn) ~= "table" then return { "spawn must be a table" } end
    for zone, share in pairs(spawn) do
        if not zoneSet[zone] then problems[#problems + 1] = "spawn zone " .. tostring(zone) end
        if type(share) ~= "number" or share < 0 or share > Spawns.CAP then
            problems[#problems + 1] = "spawn share " .. tostring(zone) .. "=" .. tostring(share)
        end
    end
    return problems
end

-- { zone = share } of one registered model at SpawnRate 1.
function Spawns.shares(model)
    local out = {}
    for _, z in ipairs(Spawns.ZONES) do
        local s = model.spawn and model.spawn[z]
        out[z] = (type(s) == "number") and s or Spawns.BASE
    end
    return out
end

-- Write every registered NEV into the zone tables of `vzd` (VehicleZoneDistribution) at `mult`.
-- Returns { [zone] = { [script] = weight } } for the log and the tests.
function Spawns.apply(mult, vzd)
    vzd = vzd or VehicleZoneDistribution
    local result = {}
    if not vzd then return result end
    mult = math.max(0, tonumber(mult) or 1)
    local models, names = Registry.all(), {}
    for _, m in pairs(models) do names[#names + 1] = m.scriptName end
    Util.sort(names, function(a, b) return a < b end)
    local nev = {}
    for _, n in ipairs(names) do nev[n] = true end
    local done = {}                           -- the traffic jam tables are one table
    for _, zone in ipairs(Spawns.ZONES) do
        local t = vzd[zone] and vzd[zone].vehicles
        if t and not done[t] then
            done[t] = true
            local others = 0
            for name, def in pairs(t) do
                if not nev[name] and type(def) == "table" and type(def.spawnChance) == "number" then
                    others = others + def.spawnChance
                end
            end
            local want, total = {}, 0
            for _, n in ipairs(names) do
                want[n] = Spawns.shares(Registry.getByName(n))[zone] * mult
                total = total + want[n]
            end
            local scale = (total > Spawns.CAP) and (Spawns.CAP / total) or 1
            local nevShare = total * scale
            result[zone] = {}
            for _, n in ipairs(names) do
                local share = want[n] * scale
                if share > 0 and others > 0 then
                    -- weight w gives w / (others + all NEV weights) = share
                    local w = others * share / (1 - nevShare)
                    t[n] = { index = -1, spawnChance = w }
                    result[zone][n] = w
                else
                    t[n] = nil
                end
            end
        elseif not t then
            Util.log("SPAWN", { event = "missingZone", zone = zone })
        end
    end
    return result
end

local function applyFromSandbox(when)
    local mult = Config.get("SpawnRate")
    local r = Spawns.apply(mult)
    local fields = { when = when, mult = mult }
    for _, zone in ipairs({ "parkingstall", "good", "medium" }) do
        for n, w in pairs(r[zone] or {}) do fields[zone .. ":" .. n] = string.format("%.2f", w) end
    end
    Util.log("SPAWN", fields)
end

-- the first: a new game (the sandbox screen has set the values); the second: every load, after vanilla has read
-- the save's sandbox values and before any chunk spawns cars
Events.OnInitWorld.Add(Util.guard("spawnsInitWorld", function() applyFromSandbox("initWorld") end))
Events.OnLoadMapZones.Add(Util.guard("spawnsMapZones", function() applyFromSandbox("mapZones") end))

return Spawns
