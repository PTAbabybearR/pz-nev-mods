-- NEV Lib: one OnTick for the client's "every N ms of real time" work (#327). The client fires OnTick about 244
-- times a second; each module with its own OnTick paid a call and a clock read every tick even when it had nothing
-- to do. Now one tick compares the clock with the earliest due time and returns; a due task runs under its own
-- guardKeep name (errors kept apart, Util.profile reads each task by name as before). Same pacing rule as the
-- modules had: after a run the task is due again `ms` later, missed runs are not made up.
require "NEVLib/Util"

local Util = NEVLib.Util
local Schedule = {}
NEVLib.Schedule = Schedule

local tasks = {}
local nextDue = 0                                        -- the earliest task.next; 0: look at the next tick

-- Run fn every `ms` of real time, the first time on the next tick.
function Schedule.every(name, ms, fn)
    tasks[#tasks + 1] = { name = name, ms = ms, fn = Util.guardKeep(name, fn), next = 0 }
    nextDue = 0
end

-- The task just ran outside the schedule (Nearby.rescan): next run `ms` from now.
function Schedule.restart(name)
    local now = getTimestampMs()
    for _, t in ipairs(tasks) do
        if t.name == name then t.next = now + t.ms end
    end
end

function Schedule.tick()
    local now = getTimestampMs()
    if now < nextDue then return end
    local due = nil
    for i = 1, #tasks do                                 -- not ipairs: an iterator call per task (#327 5-6)
        local t = tasks[i]
        if now >= t.next then
            t.next = now + t.ms
            t.fn()
        end
        if not due or t.next < due then due = t.next end
    end
    nextDue = due or now + 1000
end

-- tests: every task due on the next tick
function Schedule.reset()
    for _, t in ipairs(tasks) do t.next = 0 end
    nextDue = 0
end

Events.OnTick.Add(Util.guardKeep("clientSchedule", Schedule.tick))

return Schedule
