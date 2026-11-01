-- NEV Lib: infotainment screen (DESIGN 7.5, docs/design/cabin/tv-design.md). The screen
-- item sits in the vanilla "Radio" part, and the vanilla radio code turns the
-- part into a television that plays VHS tapes. What vanilla does not do:
-- its "take the media out when the radio is uninstalled" code is commented
-- out (Vehicles.UninstallComplete.Radio), and a re-install creates a fresh
-- DeviceData, so a tape left inside would be lost. Before an NEV screen is
-- uninstalled, the tape goes to the mechanic's inventory.
--
-- ISUninstallVehiclePart.complete runs where the action completes (single
-- player: here; multiplayer: the server), so this lives in shared/.
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/Config"
require "Vehicles/TimedActions/ISUninstallVehiclePart"

local Util, Registry, Config = NEVLib.Util, NEVLib.Registry, NEVLib.Config
local Screen = {}
NEVLib.Screen = Screen

Screen.PART_ID = "Radio"

-- Power while switched on, powered or not (DESIGN 5.3, user 2026-10-10: "a
-- small screen draws less than a TV"): 1/3 of a vanilla television's
-- generator load (screen area about 1/3: 15.7 in. against a ~27 in. CRT).
Screen.KW = Registry.VANILLA_TV_LOAD * Registry.VANILLA_LOAD_KW / 3

function Screen.drawKW(vehicle)
    local part = vehicle and vehicle:getPartById(Screen.PART_ID)
    local dd = part and part:getInventoryItem() and part:getDeviceData()
    if dd and dd:getIsTurnedOn() then return Screen.KW end
    return 0
end

-- Part update. Vanilla Vehicles.Update.Radio copies the item's device values
-- (needed: InfotainmentTV relies on it) and, with the engine off, takes a
-- fixed share of the battery per minute - meant for a 12 V battery, on a
-- 51 kWh traction battery ~0.15 kW (VehicleUtils.chargeBattery even adds
-- the delta twice). The screen's draw is Screen.KW in the battery update
-- instead, so the vanilla share is put back.
function Screen.update(vehicle, part, elapsedMinutes)
    local update = Vehicles and Vehicles.Update and Vehicles.Update.Radio
    if not update then return end
    local battery = Registry.isNEV(vehicle) and vehicle:getPartById("Battery")
    local item = battery and battery:getInventoryItem()
    local before = item and item:getCurrentUsesFloat()
    update(vehicle, part, elapsedMinutes)
    if before and item:getCurrentUsesFloat() ~= before then
        item:setUsedDelta(before)
        vehicle:transmitPartUsedDelta(battery)
    end
end

-- Takes the tape out of an NEV screen part into `container`. Returns true
-- when a tape was ejected.
function Screen.ejectTape(vehicle, part, container)
    if not vehicle or not part or not container then return false end
    if part:getId() ~= Screen.PART_ID or not Registry.isNEV(vehicle) then return false end
    local dd = part:getDeviceData()
    if not dd or not dd:hasMedia() then return false end
    if dd:isPlayingMedia() then dd:StopPlayMedia() end
    dd:removeMediaItem(container)
    Util.log("SCREEN", { event = "tapeEjected", why = "uninstall" })
    return true
end

local ejectGuarded = Util.guard("screenEject", function(action)
    if Screen.ejectTape(action.vehicle, action.part, action.character and action.character:getInventory()) then
        if HaloTextHelper and action.character then
            HaloTextHelper.addText(action.character, Util.text("IGUI_NEV_ScreenTapeOut"))
        end
    end
end)

local origComplete = ISUninstallVehiclePart.complete
function ISUninstallVehiclePart:complete()
    ejectGuarded(self)
    return origComplete(self)
end

---------------------------------------------------------------------------
-- Sandbox "InfotainmentTV" (DESIGN 7.5, REVIEW D5): off -> the part holds a
-- radio-only item (NEVLib.InfotainmentScreenRadio, "car radio": FM channels, no
-- media) instead of the TV screen. The item is what counts: vanilla
-- Vehicles.Update.Radio copies the installed item's device values onto the
-- part on EVERY update ("kludge so pre-existing radios are updated"), so
-- changing the part's DeviceData alone was undone at once (game test round
-- 4: radio channel but the media panel back). Applied whenever the vehicle
-- enters the world (part lua "init") and after an install.
---------------------------------------------------------------------------

Screen.TV_ITEM = "NEVLib.InfotainmentScreen"
Screen.RADIO_ITEM = "NEVLib.InfotainmentScreenRadio"

-- Where a tape goes when the screen becomes a radio: usually nobody sits in
-- a car that is being loaded, so the glove box, else the trunk.
local function tapeContainer(vehicle)
    for _, id in ipairs({ "GloveBox", "TruckBed" }) do
        local p = vehicle:getPartById(id)
        local c = p and p:getItemContainer()
        if c then return c end
    end
    return nil
end

-- Copy the device values vanilla copies (Vehicles.InstallComplete.Radio) so
-- the window is right before the next part update does it anyway.
local function copyDevice(dd, src)
    dd:setIsTelevision(src:getIsTelevision())
    dd:setMinChannelRange(src:getMinChannelRange())
    dd:setMaxChannelRange(src:getMaxChannelRange())
    dd:setMediaType(src:getMediaType())
    dd:generatePresets()
    dd:setRandomChannel()
end

-- Returns true when the installed item was swapped.
function Screen.apply(vehicle, part)
    if not part or part:getId() ~= Screen.PART_ID or not Registry.isNEV(vehicle) then return false end
    -- part init runs on multiplayer clients too: the server swaps and sends
    -- the part (REVIEW 3.2-2: a client swapping on its own desynced it)
    if isClient and isClient() then return false end
    local item = part:getInventoryItem()
    if not item then return false end
    local have = item:getFullType()
    if have ~= Screen.TV_ITEM and have ~= Screen.RADIO_ITEM then return false end -- something else installed
    local want = (Config.get("InfotainmentTV") ~= false) and Screen.TV_ITEM or Screen.RADIO_ITEM
    if have == want then return false end
    local dd = part:getDeviceData()
    if want == Screen.RADIO_ITEM and dd and dd:hasMedia() then
        local c = tapeContainer(vehicle)
        if not c then return false end -- never lose a tape: stay a TV for now
        if dd:isPlayingMedia() then dd:StopPlayMedia() end
        dd:removeMediaItem(c)
        Util.log("SCREEN", { event = "tapeEjected", why = "radioOnly" })
    end
    local new = instanceItem(want)
    if not new then return false end
    new:setCondition(item:getCondition())
    part:setInventoryItem(new)
    if dd and new:getDeviceData() then copyDevice(dd, new:getDeviceData()) end
    vehicle:transmitPartItem(part)
    Util.log("SCREEN", { event = "swap", item = want })
    return true
end

-- part lua "init" of the screen part (every load / spawn): also lists the car with the loaded NEVs the part-update
-- kick walks (Parts.track, #253; looked up at call time - Parts requires this file)
function Screen.init(vehicle, part)
    Screen.apply(vehicle, part)
    if NEVLib.Parts then NEVLib.Parts.track(vehicle) end
end

-- install "complete" of the screen part: vanilla first, then the sandbox value
function Screen.installComplete(vehicle, part)
    local vanilla = Vehicles and Vehicles.InstallComplete and Vehicles.InstallComplete.Radio
    if vanilla then vanilla(vehicle, part) end
    Screen.apply(vehicle, part)
end

return Screen
