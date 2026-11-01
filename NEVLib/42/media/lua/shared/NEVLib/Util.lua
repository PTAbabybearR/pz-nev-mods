-- NEV Lib: shared helpers (logging, error guard, small math, Kahlua-safe sort).
-- Lives in shared/: PZ loads shared -> client -> server (DESIGN 13.5-1).

NEVLib = NEVLib or {}
local Util = {}
NEVLib.Util = Util

Util.LOG_PREFIX = "[NEV]"

local function sortKeys(keys)
    -- insertion sort: Kahlua's table.sort is a recursive quicksort that can
    -- overflow on sorted input; these lists are tiny
    for i = 2, #keys do
        local v = keys[i]
        local j = i - 1
        while j >= 1 and keys[j] > v do
            keys[j + 1] = keys[j]
            j = j - 1
        end
        keys[j + 1] = v
    end
    return keys
end

-- Generic insertion sort with a "less" function (stable).
function Util.sort(list, less)
    for i = 2, #list do
        local v = list[i]
        local j = i - 1
        while j >= 1 and less(v, list[j]) do
            list[j + 1] = list[j]
            j = j - 1
        end
        list[j + 1] = v
    end
    return list
end

-- One deterministic log line: "[NEV] TAG a=1 b=2" (keys sorted).
function Util.formatLog(tag, fields)
    local keys = {}
    for k in pairs(fields or {}) do keys[#keys + 1] = k end
    sortKeys(keys)
    local parts = { Util.LOG_PREFIX, tag }
    for _, k in ipairs(keys) do
        local v = fields[k]
        if type(v) == "number" then
            v = string.format("%.4f", v):gsub("0+$", ""):gsub("%.$", "")
        end
        parts[#parts + 1] = k .. "=" .. tostring(v)
    end
    return table.concat(parts, " ")
end

function Util.log(tag, fields)
    print(Util.formatLog(tag, fields))
end

-- Test-only timing hook (#291 part 4, docs/testing/mp-e2e-design.md 7.6): nil in normal play, so
-- a guarded call costs one field check. The test bridge sets it to a table; then every guard /
-- guardKeep call adds to profile[name] = { n = calls, ns = total, max = longest }, timed with
-- GameTime.getServerTime() (nanoseconds). An error is re-raised unchanged after it is counted,
-- so the guards handle it exactly as without the hook.
-- ns includes guarded calls made inside (a Nearby listener, a Schedule job); top adds only the calls
-- that were not inside another timed call, so the sum of top over all names counts each microsecond
-- once (F11, #327).
Util.profile = nil
local depth = 0
local function timedCall(name, fn, ...)
    local t0 = GameTime.getServerTime()
    depth = depth + 1
    local ok, a, b, c = pcall(fn, ...)
    depth = depth - 1
    local dt = GameTime.getServerTime() - t0
    local prof = Util.profile
    if prof then
        if dt < 0 then dt = 0 end   -- a client's server-time shift can jump during a call
        local s = prof[name]
        if not s then
            s = { n = 0, ns = 0, max = 0, top = 0 }
            prof[name] = s
        end
        s.n = s.n + 1
        s.ns = s.ns + dt
        if depth == 0 then s.top = (s.top or 0) + dt end
        if dt > s.max then s.max = dt end
    end
    if not ok then error(a, 0) end
    return a, b, c
end

-- Wrap an event handler / per-frame function: the first error is logged once
-- with its name, then the function is disabled, so a per-frame error cannot
-- flood console.txt (DESIGN 13.5-9). Every Events.*.Add in the mod goes
-- through this (static check). Up to three return values are passed through
-- (nil after an error or once disabled).
Util.disabled = {}
function Util.guard(name, fn)
    local function timed(...) return timedCall(name, fn, ...) end
    return function(...)
        if Util.disabled[name] then return nil end
        local ok, a, b, c = pcall(Util.profile and timed or fn, ...)
        if not ok then
            Util.disabled[name] = true
            Util.log("ERROR", { where = name, msg = tostring(a) })
            return nil
        end
        return a, b, c
    end
end

-- Like guard, but the function keeps running after an error (REVIEW 3.3-15):
-- for the core callbacks whose loss breaks the car (power state tick, server
-- commands, the dashboard that already hid vanilla's gauges). Errors are
-- logged at most once per `everyMs` (default 60 s) with a count, so a
-- per-frame error still cannot flood console.txt.
Util.keepErrors = {}
function Util.guardKeep(name, fn, everyMs)
    everyMs = everyMs or 60000
    local function timed(...) return timedCall(name, fn, ...) end
    return function(...)
        local ok, a, b, c = pcall(Util.profile and timed or fn, ...)
        if not ok then
            local e = Util.keepErrors[name] or { count = 0, nextLog = 0 }
            Util.keepErrors[name] = e
            e.count = e.count + 1
            local now = getTimestampMs and getTimestampMs() or 0
            if now >= e.nextLog then
                e.nextLog = now + everyMs
                Util.log("ERROR", { where = name, msg = tostring(a), count = e.count })
            end
            return nil
        end
        return a, b, c
    end
end

function Util.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function Util.round(v, digits)
    local m = 10 ^ (digits or 0)
    return math.floor(v * m + 0.5) / m
end

function Util.dist(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return math.sqrt(dx * dx + dy * dy)
end

-- getText with a fallback when the key is missing (getText returns the key).
function Util.text(key, ...)
    if getText then return getText(key, ...) end
    return key
end

-- Settle a part's pending minutes under the CURRENT state, before a caller
-- changes that state (DESIGN 13.5-16). Java hands a part update the minutes
-- since the part last updated (VehicleParts.updatePart); while a powered-off
-- car has nothing running its part updates are switched off, so the first
-- update after "start charging" / "fridge on" / "power on" used to receive the
-- whole parked time and book it under the new state (M1 issue 12). Running
-- the update now with the old state gives exactly what Java would have done
-- had it updated just before the change. Same whole-minute rule as Java;
-- lastUpdated is set before the call, as Java does, so a nested settle from
-- inside the update is a no-op.
function Util.settlePart(vehicle, part, updateFn, why)
    if not part or not updateFn then return end
    local now = getGameTime():getWorldAgeHours()
    local last = part:getLastUpdated()
    if last < 0 or last > now then
        part:setLastUpdated(now)
        return
    end
    local minutes = (now - last) * 60
    if minutes < 1 then return end
    part:setLastUpdated(now)
    Util.log("SETTLE", { part = part:getId(), minutes = minutes, why = why or "?" })
    updateFn(vehicle, part, minutes)
end

-- Makes the FIRST entry of a part's itemType list as its item (DESIGN 9 / 9.1 revision 17): the armour's normal
-- grade before the Fine one, the library fridge before the old glove box kept for old saves. Not
-- VehicleUtils.createPartInventoryItem, which picks any entry of the list (Vehicles.lua). Otherwise as it: the
-- container capacity of the part, a random condition by the car's. Returns the item (nil: no itemType / no item).
function Util.createFirstItem(part)
    local types = part:getItemType()
    if not types or types:isEmpty() then return nil end
    return Util.createPartItem(part, types:get(0))
end

-- Makes `fullType` the part's item, as Util.createFirstItem does for the first entry.
function Util.createPartItem(part, fullType)
    local item = instanceItem(fullType)
    if not item then return nil end
    local cap = part:getContainerCapacity()
    if cap and cap > 0 then item:setMaxCapacity(cap) end
    part:setRandomCondition(item)
    part:setInventoryItem(item)
    return item
end

return Util
