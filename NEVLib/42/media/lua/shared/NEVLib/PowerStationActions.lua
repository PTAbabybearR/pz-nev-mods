-- NEV Lib: portable power station timed actions (DESIGN 6.4).
--  * NEVPowerStationChargeAction: charge it where it is placed on the ground
--    (user 2026-10-07: like the vanilla car battery charger), standing next
--    to it - the station's square must be powered (PowerStation.squarePowered).
--  * NEVPowerStationToCarAction: empty it into a car at the charging port
--    (Menu walks the character there first, like plugging in a charger). The
--    station is in the inventory or placed on the ground (worldObj).
-- Energy moves while the action runs (by job progress), so an interrupted
-- action keeps what was already moved. Items store their charge in
-- 1 / 100000 steps rounded to the nearest (DrainableComboItem.
-- setCurrentUsesFloat); adding a sliver every frame to the rounded value lost
-- the same fraction of a step every time - 0.04 kWh over a full charge in the
-- first game test (7-4 "full" never reached). So energy moves in chunks of
-- STEP_KWH as whole storage steps added to the current value (two players on
-- one station no longer overwrite each other, REVIEW 3.2-1), and the
-- remainder is carried over to the next chunk.
--
-- Multiplayer (M1-3 issue 6): both are B42 network timed actions (they have
-- complete()), so the server runs them: it rebuilds them through new() and
-- moves the energy in complete() (all) / serverStop() (interrupted: by the
-- network progress), then sends the station's new charge to the clients.
-- While it runs the server also settles it every LIVE_MS by network progress
-- ("live", below), so the client's numbers move with the progress bar
-- instead of jumping at the end (user 2026-10-09).
-- A multiplayer client only animates. Single player is unchanged: energy
-- moves in update() / stop() / perform(), and complete() (called right
-- after perform()) does nothing there.
require "NEVLib/Util"
require "NEVLib/PowerStation"
require "NEVLib/Charging"
require "NEVLib/Net"
require "TimedActions/ISBaseTimedAction"

local Util, PowerStation = NEVLib.Util, NEVLib.PowerStation

local STEP_KWH = 0.02
local CARRY_KWH = 0.002   -- a remainder this small is a rounding carry, not "it fell short"

local function mpClient() return isClient ~= nil and isClient() end
local function mpServer() return isServer ~= nil and isServer() end

-- server: the station item's charge changed -> tell the clients
local function syncItem(item)
    if sendItemStats then pcall(sendItemStats, item) end
end

-- Multiplayer server, live settling: B42 runs no update() for a network
-- action on the server (NetTimedAction.update is empty), only serverStart /
-- complete / serverStop. serverStart() lists the action; OnTick (the server's
-- IngameState.update triggers it while players are on) settles every listed
-- action by its network progress each LIVE_MS - the same chunked advance
-- single player runs every frame - and sends the station's charge when it
-- moved. The car's battery syncs itself (Battery.setSoc ->
-- transmitPartUsedDelta). complete() / serverStop() take it off the list and
-- settle the rest.
local LIVE_MS = 500
local live = {}
local nextLive = 0

local function anyLive()
    for _ in pairs(live) do return true end   -- Kahlua has no next()
    return false
end

local function liveTick()
    if not anyLive() or not mpServer() then return end
    local now = getTimestampMs()
    if now < nextLive then return end
    nextLive = now + LIVE_MS
    for a in pairs(live) do
        local p = a.netAction and a.netAction:getProgress()
        if a.stopped or not p then
            live[a] = nil
        else
            local before = a.done
            local ok, err = pcall(a.advance, a, math.min(math.max(p, 0), 1), false)
            if not ok then
                live[a] = nil
                Util.log("ERROR", { where = "powerStationLive", msg = tostring(err) })
            elseif a.done ~= before then
                syncItem(a.item)
            end
        end
    end
end
if mpServer() then   -- #327: only the dedicated server has live actions; it returned at once every tick elsewhere
    Events.OnTick.Add(Util.guardKeep("powerStationLive", liveTick))
end

-- for the unit tests
NEVLib.PowerStationLive = { LIVE_MS = LIVE_MS, tick = liveTick,
    listed = function(a) return live[a] == true end,
    reset = function() live = {}; nextLive = 0 end }

local function ticksFor(minutes)
    return math.max(30, math.floor(minutes * PowerStation.TICKS_PER_MINUTE + 0.5))
end

-- Shared progress bookkeeping: what the progress asks for so far goes into
-- `pending`; `move(kwh)` is called with whole chunks (or the rest at the end)
-- and returns what was really moved; a tiny remainder is carried to the next
-- chunk. Returns false when it fell short (full, no power, empty...).
local function advance(self, progress, final, move)
    local target = self.planned * math.min(1, progress)
    self.pending = self.pending + math.max(0, target - self.asked)
    self.asked = math.max(self.asked, target)
    if self.pending < STEP_KWH and not (final and self.pending > 1e-9) then return true end
    local want = self.pending
    local got = move(want)
    self.done = self.done + got
    self.pending = want - got
    if self.pending <= CARRY_KWH then
        if final then self.pending = 0 end
        return true
    end
    self.pending = 0
    return false
end

---------------------------------------------------------------------------
-- Charge the station
---------------------------------------------------------------------------
NEVPowerStationChargeAction = ISBaseTimedAction:derive("NEVPowerStationChargeAction")

function NEVPowerStationChargeAction:isValid()
    if self.item == nil then return false end   -- #321: no station on the object the server found
    local sq = self.worldObj:getSquare()
    if sq == nil or self.worldObj:getItem() ~= self.item then return false end
    -- v1.1 C3: the server checks the distance too (same limit as the give-to-car action)
    return Util.dist(self.character:getX(), self.character:getY(), sq:getX(), sq:getY()) <= NEVLib.Net.NEAR_TILES
end

function NEVPowerStationChargeAction:waitToStart()
    self.character:faceThisObject(self.worldObj)
    return self.character:shouldBeTurning()
end

function NEVPowerStationChargeAction:start()
    self:setActionAnim("Loot")
    -- the station sits on the floor: crouch like vanilla picking an item off
    -- the ground (ISGrabItemAction.lua:52); without it the loot animation is
    -- played standing (AUTOTEST pilot 1, D-1)
    self:setAnimVariable("LootPosition", "Low")
    PowerStation.chargeSeen(self, self.square)   -- generator info window
end

function NEVPowerStationChargeAction:advance(progress, final)
    local ok = advance(self, progress, final, function(kwh)
        return PowerStation.chargeStep(self.item, self.square, kwh)
    end)
    if not ok then
        self.stopped = PowerStation.cannotCharge(self.item, self.square) or "noPower"
        if not mpServer() then self:forceStop() end
    end
end

function NEVPowerStationChargeAction:update()
    PowerStation.chargeSeen(self, self.square)
    if not mpClient() then self:advance(self:getJobDelta(), false) end
end

function NEVPowerStationChargeAction:stop()
    if not mpClient() then
        pcall(self.advance, self, self:getJobDelta(), true)   -- keep what the progress paid for
        PowerStation.log({ event = "charge", done = self.done, stopped = self.stopped or "interrupted" })
    end
    PowerStation.chargeEnded(self)
    ISBaseTimedAction.stop(self)
end

function NEVPowerStationChargeAction:perform()
    if not mpClient() then
        local ok, err = pcall(self.advance, self, 1, true)
        if not ok then Util.log("ERROR", { where = "powerStationCharge", msg = tostring(err) }) end
        PowerStation.log({ event = "charge", done = self.done, kwh = PowerStation.kwh(self.item) })
    end
    PowerStation.chargeEnded(self)
    ISBaseTimedAction.perform(self)
end

function NEVPowerStationChargeAction:serverStart()
    live[self] = true
end

-- multiplayer server: the rest of the charge / an interrupted one by its progress
function NEVPowerStationChargeAction:complete()
    if mpServer() then
        live[self] = nil
        local ok, err = pcall(self.advance, self, 1, true)
        if not ok then Util.log("ERROR", { where = "powerStationCharge", msg = tostring(err) }) end
        syncItem(self.item)
        PowerStation.log({ event = "charge", done = self.done, kwh = PowerStation.kwh(self.item), via = "server" })
    end
    return true
end

function NEVPowerStationChargeAction:serverStop()
    live[self] = nil
    pcall(self.advance, self, self.netAction and self.netAction:getProgress() or 0, true)
    syncItem(self.item)
    PowerStation.log({ event = "charge", done = self.done, stopped = self.stopped or "interrupted", via = "server" })
end

function NEVPowerStationChargeAction:getDuration()
    return ticksFor(self.item and PowerStation.minutesToFull(self.item) or 0)
end

-- worldObj: the station placed on the ground (IsoWorldInventoryObject); the
-- station is taken from it (#321: the item argument can arrive as nil on a
-- multiplayer server, PowerStation.actionItem). No station there -> invalid.
function NEVPowerStationChargeAction:new(character, item, worldObj)
    local o = ISBaseTimedAction.new(self, character)
    o.item = worldObj and PowerStation.actionItem(item, worldObj)
    o.worldObj = worldObj
    o.square = o.item and worldObj:getSquare()
    o.startKwh = o.item and PowerStation.kwh(o.item) or 0   -- not "start": that would hide the start() method (Java rawgets it)
    o.planned = o.item and PowerStation.CAPACITY_KWH - o.startKwh or 0
    o.asked, o.pending, o.done = 0, 0, 0
    o.maxTime = o:getDuration()
    return o
end

---------------------------------------------------------------------------
-- Give its energy to a car
---------------------------------------------------------------------------
NEVPowerStationToCarAction = ISBaseTimedAction:derive("NEVPowerStationToCarAction")

-- The station is still where it was picked from: in the inventory, or (placed)
-- the same world object still on a square.
function NEVPowerStationToCarAction:stationThere()
    if self.worldObj then
        return self.worldObj:getSquare() ~= nil and self.worldObj:getItem() == self.item
    end
    return PowerStation.carriedBy(self.character, self.item)
end

-- Also on the server (REVIEW 3.2-6): the character must be near the car, and
-- a placed station must reach its charging port, whatever the client sent.
function NEVPowerStationToCarAction:isValid()
    if self.vehicle == nil or self.item == nil or not self:stationThere() then return false end
    if self.area and not self.vehicle:isInArea(self.area, self.character) then return false end
    if Util.dist(self.character:getX(), self.character:getY(), self.vehicle:getX(), self.vehicle:getY()) > NEVLib.Net.NEAR_TILES then
        return false
    end
    if self.worldObj and not NEVLib.Charging.portReaches(self.vehicle, self.worldObj:getSquare()) then return false end
    return true
end

function NEVPowerStationToCarAction:waitToStart()
    self.character:faceThisObject(self.vehicle)
    return self.character:shouldBeTurning()
end

function NEVPowerStationToCarAction:start()
    self:setActionAnim("VehicleWorkOnMid")
end

function NEVPowerStationToCarAction:advance(progress, final)
    local ok = advance(self, progress, final, function(kwh)
        return PowerStation.toCarStep(self.item, self.vehicle, kwh)
    end)
    if not ok then
        self.stopped = PowerStation.cannotGive(self.item, self.vehicle) or "full"
        if not mpServer() then self:forceStop() end
    end
end

function NEVPowerStationToCarAction:update()
    self.character:faceThisObject(self.vehicle)
    if not mpClient() then self:advance(self:getJobDelta(), false) end
end

function NEVPowerStationToCarAction:stop()
    if not mpClient() then
        pcall(self.advance, self, self:getJobDelta(), true)
        PowerStation.log({ event = "toCar", done = self.done, stopped = self.stopped or "interrupted" })
    end
    ISBaseTimedAction.stop(self)
end

function NEVPowerStationToCarAction:perform()
    local gave = self.planned
    if not mpClient() then
        local ok, err = pcall(self.advance, self, 1, true)
        if not ok then Util.log("ERROR", { where = "powerStationToCar", msg = tostring(err) }) end
        PowerStation.log({ event = "toCar", done = self.done, left = PowerStation.kwh(self.item) })
        gave = self.done
    end
    if gave > 0 and HaloTextHelper then
        HaloTextHelper.addText(self.character, Util.text("IGUI_NEV_PowerStationGave", string.format("%.1f", gave)))
    end
    ISBaseTimedAction.perform(self)
end

function NEVPowerStationToCarAction:serverStart()
    live[self] = true
end

-- multiplayer server: the rest of the transfer / an interrupted one by its progress
function NEVPowerStationToCarAction:complete()
    if mpServer() then
        live[self] = nil
        local ok, err = pcall(self.advance, self, 1, true)
        if not ok then Util.log("ERROR", { where = "powerStationToCar", msg = tostring(err) }) end
        syncItem(self.item)
        PowerStation.log({ event = "toCar", done = self.done, left = PowerStation.kwh(self.item), via = "server" })
    end
    return true
end

function NEVPowerStationToCarAction:serverStop()
    live[self] = nil
    pcall(self.advance, self, self.netAction and self.netAction:getProgress() or 0, true)
    syncItem(self.item)
    PowerStation.log({ event = "toCar", done = self.done, stopped = self.stopped or "interrupted", via = "server" })
end

function NEVPowerStationToCarAction:getDuration()
    return ticksFor(PowerStation.minutesToGive(self.planned))
end

-- worldObj: the placed station (IsoWorldInventoryObject), nil when carried;
-- a placed station is taken from it (#321, PowerStation.actionItem).
function NEVPowerStationToCarAction:new(character, vehicle, area, item, worldObj)
    local o = ISBaseTimedAction.new(self, character)
    o.vehicle = vehicle
    o.area = area
    o.item = PowerStation.actionItem(item, worldObj)
    o.worldObj = worldObj
    o.startKwh = o.item and PowerStation.kwh(o.item) or 0   -- not "start": that would hide the start() method (Java rawgets it)
    o.planned = o.item and vehicle and PowerStation.transferable(o.item, vehicle) or 0
    o.asked, o.pending, o.done = 0, 0, 0
    o.maxTime = o:getDuration()
    return o
end

return NEVPowerStationChargeAction
