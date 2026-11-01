-- NEV Lib: which paint a newly spawned car wears (DESIGN 10.1a, GitHub #228, user 2026-10-16: "the wraps stay as
-- rare spawns, stainless as the ordinary one"). Generic: a model pack lists its rare skins in Register.lua
--     rarePaints = { "stealth_black", ... }
-- each the paint part of a skin texture name (Vehicles/nev_cybertruck_shell_stealth_black -> "stealth_black";
-- the whole texture name works too). The rare skins together take RARE_SHARE of the car's spawns, split evenly;
-- the ordinary ones share the rest evenly. No declaration = vanilla's even pick (the L6).
-- Vanilla picks the skin in BaseVehicle.createPhysics: it fires OnSpawnVehicleStart, then, while skinIndex is
-- still -1 (a car being made, not loaded: a saved car has its index), sets Rand.Next(skin count). We pick first
-- from that event, so vanilla's line keeps ours; a car spawned with a chosen skin (debug spawner, addVehicleDebug
-- with an index) and a saved car are never touched, nor a skin a player sets later (ISVehicleColor). It runs where
-- the car is made (the server in multiplayer); clients get the index with the vehicle.
require "NEVLib/Util"

NEVLib = NEVLib or {}
local Util = NEVLib.Util
local Paint = {}
NEVLib.Paint = Paint

Paint.RARE_SHARE = 0.10   -- user 2026-10-16: "about 1 in 10 is a wrap"

-- Problems of a declaration (list of strings, empty when fine); nil / false = none declared.
function Paint.validate(decl)
    local problems = {}
    if decl == nil or decl == false then return problems end
    if type(decl) ~= "table" or #decl == 0 then
        problems[#problems + 1] = "rarePaints: a list of skin names"
        return problems
    end
    local seen = {}
    for i, n in ipairs(decl) do
        if type(n) ~= "string" or n == "" then
            problems[#problems + 1] = "rarePaints[" .. i .. "]: a skin name (string)"
        elseif seen[n] then
            problems[#problems + 1] = "rarePaints[" .. i .. "]: " .. n .. " listed twice"
        end
        if type(n) == "string" then seen[n] = true end
    end
    return problems
end

-- Does the skin texture name match a declared paint name? Whole name, or its last "_"-separated parts.
function Paint.matches(texture, name)
    if texture == name then return true end
    local tail = "_" .. name
    return #texture > #tail and string.sub(texture, -#tail) == tail
end

-- Probability of each skin (1-based, the script's order) for these texture names and rare names, and the
-- declared names that match no skin / more than one. All rare or none rare -> even.
function Paint.weights(textures, rare)
    local n = #textures
    local isRare, unknown, nRare = {}, {}, 0
    for _, name in ipairs(rare or {}) do
        local hits = {}
        for i, t in ipairs(textures) do
            if Paint.matches(t, name) then hits[#hits + 1] = i end
        end
        if #hits == 1 then
            if not isRare[hits[1]] then nRare = nRare + 1 end
            isRare[hits[1]] = true
        else
            unknown[#unknown + 1] = name .. (#hits == 0 and " (no such skin)" or " (matches " .. #hits .. " skins)")
        end
    end
    local w = {}
    for i = 1, n do
        if nRare == 0 or nRare == n then
            w[i] = 1 / n
        elseif isRare[i] then
            w[i] = Paint.RARE_SHARE / nRare
        else
            w[i] = (1 - Paint.RARE_SHARE) / (n - nRare)
        end
    end
    return w, unknown
end

-- The skin (1-based) a uniform u in [0, 1) lands on.
function Paint.pick(w, u)
    local acc = 0
    for i = 1, #w do
        acc = acc + w[i]
        if u < acc then return i end
    end
    return #w
end

-- Texture names of the car's skins, in the script's order (BaseVehicle.getSkin reads the current index's).
function Paint.skinTextures(vehicle)
    local n = vehicle:getSkinCount()
    local keep = vehicle:getSkinIndex()
    local out = {}
    for i = 0, n - 1 do
        vehicle:setSkinIndex(i)
        out[i + 1] = vehicle:getSkin()
    end
    if keep >= 0 and keep < n then vehicle:setSkinIndex(keep) end
    return out
end

-- The 0-based skin index the pack's rarePaints give this car for a uniform u in [0, 1) (nil: no declaration or a
-- single skin). Names that match no skin are logged and left out.
function Paint.pickIndex(vehicle, u)
    local cfg = NEVLib.Registry and NEVLib.Registry.get(vehicle)
    if not cfg or not cfg.rarePaints or vehicle:getSkinCount() < 2 then return nil end
    local w, unknown = Paint.weights(Paint.skinTextures(vehicle), cfg.rarePaints)
    if #unknown > 0 then
        Util.log("ERROR", { where = "Paint", model = vehicle:getScriptName(), rarePaints = table.concat(unknown, ", ") })
    end
    return Paint.pick(w, u) - 1
end

-- OnSpawnVehicleStart: a car still without a skin (-1) gets ours. Returns the index set, or nil.
function Paint.onSpawnStart(vehicle)
    if not vehicle or vehicle:getSkinIndex() ~= -1 then return nil end
    local idx = Paint.pickIndex(vehicle, ZombRand(1000000) / 1000000)
    if idx then vehicle:setSkinIndex(idx) end
    return idx
end

Events.OnSpawnVehicleStart.Add(Util.guardKeep("Paint.onSpawnStart", Paint.onSpawnStart))

return Paint
