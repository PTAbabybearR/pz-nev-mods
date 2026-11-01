-- NEV Lib: charging indicator above charging vehicles near the player
-- (UI-DESIGN 2.4): the dashboard's battery bar in small - plug icon, bar
-- with the flowing charge animation, percent and minutes left. Drawn above
-- the charge port when the model has one, else above the car. Hidden while
-- the player drives that car (the dashboard shows it there).
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/State"
require "NEVLib/Battery"
require "NEVLib/DashInfo"
require "NEVLib/Nearby"

local Util, Registry, State, Battery, DashInfo, Nearby =
    NEVLib.Util, NEVLib.Registry, NEVLib.State, NEVLib.Battery, NEVLib.DashInfo, NEVLib.Nearby
local ChargeUI = {}
NEVLib.ChargeUI = ChargeUI

ChargeUI.RADIUS = 20
ChargeUI.HEIGHT = 1.2       -- world z above the car
-- Size: clearly bigger than the vanilla action progress bar (problem 24).
-- Vanilla draws BuildBar_Bkg (32 x 8 px) times the "action progress bar
-- size" option 1..4 (zombie.ui.ActionProgressBar); ours follows the same
-- option at 3x the width and 1.75x the height, with a larger icon and font.
ChargeUI.VANILLA_W, ChargeUI.VANILLA_H = 32, 8
ChargeUI.WIDTH_FACTOR = 3
ChargeUI.HEIGHT_FACTOR = 1.75

function ChargeUI.optionScale()
    local core = getCore and getCore()
    local v = core and core:getOptionActionProgressBarSize() or 1
    return Util.clamp(tonumber(v) or 1, 1, 4)
end

-- { barW, barH, icon, pad, font } for an option scale
function ChargeUI.sizes(scale)
    local bh = math.floor(ChargeUI.VANILLA_H * ChargeUI.HEIGHT_FACTOR * scale + 0.5)
    return {
        barW = ChargeUI.VANILLA_W * ChargeUI.WIDTH_FACTOR * scale,
        barH = bh,
        icon = bh + 8 * scale,
        pad = 5 * scale,
        font = scale >= 2 and UIFont.Large or UIFont.Medium,
    }
end

local C = DashInfo.COLORS

-- Text after the bar: "72%  12 min" (minutes from DashInfo.charging).
function ChargeUI.label(vehicle)
    local info = DashInfo.charging(vehicle)
    if not info then return nil end
    local soc = Battery.getSoc(vehicle)
    return string.format("%d%%  %s", math.floor(soc * 100 + 0.5),
        Util.text("IGUI_NEV_MinutesLeft", tostring(info.minutes)))
end

-- World position to draw at: the charge port area's centre when the model
-- defines one (Registry chargePortArea, set by model packs), else the car.
function ChargeUI.anchor(vehicle)
    local cfg = Registry.get(vehicle)
    local area = cfg and cfg.chargePortArea
    if area then
        local c = vehicle:getAreaCenter(area)
        if c then return c:getX(), c:getY(), vehicle:getZ() end
    end
    return vehicle:getX(), vehicle:getY(), vehicle:getZ()
end

local tracked = {}

-- After every shared scan (NEVLib.Nearby; #253-7: 1.3.1 scanned 21 x 21 on its own every 2 s): the charging NEVs
-- within RADIUS of the player.
Nearby.onScan(Util.guard("chargeUIScan", function(found, player)   -- its own name: the draw is "chargeUI" (#327)
    local px, py = player:getX(), player:getY()
    local r = ChargeUI.RADIUS
    local list = {}
    for _, v in ipairs(found) do
        -- charging first: most cars around are not, and their position costs two Java calls (#327 5-6)
        if State.get(v).charge and math.abs(v:getX() - px) <= r and math.abs(v:getY() - py) <= r then
            list[#list + 1] = v
        end
    end
    tracked = list
end))

local whiteTex, plugTex = nil, nil
local function textures()
    if whiteTex == nil then whiteTex = getTexture("media/ui/NEVLib/white.png") or false end
    if plugTex == nil then plugTex = getTexture("media/ui/NEVLib/plug.png") or false end
    return whiteTex or nil, plugTex or nil
end

-- SpriteRenderer.render(Texture, x, y, w, h, r, g, b, a, Consumer): the
-- Consumer argument is required - there is no 9-argument overload (in-game
-- round 2, W13: "No implementation found for function: render").
local function box(tex, x, y, w, h, c, a)
    getRenderer():render(tex, x, y, w, h, c.r, c.g, c.b, a or 1, nil)
end

-- Draws one indicator centred on screen point (sx, sy).
function ChargeUI.drawAt(vehicle, sx, sy)
    local white, plug = textures()
    if not white then return end
    local label = ChargeUI.label(vehicle)
    if not label then return end
    local soc = Util.clamp(Battery.getSoc(vehicle), 0, 1)
    local tm = getTextManager()
    local z = ChargeUI.sizes(ChargeUI.optionScale())
    local font = z.font
    local tw = tm:MeasureStringX(font, label)
    local th = tm:getFontHeight(font)
    local isz, bw, bh = z.icon, z.barW, z.barH
    local pad, gap = z.pad, z.pad
    local total = pad + isz + gap + bw + gap + tw + pad
    local h = math.max(isz, th) + pad * 2
    local x0, y0 = math.floor(sx - total / 2), math.floor(sy - h / 2)
    box(white, x0, y0, total, h, C.panel, 0.8)
    local x = x0 + pad
    if plug then box(plug, x, y0 + (h - isz) / 2, isz, isz, C.text) end
    x = x + isz + gap
    local by = y0 + (h - bh) / 2
    box(white, x, by, bw, bh, C.track)
    local level = DashInfo.socLevel(soc)
    box(white, x, by, bw * soc, bh, level == "ok" and C.ok or C[level])
    if soc < 1 then
        local span = bw * (1 - soc)
        local blockW = math.max(3, math.min(span, bw * 0.15))
        local phase = (ChargeUI.clock % 1500) / 1500 -- kahlua-mod-ok: operands never negative
        box(white, x + bw * soc + (span - blockW) * phase, by, blockW, bh, C.charge, 0.75)
    end
    x = x + bw + gap
    tm:DrawString(font, x, y0 + (h - th) / 2, label, C.charge.r, C.charge.g, C.charge.b, 1)
end

-- animation clock (ms), advanced per drawn frame like vanilla UI animation
ChargeUI.clock = 0

local function draw()
    -- nothing charging around (the usual case): no Java call at all; the clock only moves the drawn animation (#327)
    if tracked[1] == nil then return end
    local player = getPlayer()
    if not player then return end
    local dt = UIManager and UIManager.getMillisSinceLastRender and UIManager.getMillisSinceLastRender() or 16
    if type(dt) ~= "number" or dt < 0 or dt > 1000 then dt = 16 end
    ChargeUI.clock = ChargeUI.clock + dt
    local num = player:getPlayerNum()
    local inside = player:getVehicle()
    for _, v in ipairs(tracked) do
        -- the driver sees the dashboard instead; passengers have no dashboard
        -- (vanilla shows it to the driver only), so they keep this bar (X5)
        local driving = v == inside and v:isDriver(player)
        if not driving and State.get(v).charge then
            local wx, wy, wz = ChargeUI.anchor(v)
            local sx = isoToScreenX(num, wx, wy, wz + ChargeUI.HEIGHT)
            local sy = isoToScreenY(num, wx, wy, wz + ChargeUI.HEIGHT)
            ChargeUI.drawAt(v, sx, sy)
        end
    end
end

-- A charge started from the menu shows up immediately.
function ChargeUI.rescan() Nearby.rescan() end

Events.OnPostUIDraw.Add(Util.guard("chargeUI", draw))

return ChargeUI
