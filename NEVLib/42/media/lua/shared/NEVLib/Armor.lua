-- NEV Lib: armour add-ons (docs/vehicles/lil6/design/parts-options-design.md section 6, v1.3, GitHub #174; U5 section 3).
-- A model pack declares which armour part protects which parts (Registry key `armor`); the library does
-- the rest. Vanilla B42 has no hook before a part loses condition (every path is Java), so armour works
-- after the fact (PARTS-DESIGN 3.4 / 6.3): the server (single player: the same code) checks the armoured
-- cars it knows every ARMOR_SWEEP_MS, puts the condition a protected part lost back and takes 0..10 points
-- off the armour by the hit's strength (Armor.cost; a Fine piece / 1.2); a window the hit smashed (its item is gone) is put
-- back. A protected part that gained condition was repaired: its snapshot follows. Clients only display what
-- the server sends.
require "NEVLib/Util"
require "NEVLib/Registry"

local Util, Registry = NEVLib.Util, NEVLib.Registry
local Armor = {}
NEVLib.Armor = Armor

Armor.SNAP_KEY = "nevArmorSnap"   -- protected part modData: the condition it should have
Armor.WEAR_KEY = "nevArmorWear"   -- armour part modData: wear below one condition point, carried over
Armor.SWEEP_MS = 250              -- real ms between checks of the known armoured cars

---------------------------------------------------------------------------
-- Declarations (Registry key `armor`, an ordered list; when two armours guard one part, the first listed with
-- condition left takes the hit - the L6 has one layer front and rear since revision 17, DESIGN 9.1)
--   { part = "NEVBullbarFront", protects = { "EngineDoor", ... } }
--   { part = "NEVArmorWindowFrontLeft", protects = { "WindowFrontLeft" }, window = "WindowFrontLeft" }
-- `window`: the protected window cannot be removed while this armour is on (the car script's requireUninstalled). It
-- can be rolled down (#317, user 10-19; Q2's lock is gone): while it is down this armour stands aside - its models
-- are hidden (Armor.applyModels) and it guards nothing (Armor.check), so vanilla's isPassengerExposed applies.
-- `name` (optional): translation key of this car's name for the part, when the shared IGUI_VehiclePart<part> name does
-- not fit it (the pickup's door plates use the part ids of the SUV's window grilles; #273, user 10-19). Used by the
-- mechanics window (client/NEVLib/Mechanics.lua).
-- What armour pays is one library rule for all of it (Armor.cost), not per declaration.
---------------------------------------------------------------------------

-- Problems of one model's armour declaration (list of strings, empty when fine). `hasPart(id)` answers
-- whether the vehicle script has that part (nil: not checked, e.g. before a vehicle exists).
function Armor.validate(decl, hasPart)
    local problems = {}
    if decl == nil or decl == false then return problems end
    if type(decl) ~= "table" then return { "armor is not a list" } end
    local seen = {}
    for i, a in ipairs(decl) do
        local where = "armor[" .. i .. "]"
        if type(a.part) ~= "string" then problems[#problems + 1] = where .. " part" end
        if seen[a.part] then problems[#problems + 1] = where .. " duplicate " .. tostring(a.part) end
        seen[a.part] = true
        -- the per-armour factor of the first v1.3 draft is gone (user 10-15): a leftover would look like it works
        if a.factor ~= nil then problems[#problems + 1] = where .. " factor (removed: Armor.cost)" end
        if a.name ~= nil and type(a.name) ~= "string" then problems[#problems + 1] = where .. " name" end
        if type(a.protects) ~= "table" or #a.protects == 0 then problems[#problems + 1] = where .. " protects" end
        if a.window ~= nil then
            local listed = false
            for _, p in ipairs(a.protects or {}) do if p == a.window then listed = true end end
            if not listed then problems[#problems + 1] = where .. " window " .. tostring(a.window) .. " not protected" end
        end
        if hasPart then
            if a.part and not hasPart(a.part) then problems[#problems + 1] = where .. " no part " .. a.part end
            for _, p in ipairs(a.protects or {}) do
                if not hasPart(p) then problems[#problems + 1] = where .. " no protected part " .. p end
            end
        end
    end
    return problems
end

-- Protected part id -> armour entries guarding it, in declaration order.
function Armor.guards(decl)
    local by = {}
    for _, a in ipairs(decl or {}) do
        for _, p in ipairs(a.protects) do
            by[p] = by[p] or {}
            by[p][#by[p] + 1] = a
        end
    end
    return by
end

---------------------------------------------------------------------------
-- The arithmetic, on plain numbers (unit tested without game objects)
---------------------------------------------------------------------------

-- What one hit costs the armour that stopped it (user 10-15, after KI5): 0..MAX_COST condition points, not
-- random but in proportion to the hit's strength. Strength = the largest condition loss the hit did to one
-- part this armour guards (a crash takes the hood, the motor and a headlight together: one hit, paid once;
-- a smashed window counts the condition it had). FULL_HIT is about the hardest hit the engine deals at the
-- default CarDamageOnImpact: a wall at the 122.4 km/h cap takes the hood 102 / 1.3 = 78 +- 5
-- (I-249-ENGINE-PERFORMANCE 4.2); harder hits (other sandbox settings) pay MAX_COST too.
Armor.MAX_COST = 10
Armor.FULL_HIT = 80

function Armor.cost(strength)
    if not strength or strength <= 0 then return 0 end
    return Armor.MAX_COST * math.min(1, strength / Armor.FULL_HIT)
end

-- The Fine grade (DESIGN 9.1 revision 17, #215): it pays a hit / FINE_FACTOR, so it stops 20 % more hits. A
-- vehicle part's condition is capped at 100 by the engine (VehiclePart.setCondition), so the grade is not a
-- higher maximum but a smaller cost on the same 0..100 bar.
Armor.FINE_FACTOR = 1.2

-- An armour piece with condition `cond` and carried wear `wear` (below one point) pays for a hit of `strength`
-- (`fine`: the Fine grade): whole points come off its condition, the fraction is carried. At 0 the wear is
-- dropped. Returns cond, wear.
function Armor.pay(cond, wear, strength, fine)
    local cost = Armor.cost(strength)
    if fine then cost = cost / Armor.FINE_FACTOR end
    cost = (wear or 0) + cost
    local whole = math.floor(cost + 1e-9)
    cond = cond - whole
    wear = cost - whole
    if cond <= 0 then return 0, 0 end
    return cond, wear
end

---------------------------------------------------------------------------
-- Game side
---------------------------------------------------------------------------

-- The grade of an armour item: Fine items end in _Fine (NEVLib.<Class>_<Piece>_Fine, DESIGN 9.1 revision 17;
-- tools/check_static.py keeps the id and the nev:finearmor tag together).
function Armor.isFine(item)
    if not item then return false end
    local t = item:getFullType()
    return t ~= nil and string.sub(t, -5) == "_Fine"
end

function Armor.declOf(vehicle)
    local cfg = Registry.get(vehicle)
    return cfg and cfg.armor or nil
end

-- Guards per declaration table, built once.
local guardCache = setmetatable({}, { __mode = "k" })
local function guardsOf(decl)
    local g = guardCache[decl]
    if not g then
        g = Armor.guards(decl)
        guardCache[decl] = g
    end
    return g
end

-- Armour does its work where the world is simulated: single player and the server (PARTS-DESIGN 6.3);
-- a multiplayer client only shows what the server transmits.
function Armor.serverSide()
    return not (isClient and isClient())
end

local function installed(vehicle, id)
    local p = vehicle:getPartById(id)
    if p and p:getInventoryItem() then return p end
    return nil
end

-- Whether the window of an armour declaration entry (`window = <its id>`) is rolled down (#317): the armour then
-- stands aside. Entries without a window (bull bars, tire guards) and windows that do not open never are.
function Armor.windowDown(vehicle, a)
    if not a.window then return false end
    local w = vehicle:getPartById(a.window)
    local win = w and w:getWindow()
    return win ~= nil and win:isOpen() == true
end

-- Part id -> translation key of this car's own name for it (declaration `name`), or nil: the shared name applies.
function Armor.nameKey(vehicle, partId)
    for _, a in ipairs(Armor.declOf(vehicle) or {}) do
        if a.part == partId then return a.name end
    end
    return nil
end

-- The armoured cars this side checks: only cars with at least one armour piece fitted (#253-3: 1.3.1 checked every
-- car that declares armour, fitted or not, about 3 times a second each, and wrote 14 snapshots each time). Filled
-- from the armour parts' init (every load and spawn, VehicleParts.initParts) and their install; a car that left the
-- world, or has no armour left, is dropped at the next sweep. A car that joins gets fresh snapshots of what it guards:
-- what it lost while nothing was fitted is not "put back" (1.3.1 kept the snapshots following those parts instead).
local tracked = {}
Armor.tracked = tracked   -- tests

-- A protected part the vehicle script gives no item: the drive motor (Engine - Vehicles.Create.Engine only sets its
-- condition, which is the part's own: VehiclePart.condition, damage lowers it). Its condition is all there is to guard,
-- so it is checked and put back whether or not an item is there; for every other part "no item" means it came off or
-- broke (a headlight hit to 0, a hood taken off) and is not put back. #336: 1.3.0-1.4.0 took the motor for the
-- latter, so the front bull bar never guarded it (DESIGN 9.1: it does). Read once per declaration and part id: the
-- check runs every SWEEP_MS for every guarded part, so a hit is plain Lua. This rests on one declaration table per
-- vehicle script (each Registry.register passes its own table literal; skins share a script, burnt / smashed cars are
-- other scripts and not registered) - two scripts sharing one table with different parts would share these answers.
local conditionOnlyCache = setmetatable({}, { __mode = "k" })   -- declaration -> part id -> true / false
local function conditionOnly(decl, pid, p)
    local byId = conditionOnlyCache[decl]
    if not byId then
        byId = {}
        conditionOnlyCache[decl] = byId
    end
    local c = byId[pid]
    if c == nil then
        local types = p:getItemType()
        c = types == nil or types:isEmpty()
        byId[pid] = c
    end
    return c
end

local function anyFitted(vehicle, decl)
    for _, a in ipairs(decl) do
        if installed(vehicle, a.part) then return true end
    end
    return false
end

function Armor.track(vehicle)
    if not vehicle or not Armor.serverSide() or tracked[vehicle] then return end
    local decl = Armor.declOf(vehicle)
    if not decl or not anyFitted(vehicle, decl) then return end
    for pid in pairs(guardsOf(decl)) do
        local p = vehicle:getPartById(pid)
        if p then p:getModData()[Armor.SNAP_KEY] = p:getInventoryItem() and p:getCondition() or nil end
        if p and conditionOnly(decl, pid, p) then p:getModData()[Armor.SNAP_KEY] = p:getCondition() end
    end
    tracked[vehicle] = true
end

-- One check of one car (PARTS-DESIGN 6.3). Every protected part keeps a snapshot of the condition it should
-- have: unarmoured it follows the part; armoured (the first declared armour with condition left whose window, if it
-- has one, is not rolled down - #317), a loss is put
-- back in full, a smashed window (`window` entries: the condition hit 0 and the item went, VehicleWindow.damage)
-- gets a new item at its old condition, and a gain (repaired) moves the snapshot up. Other parts that lost
-- their item (a headlight hit to 0, a hood taken off) are not put back: the snapshot is cleared and restarts
-- when an item is there again - except the parts that never have one (the motor, conditionOnly, #336). Then each
-- armour that stopped something pays once, for the hardest of it (Armor.cost); an armour with any condition left
-- stops the whole hit, as in KI5.
-- Tires (tire guards, DESIGN 9.1 revision 21, #272 / #286) are protected parts like any other - wear and hits
-- cannot be told apart, both come back; a tire put back re-derives the car's part stats once, as vanilla
-- Vehicles.LowerCondition does after lowering it: the tire's friction follows its condition (BaseVehicle.updatePartStats).
function Armor.check(vehicle)
    local decl = Armor.declOf(vehicle)
    if not decl then return end
    local hardest, payer = {}, {}
    local tireBack = false
    for pid, list in pairs(guardsOf(decl)) do
        local p = vehicle:getPartById(pid)
        if p then
            local md = p:getModData()
            local snap = md[Armor.SNAP_KEY]
            local item = p:getInventoryItem()
            local held = item ~= nil or conditionOnly(decl, pid, p)   -- #336: the motor has no item and is guarded
            local cur = p:getCondition()
            local guard, entry = nil, nil
            for _, a in ipairs(list) do
                local ap = installed(vehicle, a.part)
                if ap and ap:getCondition() > 0 and not Armor.windowDown(vehicle, a) then guard, entry = ap, a; break end
            end
            local lost = 0
            if guard == nil or snap == nil then
                md[Armor.SNAP_KEY] = held and cur or nil
            elseif not held then
                if entry.window == pid and snap > 0 then
                    VehicleUtils.createPartInventoryItem(p)   -- random condition (Vehicles.lua): set it right below
                    p:setCondition(snap)
                    vehicle:transmitPartItem(p)
                    vehicle:transmitPartCondition(p)
                    if p:getWindow() then vehicle:transmitPartWindow(p) end
                    Util.log("ARMOR", { vehicle = vehicle:getId(), part = pid, restored = snap, smashed = true })
                    lost = snap
                else
                    md[Armor.SNAP_KEY] = nil
                end
            elseif cur < snap then
                lost = snap - cur
                p:setCondition(snap)
                vehicle:transmitPartCondition(p)
                if p:getWheelIndex() ~= -1 then tireBack = true end
            elseif cur > snap then
                md[Armor.SNAP_KEY] = cur
            end
            if lost > 0 then
                payer[entry.part] = guard
                hardest[entry.part] = math.max(hardest[entry.part] or 0, lost)
            end
        end
    end
    if tireBack then vehicle:updatePartStats() end
    for id, ap in pairs(payer) do
        local md = ap:getModData()
        local before = ap:getCondition()
        local cond, wear = Armor.pay(before, md[Armor.WEAR_KEY] or 0, hardest[id], Armor.isFine(ap:getInventoryItem()))
        if cond ~= before then
            ap:setCondition(cond)
            vehicle:transmitPartCondition(ap)
        end
        md[Armor.WEAR_KEY] = wear
    end
end

-- Every SWEEP_MS of real time: check the tracked cars, drop the ones that left the world
-- (BaseVehicle.isRemovedFromWorld: set by removeFromWorld - chunk unloaded, car deleted -, cleared by addToWorld) or
-- have no armour left. #336: not getMovingObjectIndex < 0 - a car gets on a square's moving objects only at its first
-- postupdate, so in the frame it is loaded, when its armour's init tracks it, that is -1: 1.3.0-1.4.0 dropped every
-- armoured car of a save at the first sweep after loading (and now and then one whose chunk was reloaded).
local lastSweep = nil
function Armor.sweep()
    if not Armor.serverSide() then return end
    local now = getTimestampMs()
    if lastSweep and now - lastSweep < Armor.SWEEP_MS then return end
    lastSweep = now
    for vehicle in pairs(tracked) do
        if vehicle:isRemovedFromWorld() or not anyFitted(vehicle, Armor.declOf(vehicle) or {}) then
            tracked[vehicle] = nil
        else
            Armor.check(vehicle)
        end
    end
end

-- Tests only.
function Armor.resetSweep()
    lastSweep = nil
    for v in pairs(tracked) do tracked[v] = nil end
end

---------------------------------------------------------------------------
-- Part Lua functions (vehicle scripts: lua { create / init }, install { complete })
---------------------------------------------------------------------------

-- The normal grade of an armour part: the first entry of its itemType list (the vehicle script lists
-- "normal;Fine", DESIGN 9.1 revision 17), not any entry (Util.createFirstItem).
function Armor.createNormal(part)
    return Util.createFirstItem(part)
end

-- The cat-ear easter egg (DESIGN 9.1, #229, user 10-16: "平顶普通刷新，猫耳稀有刷新，玩家手工只能只做平顶"): a part
-- whose itemType lists a <normal>_Cat item gets it for RARE_SHARE of the cars it spawns with (a bull bar: 5 % x 1/10).
-- Never made by hand, never in containers; pays like the normal grade.
Armor.RARE_SHARE = 0.1

-- The item a car spawns with in this part: the normal grade, or now and then the _Cat one if the part has it.
function Armor.createSpawned(part)
    local types = part:getItemType()
    if types then
        for i = 0, types:size() - 1 do
            local t = types:get(i)
            if string.sub(t, -4) == "_Cat" then
                if ZombRandFloat(0, 1) < Armor.RARE_SHARE then return Util.createPartItem(part, t) end
                break
            end
        end
    end
    return Armor.createNormal(part)
end

-- Spawn with the car at the model pack's chance (Registry key `armorSpawn` = { [part id] = 0..1 },
-- PARTS-DESIGN 6.6), normal grade only; otherwise the part starts empty. Vanilla has no such field: the create
-- function decides (Vehicles.Create.Default always makes the item). The part must have an install table, or
-- VehicleParts resets `created` and rolls again on every load.
function Armor.create(vehicle, part)
    local cfg = Registry.get(vehicle)
    local chance = cfg and cfg.armorSpawn and cfg.armorSpawn[part:getId()] or 0
    if chance > 0 and ZombRandFloat(0, 1) < chance then
        Armor.createSpawned(part)
    else
        part:setInventoryItem(nil)
    end
end

-- Bull bar models (#229, art segment 5): the part carries two models, "Default" (the normal / Fine grade: flat
-- top at the rear, the C3 cage at the front) and "Cat" (the cat-ear easter egg). The script sets
-- setAllModelsVisible = false, so the engine shows neither on its own and Lua shows exactly one per installed item.
-- A client only learns of a changed part item through the multiplayer sync (no Lua init there), so the client
-- watches nearby cars (client/NEVLib/ArmorModels.lua) instead of hooking install / load.
Armor.MODEL_NORMAL, Armor.MODEL_CAT = "Default", "Cat"
Armor.MODEL_PARTS = { "NEVBullbarFront", "NEVBullbarRear" }

-- The model a part should show: Cat for a _Cat item, Default for any other item, nil when the part is empty.
function Armor.wantedModel(part)
    local item = part and part:getInventoryItem()
    if not item then return nil end
    return string.sub(item:getFullType(), -4) == "_Cat" and Armor.MODEL_CAT or Armor.MODEL_NORMAL
end

-- Split bull bars (#296, L6 rear): a part with a parent in the car script (parent = TrunkDoor) may carry an
-- upper piece per model, "<model>Trunk", skinned to the lid's bone so it swings with it. Without a lid the engine
-- would leave that piece floating where the closed lid was (the child falls back to its own still animation
-- player), so it shows only while the parent part has an item. Parts without "*Trunk" models are untouched:
-- VehiclePart.setModelVisible returns on an unknown id.
Armor.UPPER_SUFFIX = "Trunk"

-- Whether the part's upper piece may show: it has a parent part and something is installed there.
function Armor.parentInstalled(part)
    local parent = part:getParent()
    return parent ~= nil and parent:getInventoryItem() ~= nil
end

-- Window armour (#317): the parts of the declaration entries with a `window` (the L6's grilles and windshield
-- armour, the Cybertruck's door plates - any car, from its declaration). Their model over the window is bound to the
-- door, not the glass, so a rolled-down window would leave it standing over the gap: the WINDOW_MODEL shows while the
-- part is installed and the window is up. Other models of the part stay as vanilla shows them (with the item): the
-- L6 rear grilles' "Quarter" piece sits on the body over the fixed quarter glass, which never rolls down. Vanilla
-- shows every model again on each VehiclePart.setInventoryItem (load, multiplayer item sync), so the client
-- re-applies whenever this changes (client/NEVLib/ArmorModels.lua).
Armor.WINDOW_MODEL = "Default"

local windowCache = setmetatable({}, { __mode = "k" })   -- declaration -> its entries with a window
local function windowArmour(vehicle)
    local decl = Armor.declOf(vehicle)
    if not decl then return {} end
    local list = windowCache[decl]
    if not list then
        list = {}
        for _, a in ipairs(decl) do
            if a.window then list[#list + 1] = a end
        end
        windowCache[decl] = list
    end
    return list
end

local function windowArmourShown(vehicle, a)
    return installed(vehicle, a.part) ~= nil and not Armor.windowDown(vehicle, a)
end

-- One string for what the car's bull bars and window armour should show (the client re-applies only when it changes).
function Armor.modelsKey(vehicle)
    local key = ""
    for _, id in ipairs(Armor.MODEL_PARTS) do
        local part = vehicle:getPartById(id)
        if part then
            key = key .. id .. "=" .. tostring(Armor.wantedModel(part)) .. "," .. tostring(Armor.parentInstalled(part)) .. ";"
        end
    end
    for _, a in ipairs(windowArmour(vehicle)) do
        key = key .. a.part .. "=" .. tostring(windowArmourShown(vehicle, a)) .. ";"
    end
    return key
end

-- Show exactly the wanted model of every bull bar part of the car (none when empty), and its upper piece only
-- while the parent part is installed.
function Armor.applyModels(vehicle)
    for _, id in ipairs(Armor.MODEL_PARTS) do
        local part = vehicle:getPartById(id)
        if part then
            local want = Armor.wantedModel(part)
            local upper = Armor.parentInstalled(part)
            for _, m in ipairs({ Armor.MODEL_NORMAL, Armor.MODEL_CAT }) do
                part:setModelVisible(m, want == m)
                part:setModelVisible(m .. Armor.UPPER_SUFFIX, upper and want == m)
            end
        end
    end
    for _, a in ipairs(windowArmour(vehicle)) do
        local part = vehicle:getPartById(a.part)
        if part then part:setModelVisible(Armor.WINDOW_MODEL, windowArmourShown(vehicle, a)) end
    end
end

function Armor.init(vehicle, part)
    Armor.track(vehicle)
    if NEVLib.Parts then NEVLib.Parts.track(vehicle) end   -- the loaded NEVs of the part-update kick (#253)
end

-- Installed: track the car, and roll the guarded window up (an open window would leave the seat exposed,
-- AttackVehicleState.isPassengerExposed; the player may roll it down again afterwards, #317).
function Armor.installComplete(vehicle, part)
    local base = Vehicles and Vehicles.InstallComplete and Vehicles.InstallComplete.Default
    if base then base(vehicle, part) end   -- vanilla: the damage overlay
    Armor.track(vehicle)
    for _, a in ipairs(Armor.declOf(vehicle) or {}) do
        if a.part == part:getId() and a.window then
            local w = vehicle:getPartById(a.window)
            local win = w and w:getWindow()
            if win and win:isOpen() then
                win:setOpen(false)
                vehicle:transmitPartWindow(w)
            end
        end
    end
end

-- Roof rack container (6.1, GitHub #300): reachable on foot from behind the car (the part's own area, TruckBed,
-- like an open truck bed) or from either side (the four seat and four wheel areas line both flanks), and only
-- with a rack installed (the part keeps its container when the rack is off). Not from inside, not from in front
-- of the bonnet (Engine area).
Armor.ROOF_RACK_SIDE_AREAS = { "SeatFrontLeft", "SeatFrontRight", "SeatRearLeft", "SeatRearRight",
                               "TireFrontLeft", "TireFrontRight", "TireRearLeft", "TireRearRight" }
function Armor.roofRackAccess(vehicle, part, chr)
    if not part:getInventoryItem() then return false end
    if chr:getVehicle() then return false end
    if vehicle:isInArea(part:getArea(), chr) then return true end
    for _, id in ipairs(Armor.ROOF_RACK_SIDE_AREAS) do
        if vehicle:isInArea(id, chr) then return true end
    end
    return false
end

-- Library repair recipe NEVRepairArmor (PARTS-DESIGN 6.5): the damaged armour piece (input flag IsDamaged, kept)
-- gains REPAIR_POINTS. craftRecipe OnCreate gets (CraftRecipeData, character), CraftRecipeData.luaCallOnCreate.
Armor.REPAIR_POINTS = 25
function Armor.onRepairCreate(data, character)
    local item = data and data:getFirstInputItemWithFlag("IsDamaged")
    if not item then return end
    item:setCondition(math.min(item:getConditionMax(), item:getCondition() + Armor.REPAIR_POINTS))
    item:syncItemFields()   -- multiplayer: as vanilla RecipeCodeOnCreate.minorCondition does
end

return Armor
