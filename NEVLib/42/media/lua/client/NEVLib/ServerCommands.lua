-- NEV Lib: what the multiplayer server sends one player (REVIEW 3.2-4):
--   tell   { key, bad }   a notice (NEVLib.Power.tell on the server)
--   reason { vehicle, why } a refused / failed command (NEVLib.Net.reply)
-- and every client (#322):
--   radio  { vehicle, on, channel, volume } the radio / screen the power state switched (NEVLib.Power.applyRadio)
require "NEVLib/Util"
require "NEVLib/Menu"
require "NEVLib/Power"

local Util = NEVLib.Util
local ServerCommands = {}
NEVLib.ServerCommands = ServerCommands

local function halo(text, bad)
    local player = getPlayer()
    if not player or not text or not HaloTextHelper then return end
    if bad then HaloTextHelper.addBadText(player, text) else HaloTextHelper.addText(player, text) end
end

function ServerCommands.on(module, command, args)
    if module ~= "NEVLib" or type(args) ~= "table" then return end
    if command == "tell" and type(args.key) == "string" then
        halo(Util.text(args.key), args.bad == true)
    elseif command == "reason" and type(args.why) == "string" then
        local vehicle = type(args.vehicle) == "number" and getVehicleById and getVehicleById(args.vehicle) or nil
        -- only reasons the player can act on have a text; anti-cheat refusals stay silent
        halo(NEVLib.Menu.reasonText(vehicle, args.why), true)
    elseif command == "radio" then
        NEVLib.Power.applyRadio(args)
    end
end

Events.OnServerCommand.Add(Util.guard("serverCommand", ServerCommands.on))

return ServerCommands
