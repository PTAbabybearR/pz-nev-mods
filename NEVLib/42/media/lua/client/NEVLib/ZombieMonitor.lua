-- Copyright (c) 2026 熊叔
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.

-- NEV Lib: pedestrian monitor (DESIGN 11 "行人监控", #182). A local player sitting in an NEV sees the zombies around
-- on vanilla's minimap - drawn over it, only where it shows the world and only on squares the map shows (known or
-- visited; user 11-04) - and, asleep in the car, a zombie within the
-- sandbox radius wakes them the way vanilla's sleep does (Monitor.wake). Client only, each local player their own; no
-- power used, no network messages of ours (vanilla's wakeUp and addSound send theirs). One scan every SCAN_MS
-- (NEVLib/Schedule); the minimap draws the last scan.
require "NEVLib/Util"
require "NEVLib/Config"
require "NEVLib/Registry"
require "NEVLib/Schedule"
require "ISUI/Maps/ISMiniMap"

local Util, Config, Registry, Schedule = NEVLib.Util, NEVLib.Config, NEVLib.Registry, NEVLib.Schedule
local Monitor = {}
NEVLib.ZombieMonitor = Monitor

Monitor.SCAN_MS = 250
Monitor.MAX_DOTS = 200                                   -- a horde: the nearest 200 (260 drew in about 0.4 ms a frame)
Monitor.DOT = 4                                          -- px, a square (DESIGN 11)
-- dark red (170, 30, 0): vanilla's own player / car marker is a 6 px pure red square; 255,140,0 sank into the
-- residential and medical fills (user 11-04), so a darker red, clear of both and of vanilla's marker (CIEDE2000 36.6 /
-- 35.5 / 16.8; user 11-04 via the coordinator: candidate C)
Monitor.COLOR = { a = 1, r = 170 / 255, g = 30 / 255, b = 0 }
Monitor.WAKE_RETRY_MS = 2000                             -- one wakeUp per player per 2 s (MP: until the server's reply)

local dots = {}                                          -- playerNum -> { x1, y1, x2, y2, ... }; nil: not in an NEV
local wokeAt = {}                                        -- playerNum -> getTimestampMs of the last wakeUp

-- The last scan's zombie coordinates for local player n (flat x, y pairs), nil when they are not in an NEV.
function Monitor.dots(n) return dots[n] end

-- Which of `count` zombies (squared distances ds[1..count]) to keep, nearest first by whole tiles: every one nearer than
-- the tile ring where the MAX_DOTS-th falls, then that ring in list order up to MAX_DOTS. One counting pass, no sort
-- (an insertion sort of a 500 horde is 125 000 compares, 4 times a second).
local function keepNearest(ds, count, max)
    local rings = {}
    for i = 1, count do
        local k = math.floor(math.sqrt(ds[i]))
        rings[k] = (rings[k] or 0) + 1
    end
    local cut, sum = 0, 0
    while sum + (rings[cut] or 0) < max do
        sum = sum + (rings[cut] or 0)
        cut = cut + 1
    end
    local keep, room = {}, max - sum                     -- room: how many of ring `cut` still fit
    for i = 1, count do
        local k = math.floor(math.sqrt(ds[i]))
        if k < cut then
            keep[#keep + 1] = i
        elseif k == cut and room > 0 then
            keep[#keep + 1] = i
            room = room - 1
        end
    end
    return keep
end

-- Woken by a zombie the way vanilla's own is (SleepingEvent.update:257-264, in this order): panic +70, stress +0.5, a
-- noise of radius 6 where they lie, the "WakeZombies" music state, then wakeUp with the fast fade. Vanilla's fast
-- fade is data.fastWakeup, a protected field Lua can't set; wakeUp then fades in over 2 s, so the fade is restarted
-- with vanilla's 0.5 - FadeInfo.FadeIn takes whole seconds, so 0.5 is 0, as in vanilla (UIManager.java:1309/1493).
-- MP: the server's WakeUpPlayer goes to the other clients only (WakeUpPlayerPacket.processServer), not back here.
function Monitor.wake(player)
    local stats = player:getStats()
    stats:add(CharacterStat.PANIC, 70)
    stats:add(CharacterStat.STRESS, 0.5)
    addSound(player, math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ()), 6, 1)
    getSoundManager():setMusicWakeState(player, "WakeZombies")
    getSleepingEvent():wakeUp(player)
    UIManager.FadeIn(player:getPlayerNum(), 0.5)
end

-- One local player: keep their zombies (same level, alive, on a square the minimap shows, nearest MAX_DOTS) and wake
-- them when asleep and one is within the radius - any one, mapped or not. zombies: the cell's zombie list (Java
-- ArrayList). Vanilla's minimap always hides what the player hasn't seen (ISMiniMap.lua:726 HideUnvisited) and draws a
-- square known (greyed) or visited (#182 probe 11-04: tile coordinates, either one shows it).
function Monitor.scanPlayer(player, zombies, now)
    local n = player:getPlayerNum()
    local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
    local seen = WorldMapVisited.getInstance()
    local flat, ds, count, nearest = {}, {}, 0, nil
    for i = 0, zombies:size() - 1 do
        local z = zombies:get(i)
        if math.floor(z:getZ()) == pz and not z:isDead() then
            local x, y = z:getX(), z:getY()
            local d2 = (x - px) * (x - px) + (y - py) * (y - py)
            if not nearest or d2 < nearest then nearest = d2 end
            local tx, ty = math.floor(x), math.floor(y)
            if seen:isKnown(tx, ty) or seen:isVisited(tx, ty) then
                count = count + 1
                flat[2 * count - 1] = x
                flat[2 * count] = y
                ds[count] = d2
            end
        end
    end
    if count > Monitor.MAX_DOTS then
        local all = flat
        flat = {}
        for j, i in ipairs(keepNearest(ds, count, Monitor.MAX_DOTS)) do
            flat[2 * j - 1] = all[2 * i - 1]
            flat[2 * j] = all[2 * i]
        end
    end
    dots[n] = flat
    local r = Config.get("ZombieWakeRadius") or 0
    if r > 0 and nearest and nearest <= r * r and player:isAsleep() and now >= (wokeAt[n] or 0) + Monitor.WAKE_RETRY_MS then
        wokeAt[n] = now
        Monitor.wake(player)
        Util.log("MONITOR", { event = "wake", player = n, dist = math.sqrt(nearest), radius = r })
    end
end

-- Every local player; the zombie list is read only when one of them sits in an NEV.
function Monitor.scan()
    local zombies, now = nil, nil
    for n = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(n)
        local v = player and not player:isDead() and player:getVehicle()
        if v and Registry.isNEV(v) then
            if not zombies then
                local cell = getCell()
                zombies = cell and cell:getZombieList()
                now = getTimestampMs()
            end
            if zombies then Monitor.scanPlayer(player, zombies, now) else dots[n] = nil end
        else
            dots[n] = nil
        end
    end
end

-- Draw the dots of one minimap (an ISMiniMapInner). World -> UI is affine in both the flat and the isometric view:
-- three mapAPI points a frame, then plain arithmetic a zombie (#182 probe: 2e-5 px from worldToUIX/Y). Only what
-- falls inside the map's own rectangle is drawn - the minimap's visible range.
function Monitor.draw(inner, d)
    local api = inner.mapAPI
    if not api then return end
    local cx, cy = api:getCenterWorldX(), api:getCenterWorldY()
    local ox, oy = api:worldToUIX(cx, cy), api:worldToUIY(cx, cy)
    local ax, ay = (api:worldToUIX(cx + 100, cy) - ox) / 100, (api:worldToUIY(cx + 100, cy) - oy) / 100
    local bx, by = (api:worldToUIX(cx, cy + 100) - ox) / 100, (api:worldToUIY(cx, cy + 100) - oy) / 100
    local s = Monitor.DOT
    local half = s / 2
    local w, h = inner.width - half, inner.height - half
    local c = Monitor.COLOR
    for i = 1, #d, 2 do
        local dx, dy = d[i] - cx, d[i + 1] - cy
        local ux, uy = ox + dx * ax + dy * bx, oy + dx * ay + dy * by
        if ux >= half and uy >= half and ux < w and uy < h then
            inner:drawRect(ux - half, uy - half, s, s, c.a, c.r, c.g, c.b)
        end
    end
end

local drawGuarded = Util.guard("zombieMonitorDraw", Monitor.draw)
local origRender = ISMiniMapInner.render
function ISMiniMapInner:render()
    if origRender then origRender(self) end
    local d = dots[self.playerNum]
    if d and d[1] then drawGuarded(self, d) end
end

-- tests
function Monitor.reset() dots = {}; wokeAt = {} end

Schedule.every("zombieMonitor", Monitor.SCAN_MS, Monitor.scan)

return Monitor
