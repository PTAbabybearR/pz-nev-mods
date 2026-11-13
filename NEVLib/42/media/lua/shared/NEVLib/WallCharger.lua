-- Copyright (c) 2026 熊叔
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.

-- NEV Lib: the home charger mounts on a wall (#183, user 2026-11-03). One item,
-- NEVLib.HomeCharger2: placed on open floor it is the standing charger (sprites
-- 0-3, Facing S E N W); placed with its back to a wall it is the wall box
-- (sprites 4-7, vanilla MoveType WallObject, same facings). Looks only: both
-- carry the charger tileset prefix, so Charging.isChargerTile, the slow
-- charging rate, load and port range are the same.
--
-- Vanilla places a Moveable with the sprites of its item's world sprite, so
-- the switch is made here, wrapping vanilla's shared ISMoveableSpriteProps /
-- ISMoveablesAction at OnGameBoot (every Lua file is in by then; the action is
-- built again where it completes):
--   snapFaceToSquare  with no facing chosen, turn to a wall like vanilla wall objects: one it can hang on
--                     first, else one that is taken (so it shows red and says why, never a quiet standing one)
--   ISMoveablesAction.new  "place" with a facing that has a wall -> the wall sprite
--   instanceItem      picking a wall box up gives the standing item back
--   canPlaceMoveableInternal / getInfoPanelDescription  one charger per square, and a standing
--                     charger facing a wall that is taken cannot go down (red cursor, a line why)
-- The placing cursor shows the same choice (client/NEVLib/WallChargerCursor.lua).
require "NEVLib/Util"
require "NEVLib/Charging"

local Util, Charging = NEVLib.Util, NEVLib.Charging
local WallCharger = {}
NEVLib.WallCharger = WallCharger

WallCharger.FLOOR = { S = 0, E = 1, N = 2, W = 3 }
WallCharger.WALL = { S = 4, E = 5, N = 6, W = 7 }
-- vanilla's snap order (ISMoveableSpriteProps:snapFaceToSquare) and its face indexes
WallCharger.SNAP = { { "S", 3 }, { "E", 4 }, { "N", 1 }, { "W", 2 } }

-- index of a charger sprite name, or nil
local function indexOf(name)
    if type(name) ~= "string" or string.sub(name, 1, #Charging.CHARGER_TILESET) ~= Charging.CHARGER_TILESET then return nil end
    return tonumber(string.sub(name, #Charging.CHARGER_TILESET + 1))
end

function WallCharger.isFloor(name)
    local i = indexOf(name)
    return i ~= nil and i >= 0 and i <= 3
end

function WallCharger.isWall(name)
    local i = indexOf(name)
    return i ~= nil and i >= 4 and i <= 7
end

function WallCharger.wallName(facing)
    local i = WallCharger.WALL[facing]
    return i and (Charging.CHARGER_TILESET .. i) or nil
end

-- the standing sprite with the same facing as a wall sprite (anything else unchanged)
function WallCharger.floorName(name)
    local i = indexOf(name)
    if i == nil or i < 4 or i > 7 then return name end
    return Charging.CHARGER_TILESET .. (i - 4)
end

-- the wall box's props for `facing` if it can hang on `square` (vanilla's own
-- WallObject rule: a wall on that side, no other wall object there), else nil
function WallCharger.wallProps(square, facing)
    local name = square and WallCharger.wallName(facing)
    if not name then return nil end
    local props = ISMoveableSpriteProps.new(name)
    if not props.isMoveable or not props:canPlaceMoveableInternal(nil, square, nil) then return nil end
    return props
end

-- why a charger cannot go on `square` facing `facing` (user 11-04, review 20.1-2: one charger per square, and no
-- quiet fall back to the standing charger): "square" a charger is already there; "wall" (standing sprites only)
-- that side has a wall, the standing charger itself could go down there by vanilla's rules, but the wall box
-- cannot hang - something already hangs on that side (review 20.9: a fridge, a counter, a car on the square
-- stop both, and vanilla's red cursor is not ours to explain); nil when vanilla's own rules decide
function WallCharger.blockReason(square, facing, spriteName)
    if not square or not (WallCharger.isFloor(spriteName) or WallCharger.isWall(spriteName)) then return nil end
    if Charging.chargerOn(square) then return "square" end
    if not WallCharger.isFloor(spriteName) then return nil end
    local name = WallCharger.wallName(facing)
    if not name then return nil end
    local props = ISMoveableSpriteProps.new(name)
    if props.isMoveable and props:getWallForFacing(square, facing) and not WallCharger.wallProps(square, facing) then
        -- vanilla's own check (before our wrap, so this does not ask blockReason again)
        local canPlace = WallCharger.vanillaCanPlace or ISMoveableSpriteProps.canPlaceMoveableInternal
        if canPlace(ISMoveableSpriteProps.new(spriteName), nil, square, nil) then return "wall" end
    end
    return nil
end

WallCharger.BLOCK_TEXT = { square = "IGUI_NEV_ChargerSquareTaken", wall = "IGUI_NEV_ChargerWallTaken" }

-- with no facing chosen: first a wall it can hang on; failing that, turn to a wall that is taken, so blockReason
-- shows red and says why instead of the cursor keeping the item's own facing and putting a standing charger down
-- quietly (#183, user 11-04 / review 20.1-2; v1.6.0 release regression 11-10). Like vanilla wall objects, which
-- snap to any wall on that side, taken or not (ISMoveableSpriteProps:snapFaceToSquare)
local snap = Util.guard("wallChargerSnap", function(square)
    for _, f in ipairs(WallCharger.SNAP) do
        if WallCharger.wallProps(square, f[1]) then return f[2] end
    end
    for _, f in ipairs(WallCharger.SNAP) do
        if WallCharger.blockReason(square, f[1], Charging.CHARGER_TILESET .. WallCharger.FLOOR[f[1]]) == "wall" then
            return f[2]
        end
    end
    return nil
end)

local toWall = Util.guard("wallChargerPlace", function(o)
    if o.mode ~= "place" or not o.moveProps or not WallCharger.isFloor(o.moveProps.spriteName) then return end
    local wall = WallCharger.wallProps(o.square, o.moveProps.facing)
    if wall then
        o.moveProps = wall
        o.maxTime = o:getDuration()
        Util.log("WALLCHARGER", { place = wall.spriteName })
    end
end)

-- wraps the three vanilla functions once (OnGameBoot; the unit tests call it after their stand-ins)
function WallCharger.install()
    if WallCharger.installed or not ISMoveableSpriteProps or not ISMoveablesAction then return false end
    WallCharger.installed = true

    local origSnap = ISMoveableSpriteProps.snapFaceToSquare
    function ISMoveableSpriteProps:snapFaceToSquare(square)
        if WallCharger.isFloor(self.spriteName) then
            local face = snap(square)
            if face then return face end
        end
        return origSnap(self, square)
    end

    local origNew = ISMoveablesAction.new
    function ISMoveablesAction:new(character, square, mode, origSpriteName, object, direction, item, moveCursor)
        local o = origNew(self, character, square, mode, origSpriteName, object, direction, item, moveCursor)
        toWall(o)
        return o
    end

    local origInstance = ISMoveableSpriteProps.instanceItem
    function ISMoveableSpriteProps:instanceItem(spriteNameOverride)
        local name = spriteNameOverride or self.spriteName
        if WallCharger.isWall(name) then
            return origInstance(self, WallCharger.floorName(name))
        end
        return origInstance(self, spriteNameOverride)
    end

    -- the cursor (via canPlaceMoveable) and the final placeMoveable both ask this, so a blocked charger shows red
    -- and is never put down, also where the action completes on the server; rotating does not ask it
    local origCanPlace = ISMoveableSpriteProps.canPlaceMoveableInternal
    WallCharger.vanillaCanPlace = origCanPlace
    function ISMoveableSpriteProps:canPlaceMoveableInternal(character, square, item, forceTypeObject)
        if WallCharger.blockReason(square, self.facing, self.spriteName) then return false end
        return origCanPlace(self, character, square, item, forceTypeObject)
    end

    -- and the cursor's info panel says why
    local origInfo = ISMoveableSpriteProps.getInfoPanelDescription
    function ISMoveableSpriteProps:getInfoPanelDescription(square, object, player, mode)
        local t = origInfo(self, square, object, player, mode)
        local reason = mode == "place" and WallCharger.blockReason(square, self.facing, self.spriteName)
        if reason and type(t) == "table" then
            local c = ISMoveableSpriteProps.bhc
            ISMoveableSpriteProps.addLineToInfoTable(t, getText(WallCharger.BLOCK_TEXT[reason]),
                c and c:getR() * 255 or 255, c and c:getG() * 255 or 0, c and c:getB() * 255 or 0)
        end
        return t
    end
    return true
end

Events.OnGameBoot.Add(Util.guard("wallChargerBoot", WallCharger.install))

return WallCharger
