-- NEV Lib: server side of player actions in multiplayer (see NEVLib/Net).
require "NEVLib/Util"
require "NEVLib/Net"
require "NEVLib/Parts"
require "NEVLib/Armor"

-- core: one bad command must not switch off every later one (REVIEW 3.1-5 / 3.3-15)
Events.OnClientCommand.Add(NEVLib.Util.guardKeep("clientCommand", NEVLib.Net.onClientCommand))

-- Dedicated / hosting server: the 1-minute part-update kick (REVIEW 3.2-8) over the loaded NEVs, once per minute
-- whatever the number of players (#253: 1.3.1 scanned squares around every online player). Single player runs the
-- client's (no isServer()).
local function kickAll()
    if not (isServer and isServer()) then return end
    NEVLib.Parts.kickTracked()
end
if isServer() then   -- #327: registered only where it works
    Events.EveryOneMinute.Add(NEVLib.Util.guard("serverKick", kickAll))
end
NEVLib.ServerKick = kickAll   -- tests

-- Armour (PARTS-DESIGN 6.3, #174): the armoured cars are checked every Armor.SWEEP_MS of real time; it runs on the
-- server and in single player (Armor.serverSide), never on a multiplayer client - so not registered there (#327; a
-- client loads server/ after it knows it is one, GameLoadingState reads GameClient.client before LoadDirBase("server")).
if not isClient() then
    Events.OnTick.Add(NEVLib.Util.guardKeep("armorSweep", NEVLib.Armor.sweep))
end

-- #263: a dedicated server reads the translations before it loads the mods (GameServer.java:639 Translator.loadFiles,
-- :1355 loadMods) and never again, so a mod key's getText returns the key itself there. A vehicle key is named on
-- the side that makes it (BaseVehicle.keyNamerVehicle:9704: getText("IGUI_VehicleName" .. car)), in multiplayer the
-- server, and clients get the finished string: "Vehicle Key - IGUI_VehicleNameNEV_LiL6" for every car pack. Reload
-- them once the mods are in: OnGameBoot (GameServer.java:1428, after the Lua files, before any player joins). Vanilla's
-- debug menu reloads them the same way (ISDebugMenu.lua:283). Single player reads them after the mods already.
local function loadModTranslations()
    if not (isServer and isServer()) then return end
    Translator.loadFiles()
    NEVLib.Util.log("SERVER", { event = "translationsReloaded", check = getText("IGUI_NEV_PowerOn") })
end
Events.OnGameBoot.Add(NEVLib.Util.guard("serverTranslations", loadModTranslations))
NEVLib.ServerTranslations = loadModTranslations   -- tests
