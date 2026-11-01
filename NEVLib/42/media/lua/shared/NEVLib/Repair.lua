-- NEV Lib: debug / admin "repair vehicle" and "repair part" on a new-energy car (GitHub #232).
-- Vanilla VehiclePart.repair (42.x, decompiled line 976) fills an EMPTY part with a random entry of its itemType
-- and calls its init: on our parts that is the Fine grade or the cat ears of an armour add-on, the old L6 battery,
-- the old glove box (the lists keep them for old saves and hand fitting). Repairing fixes, it does not fit
-- add-ons, so after vanilla's repair a part of ours that was empty before:
--   - an armour add-on (create = NEVLib.Armor.create): empty again;
--   - any other library part (battery, fridge, range extender): emptied and made again by its own create, i.e.
--     what a new car gets, then repaired by vanilla (condition 100, full charge).
-- A part that already had an item is left to vanilla (a fitted Fine guard stays Fine, at condition 100).
-- Hooked on the Java methods through their class metatables, so every Lua caller is covered: the server command
-- "vehicle"/"repair" and "repairPart" (debug spawner, mechanics window cheat, admin), the debug scenarios.
-- Java calling repair directly is not covered: the admin command /addvehicle does (AddVehicleCommand.java:96, every
-- armour part filled); the user chose not to fix that (#248: an admin tool, not normal play).
require "NEVLib/Registry"

NEVLib = NEVLib or {}
local Repair = {}
NEVLib.Repair = Repair
local Registry = NEVLib.Registry

local ARMOUR_CREATE = "NEVLib.Armor.create"

-- the library's create function name of a part, or nil for a vanilla part
function Repair.libCreate(part)
    local fn = part:getLuaFunction("create")
    if fn and string.find(fn, "NEVLib.", 1, true) == 1 then return fn end
    return nil
end

local function resolve(name)
    local t = _G
    for k in string.gmatch(name or "", "[^%.]+") do
        if type(t) ~= "table" then return nil end
        t = t[k]
    end
    return type(t) == "function" and t or nil
end

-- the library parts of a car that are empty right now (before vanilla's repair)
function Repair.emptyParts(vehicle)
    local list = {}
    for i = 0, vehicle:getPartCount() - 1 do
        local p = vehicle:getPartByIndex(i)
        if p and not p:getInventoryItem() and Repair.libCreate(p) then list[#list + 1] = p end
    end
    return list
end

-- after vanilla's repair: undo what it fitted into the parts that were empty (see the top)
function Repair.after(vehicle, parts, partRepair)
    for _, p in ipairs(parts) do
        if p:getInventoryItem() then
            local fn = Repair.libCreate(p)
            p:setInventoryItem(nil)
            if fn ~= ARMOUR_CREATE then
                local create = resolve(fn)
                if create then create(vehicle, p) end
                if p:getInventoryItem() then partRepair(p) end
            end
            vehicle:transmitPartItem(p)
            local init = resolve(p:getLuaFunction("init"))
            if init then init(vehicle, p) end
        end
    end
end

-- wrap BaseVehicle.repair and VehiclePart.repair once; returns true when the hooks are in place
function Repair.hook(metatables)
    metatables = metatables or __classmetatables
    if type(metatables) ~= "table" or not BaseVehicle or not VehiclePart then return false end
    local mv, mp = metatables[BaseVehicle.class], metatables[VehiclePart.class]
    local iv, ip = mv and mv.__index, mp and mp.__index
    if type(iv) ~= "table" or type(ip) ~= "table" or not iv.repair or not ip.repair then return false end
    if iv.NEVRepairHooked then return true end
    local vehicleRepair, partRepair = iv.repair, ip.repair
    iv.repair = function(self, ...)
        local list = Registry.isNEV(self) and Repair.emptyParts(self) or nil
        local r = vehicleRepair(self, ...)
        if list and #list > 0 then Repair.after(self, list, partRepair) end
        return r
    end
    ip.repair = function(self, ...)
        local v = self:getVehicle()
        local list = v and not self:getInventoryItem() and Repair.libCreate(self) and Registry.isNEV(v) and { self } or nil
        local r = partRepair(self, ...)
        if list then Repair.after(v, list, partRepair) end
        return r
    end
    iv.NEVRepairHooked = true
    return true
end

Repair.hooked = Repair.hook()
