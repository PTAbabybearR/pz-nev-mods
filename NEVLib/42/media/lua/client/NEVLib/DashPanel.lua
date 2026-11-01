-- NEV Lib: our own dashboard panel (docs/design/ui/dashboard-design.md 25, #339). An ISPanel of its own, not
-- vanilla's ISVehicleDashboard class or instance: a mod that replaces that class can neither remove nor overdraw it.
-- NEVLib/DashRoute decides when it is shown; NEVLib/Dashboard lays it out and draws it.
-- The vanilla icons the NEV dashboard keeps (door lock, lights, radio / screen, heater, trunk, cruise) are this
-- panel's own children. Their state, colours, clicks, the ignition key sound and the damage flicker follow the same
-- rules as vanilla ISVehicleDashboard.lua (line numbers below are that file's, 42.21), written here, not copied
-- (25.4, user 10-23 Q1 B). Nothing on the run-time ISVehicleDashboard class is read: another mod may have changed it.
require "ISUI/ISPanel"
require "ISUI/ISImage"
require "NEVLib/Util"
require "NEVLib/Dashboard"

local Util, Dashboard = NEVLib.Util, NEVLib.Dashboard

local Panel = ISPanel:derive("NEVDashboardPanel")
NEVLib.DashPanel = Panel

Panel.DAMAGE_MS = 180         -- vanilla compares part conditions every 11 ticks (:666-684), ~180 ms at 60 fps
Panel.DAMAGE_DROP = 10        -- a part losing more than this flickers the icons (:643-654)
Panel.FLICK_FRAMES = 100      -- vanilla damageFlick (:143-153)

-- field, texture (media/ui/vehicles/), tooltip key, click handler (createChildren :26-90)
Panel.ICONS = {
    { field = "doorTex", tex = "icon_doorslocked_light", tip = "Tooltip_Dashboard_LockedDoors", click = "onClickDoors" },
    { field = "lightsTex", tex = "icon_headlights_light", tip = "Tooltip_Dashboard_Headlights", click = "onClickHeadlights" },
    { field = "heaterTex", tex = "icon_heating_light", tip = "Tooltip_Dashboard_Heater", click = "onClickHeater" },
    { field = "trunkTex", tex = "icon_trunk_light", click = "onClickTrunk" },
}

-- Keys the panel does not have: while it stands in a player's dashboard slot (DashRoute), another mod that got it
-- from getPlayerVehicleDashboard may call a method it added to the vanilla dashboard (Retro's damageFlick calls
-- dash:rdStartFlicker()). Such a key is looked up on the vanilla instance it replaced (nevOrig, recorded by
-- DashRoute when it took the slot - never through getPlayerVehicleDashboard, which is this panel); a function there
-- answers a function that does nothing, anything else nil (25.5 table 2). Our class chain is searched first, so
-- this only runs for keys neither the panel nor ISPanel / ISUIElement has.
local function noop() end
Panel.INSTANCE_MT = {
    __index = function(t, k)
        local v = Panel[k]
        if v ~= nil then return v end
        local orig = rawget(t, "nevOrig")
        if orig ~= nil and type(orig[k]) == "function" then return noop end
        return nil
    end,
}

function Panel:new(playerNum, character)
    local o = ISPanel:new(0, 0, Dashboard.MIN_W, Dashboard.COLLAPSED_H)
    setmetatable(o, Panel.INSTANCE_MT)
    o.playerNum, o.character = playerNum, character
    o:noBackground()
    -- the scale base, as the vanilla background was wide (no field named backgroundTex: AutoDrive would size its
    -- HUD by it, 25.3-2)
    local bg = getTexture("media/ui/vehicles/dashboard.png")
    o.nevBgW = bg and bg:getWidth() or Dashboard.BASE_W
    o.wasKeyInIgnition = false
    o.nevFlickT, o.nevFlickA, o.nevFlickUp = 0, 0, true
    return o
end

local function image(self, texture, w, h)
    local img = ISImage:new(0, 0, w, h, texture)
    img:initialise()
    img:instantiate()
    img.target = self
    self:addChild(img)
    return img
end

function Panel:createChildren()
    for _, d in ipairs(Panel.ICONS) do
        local t = getTexture("media/ui/vehicles/" .. d.tex .. ".png")
        local img = image(self, t, t:getWidthOrig(), t:getHeightOrig())
        img.onclick = Panel[d.click]
        if d.tip then img.mouseovertext = getText(d.tip) end
        self[d.field] = img
    end
    -- the radio at half its texture, drawn 16 px (:50-58); Dashboard.applyScreenButton turns it into the screen
    local radio = getTexture("Icon_Radio_Speaker")
    self.radioTex = image(self, radio, radio:getWidthOrig() / 2, radio:getHeightOrig() / 2)
    self.radioTex.scaledWidth, self.radioTex.scaledHeight = 16, 16
    self.radioTex.onclick = Panel.onClickRadio
    self.radioTex.mouseovertext = getText("Tooltip_Dashboard_Radio")
    local reg = getTexture("media/ui/vehicles/speedregulator_light.png")
    self.speedregulatorTex = image(self, reg, reg:getWidthOrig(), reg:getHeightOrig())
    self.speedregulatorTex.mouseovertext = getText("Tooltip_Dashboard_SpeedRegulator", Keyboard.getKeyName(Keyboard.KEY_LSHIFT),
        Keyboard.getKeyName(getCore():getKey(KeybindId.FORWARD)), Keyboard.getKeyName(getCore():getKey(KeybindId.BACKWARD)))
end

---------------------------------------------------------------------------
-- Showing a vehicle (DashRoute calls bind / unbind)
---------------------------------------------------------------------------

-- Vanilla's ISPlayerDataObject:onResolutionChange (:253-254) calls the slot's onResolutionChange directly: an error
-- in our layout must not break the resolution change (review round 6, advice 1)
local applyLayout = Util.guardKeep("dashboardLayout", function(self) Dashboard.applyLayout(self) end)

function Panel:bind(vehicle)
    if self.vehicle ~= vehicle then
        self.nevLayout, self.nevLayoutKey, self.nevHits, self.nevRead = nil, nil, nil, nil
        self.nevLastSpeed, self.nevRegenUntil, self.nevDamage = nil, nil, nil
    end
    self.vehicle = vehicle
    applyLayout(self)
end

-- The icons' tooltips are their own windows (ISImage:updateTooltip): put away with the panel, or one stays on
-- screen after the player gets out (T-3).
function Panel:unbind()
    self.vehicle, self.nevHits = nil, nil
    for _, name in ipairs({ "doorTex", "lightsTex", "radioTex", "heaterTex", "trunkTex", "speedregulatorTex" }) do
        local img = self[name]
        if img then
            img.mouseover = false
            if img.tooltipUI then
                img.tooltipUI:setVisible(false)
                img.tooltipUI:removeFromUIManager()
            end
        end
    end
end

-- 25.5 table 2: whoever calls the player's dashboard (vanilla on entering / leaving / switching seats) reaches
-- this panel while it stands in the slot; DashRoute keeps it, or hands the slot back to the vanilla instance.
function Panel:setVehicle(vehicle)
    NEVLib.DashRoute.panelSetVehicle(self, vehicle)
end

function Panel:onResolutionChange()
    if self.vehicle then applyLayout(self) end
end

---------------------------------------------------------------------------
-- The vanilla icons: state (ISVehicleDashboard:prerender :329-388)
---------------------------------------------------------------------------

local function highlight(c, a) return { r = c:getR(), g = c:getG(), b = c:getB(), a = a } end

function Panel:updateIcons()
    local v = self.vehicle
    local a = self:nevFlickAlpha(0.65)
    local grey = { r = 0.5, g = 0.5, b = 0.5, a = a }
    local good = highlight(getCore():getGoodHighlitedColor(), a)
    local bad = highlight(getCore():getBadHighlitedColor(), a)
    -- lights: on but cannot light = bad, on = good (:329-337)
    if v:getHeadlightsOn() and not v:getHeadlightCanEmmitLight() then
        self.lightsTex.backgroundColor = bad
    elseif v:getHeadlightsOn() then
        self.lightsTex.backgroundColor = good
    else
        self.lightsTex.backgroundColor = grey
    end
    -- doors: all locked = good, some = yellow (:338-345)
    if v:areAllDoorsLocked() then
        self.doorTex.backgroundColor = good
    elseif v:isAnyDoorLocked() then
        self.doorTex.backgroundColor = { r = 1, g = 1, b = 0, a = a }
    else
        self.doorTex.backgroundColor = grey
    end
    -- heater: only a car with one changes it (:346-353)
    local heater = v:getPartById("Heater")
    if heater then
        self.heaterTex.backgroundColor = heater:getModData().active and good or grey
    end
    -- cruise (:354-359)
    self.speedregulatorTex.backgroundColor = v:isRegulator() and good or grey
    -- trunk: shown with a truck bed only (:360-367)
    self.trunkTex:setVisible(v:getPartById("TruckBed") ~= nil)
    if v:isTrunkLocked() then
        self.trunkTex.backgroundColor = good
        self.trunkTex.mouseovertext = getText("Tooltip_Dashboard_TrunkLocked")
    else
        self.trunkTex.backgroundColor = grey
        self.trunkTex.mouseovertext = getText("Tooltip_Dashboard_TrunkUnlocked")
    end
    -- radio / screen: on = good; powered with no radio item = bad (:378-388, vanilla's operator precedence kept)
    local radio = v:getPartById("Radio")
    self.radioTex.backgroundColor = grey
    if radio and radio:getDeviceData() and radio:getDeviceData():getIsTurnedOn() then
        self.radioTex.backgroundColor = good
    end
    if v:isKeysInIgnition() or (v:isHotwired() and (v:isEngineRunning() or v:isStarting())) and v:getBatteryCharge() > 0 then
        if not radio or not radio:getInventoryItem() then
            self.radioTex.backgroundColor = bad
        end
    end
end

-- Ignition key in / out (:296-327): vanilla shows a key icon (key in, or running / starting) unless hot-wired, and
-- plays the sound when that changes. wasKeyInIgnition is vanilla's field name: DashRoute carries it across when the
-- slot changes hands, so a car change sounds as it did with one dashboard.
function Panel:keySound()
    local v = self.vehicle
    local key = not v:isHotwired() and (v:isKeysInIgnition() or v:isEngineRunning() or v:isStarting())
    if key and not self.wasKeyInIgnition then
        self.wasKeyInIgnition = true
        if self.character then self.character:playSound("VehicleInsertIgnitionKey") end
    elseif not key and self.wasKeyInIgnition then
        self.wasKeyInIgnition = false
        if self.character then self.character:playSound("VehicleRemoveIgnitionKey") end
    end
end

---------------------------------------------------------------------------
-- Damage flicker: detected here, not from flags another dashboard sets (25.4)
---------------------------------------------------------------------------

-- vanilla damageFlick / getAlphaFlick (:143-178): 100 frames, alpha 0.2 steps up and down. Named nev*: vanilla's
-- damageFlick (run from its OnTick damageChecker, :659-685) writes flickAlpha / flickAlphaUp / flickingTimer on
-- whatever getPlayerVehicleDashboard returns - our panel while it is ours - and a field written there hides a class
-- method of that name (10-23 L3: "Object 0.0 did not have __call metatable set" every frame after a crash)
function Panel:startFlick()
    self.nevFlickT, self.nevFlickA, self.nevFlickUp = Panel.FLICK_FRAMES, 0, true
end

function Panel:nevFlickAlpha(default)
    if self.nevFlickT <= 0 then return default end
    self.nevFlickT = self.nevFlickT - 1
    if self.nevFlickUp then
        self.nevFlickA = self.nevFlickA + 0.2
        if self.nevFlickA >= 1 then self.nevFlickA, self.nevFlickUp = 0.8, false end
    else
        self.nevFlickA = self.nevFlickA - 0.2
        if self.nevFlickA <= 0 then self.nevFlickA, self.nevFlickUp = 0.2, true end
    end
    return self.nevFlickA
end

-- vanilla damageChecker / comparePartsDamage (:637-685): every part's condition, compared with the last reading
function Panel:checkDamage()
    local v = self.vehicle
    local now = Dashboard.clock
    local last = self.nevDamage
    if last and last.vehicle == v and now < last.at + Panel.DAMAGE_MS then return end
    local cond = {}
    for i = 0, v:getPartCount() - 1 do
        local part = v:getPartByIndex(i)
        cond[part] = part:getCondition()
    end
    if last and last.vehicle == v then
        for part, c in pairs(last.cond) do
            local now2 = cond[part]
            if now2 ~= nil and math.abs(now2 - c) > Panel.DAMAGE_DROP then
                self:startFlick()
                break
            end
        end
    end
    self.nevDamage = { vehicle = v, at = now, cond = cond }
end

---------------------------------------------------------------------------
-- Clicks (:487-555): same calls as vanilla, behind the same game speed guard
---------------------------------------------------------------------------

local function speedOk()
    if getGameSpeed() == 0 then return false end
    if getGameSpeed() > 1 then setGameSpeed(1) end
    return true
end

function Panel:onClickHeadlights()
    if speedOk() then ISVehicleMenu.onToggleHeadlights(self.character) end
end

function Panel:onClickDoors()
    if speedOk() then ISVehiclePartMenu.onLockDoors(self.character, self.vehicle, not self.vehicle:isAnyDoorLocked()) end
end

function Panel:onClickTrunk()
    if speedOk() then ISVehicleMenu.onToggleTrunkLocked(self.character) end
end

function Panel:onClickHeater()
    if speedOk() then ISVehicleMenu.onToggleHeater(self.character) end
end

function Panel:onClickRadio()
    if not speedOk() then return end
    local radio = self.vehicle:getPartById("Radio")
    if not radio or not radio:getInventoryItem() or not radio:getDeviceData() then return end
    getSoundManager():playUISound("VehicleRadioButton")
    if radio:getDeviceData():getIsTurnedOn() then
        radio:getDeviceData():setIsTurnedOn(false)
        if ISRadioWindow.isActive(self.character, radio) then ISRadioWindow.closeIfActive(self.character, radio) end
        return
    end
    if ISRadioWindow.isActive(self.character, radio) then
        ISRadioWindow.closeIfActive(self.character, radio)
    else
        ISVehicleMenu.onSignalDevice(self.character, radio)
    end
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

-- core: keeps drawing after an error (REVIEW 3.3-15)
local prerenderPanel = Util.guardKeep("dashboardPrerender", function(self)
    Dashboard.drawFrame(self)
    self:checkDamage()
    self:updateIcons()
    self:keySound()
end)

local renderPanel = Util.guardKeep("dashboardRender", Dashboard.drawContents)

-- Drawn only while bound to the car its player sits in. Otherwise the car went away (deleted, teleported) without
-- an event: nothing drawn, and DashRoute sorts it out next tick (25.5 table 4).
local function current(self)
    if not self.vehicle or not ISUIHandler.allUIVisible then return false end
    local chr = self.character
    if chr and chr:getVehicle() == self.vehicle then return true end
    NEVLib.DashRoute.later(self.playerNum, "reconcile")
    return false
end

function Panel:prerender()
    if current(self) then prerenderPanel(self) end
end

function Panel:render()
    if current(self) then renderPanel(self) end
end

function Panel:onMouseDown(x, y)
    if self.vehicle and Dashboard.click(self, x, y) then return true end
    return ISPanel.onMouseDown(self, x, y)
end

return Panel
