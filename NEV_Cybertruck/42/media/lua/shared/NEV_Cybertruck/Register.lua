-- Tesla Cybertruck, Premium All-Wheel Drive (BEV pickup): model configuration for NEV Lib (DESIGN 5, 13.3;
-- numbers docs/vehicles/cybertruck/design/stats-design.md). Ships with v2.0: the pack carries UNRELEASED.txt until then.
-- Energy numbers are the reference draws; this car's own energyScale scales the time-based ones at load
-- (DESIGN 5.1 "BEV": solved by tools/balance_model.py from EV range = CLTC x the library factor).
require "NEVLib/Registry"
require "NEVLib/HideWhenOpen"   -- before register: the hideWhenOpen declaration is validated there
require "NEVLib/Paint"          -- likewise rarePaints
require "NEVLib/Armor"          -- likewise the armour declaration
require "NEVLib/Spawns"         -- likewise the spawn declaration (v1.0.1)
require "NEVLib/Util"

NEVLib.Registry.register("Base.NEV_Cybertruck", {
    powertrain = "BEV",             -- the library's BEV batteries (75 / 100 / 125 kWh); the draw is solved on 100
    massKg = 3009,                  -- owner's manual, Premium All-Wheel Drive All Season (curb mass)
    -- top speed while driving on the throttle (DESIGN 5.5, #368 C4): the ruler's 90 cap (game about 109.8); the
    -- script maxSpeed 130 is the steering reference only
    driveMaxKmh = 90,
    -- drive power P(v) = idle + a*v + b*v^2: the L6's shape; the level comes from energyScale (solved so the
    -- middle BEV battery runs CLTC x 2.23: no CLTC for this car - EPA 325 mi = 523 km x 1.42 = 743 CLTC km,
    -- DESIGN 5.1 / #241, user 10-16)
    idleKW = 0.6,
    driveA = 0.08,
    driveB = 0.0009,
    heaterKW = 1.0,
    energyScale = 0.419,            -- solved by tools/balance_model.py (--check keeps it within 2 %)
    -- no fridge (the real car has none, CYBERTRUCK-DESIGN 5)
    camping = true,                 -- Camp Mode (owner's manual, climate controls)
    campingKW = 1.5,
    airFilter = true,               -- HEPA filter (owner's manual "if equipped"; Premium AWD has it)
    -- pickup: the bed does not open into the cabin, so the tailgate is not part of the seal (DESIGN 7.3)
    cabinSealParts = { "DoorFrontLeft", "DoorFrontRight", "DoorRearLeft", "DoorRearRight",
                       "WindowFrontLeft", "WindowFrontRight", "WindowRearLeft", "WindowRearRight",
                       "Windshield", "WindshieldRear" },
    chargePortSide = "RearLeft",    -- the real car's side (#303, DESIGN 6.1); area ChargePort in nev_cybertruck.txt
    -- seat-switch window only (client/NEVLib/SeatUI.lua): rear left / right icons spread sideways so the
    -- middle seat's icon does not cover them (written by build_mod.py from the seat positions)
    seatUIScaleX = { [2] = 1.07, [3] = 1.07 },
    initialSocMin = 0.2,
    initialSocMax = 0.8,
    -- the tonneau cover (part TonneauCover, a child of the tailgate, no item of its own) is drawn whenever the
    -- tailgate is fitted; it slides into the front of the bed as the tailgate opens (trunk_open, #249, user 10-17)
    hideWhenOpen = { { door = "TrunkDoor", model = "Default", part = "TonneauCover", showOpen = true } },
    -- the 8 Tesla wraps are the rare tier, stainless the ordinary one (DESIGN 10.1a, #228, user 10-16): stainless
    -- 90 %, each wrap 1.25 % (skins in nev_cybertruck.txt, CT-TEX 8.1)
    rarePaints = { "stealth_black", "dark_grey", "abyss_blue", "forest_green", "tactical_green", "crimson_red",
                   "copper_tint", "rose_gold" },
    -- armour add-ons (DESIGN 9.1 revision 21, #273; docs/design/parts/pickup-armor-design.md 4 / 5): the pickup class items
    -- (NEVLib.Pickup_*, normal / Fine), one layer. What a hit costs is the library's rule (NEVLib.Armor.cost). `window`: that
    -- window is locked shut while the plate is on and is put back when a hit smashes it. The rear bull bar has no GasTank to
    -- guard (BEV). Tire guards: the tire's condition is put back, the guard pays (design 5.3). `name`: the door plates
    -- reuse the SUV grilles' part ids, so the mechanics window and the window notice take this car's name (user 10-19)
    armor = {
        { part = "NEVArmorWindowFrontLeft", protects = { "WindowFrontLeft" }, window = "WindowFrontLeft",
          name = "IGUI_NEV_PartDoorArmorFrontLeft" },
        { part = "NEVArmorWindowFrontRight", protects = { "WindowFrontRight" }, window = "WindowFrontRight",
          name = "IGUI_NEV_PartDoorArmorFrontRight" },
        { part = "NEVArmorWindowRearLeft", protects = { "WindowRearLeft" }, window = "WindowRearLeft",
          name = "IGUI_NEV_PartDoorArmorRearLeft" },
        { part = "NEVArmorWindowRearRight", protects = { "WindowRearRight" }, window = "WindowRearRight",
          name = "IGUI_NEV_PartDoorArmorRearRight" },
        { part = "NEVArmorWindshield", protects = { "Windshield" }, window = "Windshield" },
        { part = "NEVArmorWindshieldRear", protects = { "WindshieldRear" }, window = "WindshieldRear" },
        { part = "NEVBullbarFront", protects = { "EngineDoor", "Engine", "HeadlightLeft", "HeadlightRight" } },
        { part = "NEVBullbarRear", protects = { "TrunkDoor", "HeadlightRearLeft", "HeadlightRearRight" } },
        { part = "NEVTireGuardFrontLeft", protects = { "TireFrontLeft" } },
        { part = "NEVTireGuardFrontRight", protects = { "TireFrontRight" } },
        { part = "NEVTireGuardRearLeft", protects = { "TireRearLeft" } },
        { part = "NEVTireGuardRearRight", protects = { "TireRearRight" } },
    },
    -- spawned with the car, normal grade only (the library rule, same for every class): roof rack 25 %, each bull bar 5 %
    armorSpawn = { NEVRoofRack = 0.25, NEVBullbarFront = 0.05, NEVBullbarRear = 0.05 },
    -- spawning (DESIGN 10.1): the library's base share in every ordinary-car zone, more in good / medium like the
    -- L6 (v1.0.1, user 2026-10-21: "照抄 L6 的 8% / 4%")
    spawn = { good = 0.08, medium = 0.04 },
})
