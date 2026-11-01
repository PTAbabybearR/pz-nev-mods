-- NEV Lib: apply hideWhenOpen (shared/NEVLib/HideWhenOpen.lua, GitHub #238) on the client. The NEVs around the local
-- player that declare it come from the shared scan (NEVLib.Nearby, every 500 ms; #253-7: 1.3.1 scanned on its own
-- every 60 frames). A model is re-applied only when an input of HideWhenOpen.visible changed (#327, as
-- NEVLib/ArmorModels): every FAST_MS (Schedule) the declared doors' isOpen(), every scan the item objects of the door
-- parts and model parts; a car entering the scan list is applied once in full.
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/HideWhenOpen"
require "NEVLib/Nearby"
require "NEVLib/Schedule"

local Util, Registry, HideWhenOpen, Nearby, Schedule =
    NEVLib.Util, NEVLib.Registry, NEVLib.HideWhenOpen, NEVLib.Nearby, NEVLib.Schedule

local FAST_MS = 80                                       -- about the 5 frames of 1.3.1 at 60 fps
local watched = setmetatable({}, { __mode = "k" })       -- vehicle -> what is looked at (watch(v, decl))

local function watch(v, decl)
    local w = { decl = decl, parts = {}, items = {}, doors = {}, open = {} }
    local function part(p)
        if p then
            w.parts[#w.parts + 1] = p
            w.items[#w.parts] = p:getInventoryItem()
        end
    end
    for _, e in ipairs(decl) do
        local dp = v:getPartById(e.door)
        part(dp)
        if e.part and e.part ~= e.door then part(v:getPartById(e.part)) end
        local d = not e.showOpen and dp and dp:getDoor()
        if d then
            w.doors[#w.doors + 1] = d
            w.open[#w.doors] = d:isOpen()
        end
    end
    return w
end

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

Nearby.onScan(Util.guardKeep("hideWhenOpenScan", function(found)
    local inList = {}
    for _, v in ipairs(found) do
        local cfg = Nearby.cfg(v)                        -- the scan read it (#327 5-6)
        local decl = cfg and cfg.hideWhenOpen
        if decl then
            inList[v] = true
            local w = watched[v]
            if not w then
                watched[v] = watch(v, decl)
                HideWhenOpen.apply(v, decl)
            elseif itemsChanged(w) then
                HideWhenOpen.apply(v, decl)
            end
        end
    end
    for v in pairs(watched) do
        if not inList[v] then watched[v] = nil end
    end
end))

Schedule.every("hideWhenOpen", FAST_MS, function()
    for v, w in pairs(watched) do
        local changed = false
        for i, d in ipairs(w.doors) do
            local open = d:isOpen()
            if open ~= w.open[i] then
                w.open[i] = open
                changed = true
            end
        end
        if changed then HideWhenOpen.apply(v, w.decl) end
    end
end)
