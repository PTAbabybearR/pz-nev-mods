-- NEV Lib: every state-changing player action goes through Net.run (M1-PLAN
-- 2.14). Single player / host: runs right away. Multiplayer client: sent to
-- the server, which runs the same action (server-authoritative). Only single
-- player is tested for now (DESIGN 16.2).
require "NEVLib/Util"
require "NEVLib/State"
require "NEVLib/Power"
require "NEVLib/Camping"
require "NEVLib/Charging"
require "NEVLib/Fridge"
require "NEVLib/Battery"

local Util, State, Power, Camping, Charging, Fridge, Battery =
    NEVLib.Util, NEVLib.State, NEVLib.Power, NEVLib.Camping, NEVLib.Charging, NEVLib.Fridge, NEVLib.Battery
local Net = {}
NEVLib.Net = Net

Net.MODULE = "NEVLib"

-- name -> function(vehicle, args, player) returning ok, reason
Net.actions = {
    powerOn = function(vehicle, args, player)
        local target, blocker = Power.manualOn(vehicle, player)
        return target == "drive", blocker
    end,
    -- energy mode: "setMode" (picked directly), registered by NEVLib/EnergyMode
    -- vehicle settings (UI-DESIGN 19): exit turns off every device incl. the fridge
    toggleExitAllOff = function(vehicle)
        local st = State.get(vehicle)
        st.exitAllOff = not st.exitAllOff
        Util.log("SETTING", { exitAllOff = st.exitAllOff })
        return true
    end,
    toggleFridge = function(vehicle)
        Fridge.setOn(vehicle, not Fridge.isOn(Fridge.part(vehicle)))
        return true
    end,
    -- cool / freeze / heat (DESIGN 7.1 revision 15); an unknown mode is refused by Fridge.setMode
    setFridgeMode = function(vehicle, args)
        if not Fridge.setMode(vehicle, args and args.mode) then return false, "badMode" end
        return true
    end,
    toggleCamping = function(vehicle)
        return Camping.set(vehicle, not State.get(vehicle).camping, "menu")
    end,
    startCharge = function(vehicle, args)
        local sq = getCell():getGridSquare(args.x, args.y, args.z)
        local source = nil
        if sq then
            if args.kind == "fast" then source = Charging.pumpOn(sq) else source = Charging.chargerOn(sq) end
        end
        return Charging.start(vehicle, args.kind, source)
    end,
    stopCharge = function(vehicle)
        Charging.stop(vehicle, "manual")
        return true
    end,
}

-- Multiplayer: the power state machine runs on the server (REVIEW 3.1-6).
-- Clients report seat changes, the gas pedal and the 1 s check with this
-- command; the server decides and the engine state reaches everyone the
-- vanilla way. why = "enter" | "switchSeat" | "seated" | "exit" | "tick" | "pedal".
-- #382: vanilla sends the engine state once, when it changes (transmitEngine: VehicleUpdate flag 4); a full update
-- going to that client in the same server update drops it, and a vehicle the client already has keeps its old engine
-- (a driver rejoining and sitting down again: Idle there, Running on the server and the others, for good). The 1 s
-- tick carries what the client sees (`running`); when it differs, the server sends the engine state again (DESIGN
-- 13.6). An older client sends no `running`: nothing is re-sent. Only from Running or Idle: re-sending ShuttingDown
-- would make each client clear the heater again (vanilla does it on parsing that state) after Power put it back for
-- camping (#324); a state in passing is sent by vanilla anyway when it ends. Logged as ENGINE, not POWER: the e2e
-- scenarios read the last POWER line as the power state (S5).
local STEADY = { Running = true, Idle = true }
function Net.resyncEngine(vehicle, args, player)
    if type(args.running) ~= "boolean" then return false end
    local server = vehicle:isEngineRunning()
    if args.running == server or not STEADY[tostring(vehicle:getEngineState())] then return false end
    vehicle:transmitEngine()
    Util.log("ENGINE", { event = "resync", client = args.running, server = server,
                        player = player and player:getUsername() or "?" })
    return true
end
Net.actions.evaluatePower = function(vehicle, args, player)
    if args.why == "pedal" then
        if not vehicle:isEngineRunning() and vehicle:isEngineStarted() then
            Power.requestDrive(vehicle, vehicle:getDriver(), "pedal")
        end
        return true
    end
    if args.why == "enter" or args.why == "switchSeat" or args.why == "seated" then
        Power.onSeated(vehicle, player, args.why)
        return true
    end
    Power.evaluate(vehicle, args.why or "tick")
    Net.resyncEngine(vehicle, args, player)
    return true
end

-- Who may send what (REVIEW 3.1-5): "inside" = the player sits in that car;
-- "near" = within NEAR_TILES of it (outside actions such as charging or the
-- fridge through the door). Anything not listed is refused.
Net.NEAR_TILES = 6
Net.RULES = {
    powerOn = "inside", setMode = "inside", toggleExitAllOff = "inside", toggleCamping = "inside",
    evaluatePower = "inside+exit", toggleFridge = "near", setFridgeMode = "near", startCharge = "near", stopCharge = "near",
}
Net.CHARGE_KINDS = { fast = true, slow = true }

-- Server: is `player` allowed to run `command` on `vehicle` with `args`?
function Net.allowed(command, player, vehicle, args)
    local rule = Net.RULES[command]
    if not rule then return false, "unknownCommand" end
    if not player or not vehicle then return false, "noPlayerOrVehicle" end
    local inside = player:getVehicle() == vehicle
    if rule == "inside" and not inside then return false, "notInside" end
    if rule == "inside+exit" and not inside then
        -- an exit is reported after the player left the seat: near is enough
        if args.why ~= "exit" then return false, "notInside" end
        rule = "near"
    end
    if rule == "near" and not inside then
        if Util.dist(player:getX(), player:getY(), vehicle:getX(), vehicle:getY()) > Net.NEAR_TILES then
            return false, "tooFar"
        end
    end
    if command == "startCharge" then
        if not Net.CHARGE_KINDS[args.kind] then return false, "badKind" end
        for _, k in ipairs({ "x", "y", "z" }) do
            if type(args[k]) ~= "number" then return false, "badSquare" end
        end
        if Util.dist(player:getX(), player:getY(), args.x, args.y) > Net.NEAR_TILES then return false, "sourceFar" end
    end
    return true, nil
end

-- Runs `name` for `vehicle`. Returns ok, reason when run locally.
function Net.run(name, vehicle, args, player)
    args = args or {}
    if isClient and isClient() then
        args.vehicle = vehicle:getId()
        sendClientCommand(player, Net.MODULE, name, args)
        return true
    end
    local fn = Net.actions[name]
    if not fn then return false, "unknownAction" end
    return fn(vehicle, args, player)
end

-- Our state of the vehicle as one string: compared before / after a command so the state goes out only when it
-- changed (REVIEW 3.2-5: every player in a car sent a 1 s "tick" and each one re-sent the whole modData).
-- transmitModData sends the vehicle's own modData and nothing else (ObjectModDataPacket writes
-- getObject().getModData()); a part's modData travels with transmitPartModData, which the actions send themselves
-- (Fridge.setOn / setMode). So only our table in the vehicle's modData counts (#253-5: 1.3.1 flattened the whole
-- vehicle modData, other mods' keys too, and all 54 parts' modData twice per command, 0.4-0.5 ms).
local function flat(t, depth)
    if type(t) ~= "table" then return tostring(t) end
    if depth > 3 then return "{...}" end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    Util.sort(keys, function(a, b) return a < b end)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = t[k]
        if v == nil then v = t[tonumber(k)] end
        parts[#parts + 1] = k .. "=" .. flat(v, depth + 1)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end
function Net.stateKey(vehicle)
    return flat(vehicle:getModData()[State.KEY], 0)
end

-- A refused or failed command: tell that player why (REVIEW 3.2-4: on a
-- multiplayer client Net.run returns true at once, so the menu's own
-- message never came). Shown by client/NEVLib/ServerCommands.lua.
function Net.reply(player, vehicle, why)
    if not player or not why or not sendServerCommand then return end
    sendServerCommand(player, Net.MODULE, "reason", { vehicle = vehicle and vehicle:getId() or -1, why = tostring(why) })
end

-- Server side of multiplayer: validated, then run, then the vehicle's state
-- is sent to every client when it changed. Wrapped with Util.guardKeep in
-- Server.lua, so one malformed command cannot switch off all later ones.
function Net.onClientCommand(module, command, player, args)
    if module ~= Net.MODULE then return end
    local fn = Net.actions[command]
    if type(args) ~= "table" or type(args.vehicle) ~= "number" then
        Util.log("NET", { event = "refused", command = tostring(command), why = "badArgs" })
        return
    end
    local vehicle = getVehicleById(args.vehicle)
    if not fn or not vehicle or not NEVLib.Registry.isNEV(vehicle) then
        Util.log("NET", { event = "refused", command = tostring(command), why = "noSuchVehicleOrCommand" })
        return
    end
    local ok, why = Net.allowed(command, player, vehicle, args)
    if not ok then
        Util.log("NET", { event = "refused", command = command, why = why,
                          player = player and player:getUsername() or "?" })
        Net.reply(player, vehicle, why)
        return
    end
    local before = Net.stateKey(vehicle)
    local done, reason = fn(vehicle, args, player)
    if done == false and reason then Net.reply(player, vehicle, reason) end
    if Net.stateKey(vehicle) ~= before then vehicle:transmitModData() end
end

return Net
