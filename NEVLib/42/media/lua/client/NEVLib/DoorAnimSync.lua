-- NEV Lib: door pictures follow the door state in multiplayer (GitHub #337; design docs/design/parts/door-anim-sync-design.md).
-- Vanilla plays a door's Open / Close animation only on the client that runs ISOpenVehicleDoor / ISCloseVehicleDoor
-- (start(): "TODO: sync part animation"); the state is set on the server (complete()) and a client that receives it
-- only stores it. When an animation ends, BaseVehicle.updateAnimationPlayer puts the still pose Opened / Closed for
-- the state the client has at that moment and never looks again (a still pose is never removed). So others see a
-- door frozen as it was when the car loaded, and the one who opened it sees it the wrong way round when the
-- animation ended before the state came back. Here, on a multiplayer client only, for the NEVs around the player:
--   A car entering the scan list: every door is put in the still pose of its state.
--   B a state changes and the local player has not started the same move on that door: play Open / Close.
--   C it changes and the local player has (pend): no second animation; once every local move on that door has come
--     back (pend empty) and the last one's animation is over (last + SETTLE_MS), put the still pose of the state then.
-- The door state itself is never touched (the server owns it). Cost (design 3.5, the F11 run of the first version):
-- the cars within Nearby.NEAR are read on every check, the others of the scan list once every FAR_MS each.
require "NEVLib/Util"
require "NEVLib/Nearby"
require "NEVLib/Schedule"

local Util, Nearby, Schedule = NEVLib.Util, NEVLib.Nearby, NEVLib.Schedule
local DoorAnimSync = {}
NEVLib.DoorAnimSync = DoorAnimSync

DoorAnimSync.CHECK_MS = 500                              -- how late others nearby see a door move
DoorAnimSync.FAR_MS = 2000                               -- a car beyond Nearby.NEAR: read this often
DoorAnimSync.SETTLE_MS = 1500                            -- a door animation is 15 frames, about 0.75 s of real time
DoorAnimSync.LOCAL_WINDOW_MS = 5000                      -- a state this long after a local move is someone else's

local cars = setmetatable({}, { __mode = "k" })          -- vehicle -> { doors = { { part, door, open, fix }, ... }, due }
local mine = setmetatable({}, { __mode = "k" })          -- part -> { pend = { { open, at }, ... }, last = ms }

local function still(v, part, open) v:playPartAnim(part, open and "Opened" or "Closed") end

-- Local moves older than LOCAL_WINDOW_MS never came back (a locked door, two states inside one check): dropped.
local function expire(m, now)
    local pend = m.pend
    while pend[1] and now - pend[1].at >= DoorAnimSync.LOCAL_WINDOW_MS do table.remove(pend, 1) end
end

-- ISOpenVehicleDoor / ISCloseVehicleDoor started on this client for `part` (`open`: which way).
function DoorAnimSync.noteLocal(part, open)
    if not part then return end
    local now = getTimestampMs()
    local m = mine[part]
    if not m then
        m = { pend = {} }
        mine[part] = m
    end
    expire(m, now)
    m.pend[#m.pend + 1] = { open = open, at = now }
    m.last = now
end

local function watch(v)
    local doors = {}
    for i = 0, v:getPartCount() - 1 do
        local part = v:getPartByIndex(i)
        local door = part and part:getDoor()
        if door then
            local open = door:isOpen()
            doors[#doors + 1] = { part = part, door = door, open = open }
            still(v, part, open)                         -- A
        end
    end
    return doors
end

function DoorAnimSync.onScan(found)
    local inList = {}
    for _, v in ipairs(found) do
        inList[v] = true
        if not cars[v] then cars[v] = { doors = watch(v), due = getTimestampMs() + DoorAnimSync.FAR_MS } end
    end
    for v in pairs(cars) do
        if not inList[v] then cars[v] = nil end
    end
end

local function changed(v, e, open, now)
    local m = mine[e.part]
    local k = nil
    if m then
        expire(m, now)
        for i, a in ipairs(m.pend) do
            if a.open == open then k = i; break end      -- the first local move this way
        end
    end
    if k then                                            -- C: the moves before it were overtaken by later ones
        for _ = 1, k do table.remove(m.pend, 1) end
        e.fix = true
    else                                                 -- B
        e.fix = nil                                      -- a pending fix would jump this animation to its end
        v:playPartAnim(e.part, open and "Open" or "Close")
    end
end

local function settle(v, e, now)
    local m = mine[e.part]
    if m then
        expire(m, now)
        if #m.pend > 0 or now < m.last + DoorAnimSync.SETTLE_MS then return end
    end
    still(v, e.part, e.door:isOpen())
    e.fix = nil
end

function DoorAnimSync.check()
    local now = getTimestampMs()
    local near = Nearby.near
    for v, c in pairs(cars) do
        if near(v) or now >= c.due then
            c.due = now + DoorAnimSync.FAR_MS
            for _, e in ipairs(c.doors) do
                local open = e.door:isOpen()
                if open ~= e.open then
                    e.open = open
                    changed(v, e, open, now)
                end
                if e.fix then settle(v, e, now) end
            end
        end
    end
end

-- Record a local move after vanilla's start() ran (its arguments and results untouched).
local function wrap(cls, open)
    if not cls or type(cls.start) ~= "function" then return false end
    local start = cls.start
    local note = Util.guardKeep("doorAnimSyncLocal", DoorAnimSync.noteLocal)
    cls.start = function(self, ...)
        local function after(...)
            note(self.part, open)
            return ...
        end
        return after(start(self, ...))
    end
    return true
end

function DoorAnimSync.install()
    Nearby.onScan(Util.guardKeep("doorAnimSyncScan", DoorAnimSync.onScan))
    Schedule.every("doorAnimSync", DoorAnimSync.CHECK_MS, DoorAnimSync.check)
    local o, c = wrap(ISOpenVehicleDoor, true), wrap(ISCloseVehicleDoor, false)
    Util.log("DOORSYNC", { event = "registered", open = o, close = c })
end

-- A multiplayer client only: the game sets GameClient.client before it reloads shared/ and client/ on joining
-- (ConnectionManager:172, ConnectToServerState:138 -> Core:4163), so isClient() is already true here.
if isClient() then DoorAnimSync.install() end

return DoorAnimSync
