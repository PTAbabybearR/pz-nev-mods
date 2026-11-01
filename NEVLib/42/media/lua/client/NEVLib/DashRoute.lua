-- NEV Lib: which driver's dashboard the player sees (docs/design/ui/dashboard-design.md 25.3, 25.5, #339).
-- User 10-23: on our cars only our dashboard, on other cars never ours; 15:02: this is about the driver's dashboard
-- only - any other seat is left to the other mods.
--  * While the player drives an NEV ("ours"), the player's dashboard slot (ISPlayerData[n + 1].vehicleDashboard,
--    what getPlayerVehicleDashboard returns) holds our panel (NEVLib/DashPanel); otherwise the vanilla instance.
--    Whatever vanilla or another mod does to "the dashboard" then lands on the right object (AutoDrive's HUD too).
--  * The vanilla instance is never deleted and its class never changed: a few methods are put on the instance
--    itself (instance fields win over any class change, whatever the load order), keeping it off screen while ours
--    and calling the class otherwise - looked up at call time, never stored (25.3-4).
--  * Another mod's driver dashboard that is a separate panel derived from the vanilla class is put away while ours
--    and put back (if it still wants to be shown) the tick after the player leaves the driver's seat (table 3).
-- No per-frame scan: events, the covered methods and a one-shot next-tick pass do the work.
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/DashPanel"

local Util, Registry, Panel = NEVLib.Util, NEVLib.Registry, NEVLib.DashPanel
local T = Util.text

local Route = {}
NEVLib.DashRoute = Route

-- [playerNum] = { orig = covered vanilla instance, mine = our panel in the slot, held = { table 3 entries } }
Route.players = {}
Route.panels = {}          -- [playerNum] = our panel, made on first use and kept
Route.pending = {}         -- [playerNum] = { reconcile =, scan = ticks left, release = } for the next tick
-- Table 3 looks on this many ticks after a re-match: a panel another mod adds in the same event is only in the UI
-- list after the UI update that follows the first tick (10-23 L3, stand-in form 4: not in the list on tick 0, in it
-- from tick 1), so one look on the next tick came too early every time.
Route.SCAN_TICKS = 3

local loggedOnce = {}
local function logOnce(what, fields)
    if loggedOnce[what] then return end
    loggedOnce[what] = true
    fields.event = what
    Util.log("DASH", fields)
end

-- The method of obj's own class, looked up now (25.3-4): not the global ISVehicleDashboard (a mod may have swapped
-- the whole table) and not stored at load time (a mod loaded later may still change the class).
local function classMethod(obj, name)
    local mt = getmetatable(obj)
    local idx = mt and mt.__index
    if type(idx) == "table" then return idx[name] end
    if type(idx) == "function" then return idx(obj, name) end
    return nil
end
Route.classMethod = classMethod

-- The class's own method (vanilla's or another mod's) during a hand-over, in its own pcall: an error there is logged
-- as that class's, never as ours, and the hand-over goes on - our car still gets our panel (review round 6, M5).
local function callClass(obj, name, ...)
    local fn = classMethod(obj, name)
    if fn == nil then return end
    local ok, err = pcall(fn, obj, ...)
    if not ok then
        Util.log("DASH", { event = "classError", method = name, type = tostring(obj.Type), msg = tostring(err) })
    end
end
Route.callClass = callClass

local function slotOf(n)
    return ISPlayerData and ISPlayerData[n + 1] or nil
end

local function isLocal(chr)
    return chr ~= nil and instanceof(chr, "IsoPlayer") and chr:isLocalPlayer()
end

-- "Ours": player n sits in vehicle as its driver, and it is an NEV.
function Route.wants(n, vehicle)
    if vehicle == nil then return false end
    local chr = getSpecificPlayer(n)
    return chr ~= nil and not chr:isDead() and chr:getVehicle() == vehicle and vehicle:isDriver(chr)
        and Registry.isNEV(vehicle)
end

local function mineOf(obj)
    local n = rawget(obj, "nevRouteN")
    local st = n and Route.players[n]
    return st ~= nil and st.mine and st.orig == obj
end

---------------------------------------------------------------------------
-- Table 1: the vanilla instance
---------------------------------------------------------------------------

-- Only the decision is guarded: an error of ours falls back to "not ours" (the vanilla way). The class's own
-- setVehicle that the hand-over calls runs apart (callClass), so its errors stay its own (review round 6, M5).
local takeIfOurs = Util.guardKeep("dashRouteSet", function(obj, vehicle)
    local n = rawget(obj, "nevRouteN")
    local st = n and Route.players[n]
    if not st or st.orig ~= obj or not Route.wants(n, vehicle) then return false end
    Route.take(n, vehicle)
    return true
end)

Route.COVERS = {
    setVehicle = function(self, vehicle)
        if vehicle ~= nil and takeIfOurs(self, vehicle) then return end
        return classMethod(self, "setVehicle")(self, vehicle)
    end,
    addToUIManager = function(self)
        if mineOf(self) then return end
        return classMethod(self, "addToUIManager")(self)
    end,
    setVisible = function(self, visible)
        if visible and mineOf(self) then return end
        return classMethod(self, "setVisible")(self, visible)
    end,
    -- shown anyway (a mod got round the methods above): put it away whole, children included
    prerender = function(self)
        if mineOf(self) then
            classMethod(self, "removeFromUIManager")(self)
            logOnce("vanillaShown", { player = rawget(self, "nevRouteN") })
            return
        end
        return classMethod(self, "prerender")(self)
    end,
    -- not in the design's list: render comes right after prerender in the same frame, keep it quiet too
    render = function(self)
        if mineOf(self) then return end
        return classMethod(self, "render")(self)
    end,
}

function Route.cover(n, obj)
    rawset(obj, "nevRouteN", n)
    for name, fn in pairs(Route.COVERS) do rawset(obj, name, fn) end
end

---------------------------------------------------------------------------
-- The slot changing hands
---------------------------------------------------------------------------

function Route.panelOf(n)
    local chr = getSpecificPlayer(n)
    local p = Route.panels[n]
    if not p then
        p = Panel:new(n, chr)
        p:initialise()
        p:instantiate()
        Route.panels[n] = p
    end
    p.character = chr
    return p
end

-- as vanilla setVehicle shows its dashboard (:217-227)
function Route.show(p, vehicle)
    p:bind(vehicle)
    p:setVisible(true)
    p:addToUIManager()
    if not ISUIHandler.allUIVisible then p:removeFromUIManager() end
end

local function putAway(p)
    if not p then return end
    p:unbind()
    p:removeFromUIManager()
end

-- Table 1 setVehicle, "ours": the vanilla class gets nil first (it and any mod on it put their things away), then
-- the slot gets our panel. The order is fixed: vanilla's removeFromUIManager is not covered, so nothing of ours is
-- touched on the way.
function Route.take(n, vehicle)
    local st = Route.players[n]
    local orig = st.orig
    callClass(orig, "setVehicle", nil)
    local p = Route.panelOf(n)
    p.nevOrig = orig
    p.wasKeyInIgnition = rawget(orig, "wasKeyInIgnition") == true
    slotOf(n).vehicleDashboard = p
    st.mine = true
    Route.show(p, vehicle)
    Route.scan(n)
    Route.later(n, "scan")
end

-- Table 2 setVehicle with anything not ours: the slot back to the vanilla instance, then its class gets the call
-- (straight to the class: not ours, so the cover would only pass it through).
function Route.giveBack(n, vehicle)
    local st = Route.players[n]
    local p, orig = Route.panels[n], st.orig
    st.mine = false
    putAway(p)
    local slot = slotOf(n)
    if slot and slot.vehicleDashboard == p then slot.vehicleDashboard = orig end
    if st.held then Route.later(n, "release") end
    if orig then
        if p then orig.wasKeyInIgnition = p.wasKeyInIgnition end
        callClass(orig, "setVehicle", vehicle)
    end
end

Route.panelSetVehicle = Util.guardKeep("dashRoutePanel", function(p, vehicle)
    local n = p.playerNum
    local st = Route.players[n]
    if st and st.mine and Route.panels[n] == p then
        if Route.wants(n, vehicle) then Route.show(p, vehicle) else Route.giveBack(n, vehicle) end
        return
    end
    putAway(p)   -- not in a slot any more (the player data was rebuilt)
end)

-- Make the slot match the player: a new vanilla instance gets covered, a lost cover is put back, and the panel /
-- vanilla instance swap as needed. leaving: the player is getting out (the vehicle may not be cleared yet).
function Route.reconcile(n, leaving)
    local st = Route.players[n] or {}
    Route.players[n] = st
    local slot = slotOf(n)
    local cur = slot and slot.vehicleDashboard
    if cur == nil then
        -- no player data (dead, not made yet): nothing to show
        if st.mine then
            st.mine = false
            putAway(Route.panels[n])
            if st.held then Route.later(n, "release") end
        end
        return
    end
    if cur ~= st.orig and cur ~= Route.panels[n] then
        -- a new instance (respawn, split screen, another mod replaced it): cover it, forget the old one
        if st.mine then putAway(Route.panels[n]) end
        if st.held then Route.later(n, "release") end   -- put back unless ours again by then (review round 6, advice 2)
        st.mine, st.orig = false, cur
        Route.cover(n, cur)
    elseif cur == st.orig and rawget(cur, "setVehicle") ~= Route.COVERS.setVehicle then
        Route.cover(n, cur)
        Util.log("DASH", { event = "recovered", player = n })
    end
    local chr = getSpecificPlayer(n)
    local v = (not leaving and chr and not chr:isDead()) and chr:getVehicle() or nil
    if Route.wants(n, v) then
        if not st.mine then
            Route.take(n, v)
        else
            local p = Route.panels[n]
            if p.vehicle ~= v then Route.show(p, v) end
            Route.scan(n)
            Route.later(n, "scan")
        end
    elseif st.mine then
        Route.giveBack(n, (v and v:isDriver(chr)) and v or nil)
    end
end

---------------------------------------------------------------------------
-- Table 3: other mods' driver dashboards
---------------------------------------------------------------------------

Route.HELD = { "addToUIManager", "removeFromUIManager", "setVisible", "prerender", "render" }

-- While held, another mod's show / hide calls are not run (it is off screen already), only its last wish kept.
local function heldOf(obj) return rawget(obj, "nevHeld") end
Route.HELD_COVERS = {
    addToUIManager = function(self) heldOf(self).wish = "show" end,
    removeFromUIManager = function(self) heldOf(self).wish = "hide" end,
    setVisible = function(self, visible) heldOf(self).wish = visible and "show" or "hide" end,
    prerender = function(self)
        classMethod(self, "removeFromUIManager")(self)
        logOnce("heldShown", { type = tostring(self.Type) })
    end,
    -- as table 1: the frame prerender puts it away, its render still runs once (review round 6, advice 3)
    render = function(self) end,
}

local function derivesFrom(obj, classes)
    local mt = getmetatable(obj)
    for _ = 1, 32 do
        if mt == nil then return false end
        for i = 1, #classes do
            if mt == classes[i] then return true end
        end
        mt = getmetatable(mt)
    end
    return false
end

-- Every local player's vanilla instance and panel are ours, never another mod's (11).
local function isOurs(obj)
    for n, st in pairs(Route.players) do
        if st.orig == obj or Route.panels[n] == obj then return true end
    end
    return false
end

-- Player n's own: playerNum is n or character is n's; neither = cannot tell = not taken (11).
local function belongsTo(obj, n, chr)
    return (obj.playerNum ~= nil and obj.playerNum == n) or (obj.character ~= nil and obj.character == chr)
end

function Route.scan(n)
    local st = Route.players[n]
    if not (st and st.mine) then return end
    if not ISUIHandler.allUIVisible then
        -- everything is hidden (toggleUI): nothing reads as visible; look again once it is shown
        Route.later(n, "scan")
        return
    end
    local classes = { rawget(_G, "ISVehicleDashboard") }
    for _, s in pairs(Route.players) do
        if s.orig then classes[#classes + 1] = getmetatable(s.orig) end
    end
    local chr = getSpecificPlayer(n)
    local found = {}
    local list = UIManager.getUI()
    for i = 0, list:size() - 1 do
        local obj = list:get(i):getTable()
        if obj and not heldOf(obj) and not isOurs(obj) and derivesFrom(obj, classes) and belongsTo(obj, n, chr)
            and obj:isReallyVisible() then
            found[#found + 1] = obj      -- taken after the walk: taking one changes the list
        end
    end
    for _, obj in ipairs(found) do Route.hold(n, obj) end
end

function Route.hold(n, obj)
    local st = Route.players[n]
    local e = { obj = obj, saved = {} }
    for _, name in ipairs(Route.HELD) do e.saved[name] = rawget(obj, name) end
    obj:removeFromUIManager()
    rawset(obj, "nevHeld", e)
    for name, fn in pairs(Route.HELD_COVERS) do rawset(obj, name, fn) end
    st.held = st.held or {}
    st.held[#st.held + 1] = e
    Util.log("DASH", { event = "held", player = n, type = tostring(obj.Type) })
end

-- The tick after the player left the driver's seat (exit, other seat, other car, death): the covers off, and back
-- on screen only what still wants to be - its last wish "show", or no wish and still showing the car the player now
-- drives (review round 4, advice 2). Not while the player is ours again (advice 1).
function Route.release(n)
    local st = Route.players[n]
    if not st or not st.held or st.mine then return end
    local chr = getSpecificPlayer(n)
    for _, e in ipairs(st.held) do
        local obj = e.obj
        for _, name in ipairs(Route.HELD) do rawset(obj, name, e.saved[name]) end
        rawset(obj, "nevHeld", nil)
        local v = obj.vehicle
        local driving = v ~= nil and chr ~= nil and not chr:isDead() and chr:getVehicle() == v and v:isDriver(chr)
        if e.wish == "show" or (e.wish == nil and driving) then obj:addToUIManager() end
    end
    st.held = nil
    if st.forget then Route.players[n] = nil end
end

---------------------------------------------------------------------------
-- Next tick (one check of a flag per tick while there is nothing to do)
---------------------------------------------------------------------------

local queued = false

function Route.nextTick()
    if not queued then return end
    queued = false
    local work = Route.pending
    Route.pending = {}
    for n, w in pairs(work) do
        if w.reconcile then Route.reconcile(n) end
        if w.scan then
            Route.scan(n)
            local st = Route.players[n]
            if w.scan > 1 and st and st.mine then Route.later(n, "scan", w.scan - 1) end
        end
        if w.release then Route.release(n) end
    end
end

-- what "scan": on the next `ticks` ticks (default SCAN_TICKS), never fewer than already asked
function Route.later(n, what, ticks)
    local w = Route.pending[n] or {}
    Route.pending[n] = w
    if what == "scan" then
        w.scan = math.max(w.scan or 0, ticks or Route.SCAN_TICKS)
    else
        w[what] = true
    end
    queued = true
end

---------------------------------------------------------------------------
-- The obsolete player patch (25.8)
---------------------------------------------------------------------------

Route.PATCH_IDS = { NEVRDFix_TestCore_020 = true, NEV_RealisticDash_Router = true }

function Route.patchInstalled()
    if rawget(_G, "NEVRDFixTest") ~= nil or rawget(_G, "NEVRDCompat") ~= nil then return true end
    local mods = getActivatedMods and getActivatedMods()
    if not mods then return false end
    for i = 0, mods:size() - 1 do
        local id = string.gsub(tostring(mods:get(i)), "^\\", "")
        if Route.PATCH_IDS[id] then return true end
    end
    return false
end

-- Its car list emptied (before its client file reads it, it takes no car), and once it has installed, its own
-- shutdown (takes its hooks and events off again). Its files are not touched.
function Route.disablePatch()
    local sel = rawget(_G, "NEVRDFixTestSelection")
    if type(sel) == "table" then
        local names = {}
        for name in pairs(sel) do names[#names + 1] = name end
        for _, name in ipairs(names) do sel[name] = nil end
    end
    local R = rawget(_G, "NEVRDFixTest")
    if type(R) == "table" and R.enabled and type(R.shutdown) == "function" then
        local ok, err = pcall(R.shutdown)
        Util.log("DASH", { event = "patchShutdown", ok = tostring(ok), err = err and tostring(err) or nil })
    end
end

local told = false
function Route.tellPatch()
    if told or not Route.patchInstalled() then return end
    told = true
    Util.log("DASH", { event = "patchInstalled" })
    local chr = getSpecificPlayer(0)
    if chr and HaloTextHelper then HaloTextHelper.addBadText(chr, T("IGUI_NEV_Dash_PatchObsolete")) end
end

if Route.patchInstalled() then Route.disablePatch() end

---------------------------------------------------------------------------
-- Events (registered after vanilla's: the client files load after vanilla)
---------------------------------------------------------------------------

local function reconcileAll()
    for n = 0, getNumActivePlayers() - 1 do Route.reconcile(n) end
end

function Route.onEnter(chr)
    if isLocal(chr) then Route.reconcile(chr:getPlayerNum()) end
end

function Route.onExit(chr)
    if isLocal(chr) then Route.reconcile(chr:getPlayerNum(), true) end
end

function Route.onSeat(chr)
    if isLocal(chr) then Route.reconcile(chr:getPlayerNum()) end
end

-- createPlayerData has rebuilt every player's data (ISPlayerData.lua:158-174): all of them again
function Route.onCreatePlayer()
    reconcileAll()
end

function Route.onGameStart()
    if Route.patchInstalled() then Route.disablePatch() end
    reconcileAll()
    Route.tellPatch()
end

-- Unbound at once; held dashboards back the next tick like any leaving (C); the record dropped after that.
function Route.onDeath(chr)
    if not isLocal(chr) then return end
    local n = chr:getPlayerNum()
    local st = Route.players[n]
    if not st then return end
    st.mine = false
    putAway(Route.panels[n])
    st.forget = true
    if st.held then Route.later(n, "release") else Route.players[n] = nil end
end

function Route.onBoot()
    if Route.patchInstalled() then Route.disablePatch() end
end

Events.OnGameBoot.Add(Util.guard("dashRouteBoot", Route.onBoot))
Events.OnTick.Add(Util.guardKeep("dashRouteTick", Route.nextTick))
Events.OnEnterVehicle.Add(Util.guardKeep("dashRouteEnter", Route.onEnter))
Events.OnExitVehicle.Add(Util.guardKeep("dashRouteExit", Route.onExit))
Events.OnSwitchVehicleSeat.Add(Util.guardKeep("dashRouteSeat", Route.onSeat))
Events.OnCreatePlayer.Add(Util.guardKeep("dashRouteCreate", Route.onCreatePlayer))
Events.OnGameStart.Add(Util.guardKeep("dashRouteStart", Route.onGameStart))
Events.OnPlayerDeath.Add(Util.guardKeep("dashRouteDeath", Route.onDeath))

return Route
