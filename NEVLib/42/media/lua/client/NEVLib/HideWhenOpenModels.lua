-- Copyright (c) 2026 熊叔
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.

-- NEV Lib: apply hideWhenOpen (shared/NEVLib/HideWhenOpen.lua, GitHub #238) on the client. The NEVs around the local
-- player that declare it come from the shared scan (NEVLib.Nearby, every 500 ms; #253-7: 1.3.1 scanned on its own
-- every 60 frames). A model is re-applied only when an input of HideWhenOpen.visible changed (#327, as
-- NEVLib/ArmorModels): every FAST_MS (Schedule) the declared doors' isOpen(), every scan the item objects of the door
-- parts and model parts; a car entering the scan list is applied once in full. #395: the fast check walks only the
-- cars with a door to look at (a showOpen entry has none), and a model part with no item slot is not looked at (its
-- item never matters to HideWhenOpen.visible, and neither vanilla nor NEVLib ever gives it one).
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/HideWhenOpen"
require "NEVLib/Nearby"
require "NEVLib/Schedule"

local Util, Registry, HideWhenOpen, Nearby, Schedule =
    NEVLib.Util, NEVLib.Registry, NEVLib.HideWhenOpen, NEVLib.Nearby, NEVLib.Schedule

local FAST_MS = 80                                       -- about the 5 frames of 1.3.1 at 60 fps
local watched = setmetatable({}, { __mode = "k" })       -- vehicle -> what is looked at (watch(v, decl))
local fast = setmetatable({}, { __mode = "k" })          -- the cars of `watched` with doors to look at (#395)

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
        local mp = e.part and e.part ~= e.door and v:getPartById(e.part)
        local types = mp and mp:getItemType()                 -- as HideWhenOpen.visible: only an item slot counts
        if types and not types:isEmpty() then part(mp) end
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
                w = watch(v, decl)
                watched[v] = w
                if #w.doors > 0 then fast[v] = w end
                HideWhenOpen.apply(v, decl)
            elseif itemsChanged(w) then
                HideWhenOpen.apply(v, decl)
            end
        end
    end
    for v in pairs(watched) do
        if not inList[v] then watched[v] = nil; fast[v] = nil end
    end
end))

Schedule.every("hideWhenOpen", FAST_MS, function()
    for v, w in pairs(fast) do
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
