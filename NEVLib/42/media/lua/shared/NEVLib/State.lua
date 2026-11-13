-- Copyright (c) 2026 熊叔
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.

-- NEV Lib: per-vehicle state kept in the vehicle's modData (saved with the
-- game). Versioned so later releases can migrate old saves (M1-PLAN 2.14).
require "NEVLib/Util"

local State = {}
NEVLib.State = State

State.VERSION = 1
-- modData key (REVIEW 3.3-11: "nev" was too generic for a key other mods
-- share; fixed before the first release). v1.1 (FINAL-REVIEW 2026-10-12 B1):
-- the one-time move of "nev" is gone - it only existed in internal test saves,
-- and on a public car a "nev" table may be another mod's.
State.KEY = "NEVLib"

State.MODES = { "ev", "hybrid", "fuel" } -- EV priority / hybrid / fuel priority (DESIGN 3.5)

local function fresh()
    return {
        v = State.VERSION,
        mode = "ev",
        exitAllOff = false, -- vehicle setting: leaving the car turns off every device, fridge too (UI-DESIGN 19)
        keepLights = false, -- vehicle setting: the headlights stay as they were at power-off (#389); add-only field, no migration
        engineSoundOff = false, -- vehicle setting: the simulated engine sound is off (#236); add-only field, no migration (nil = on)
        holdSoc = nil,      -- fuel priority: SOC to hold (captured when switching)
        snap = nil,         -- devices remembered at power-off
        camping = false,
        rexOn = false,
        parkedRex = nil,    -- parked recharge running (DESIGN 3.5 revision 15); add-only field, no migration
        charge = nil,       -- { kind = "fast"|"slow", x, y, z, sx, sy, sprite }
        kwhPerKm = nil,     -- moving average for the range estimate
        v2l = nil,          -- vehicle-to-load (#180): { unlocked, wearK, on, gx, gy, gz, fuelW, kw, stop }; add-only field, none = locked
        poweredOnce = nil,  -- #319: powered on (drive / camping) at least once; add-only field, old saves: Battery.everPowered
        lastSpeed = 0,
    }
end

function State.get(vehicle)
    local md = vehicle:getModData()
    local s = md[State.KEY]
    if type(s) ~= "table" then
        s = fresh()
        md[State.KEY] = s
    elseif (s.v or 0) < State.VERSION then
        for k, v in pairs(fresh()) do
            if s[k] == nil then s[k] = v end
        end
        s.v = State.VERSION
    end
    return s
end

return State
