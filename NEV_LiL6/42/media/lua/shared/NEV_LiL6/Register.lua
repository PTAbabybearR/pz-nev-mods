-- Li Auto L6 (EREV): model configuration for NEV Lib (DESIGN 5, 13.3).
-- Energy numbers are the reference draws; NEVLib.Registry.ENERGY_SCALE scales the
-- time-based ones at load (v1 balance, docs/design/energy/energy-balance-design.md; tools/balance_model.py).
require "NEVLib/Registry"
require "NEVLib/Armor"   -- before register: the armour declaration is validated there
require "NEVLib/Util"
require "NEVLib/Spawns" -- before register: the spawn declaration is validated there

-- The v1.0-v1.2 L6 battery (51 kWh): old saves keep it in the car and it keeps working; never spawned or made
-- (DESIGN 5.1 revision 17: new cars take the library's EREV batteries, 37.5 / 50 / 62.5 kWh).
NEVLib.Registry.registerBatteryItem("NEV_LiL6.TractionBattery", 51)

NEVLib.Registry.register("Base.NEV_LiL6", {
    powertrain = "EREV",            -- the library's EREV batteries; the draw is solved on the middle one (50 kWh)
    massKg = 2520,
    -- top speed while driving on the throttle (DESIGN 5.5, #368 C4): the ruler's 90 cap (game about 109.8); the
    -- script maxSpeed 130 is the steering reference only
    driveMaxKmh = 90,
    -- drive power P(v) = idle + a*v + b*v^2, the real car: about 8.6 kW at
    -- 60 km/h. In game x the library's energy scale (tools/balance_model.py solves it so the middle EREV
    -- battery runs the ruler range, CLTC 300 km x 2.23)
    idleKW = 0.6,
    driveA = 0.08,
    driveB = 0.0009,
    heaterKW = 1.0,
    -- range extender: about the 60 km/h draw (scaled the same), so hybrid
    -- mode on the road roughly holds the charge; a 65 L tank = about 3 batteries
    rexKW = 8.6,
    -- the EV share of the combined range = the real car's CLTC 300 / 1250 (DESIGN 5.1 revision 14 / 15),
    -- solved on the normal tank of the parts class (type 2: 65 L): 3.06 x 49 / 65 (tools/balance_model.py)
    rexFuelKWhPerL = 2.31,
    rexFuelPriorityFactor = 1.5,
    fridge = true,
    -- fridgeKW: the library's (1/6 of a vanilla fridge, DESIGN 5.3)
    camping = true,
    campingKW = 1.5,          -- real; in game x scale: about 0.9 % per hour before heater / AC effort
    airFilter = true,
    -- SUV: the tailgate opens into the cabin (DESIGN 7.3)
    cabinSealParts = { "DoorFrontLeft", "DoorFrontRight", "DoorRearLeft", "DoorRearRight",
                       "WindowFrontLeft", "WindowFrontRight", "WindowRearLeft", "WindowRearRight",
                       "Windshield", "WindshieldRear", "TrunkDoor" },
    chargePortSide = "RearRight", -- area ChargePort in nev_lil6.txt
    -- seat-switch window only (client/NEVLib/SeatUI.lua): rear left / right icons
    -- spread sideways so the middle seat's icon does not cover them. Real
    -- offsets are the script's x 1.82 (rear x +-0.32, server self test);
    -- the window draws about 96 px per unit and icons are 41 px wide, so the
    -- rear ones need >= 0.45 from the middle: x 1.45 -> +-0.464
    seatUIScaleX = { [2] = 1.20, [3] = 1.20 },
    initialSocMin = 0.2,
    initialSocMax = 0.8,
    -- armour add-ons (DESIGN 9.1 revision 17, #215): the SUV class items (NEVLib.SUV_*, normal / Fine), one layer
    -- front and rear. What a hit costs is the library's rule (NEVLib.Armor.cost: 0-10 by its strength, user 10-15;
    -- a Fine piece / 1.2). `window`: that window is locked shut while the armour is on and is put back when a hit
    -- smashes it (Q2)
    armor = {
        { part = "NEVArmorWindowFrontLeft", protects = { "WindowFrontLeft" }, window = "WindowFrontLeft" },
        { part = "NEVArmorWindowFrontRight", protects = { "WindowFrontRight" }, window = "WindowFrontRight" },
        { part = "NEVArmorWindowRearLeft", protects = { "WindowRearLeft" }, window = "WindowRearLeft" },
        { part = "NEVArmorWindowRearRight", protects = { "WindowRearRight" }, window = "WindowRearRight" },
        { part = "NEVArmorWindshield", protects = { "Windshield" }, window = "Windshield" },
        { part = "NEVArmorWindshieldRear", protects = { "WindshieldRear" }, window = "WindshieldRear" },
        { part = "NEVBullbarFront", protects = { "EngineDoor", "Engine", "HeadlightLeft", "HeadlightRight" } },
        { part = "NEVBullbarRear", protects = { "TrunkDoor", "HeadlightRearLeft", "HeadlightRearRight", "GasTank" } },
    },
    -- spawned with the car, normal grade only (Q5, revision 17): roof rack 25 %, each bull bar 5 %, armour never
    armorSpawn = { NEVRoofRack = 0.25, NEVBullbarFront = 0.05, NEVBullbarRear = 0.05 },
    -- spawning (#222, user 2026-10-16): the library's base share in every ordinary-car zone (NEVLib/Spawns),
    -- more in the rich / middle-class areas where vanilla keeps its SUV
    spawn = { good = 0.08, medium = 0.04 },
})
