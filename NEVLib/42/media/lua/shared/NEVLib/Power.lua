-- NEV Lib: power on / off instead of ignition (DESIGN 3.3), plus camping
-- mode's "cabin powered, engine off" state (DESIGN 7.2).
--
-- Three states:
--   drive   : engine Running (engineDoRunning, no start-up, M0 V1)
--   camping : engine off (no 8-tile engine noise), cabin systems powered
--   off     : engine off, every device off except the fridge (unless the
--             vehicle setting exitAllOff is on); the device state is
--             remembered and restored on the next power-on
-- No manual power on / off since UI-DESIGN 19 (getting in powers on, the
-- last one out powers off); manualOn is the menu's power-on (manual power-off was removed
-- as unused, REVIEW 3.2-12; v2 may bring it back).
-- Power.evaluate() picks the target state from the situation and performs
-- the transition. It is called on seat changes, menu actions, camping
-- changes, an empty battery and periodically for the driven vehicle.
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/State"
require "NEVLib/Battery"

local Util, Registry, State, Battery = NEVLib.Util, NEVLib.Registry, NEVLib.State, NEVLib.Battery
local Power = {}
NEVLib.Power = Power

---------------------------------------------------------------------------
-- Pure decision
---------------------------------------------------------------------------

-- s = { current = "drive"|"camping"|"off", occupants, driverCanPower,
--       camping, soc, motorOk, batteryPresent, rexAvailable }
-- rexAvailable: a range extender with fuel can supply the car, so an empty
-- battery does not stop it (UI-DESIGN 22.5, user 2026-10-07: "battery or
-- fuel, either one non-empty, and the car drives").
-- returns target state and, when the driver cannot power on, the reason.
function Power.decide(s)
    -- camping needs the battery it runs on (REVIEW 3.1-3: removed while camping)
    if s.camping and s.batteryPresent then return "camping" end
    local blocker = nil
    if not s.batteryPresent then
        blocker = "noBattery"
    elseif not s.motorOk then
        blocker = "motorBroken"
    elseif s.soc <= 0 and not s.rexAvailable then
        blocker = "noCharge"
    end
    if s.current == "drive" then
        if blocker then return "off", blocker end
        if s.occupants == 0 then return "off", nil end
        return "drive", nil
    end
    if not s.driverCanPower then return "off", nil end
    if blocker then return "off", blocker end
    return "drive", nil
end

---------------------------------------------------------------------------
-- Reading the vehicle
---------------------------------------------------------------------------

function Power.occupants(vehicle)
    local n = 0
    for seat = 0, vehicle:getMaxPassengers() - 1 do
        if vehicle:getCharacter(seat) then n = n + 1 end
    end
    return n
end

-- Driver seated with the key on them (keyless entry), key in the ignition,
-- hotwired, or the vanilla "easy use" sandbox option.
function Power.driverCanPower(vehicle)
    local driver = vehicle:getDriver()
    if not driver then return false end
    if vehicle:isHotwired() or vehicle:isKeysInIgnition() then return true end
    if SandboxVars and SandboxVars.VehicleEasyUse then return true end
    return driver:getInventory():haveThisKeyId(vehicle:getKeyId()) ~= nil
end

function Power.current(vehicle)
    if vehicle:isEngineRunning() then return "drive" end
    if State.get(vehicle).camping then return "camping" end
    return "off"
end

function Power.situation(vehicle)
    local st = State.get(vehicle)
    local soc, bpart = Battery.getSoc(vehicle)
    local motor = vehicle:getPartById("Engine")
    return {
        current = Power.current(vehicle),
        occupants = Power.occupants(vehicle),
        driverCanPower = Power.driverCanPower(vehicle),
        camping = st.camping == true,
        soc = soc,
        motorOk = motor ~= nil and motor:getCondition() > 0,
        batteryPresent = bpart ~= nil,
        rexAvailable = Power.rexAvailable(vehicle),
    }
end

-- EREV with a working range extender and fuel in the tank.
function Power.rexAvailable(vehicle)
    local cfg = Registry.get(vehicle)
    if not cfg or cfg.powertrain ~= "EREV" then return false end
    local rp = vehicle:getPartById("NEVRangeExtender")
    if not rp or not rp:getInventoryItem() or rp:getCondition() <= 0 then return false end
    local gas = vehicle:getPartById("GasTank")
    return gas ~= nil and gas:getInventoryItem() ~= nil and gas:getContainerContentAmount() > 0
end

---------------------------------------------------------------------------
-- Devices remembered across power-off (DESIGN 3.3)
---------------------------------------------------------------------------

local function radioData(vehicle)
    local radio = vehicle:getPartById("Radio")
    return radio and radio:getDeviceData()
end

local function heaterData(vehicle)
    local heater = vehicle:getPartById("Heater")
    return heater and heater:getModData()
end

-- #322: in multiplayer this runs on the server (13.6), and what it changes there has to reach the clients. The
-- heater is the Heater part's modData: sent with transmitPartModData (a no-op off a server). The radio / screen is
-- the Radio part's DeviceData, whose setters send nothing from a server (DeviceData.transmitDeviceDataState is
-- client-only): the server tells every client (NEVLib "radio"; a client without the car ignores it, and one that
-- loads it later gets the part's saved state) and Power.applyRadio sets it there without sending it back.
-- The headlights (setHeadlightsOn flags the vehicle update) and the fridge (Fridge.setOn) carry their own sync.
local function sendHeater(vehicle)
    vehicle:transmitPartModData(vehicle:getPartById("Heater"))
end

local function sendRadio(vehicle, rd)
    if not (isServer and isServer()) or not sendServerCommand then return end
    sendServerCommand("NEVLib", "radio", { vehicle = vehicle:getId(), on = rd:getIsTurnedOn() == true,
                                           channel = rd:getChannel(), volume = rd:getDeviceVolume() })
end

-- Client side of the "radio" message (client/NEVLib/ServerCommands.lua): the raw setters change this client's copy
-- only, like vanilla's own RadioDeviceDataState handler does (DeviceData.receiveDeviceDataStatePacket).
function Power.applyRadio(args)
    if type(args) ~= "table" or type(args.vehicle) ~= "number" or not getVehicleById then return end
    local vehicle = getVehicleById(args.vehicle)
    local rd = vehicle and radioData(vehicle)
    if not rd then return end
    if type(args.channel) == "number" then rd:setChannelRaw(args.channel) end
    if type(args.volume) == "number" then rd:setDeviceVolumeRaw(args.volume) end
    rd:setTurnedOnRaw(args.on == true)
end

function Power.snapshot(vehicle)
    local snap = { headlights = vehicle:getHeadlightsOn() }
    local rd = radioData(vehicle)
    if rd then
        snap.radio = rd:getIsTurnedOn()
        snap.radioChannel = rd:getChannel()
        snap.radioVolume = rd:getDeviceVolume()
    end
    local hd = heaterData(vehicle)
    if hd then
        snap.heater = hd.active == true
        snap.heaterTemp = hd.temperature
    end
    return snap
end

function Power.devicesOff(vehicle)
    vehicle:setHeadlightsOn(false)
    local rd = radioData(vehicle)
    if rd then
        -- infotainment screen: a playing tape stops and stays inside (StopPlayMedia sends itself)
        if rd:isPlayingMedia() then rd:StopPlayMedia() end
        if rd:getIsTurnedOn() then
            rd:setIsTurnedOn(false)
            sendRadio(vehicle, rd)
        end
    end
    local hd = heaterData(vehicle)
    if hd and hd.active then
        hd.active = false
        sendHeater(vehicle)   -- camping -> off: no engine shut-down clears it on the clients (#322)
    end
end

function Power.restore(vehicle, snap)
    if not snap then return end
    if snap.headlights then vehicle:setHeadlightsOn(true) end
    local rd = radioData(vehicle)
    if rd and snap.radio then
        if snap.radioChannel then rd:setChannel(snap.radioChannel) end
        if snap.radioVolume then rd:setDeviceVolume(snap.radioVolume) end
        rd:setIsTurnedOn(true)
        sendRadio(vehicle, rd)
    end
    local hd = heaterData(vehicle)
    if hd and snap.heater then
        hd.active = true
        if snap.heaterTemp ~= nil then hd.temperature = snap.heaterTemp end
        sendHeater(vehicle)
    end
    if snap.fridge and NEVLib.Fridge and NEVLib.Fridge.part(vehicle) then NEVLib.Fridge.setOn(vehicle, true) end
end

---------------------------------------------------------------------------
-- Transitions
---------------------------------------------------------------------------

local REASON_TEXT = {
    noBattery = "IGUI_NEV_NoBattery",
    motorBroken = "IGUI_NEV_MotorBroken",
    noCharge = "IGUI_NEV_NoCharge",
}

function Power.reasonKey(reason)
    return REASON_TEXT[reason]
end

function Power.reasonText(reason)
    return REASON_TEXT[reason] and Util.text(REASON_TEXT[reason]) or nil
end

-- Floating text over `chr`: a translation key, translated where it is shown.
-- A multiplayer server has no HaloTextHelper and no mod translations
-- (GameServer loads them before mods), so it sends the key to that player
-- (REVIEW 3.2-4: these notices were lost); client/NEVLib/ServerCommands.lua
-- shows it.
local function tell(chr, key, bad)
    if not chr or not key then return end
    if isServer and isServer() then
        if sendServerCommand then sendServerCommand(chr, "NEVLib", "tell", { key = key, bad = bad == true }) end
        return
    end
    if not HaloTextHelper then return end
    local text = Util.text(key)
    if bad then HaloTextHelper.addBadText(chr, text) else HaloTextHelper.addText(chr, text) end
end
Power.tell = tell

local function enter(vehicle, from, to, st)
    if to ~= "off" then st.poweredOnce = true end   -- #319: the fridge works from the first power-on
    if to == "drive" then
        vehicle:engineDoRunning()
        if from == "off" then
            Power.restore(vehicle, st.snap)
            st.snap = nil
        end
    elseif to == "camping" then
        if from == "drive" then
            -- #324: vanilla's shut-down clears the heater on every side (BaseVehicle.onEngineStateChanged,
            -- ShuttingDown), but camping keeps the cabin powered and the heater working (DESIGN 7.2): put it back
            -- and send it (a client parses the engine state before the part modData of the same vehicle update)
            local hd = heaterData(vehicle)
            local heaterOn = hd ~= nil and hd.active == true
            vehicle:engineDoShuttingDown()
            if heaterOn and not hd.active then
                hd.active = true
                sendHeater(vehicle)
            end
        end
        if from == "off" then
            Power.restore(vehicle, st.snap)
            st.snap = nil
        end
    else -- off
        st.snap = Power.snapshot(vehicle)
        Power.devicesOff(vehicle)
        -- vehicle setting "leaving turns off every device" (UI-DESIGN 19): the
        -- fridge too, back on at the next power-on like the other devices
        local Fridge = NEVLib.Fridge
        if st.exitAllOff and Fridge and Fridge.part(vehicle) and Fridge.isOn(Fridge.part(vehicle)) then
            st.snap.fridge = true
            Fridge.setOn(vehicle, false)
        end
        if from == "drive" then vehicle:engineDoShuttingDown() end
        st.rexOn = false
    end
end

-- Re-decide and apply. Returns the new state and the refusal reason (if the
-- driver is seated and could not power on). `from` overrides the current
-- state when the caller just changed what it is derived from (camping flag).
function Power.evaluate(vehicle, why, from)
    if not Registry.isNEV(vehicle) then return nil end
    Battery.settle(vehicle, why) -- energy up to date before the state may change (13.5-16)
    local st = State.get(vehicle)
    local s = Power.situation(vehicle)
    if from then s.current = from end
    -- the engine runs although camping keeps it off: something outside our
    -- menus started it (vanilla gas pedal, another mod) -> the driver wants
    -- to drive (13.5-17). Entering camping from drive passes from = "drive".
    if st.camping and s.current == "drive" and why ~= "campingOn" then
        return Power.requestDrive(vehicle, vehicle:getDriver(), why)
    end
    local target, blocker = Power.decide(s)
    if target ~= s.current then
        enter(vehicle, s.current, target, st)
        Util.log("POWER", { from = s.current, to = target, why = why or "?", soc = s.soc,
                            occupants = s.occupants, blocker = blocker or "none" })
    end
    return target, blocker
end

-- The driver asked to drive: the power-on menu / dashboard engine button
-- while camping, or the vanilla start sequence (gas pedal). When the car can
-- power on and camping ends (with a notice);
-- otherwise nothing changes, a vanilla start in progress is stopped and the
-- reason is shown (M1 issue 11, user decision 2026-10-07).
function Power.requestDrive(vehicle, chr, why)
    Battery.settle(vehicle, why)
    local st = State.get(vehicle)
    local s = Power.situation(vehicle)
    s.camping = false
    if s.current == "camping" then s.current = "off" end
    local target, blocker = Power.decide(s)
    if target ~= "drive" then
        if vehicle:isEngineStarted() or vehicle:isEngineRunning() then vehicle:engineDoShuttingDown() end
        Util.log("POWER", { event = "driveRefused", why = why or "?", blocker = blocker or "none",
                            camping = st.camping == true })
        if blocker then tell(chr, Power.reasonKey(blocker), true) end
        return Power.current(vehicle), blocker
    end
    local wasCamping = st.camping == true
    if wasCamping then
        st.camping = false
        Util.log("CAMPING", { on = false, why = why or "?", soc = s.soc })
        tell(chr, "IGUI_NEV_CampingExited", false)
    end
    return Power.evaluate(vehicle, why, wasCamping and "camping" or nil)
end

-- Seat changes: every decision is logged with its inputs (M1 issue 1: a re-seat sometimes powered
-- on only at the next 1 s check and the reason was not visible).
function Power.seatLog(event, vehicle, chr, extra)
    local driver = vehicle:getDriver()
    local inv = chr and chr:getInventory()
    local fields = {
        event = event, isDriver = driver ~= nil and driver == chr, hasDriver = driver ~= nil,
        keyOnBody = inv ~= nil and inv:haveThisKeyId(vehicle:getKeyId()) ~= nil,
        keyInIgnition = vehicle:isKeysInIgnition() == true, hotwired = vehicle:isHotwired() == true,
        easyUse = SandboxVars ~= nil and SandboxVars.VehicleEasyUse == true,
        soc = (Battery.getSoc(vehicle)), running = vehicle:isEngineRunning() == true,
    }
    local st = State.get(vehicle)
    fields.camping = st.camping == true
    for k, v in pairs(extra or {}) do fields[k] = v end
    Util.log("SEAT", fields)
end

function Power.onSeated(vehicle, chr, event)
    if not Registry.isNEV(vehicle) then return end
    local target, blocker = Power.evaluate(vehicle, "seat")
    Power.seatLog(event or "seat", vehicle, chr, { target = target, blocker = blocker or "none" })
    if target ~= "drive" and blocker and vehicle:getDriver() == chr then
        tell(chr, Power.reasonKey(blocker), true)
    end
end

function Power.manualOn(vehicle, chr)
    local st = State.get(vehicle)
    if st.camping then return Power.requestDrive(vehicle, chr, "powerOn") end
    local target, blocker = Power.evaluate(vehicle, "manualOn")
    if target ~= "drive" and blocker then tell(chr, Power.reasonKey(blocker), true) end
    return target, blocker
end

---------------------------------------------------------------------------
-- Per-frame watch of the vehicle the local player sits in (13.5-17).
-- Pressing the gas pedal with the engine off makes Java's CarController call
-- BaseVehicle.tryStartEngine directly (no Lua): it takes 2.5 % off the
-- battery item - our traction battery - on every attempt, then runs the
-- vanilla start sequence. We give the 2.5 % back and treat the start as
-- "the driver wants to drive" instead of fighting it every second (in the M1
-- test that loop ran 9 times while camping: about 22 % lost).
---------------------------------------------------------------------------

Power.STARTER_DRAIN = 0.025 -- BaseVehicle.tryStartEngine: currentCharge - 0.025f
Power.STARTER_BAND = 0.001  -- our own draw in one frame is far below this

-- Did the SOC change between two frames look like vanilla's starter drain?
function Power.isStarterDrain(prevSoc, soc)
    if not prevSoc or not soc then return false end
    local d = prevSoc - soc
    if math.abs(d - Power.STARTER_DRAIN) <= Power.STARTER_BAND then return true end
    -- below 2.5 % the drain is clamped at 0
    return soc <= 0 and prevSoc > 0 and prevSoc <= Power.STARTER_DRAIN + Power.STARTER_BAND
end

-- `mem` is the caller's memory between frames ({} at first).
function Power.onFrame(vehicle, mem)
    local soc = (Battery.getSoc(vehicle))
    local running = vehicle:isEngineRunning()
    if mem.vehicle == vehicle and not mem.running and not running and Power.isStarterDrain(mem.soc, soc) then
        Battery.setSoc(vehicle, mem.soc)
        Util.log("STARTER", { event = "refund", soc = mem.soc, drained = mem.soc - soc })
        soc = mem.soc
    end
    if not running and vehicle:isEngineStarted() then
        -- we never use the vanilla start sequence: someone pressed the pedal
        Power.requestDrive(vehicle, vehicle:getDriver(), "pedal")
        running = vehicle:isEngineRunning()
        soc = (Battery.getSoc(vehicle))
    end
    mem.vehicle, mem.soc, mem.running = vehicle, soc, running
end

return Power
