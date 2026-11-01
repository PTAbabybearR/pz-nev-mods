-- NEV Lib: seat icons in the vanilla seat-switch window (ISVehicleSeatUI).
-- Vanilla draws each seat's 41 px icon at the seat's "inside" position
-- (passenger offset x / z times the window scale). Three rear seats 0.32
-- apart (loaded value) overlap there (five-seat L6, first game test 2026-10-07).
-- A model can spread seat icons sideways in this window only (cfg.seatUIScaleX:
-- seat index -> factor on the seat's x; a factor, not a position, because the
-- script's numbers are scaled on load): the offsets are changed for the duration of the vanilla
-- render and put back right after, so where passengers actually sit is
-- unchanged (single main thread: nothing else reads them in between).
require "NEVLib/Util"
require "NEVLib/Registry"
require "Vehicles/ISUI/ISVehicleSeatUI"

local Util, Registry = NEVLib.Util, NEVLib.Registry
local SeatUI = {}
NEVLib.SeatUI = SeatUI

-- Moves the icons of `vehicle`'s seats; returns what to restore.
function SeatUI.shift(vehicle)
    local cfg = vehicle and Registry.get(vehicle)
    local moves = cfg and cfg.seatUIScaleX
    if not moves then return nil end
    local script = vehicle:getScript()
    local restore = {}
    for seat, factor in pairs(moves) do
        local pngr = seat < script:getPassengerCount() and script:getPassenger(seat)
        local posn = pngr and pngr:getPositionById("inside")
        local offset = posn and posn:getOffset()
        if offset then
            restore[#restore + 1] = { offset = offset, x = offset:x(), y = offset:y(), z = offset:z() }
            offset:set(offset:x() * factor, offset:y(), offset:z())
        end
    end
    return restore
end

function SeatUI.restore(list)
    for _, r in ipairs(list or {}) do r.offset:set(r.x, r.y, r.z) end
end

local shiftGuarded = Util.guard("seatUIShift", SeatUI.shift)

local origRender = ISVehicleSeatUI.render
function ISVehicleSeatUI:render()
    local restore = shiftGuarded(self.vehicle)
    local ok, err = pcall(origRender, self)
    SeatUI.restore(restore)
    if not ok then error(err) end
end

return SeatUI
