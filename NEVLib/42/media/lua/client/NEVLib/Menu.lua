-- NEV Lib: menus (DESIGN 3.3, 6.1, 11).
--  * in-vehicle radial menu (V): energy-mode submenu (EV / hybrid / fuel
--    priority, each greyed with the reason when the charge does not allow
--    it, UI-DESIGN 18 W4), fridge and camping slices, settings (exit: all
--    off). Power is instant on getting in / out (DESIGN 3.3), no slice.
--  * right-click outside a vehicle: start / stop charging
--  * right-click a gas pump or a placed home charger: charge the NEV next to it
--  * portable power station (DESIGN 6.4): right-click the station itself (in
--    the inventory, or placed on the ground) -> charge it / give its energy to
--    the nearby NEV (user 2026-10-07: like the home charger, not on the car)
-- Vanilla functions are wrapped, never replaced wholesale, so other mods that
-- wrap them too keep working (M1-PLAN 6).
require "NEVLib/Util"
require "Vehicles/ISUI/ISVehicleMenu"
require "NEVLib/Registry"
require "NEVLib/State"
require "NEVLib/Battery"
require "NEVLib/Charging"
require "NEVLib/Camping"
require "NEVLib/Fridge"
require "NEVLib/Net"
require "NEVLib/EnergyMode"
require "NEVLib/ChargeAction"
require "NEVLib/PowerStation"
require "NEVLib/PowerStationActions"

local Util, Registry, State, Battery, Charging, Camping, Fridge, Net =
    NEVLib.Util, NEVLib.Registry, NEVLib.State, NEVLib.Battery, NEVLib.Charging, NEVLib.Camping, NEVLib.Fridge, NEVLib.Net
local EnergyMode = NEVLib.EnergyMode
local PowerStation = NEVLib.PowerStation
local Menu = {}
NEVLib.Menu = Menu

local T = Util.text

local function tellBad(player, text)
    if text and HaloTextHelper then HaloTextHelper.addBadText(player, text) end
end

local REASON = {
    moving = "IGUI_NEV_Reason_Moving", lowCharge = "IGUI_NEV_Reason_LowCharge",
    noBattery = "IGUI_NEV_NoBattery", notSupported = "IGUI_NEV_Reason_NotSupported",
    noSource = "IGUI_NEV_Reason_NoSource", noPower = "IGUI_NEV_Reason_NoPower",
    full = "IGUI_NEV_Reason_Full", fastDisabled = "IGUI_NEV_Reason_FastDisabled",
    motorBroken = "IGUI_NEV_MotorBroken", noCharge = "IGUI_NEV_NoCharge",
    needSoc20 = "IGUI_NEV_Reason_NeedSoc20", needSoc3 = "IGUI_NEV_Reason_NeedSoc3",
    stationEmpty = "IGUI_NEV_Reason_StationEmpty", noVehicle = "IGUI_NEV_Reason_NoVehicleNear",
    needPlaced = "IGUI_NEV_Reason_NeedPlaced", stationNoPower = "IGUI_NEV_Reason_StationNoPower",
}
Menu.REASON = REASON

-- Text for a refusal reason; "portFar" names the side of the port.
function Menu.reasonText(vehicle, reason)
    if reason == "portFar" then
        local cfg = vehicle and Registry.get(vehicle)
        local side = cfg and cfg.chargePortSide
        if side then return T("IGUI_NEV_Reason_PortFar", T("IGUI_NEV_Side_" .. side)) end
        return T("IGUI_NEV_Reason_PortFarNoSide")
    end
    return REASON[reason] and T(REASON[reason]) or nil
end

function Menu.run(player, name, vehicle, args)
    local ok, reason = Net.run(name, vehicle, args, player)
    if ok == false and reason then tellBad(player, Menu.reasonText(vehicle, reason)) end
    return ok, reason
end

---------------------------------------------------------------------------
-- In-vehicle radial menu
---------------------------------------------------------------------------

local MODE_TEXT = { ev = "IGUI_NEV_Mode_EV", hybrid = "IGUI_NEV_Mode_Hybrid", fuel = "IGUI_NEV_Mode_Fuel" }

local function icon(path) return getTexture(path) end
-- the fridge modes: vanilla's temperature icons for cool / heat, our own frozen F for freeze (#173, same style)
local FRIDGE_MODE_ICON = { cool = "media/ui/vehicles/vehicle_temperatureCOLD.png",
                           freeze = "media/ui/vehicles/nev_temperatureFREEZE.png",   -- #173: own icon (art/ui/freeze_icon.py)
                           heat = "media/ui/vehicles/vehicle_temperatureHOT.png" }

function Menu.addRadialSlices(menu, player, vehicle)
    local cfg = Registry.get(vehicle)
    local st = State.get(vehicle)
    -- drop vanilla start / stop engine (no ignition on an NEV: getting in
    -- powers on, the last one out powers off, UI-DESIGN 19), and
    -- call hotwiring "hack the car computer" (user decision 2026-10-07,
    -- issue 27: "hotwire" is out of character for an EV)
    local keep = {}
    local changed = false
    local hotwireSkill = getText("ContextMenu_VehicleHotwireSkill")
    for _, slice in ipairs(menu.slices) do
        local cmd = slice.command and slice.command[1]
        if cmd == ISVehicleMenu.onShutOff or cmd == ISVehicleMenu.onStartEngine then
            changed = true
        else
            if ISVehicleMenu.onHotwire and cmd == ISVehicleMenu.onHotwire then
                slice.text = T("IGUI_NEV_Hack")
                changed = true
            elseif slice.text == hotwireSkill then
                slice.text = T("IGUI_NEV_HackSkill")
                changed = true
            end
            keep[#keep + 1] = slice
        end
    end
    if changed then
        menu:clear()
        for _, slice in ipairs(keep) do
            local c = slice.command
            menu:addSlice(slice.text, slice.texture, c[1], c[2], c[3], c[4], c[5], c[6], c[7])
        end
    end
    if cfg.powertrain == "EREV" then
        -- opens the energy-mode submenu (UI-DESIGN 3.1; problem 5: no cycling)
        menu:addSlice(T("IGUI_NEV_ModeSlice", T(MODE_TEXT[st.mode] or MODE_TEXT.ev)),
            icon("media/ui/NEVLib/rex.png"), Menu.showModeMenu, player, vehicle)
    end
    if Fridge.part(vehicle) then
        local on = Fridge.isOn(Fridge.part(vehicle))
        menu:addSlice(T(on and "IGUI_NEV_FridgeOff" or "IGUI_NEV_FridgeOn"),
            icon("media/ui/vehicles/vehicle_temperatureCOLD.png"), Menu.run, player, "toggleFridge", vehicle)
        -- cool / freeze / heat (DESIGN 7.1 revision 15): a submenu, as the energy modes
        menu:addSlice(T("IGUI_NEV_FridgeModeSlice", T("IGUI_NEV_FridgeMode_" .. Fridge.mode(Fridge.part(vehicle)))),
            icon(FRIDGE_MODE_ICON[Fridge.mode(Fridge.part(vehicle))]), Menu.showFridgeModeMenu, player, vehicle)
    end
    if cfg.camping then
        local blocker = (not st.camping) and Camping.cannotStart(vehicle) or nil
        local text = T(st.camping and "IGUI_NEV_CampingOff" or "IGUI_NEV_CampingOn")
        if blocker then text = text .. "\n(" .. T(REASON[blocker] or "IGUI_NEV_Reason_NotSupported") .. ")" end
        -- I-228 (UI-DESIGN 24): the slice names the mode to switch to, with that mode's icon
        menu:addSlice(text, icon(st.camping and "media/ui/NEVLib/driving.png" or "media/ui/NEVLib/camping.png"),
            Menu.run, player, "toggleCamping", vehicle)
    end
    -- vehicle settings submenu (UI-DESIGN 19)
    menu:addSlice(T("IGUI_NEV_Settings"), icon("media/ui/NEVLib/settings.png"), Menu.showSettingsMenu, player, vehicle)
end

-- Submenus: the same radial menu refilled. The vanilla menu closes before it
-- runs a slice command (ISRadialMenu:onMouseDown), so it is shown again here
-- the way ISVehicleMenu.showRadialMenu shows it.
local MODE_ICON = { ev = "media/ui/NEVLib/mode_ev.png", hybrid = "media/ui/NEVLib/mode_hybrid.png", fuel = "media/ui/NEVLib/mode_fuel.png" }

local function showAgain(player, fill)
    local num = player:getPlayerNum()
    local menu = getPlayerRadialMenu(num)
    fill(menu)
    menu:setX(getPlayerScreenLeft(num) + getPlayerScreenWidth(num) / 2 - menu:getWidth() / 2)
    menu:setY(getPlayerScreenTop(num) + getPlayerScreenHeight(num) / 2 - menu:getHeight() / 2)
    menu:addToUIManager()
    if JoypadState and JoypadState.players[num + 1] then
        menu:setHideWhenButtonReleased(Joypad.DPadUp)
        setJoypadFocus(num, menu)
    end
end

-- "Back": vanilla showRadialMenu is a toggle and, within the click that
-- closed the menu, still sees it as visible -> it would just close it
-- (UI-DESIGN 18 W9). Rebuild the main menu with the toggle check bypassed.
Menu.backToMain = Util.guard("radialBack", function(player)
    local menu = getPlayerRadialMenu(player:getPlayerNum())
    local own = rawget(menu, "isReallyVisible")
    menu.isReallyVisible = function() return false end
    local ok, err = pcall(ISVehicleMenu.showRadialMenu, player)
    menu.isReallyVisible = own
    if not ok then error(err) end
end)

-- Energy modes (W4): the three modes; the ones the charge does not allow are
-- listed but inert, with the reason.
function Menu.fillModeMenu(menu, player, vehicle)
    local st = State.get(vehicle)
    local soc = Battery.getSoc(vehicle)
    menu:clear()
    for _, mode in ipairs(EnergyMode.ORDER) do
        local label = T(MODE_TEXT[mode])
        if st.mode == mode then label = T("IGUI_NEV_ModeCurrent", label) end
        local ok, why = EnergyMode.allowed(mode, soc)
        if ok then
            menu:addSlice(label, icon(MODE_ICON[mode]), Menu.run, player, "setMode", vehicle, { mode = mode })
        else
            menu:addSlice(label .. "\n(" .. T(REASON[why] or "IGUI_NEV_Reason_NotSupported") .. ")", icon(MODE_ICON[mode]))
        end
    end
    menu:addSlice(T("IGUI_NEV_Back"), icon("media/ui/NEVLib/arrow_left.png"), Menu.backToMain, player)
end

Menu.showModeMenu = Util.guard("modeMenu", function(player, vehicle)
    if not vehicle or player:getVehicle() ~= vehicle then return end
    showAgain(player, function(menu) Menu.fillModeMenu(menu, player, vehicle) end)
end)

-- Fridge modes (DESIGN 7.1 revision 15): one slice per mode, the current one marked, back.
function Menu.fillFridgeModeMenu(menu, player, vehicle)
    local current = Fridge.mode(Fridge.part(vehicle))
    menu:clear()
    for _, mode in ipairs(Fridge.MODES) do
        local label = T("IGUI_NEV_FridgeMode_" .. mode)
        if mode == current then label = T("IGUI_NEV_ModeCurrent", label) end
        menu:addSlice(label, icon(FRIDGE_MODE_ICON[mode]), Menu.run, player, "setFridgeMode", vehicle, { mode = mode })
    end
    menu:addSlice(T("IGUI_NEV_Back"), icon("media/ui/NEVLib/arrow_left.png"), Menu.backToMain, player)
end

Menu.showFridgeModeMenu = Util.guard("fridgeModeMenu", function(player, vehicle)
    if not vehicle or player:getVehicle() ~= vehicle then return end
    showAgain(player, function(menu) Menu.fillFridgeModeMenu(menu, player, vehicle) end)
end)

-- Vehicle settings (UI-DESIGN 19): per-vehicle switches.
function Menu.fillSettingsMenu(menu, player, vehicle)
    local st = State.get(vehicle)
    menu:clear()
    menu:addSlice(T(st.exitAllOff and "IGUI_NEV_SettingExitAllOffOn" or "IGUI_NEV_SettingExitAllOffOff"),
        icon("media/ui/NEVLib/fridge.png"), Menu.runAndReopen, player, "toggleExitAllOff", vehicle)
    menu:addSlice(T("IGUI_NEV_Back"), icon("media/ui/NEVLib/arrow_left.png"), Menu.backToMain, player)
end

Menu.showSettingsMenu = Util.guard("settingsMenu", function(player, vehicle)
    if not vehicle or player:getVehicle() ~= vehicle then return end
    showAgain(player, function(menu) Menu.fillSettingsMenu(menu, player, vehicle) end)
end)

-- A switch in the settings menu: toggle, then show the settings again so
-- the new value is visible.
function Menu.runAndReopen(player, name, vehicle)
    Menu.run(player, name, vehicle)
    Menu.showSettingsMenu(player, vehicle)
end

local origRadial = ISVehicleMenu.showRadialMenu
local radialGuarded = Util.guard("radialMenu", function(player)
    local vehicle = player:getVehicle()
    if not vehicle or not Registry.isNEV(vehicle) then return end
    local menu = getPlayerRadialMenu(player:getPlayerNum())
    -- the vanilla function closes the menu (and leaves it empty) when it was open
    if #menu.slices == 0 then return end
    Menu.addRadialSlices(menu, player, vehicle)
end)
function ISVehicleMenu.showRadialMenu(player)
    origRadial(player)
    radialGuarded(player)
end

-- Key bindings and other mods (e.g. AutoDrive) call these. NEVs have no
-- ignition (UI-DESIGN 19): "start" just runs the normal automatic power-on
-- (getting in already did it), "shut off" does nothing - there is no manual
-- power-off in v1.
local origStart, origShutOff = ISVehicleMenu.onStartEngine, ISVehicleMenu.onShutOff
function ISVehicleMenu.onStartEngine(player)
    local vehicle = player:getVehicle()
    if vehicle and Registry.isNEV(vehicle) then
        Menu.run(player, "powerOn", vehicle)
        return
    end
    return origStart(player)
end
function ISVehicleMenu.onShutOff(player)
    local vehicle = player:getVehicle()
    if vehicle and Registry.isNEV(vehicle) then return end
    return origShutOff(player)
end

---------------------------------------------------------------------------
-- Charging options
---------------------------------------------------------------------------

-- Finds a charging source near the vehicle: { kind, obj }.
function Menu.sourcesNear(vehicle)
    local list = {}
    local pump = Charging.findSourceFor(vehicle, "fast")
    if pump then list[#list + 1] = { kind = "fast", obj = pump } end
    local charger = Charging.findSourceFor(vehicle, "slow")
    if charger then list[#list + 1] = { kind = "slow", obj = charger } end
    return list
end

-- Walk to a vehicle area the way vanilla refuelling does. Standing in it
-- already -> no walk: the vanilla path-find to the area one stands in fails
-- and clears the whole queue, so nothing happened at all (M1-3 issue 3). A
-- walk that fails says so, like vanilla's "no way to the fuel tank inlet"
-- (ISVehiclePartMenu.onPumpGasolinePathFail).
function Menu.walkToArea(player, vehicle, area)
    if vehicle:isInArea(area, player) then return false end
    local action = ISPathFindAction:pathToVehicleArea(player, vehicle, area)
    if action.setOnFail then action:setOnFail(Menu.onWalkToAreaFail, player) end
    ISTimedActionQueue.add(action)
    return true
end

function Menu.onWalkToAreaFail(player)
    if HaloTextHelper and HaloTextHelper.addBadText then
        HaloTextHelper.addBadText(player, T("IGUI_NEV_NoWayToPort"))
    end
end

-- Start charging the way vanilla refuels (DESIGN 6.1): walk to the
-- charging port area, plug in (NEVConnectChargerAction), then start. Models
-- without a port area start right away.
function Menu.beginCharge(player, vehicle, args)
    local cfg = Registry.get(vehicle)
    local area = cfg and cfg.chargePortArea
    if not area or not vehicle:getAreaCenter(area) or not ISPathFindAction then
        return Menu.run(player, "startCharge", vehicle, args)
    end
    if player:getVehicle() then ISVehicleMenu.onExit(player) end
    Menu.walkToArea(player, vehicle, area)
    -- a network timed action: it starts the charge itself (complete(), on the
    -- server in multiplayer), so it carries the source square, not a callback
    ISTimedActionQueue.add(NEVConnectChargerAction:new(player, vehicle, area, args.kind, args.x, args.y, args.z))
    return true
end

function Menu.addChargeOptions(context, player, vehicle, sources)
    if Charging.isCharging(vehicle) then
        context:addOption(T("ContextMenu_NEV_StopCharge"), player, Menu.run, "stopCharge", vehicle)
        return
    end
    for _, src in ipairs(sources) do
        local sq = src.obj:getSquare()
        local label = T(src.kind == "fast" and "ContextMenu_NEV_FastCharge" or "ContextMenu_NEV_SlowCharge")
        local option = context:addOption(label, player, Menu.beginCharge, vehicle,
            { kind = src.kind, x = sq:getX(), y = sq:getY(), z = sq:getZ() })
        local why = Charging.cannotStart(vehicle, src.kind, src.obj)
        if why then
            option.notAvailable = true
            local tip = ISToolTip:new()
            tip:initialise()
            tip.description = Menu.reasonText(vehicle, why) or T("IGUI_NEV_Reason_NotSupported")
            option.toolTip = tip
        end
    end
end

local function greyOut(option, vehicle, why)
    option.notAvailable = true
    local tip = ISToolTip:new()
    tip:initialise()
    tip.description = Menu.reasonText(vehicle, why) or T("IGUI_NEV_Reason_NotSupported")
    option.toolTip = tip
end

-- Portable power station -> car (DESIGN 6.4): walk to the charging port like
-- plugging in a charger, then empty the station into the battery. worldObj:
-- the station placed on the ground (nil when carried).
function Menu.giveFromStation(player, vehicle, item, worldObj)
    local cfg = Registry.get(vehicle)
    local area = cfg and cfg.chargePortArea
    if not area or not vehicle:getAreaCenter(area) or not ISPathFindAction then area = nil end
    if player:getVehicle() then ISVehicleMenu.onExit(player) end
    if area then Menu.walkToArea(player, vehicle, area) end
    ISTimedActionQueue.add(NEVPowerStationToCarAction:new(player, vehicle, area, item, worldObj))
    return true
end

-- "Charge the nearby NEV from it": the nearest NEV around the station (carried:
-- around the player); a placed station must be within reach of the car's
-- charging port, like a placed home charger (DESIGN 6.1).
function Menu.addStationGiveOption(context, player, item, worldObj)
    local sq = worldObj and worldObj:getSquare() or player:getCurrentSquare()
    local vehicle = Menu.nearestNEV(sq:getX(), sq:getY(), sq:getZ(), Charging.START_RANGE, worldObj and sq or nil)
    local option = context:addOption(T("ContextMenu_NEV_PowerStationToCar", string.format("%.1f", PowerStation.kwh(item))),
        player, Menu.giveFromStation, vehicle, item, worldObj)
    local why
    if not vehicle then
        why = "noVehicle"
    else
        why = PowerStation.cannotGive(item, vehicle)
        if not why and worldObj and not Charging.portReaches(vehicle, sq) then why = "portFar" end
    end
    if why then greyOut(option, vehicle, why) end
end

-- I-251 (GitHub #159, user 10-14: "both entries"; DESIGN 6.4 revision 15): the car's own menus offer the
-- station too. The station used: the fullest one the player carries (bags included) or one placed where the
-- car's charging port reaches (the same reach as a placed home charger).
function Menu.stationFor(player, vehicle)
    local best, bestKwh, bestObj = nil, -1, nil
    local inv = player and player:getInventory()
    local list = inv and inv.getAllTypeRecurse and inv:getAllTypeRecurse(PowerStation.ITEM)
    for i = 0, (list and list:size() or 0) - 1 do
        local it = list:get(i)
        local k = PowerStation.kwh(it)
        if k > bestKwh then best, bestKwh, bestObj = it, k, nil end
    end
    local cell = getCell()
    local x, y, z = math.floor(vehicle:getX()), math.floor(vehicle:getY()), math.floor(vehicle:getZ())
    local r = Charging.START_RANGE
    for dy = -r, r do
        for dx = -r, r do
            local sq = cell and cell:getGridSquare(x + dx, y + dy, z)
            local objs = sq and sq.getWorldObjects and sq:getWorldObjects()
            for i = 0, (objs and objs:size() or 0) - 1 do
                local o = objs:get(i)
                local it = o:getItem()
                if PowerStation.isStation(it) and Charging.portReaches(vehicle, sq) then
                    local k = PowerStation.kwh(it)
                    if k > bestKwh then best, bestKwh, bestObj = it, k, o end
                end
            end
        end
    end
    return best, bestObj
end

-- "Charge from the power station (x kWh)" on the car; nothing when there is no station at all.
function Menu.addCarStationOption(context, player, vehicle)
    local item, worldObj = Menu.stationFor(player, vehicle)
    if not item then return nil end
    local option = context:addOption(T("ContextMenu_NEV_CarFromStation", string.format("%.1f", PowerStation.kwh(item))),
        player, Menu.giveFromStation, vehicle, item, worldObj)
    local why = PowerStation.cannotGive(item, vehicle)
    if why then greyOut(option, vehicle, why) end
    return option
end

-- Charge a placed station (user 2026-10-07: only on the ground, like the
-- vanilla car battery charger): walk next to it, then the charge action.
function Menu.chargeStation(player, item, worldObj)
    if luautils.walkAdj(player, worldObj:getSquare(), false) then
        ISTimedActionQueue.add(NEVPowerStationChargeAction:new(player, item, worldObj))
    end
end

local function chargeLabel(item)
    return T("ContextMenu_NEV_PowerStationCharge", string.format("%.1f", PowerStation.kwh(item)),
        tostring(PowerStation.CAPACITY_KWH))
end

-- Carried: charging is shown greyed ("place it on the ground first"), giving works.
function Menu.addStationInventoryOption(context, player, item)
    local option = context:addOption(chargeLabel(item), player, nil)
    greyOut(option, nil, "needPlaced")
    Menu.addStationGiveOption(context, player, item, nil)
end

-- Placed on the ground: charge it here, or give its energy to the nearby NEV.
function Menu.addStationWorldOptions(context, player, worldObj)
    local item = worldObj:getItem()
    local option = context:addOption(chargeLabel(item), player, Menu.chargeStation, item, worldObj)
    local why = PowerStation.cannotCharge(item, worldObj:getSquare())
    if why then greyOut(option, nil, why) end
    Menu.addStationGiveOption(context, player, item, worldObj)
end

local function onInventoryMenu(playerNum, context, items)
    local player = getSpecificPlayer(playerNum)
    for _, v in ipairs(items) do
        local item = v
        if type(v) == "table" and v.items then item = v.items[1] end
        if PowerStation.isStation(item) and PowerStation.carriedBy(player, item) then
            Menu.addStationInventoryOption(context, player, item)
            return
        end
    end
end
Events.OnFillInventoryObjectContextMenu.Add(Util.guard("inventoryMenu", onInventoryMenu))

local origOutside = ISVehicleMenu.FillMenuOutsideVehicle
-- Vanilla hands this the player NUMBER and looks the player up itself (ISVehicleMenu.lua:594-595);
-- our options need the player object (I-241, player report on v1.0.0: passing the number on made
-- "start charging" from the car's menu throw in beginCharge, and stop / failure messages break too).
local outsideGuarded = Util.guard("outsideMenu", function(playerNum, context, vehicle, test)
    if test or not vehicle or not Registry.isNEV(vehicle) then return end
    local player = type(playerNum) == "number" and getSpecificPlayer(playerNum) or playerNum
    if not player then return end
    Menu.addChargeOptions(context, player, vehicle, Menu.sourcesNear(vehicle))
    Menu.addCarStationOption(context, player, vehicle)
end)
function ISVehicleMenu.FillMenuOutsideVehicle(player, context, vehicle, test)
    local r = origOutside(player, context, vehicle, test)
    outsideGuarded(player, context, vehicle, test)
    return r
end

-- Right-click a pump or a placed home charger: charge the nearest NEV.
-- With `sourceSq`, an NEV whose charging port reaches it wins over a nearer
-- one that does not (same rule as Charging.cannotStart).
function Menu.nearestNEV(x, y, z, radius, sourceSq)
    local cell = getCell()
    local best, bestD, bestReach = nil, 1e9, false
    for dy = -radius, radius do
        for dx = -radius, radius do
            local sq = cell:getGridSquare(math.floor(x) + dx, math.floor(y) + dy, z)
            local v = sq and sq:getVehicleContainer()
            if v and Registry.isNEV(v) then
                local d = Util.dist(x, y, v:getX(), v:getY())
                local reach = sourceSq ~= nil and Charging.portReaches(v, sourceSq)
                if (reach and not bestReach) or (reach == bestReach and d < bestD) then
                    best, bestD, bestReach = v, d, reach
                end
            end
        end
    end
    return best
end

local function onWorldMenu(playerNum, context, worldObjects, test)
    if test then return end
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end
    local squares, seen = {}, {}
    for _, obj in ipairs(worldObjects) do
        local sq = obj:getSquare()
        if sq and not seen[sq] then
            seen[sq] = true
            squares[#squares + 1] = sq
        end
    end
    local station = PowerStation.worldAt(squares)
    if station then Menu.addStationWorldOptions(context, player, station) end
    local source = Charging.sourceAt(squares)
    if not source then return end
    local sq = source.obj:getSquare()
    local vehicle = Menu.nearestNEV(sq:getX(), sq:getY(), sq:getZ(), Charging.START_RANGE, sq)
    if vehicle then
        Menu.addChargeOptions(context, player, vehicle, { source })
    elseif source.kind == "slow" then
        local option = context:addOption(T("ContextMenu_NEV_SlowCharge"), nil, nil)
        option.notAvailable = true
        local tip = ISToolTip:new()
        tip:initialise()
        tip.description = T("IGUI_NEV_Reason_NoVehicle")
        option.toolTip = tip
    end
end

Events.OnFillWorldObjectContextMenu.Add(Util.guard("worldMenu", onWorldMenu))

return Menu
