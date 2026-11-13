-- Copyright (c) 2026 熊叔
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.

-- NEV Lib: the placing cursor shows the wall box where the home charger will
-- hang on a wall (#183; the choice itself is made in shared/NEVLib/WallCharger.lua
-- when the place action is built). Vanilla's ISMoveableCursor:isValid picks the
-- standing sprite for the cursor's facing; with a wall on that side the wall
-- sprite is shown instead, with vanilla's own wall-object placing check.
-- ISMoveableCursor lives in server/ (loaded after client/). At OnGameBoot it is not
-- there yet in single player (#183 probe 11-03: cursorInstalled nil), so the wrap is
-- tried again at OnGameStart; installCursor runs once.
require "NEVLib/Util"
require "NEVLib/WallCharger"

local Util, WallCharger = NEVLib.Util, NEVLib.WallCharger

local toWall = Util.guard("wallChargerCursor", function(cursor, square)
    if ISMoveableCursor.mode[cursor.player] ~= "place" then return end
    local cur = cursor.currentMoveProps
    if not cur or not WallCharger.isFloor(cur.spriteName) then return end
    local wall = WallCharger.wallProps(square, cur.facing)
    if not wall then return end
    cursor.currentMoveProps = wall
    cursor.objectSprite = wall.sprite
    cursor.canCreate = wall:canPlaceMoveable(cursor.character, square, nil)
    cursor.colorMod = cursor.canCreate and ISMoveableCursor.normalColor or ISMoveableCursor.invalidColor
    cursor.yOffset = wall:getYOffsetCursor()
end)

function WallCharger.installCursor()
    if WallCharger.cursorInstalled or not ISMoveableCursor then return false end
    WallCharger.cursorInstalled = true
    local origIsValid = ISMoveableCursor.isValid
    function ISMoveableCursor:isValid(square)
        local ok = origIsValid(self, square)
        if ok then toWall(self, square) end
        return ok
    end
    return true
end

Events.OnGameBoot.Add(Util.guard("wallChargerCursorBoot", WallCharger.installCursor))
Events.OnGameStart.Add(Util.guard("wallChargerCursorStart", WallCharger.installCursor))
