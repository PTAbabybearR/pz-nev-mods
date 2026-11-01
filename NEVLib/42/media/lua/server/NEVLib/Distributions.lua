-- NEV Lib: where the portable power station and the home charger are found.
-- v1.0.3 (DESIGN 6.1 / 6.4, I-240, user 10-13): the power station is "the petrol can's
-- stand-in, easy to find" (S2): every vanilla list with the empty petrol can gets the
-- station at CAN_RATIO of the can's total weight in that list (v1.0.3: 1/2; v1.0.4 I-256, user 10-14:
-- 1/3 - "感觉可以再往下调一点") (vanilla 42.21:
-- ProceduralDistributions, VehicleDistributions, Distributions.lua Bag_BreakdownBag),
-- plus the electronics / camping / generator lists it had since v1.0. The charger is
-- rare (C1): mechanic electric shelves and appliance stores only; it can still be crafted.
require "NEVLib/Util"
require "NEVLib/PowerStation"
require "Items/ProceduralDistributions"
require "Items/Distributions"
require "Vehicles/VehicleDistributions"
require "Items/Distribution_ClosetJunk"
require "Vehicles/VehicleDistribution_TrunkJunk"

local Util, PowerStation = NEVLib.Util, NEVLib.PowerStation
local Distributions = {}
NEVLib.Distributions = Distributions

-- The station's weight in a list = the vanilla empty petrol can's total weight there x this. The tables below
-- hold the CAN's weights (as in vanilla) through can(); the L2 check loot-station-follows-can uses the same ratio.
Distributions.CAN_RATIO = 1 / 3
local function can(w) return w * Distributions.CAN_RATIO end

-- container loot: ProceduralDistributions.list[name]
Distributions.ADD = {
    ["NEVLib.PortablePowerStation"] = {
        ElectronicStoreAppliances = 1, ElectronicStoreMisc = 1, CampingStoreGear = 1,
        CrateElectronics = 1, CrateCamping = 1, CrateGenerator = 2, GarageTools = 0.5,
        -- follows the empty petrol can (can weights: 20+20+10+10, 10, 4, 10, 20+10, 20+10, 20+10)
        CarSupplyGasCans = can(60), CrateMechanics = can(10), DrugLabSupplies = can(4), GarageMechanics = can(10),
        GasStorageMechanics = can(30), GasStoreEmergency = can(30), StoreShelfMechanics = can(30),
    },
    ["NEVLib.HomeCharger2"] = {
        MechanicShelfElectric = 0.5, ElectronicStoreAppliances = 0.2,
    },
}
-- vehicle loot: VehicleDistributions[name] (can weights: 50+20+20, 10, 10, 10)
Distributions.ADD_VEHICLE = {
    ["NEVLib.PortablePowerStation"] = {
        FossoilTruckBed = can(90), FossoilSeatFront = can(10), ArmyHeavyTruckBed = can(10), MechanicTruckBed = can(10),
    },
}
-- bags: SuburbsDistributions[name] (can weights 20 and 0.005; the trash bag one is in
-- Distribution_BinJunk.lua, found by the L2 check V103-LR-3)
Distributions.ADD_BAG = {
    ["NEVLib.PortablePowerStation"] = { Bag_BreakdownBag = can(20), Bag_TrashBag = can(0.005) },
}
-- clutter: ClutterTables[name] (can weights: closet 0.01, Distribution_ClosetJunk.lua; vehicle
-- trunk 10, VehicleDistribution_TrunkJunk.lua - both found by the L2 check V103-LR-3). The trash
-- bag's list is the bins' clutter list (ClutterTables.BinItems), so bins are covered above.
Distributions.ADD_CLUTTER = {
    ["NEVLib.PortablePowerStation"] = { ClosetJunk = can(0.01), TrunkJunk = can(10) },
}

-- Returns the number of entries added; lists missing in this game version are logged.
function Distributions.apply(lists, add)
    local n = 0
    for item, where in pairs(add or Distributions.ADD) do
        local names = {}
        for name in pairs(where) do names[#names + 1] = name end
        Util.sort(names, function(a, b) return a < b end)
        for _, name in ipairs(names) do
            local list = lists and lists[name]
            if list and list.items then
                table.insert(list.items, item)
                table.insert(list.items, where[name])
                n = n + 1
            else
                Util.log("DISTRIBUTION", { event = "missingList", list = name, item = item })
            end
        end
    end
    return n
end

Distributions.added = Distributions.apply(ProceduralDistributions and ProceduralDistributions.list)
    + Distributions.apply(VehicleDistributions, Distributions.ADD_VEHICLE)
    + Distributions.apply(SuburbsDistributions, Distributions.ADD_BAG)
    + Distributions.apply(ClutterTables, Distributions.ADD_CLUTTER)

-- Class modification manuals (DESIGN 9.1 revision 17, #215; user 10-16 Q3): found where the vanilla mechanics
-- magazines are (MechanicMag1-3: 31 container lists in 42.21, from car dealer desks 20 to living room shelves
-- 0.1), at MANUAL_RATIO of their weight there (the three share one weight in every list; should a game update
-- part them, the largest counts). Followed, not listed: a game update that moves the magazines moves the manuals.
Distributions.MANUAL_RATIO = 1 / 4
Distributions.MANUALS = { "NEVLib.Manual_SUV", "NEVLib.Manual_Pickup" }   -- Pickup: DESIGN 9.1 revision 21, #272
local MAGAZINES = { MechanicMag1 = true, MechanicMag2 = true, MechanicMag3 = true,
                    ["Base.MechanicMag1"] = true, ["Base.MechanicMag2"] = true, ["Base.MechanicMag3"] = true }

-- Adds every manual to every list of `lists` holding a magazine; returns the number of entries added. A manual
-- already in a list is not added again.
function Distributions.followMagazines(lists, manuals)
    local names = {}
    for name in pairs(lists or {}) do names[#names + 1] = name end
    Util.sort(names, function(a, b) return a < b end)
    local n = 0
    for _, name in ipairs(names) do
        local items = type(lists[name]) == "table" and lists[name].items
        if type(items) == "table" then
            local mag, have = 0, {}
            for i = 1, #items - 1, 2 do
                if MAGAZINES[items[i]] then mag = math.max(mag, tonumber(items[i + 1]) or 0) end
                have[items[i]] = true
            end
            if mag > 0 then
                for _, m in ipairs(manuals or Distributions.MANUALS) do
                    if not have[m] then
                        table.insert(items, m)
                        table.insert(items, mag * Distributions.MANUAL_RATIO)
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end

Distributions.manualsAdded = Distributions.followMagazines(ProceduralDistributions and ProceduralDistributions.list)

-- After the game fills a container with loot: power stations get their random
-- 0 - 50 % charge (DESIGN 6.4). Returns how many were set.
-- The third argument is not always an ItemContainer: for a zombie's bag the
-- game passes the bag's loot definition (ItemPickerJava: "Zombie Bag",
-- ItemPickerContainer) - first game test, the handler threw and was disabled.
function Distributions.onFillContainer(roomName, containerType, container)
    if not instanceof(container, "ItemContainer") then return 0 end
    local items = container:getItems()
    local n = 0
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if PowerStation.isStation(it) and PowerStation.onFound(it) then n = n + 1 end
    end
    return n
end
Events.OnFillContainer.Add(Util.guard("fillContainer", Distributions.onFillContainer))

return Distributions
