-- NEV Lib: a part model that disappears while a door is open (GitHub #238, user 2026-10-16: the Cybertruck's
-- tonneau cover is not drawn while the tailgate is open - no roll-up animation). Generic: a model pack declares
-- in Register.lua
--     hideWhenOpen = { { door = "TrunkDoor", model = "Tonneau" } }
-- `door`: the part whose door state counts; `model`: a model id of `part` (default: the door part itself).
-- The model shows while the door is closed and the door part (and `part`, when it takes an item) has its item
-- (vanilla hides every model of a removed part, BaseVehicle; we never show one back). The client applies it
-- (client/NEVLib/HideWhenOpen.lua).
-- `showOpen = true` (#249): the model also shows while the door is open - for a part with no item of its own whose
-- models vanilla never shows (VehiclePart.setInventoryItem is what shows them), e.g. the Cybertruck's tonneau cover,
-- a child part of the tailgate that animates with it: shown whenever the tailgate is fitted.
require "NEVLib/Util"

NEVLib = NEVLib or {}
local HideWhenOpen = {}
NEVLib.HideWhenOpen = HideWhenOpen

-- Problems of a declaration (list of strings, empty when fine); nil / false = none declared.
function HideWhenOpen.validate(decl)
    local problems = {}
    if decl == nil or decl == false then return problems end
    if type(decl) ~= "table" or #decl == 0 then
        problems[#problems + 1] = "hideWhenOpen: a list of { door = ..., model = ... }"
        return problems
    end
    for i, e in ipairs(decl) do
        if type(e) ~= "table" or type(e.door) ~= "string" or type(e.model) ~= "string"
            or (e.part ~= nil and type(e.part) ~= "string") or (e.showOpen ~= nil and type(e.showOpen) ~= "boolean") then
            problems[#problems + 1] = "hideWhenOpen[" .. i .. "]: door and model (strings), part / showOpen optional"
        end
    end
    return problems
end

local function doorOpen(vehicle, id)
    local p = vehicle:getPartById(id)
    local d = p and p:getDoor()
    return d ~= nil and d:isOpen()
end

-- Should this entry's model show now?
function HideWhenOpen.visible(vehicle, e)
    local part, door = vehicle:getPartById(e.part or e.door), vehicle:getPartById(e.door)
    if not part or not door or not door:getInventoryItem() then return false end
    local types = part ~= door and part:getItemType()          -- `part` takes an item of its own and has none
    if types and not types:isEmpty() and not part:getInventoryItem() then return false end
    if e.showOpen then return true end
    return not doorOpen(vehicle, e.door)
end

-- A string that changes whenever what the car should show changes (the client re-applies only then).
function HideWhenOpen.key(vehicle, decl)
    local k = {}
    for i, e in ipairs(decl or {}) do k[i] = HideWhenOpen.visible(vehicle, e) and "1" or "0" end
    return table.concat(k)
end

function HideWhenOpen.apply(vehicle, decl)
    for _, e in ipairs(decl or {}) do
        local part = vehicle:getPartById(e.part or e.door)
        if part then part:setModelVisible(e.model, HideWhenOpen.visible(vehicle, e)) end
    end
end

return HideWhenOpen
