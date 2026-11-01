-- NEV Lib: the frunk, every NEV's second storage box (GitHub #306, docs/design/parts/frunk-design.md). A car pack adds
-- it with two script lines: `template = NEVFrunk,` (the library's vehicle template, scripts/vehicles/nev_frunk.txt)
-- and the part's container capacity. This is the template's container test.
NEVLib = NEVLib or {}
local Frunk = {}
NEVLib.Frunk = Frunk

-- The lid in front of the box (vanilla's bonnet part; a front bull bar rides on it and does not block it).
Frunk.LID = "EngineDoor"

-- Reachable on foot in the part's own area (Engine: in front of the car) while the lid is open or not fitted - the
-- vanilla trunk's rule behind its tailgate (Vehicles.ContainerAccess.TruckBed) with the lid in place of the
-- tailgate. Not from inside a car (the frunk does not open into the cabin), and only with the frunk item in the part:
-- the part keeps its container when the item is gone (like the roof rack, NEVLib.Armor.roofRackAccess).
function Frunk.access(vehicle, part, chr)
    if chr:getVehicle() then return false end
    if not part:getInventoryItem() then return false end
    if not vehicle:isInArea(part:getArea(), chr) then return false end
    local lid = vehicle:getPartById(Frunk.LID)
    if lid and lid:getDoor() and lid:getInventoryItem() and not lid:getDoor():isOpen() then return false end
    return true
end

return Frunk
