-- NEV Lib: sleeping in an NEV with camping mode on counts as an ordinary bed
-- (NEVLib.Camping.bedType; M1 issue 16). Wraps the vanilla bed-quality lookup,
-- which the sleep action calls as ISWorldObjectContextMenu.getBedQuality.
require "NEVLib/Util"
require "ISUI/ISWorldObjectContextMenu"
require "NEVLib/Camping"

local Util, Camping = NEVLib.Util, NEVLib.Camping

local upgrade = Util.guard("sleepBed", function(playerObj, bedType)
    local vehicle = playerObj and playerObj:getVehicle()
    local result = Camping.bedType(bedType, vehicle)
    if result ~= bedType then Util.log("SLEEP", { bed = result, vanilla = bedType }) end
    return result
end)

local origBedQuality = ISWorldObjectContextMenu.getBedQuality
function ISWorldObjectContextMenu.getBedQuality(playerObj, bed)
    local bedType = origBedQuality(playerObj, bed)
    return upgrade(playerObj, bedType) or bedType
end
