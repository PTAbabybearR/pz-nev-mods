-- NEV Lib: armour models follow the car's state (shared/NEVLib/Armor.lua Armor.applyModels): bull bars the installed
-- item (#229 cat-ear easter egg; the part scripts set setAllModelsVisible = false, so nothing shows a bull bar but
-- this), window armour the window (#317: hidden while its window is rolled down). The NEVs around the local player
-- come from the shared scan (NEVLib.Nearby, every 500 ms of real time; #253-7: 1.3.1 scanned on its own every 60
-- frames).
-- #327: re-applied only when an input of Armor.applyModels changed, found without building a key string (8.6 us a
-- car every 80 ms was the biggest client cost with 30 L6 around). A client gets no Lua event when a part, door or
-- window state arrives from the server, so it still has to look; what it looks at is cached when the car enters
-- the scan list:
--   every FAST_MS (Schedule)  the openable windows of the window armour entries of the cars within Nearby.NEAR (10
--                             tiles) of the player: isOpen() against the last value - a rolled-down window shows its
--                             gap at once;
--   every scan (500 ms)       the bull bar parts, their parent parts and the window armour parts: the installed item
--                             object against the last one - install, uninstall and a multiplayer item resync (which
--                             makes vanilla show every model of the part again) all put a new object there; and the
--                             windows of the cars 10-30 tiles away (#327 1d, coordinator 10-24: 692-765 us / s with 30
--                             L6 around was the biggest client cost; a far car's gap shows within 500 ms).
-- A car entering the list is applied once in full (spawned, loaded, came back in range).
require "NEVLib/Util"
require "NEVLib/Armor"
require "NEVLib/Nearby"
require "NEVLib/Schedule"

local Util, Armor, Nearby, Schedule = NEVLib.Util, NEVLib.Armor, NEVLib.Nearby, NEVLib.Schedule

local FAST_MS = 80
local watched = setmetatable({}, { __mode = "k" })       -- vehicle -> what is looked at (watch(v))
local near = {}                                          -- { v, w } of the watched cars within Nearby.NEAR (last scan)

local function watch(v)
    local w = { parts = {}, items = {}, wins = {}, open = {} }
    local function part(p)
        if p then
            w.parts[#w.parts + 1] = p
            w.items[#w.parts] = p:getInventoryItem()
        end
    end
    for _, id in ipairs(Armor.MODEL_PARTS) do
        local p = v:getPartById(id)
        if p then
            part(p)
            part(p:getParent())
        end
    end
    for _, a in ipairs(Armor.declOf(v) or {}) do
        if a.window then
            part(v:getPartById(a.part))
            local wp = v:getPartById(a.window)
            local win = wp and wp:getWindow()
            if win and win:isOpenable() then
                w.wins[#w.wins + 1] = win
                w.open[#w.wins] = win:isOpen()
            end
        end
    end
    return w
end

-- Whether an installed item changed since the last look (and remember the new ones).
local function itemsChanged(w)
    local changed = false
    for i, p in ipairs(w.parts) do
        local item = p:getInventoryItem()
        if item ~= w.items[i] then
            w.items[i] = item
            changed = true
        end
    end
    return changed
end

-- Whether a window's open state changed since the last look (and remember the new ones).
local function windowsChanged(w)
    local changed = false
    for i, win in ipairs(w.wins) do
        local open = win:isOpen()
        if open ~= w.open[i] then
            w.open[i] = open
            changed = true
        end
    end
    return changed
end

Nearby.onScan(Util.guardKeep("armorModels", function(found)
    local inList, nearNow = {}, {}
    for _, v in ipairs(found) do
        inList[v] = true
        local w = watched[v]
        local isNear = Nearby.near(v)
        if not w then
            w = watch(v)
            watched[v] = w
            Armor.applyModels(v)
        else
            local changed = itemsChanged(w)
            if not isNear and windowsChanged(w) then changed = true end
            if changed then Armor.applyModels(v) end
        end
        if isNear and w.wins[1] then nearNow[#nearNow + 1] = { v, w } end
    end
    near = nearNow
    for v in pairs(watched) do
        if not inList[v] then watched[v] = nil end
    end
end))

Schedule.every("armorModelsFast", FAST_MS, function()
    for _, e in ipairs(near) do
        if windowsChanged(e[2]) then Armor.applyModels(e[1]) end
    end
end)
