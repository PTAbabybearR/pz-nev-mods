-- NEV Lib: NEV dashboard layout and drawing (docs/design/ui/dashboard-design.md 2, 16-23, 25). Draws on our own
-- panel NEVLib/DashPanel; NEVLib/DashRoute decides when the player sees it (#339: the driver of an NEV only, other
-- vehicles keep vanilla's or another mod's dashboard untouched).
--  * visual v5, A "cockpit cards" (UI-DESIGN 23, user 2026-10-08): near-black
--    glass panel at the bottom centre, three rounded cards; sizes measured
--    from the real fonts at run time (in-game round 1: fonts are far larger
--    than a fixed layout assumes)
--  * no ignition on an NEV (UI-DESIGN 19): vanilla engine light, battery
--    light and key slot hidden; one access badge (key / hacked / none) at
--    the left end of the icon row; powered = cards shown, off = the panel
--    shrinks to the icon row (plus the middle card while charging)
--  * icon row: access badge, door lock | lights, screen, heater, trunk,
--    fridge, camping, air filter, range extender (one centre line, even pitch)
--  * left card: gear + speed | mode label + cruise | energy-mode segments
--    middle card: battery / fuel bars | right card: range, date + time, temps
--  * tooltips follow the mouse (W8)
-- What is shown comes from NEVLib/DashInfo (unit tested); this file only lays
-- it out and handles clicks. Entry points for the panel: drawFrame (prerender),
-- drawContents (render), click, applyLayout.
require "NEVLib/Util"
require "NEVLib/Registry"
require "NEVLib/State"
require "NEVLib/Battery"
require "NEVLib/Fridge"
require "NEVLib/AirFilter"
require "NEVLib/DashInfo"
require "NEVLib/EnergyMode"
require "NEVLib/Menu"

local Util, Registry, State, Battery, Fridge, AirFilter, DashInfo, EnergyMode, Menu =
    NEVLib.Util, NEVLib.Registry, NEVLib.State, NEVLib.Battery, NEVLib.Fridge, NEVLib.AirFilter, NEVLib.DashInfo, NEVLib.EnergyMode, NEVLib.Menu
local Dashboard = {}
NEVLib.Dashboard = Dashboard

local T = Util.text
local C = DashInfo.COLORS

-- Base pixels (UI-DESIGN 23.1), scaled by the width of the vanilla background
-- texture (the panel keeps it as nevBgW, 25.3-2); everything holding text is
-- measured instead.
Dashboard.BASE_W = 552            -- vanilla background width = scale 1
Dashboard.MIN_W = 600             -- panel width at scale 1 (A mock-up)
Dashboard.SIDE = 10               -- panel edge to the cards
Dashboard.CARD_PAD = 10           -- inside a card
Dashboard.CARD_GAP = 8            -- between cards
Dashboard.BOTTOM = 8              -- cards to the screen bottom
Dashboard.COLLAPSED_H = 40        -- off: icon row only
Dashboard.PANEL_R = 16
Dashboard.CARD_R = 10
Dashboard.SEG_R = 9               -- energy-mode control
Dashboard.SEG_SEL_R = 7
Dashboard.BAR_H = 10              -- thin continuous bars
Dashboard.ICON_MARGIN = 14        -- icon row to the panel edge
Dashboard.ICON_ROW_Y = 6          -- top of the 20 px icon slots
Dashboard.ICON_SLOT = 20
Dashboard.ICON_PITCH = 28
Dashboard.ICON_GROUPS = {
    { names = { "__badge", "doorTex" } },   -- "__badge": access badge, drawn by us
    { names = { "lightsTex", "radioTex", "heaterTex", "trunkTex" } },
}
Dashboard.LAMP_SLOTS = 4          -- fridge, camping, air filter, range extender
Dashboard.LAMP = 20
Dashboard.ICON = 18               -- plug / fuel icons in the bars
Dashboard.BADGE_ARROW = 13        -- port side badge: solid triangle at the icon's bottom right (round 4; 11 until #338 Q3)
Dashboard.PORTS_GAP = 14          -- collapsed bar: plug group to fuel group (#338 Q2)
Dashboard.BAR_MIN_W = 130         -- shortest bar; bars grow to fill the middle card
Dashboard.READ_MS = 250           -- #320: the numbers are read every 0.25 s (UI clock = real time), Dashboard.readings

local TEX = {}
local function tex(name)
    if TEX[name] == nil then TEX[name] = getTexture("media/ui/NEVLib/" .. name .. ".png") or false end
    return TEX[name] or nil
end

local function isNEV(self) return self.vehicle ~= nil and Registry.isNEV(self.vehicle) end

local function fontH(font) return getTextManager():getFontHeight(font) end
local function textW(font, str) return getTextManager():MeasureStringX(font, str) end

function Dashboard.scale(self)
    local w = self.nevBgW or Dashboard.BASE_W
    if not w or w <= 0 then return 1 end
    return w / Dashboard.BASE_W
end

---------------------------------------------------------------------------
-- Layout: measured; depends on the vehicle type, the fonts and whether the
-- car is powered / charging
---------------------------------------------------------------------------

-- The layout only changes with what the comment above lists, so it is
-- measured again only when one of those changed (REVIEW 3.4-14: about 20
-- string measurements and getText calls every frame). Font heights stand in
-- for "the fonts" (the font size option changes them).
function Dashboard.layoutKey(self)
    local v = self.vehicle
    return table.concat({ tostring(v and v:getScriptName()), tostring(Dashboard.scale(self)),
        tostring(DashInfo.powered(v)), tostring(v ~= nil and State.get(v).charge ~= nil),   -- = DashInfo.charging(v) ~= nil
        tostring(fontH(UIFont.Small)), tostring(fontH(UIFont.Medium)), tostring(fontH(UIFont.Large)),
        tostring(self.speedregulatorTex ~= nil) }, "|")
end

function Dashboard.measureCached(self)
    local key = Dashboard.layoutKey(self)
    if self.nevLayout and self.nevLayoutKey == key then return self.nevLayout end
    self.nevLayoutKey = key
    return Dashboard.measure(self)
end

-- Width of a port icon with its side badge (half the badge sticks out on the right; #338).
function Dashboard.portW(s)
    return (Dashboard.ICON + Dashboard.BADGE_ARROW * 0.5) * s
end

-- Returns L: { s, W, H, powered, charging, collapsed, top, cards = { left,
-- mid, right }, blocks by name {x, y, w, h, ...}, groupX = { left, right } }.
-- Visual v5 (UI-DESIGN 23, A "cockpit cards"): three rounded cards under the
-- icon row; sizes measured from the real fonts.
function Dashboard.measure(self)
    local v = self.vehicle
    local cfg = Registry.get(v)
    local s = Dashboard.scale(self)
    local S, M, Lf = UIFont.Small, UIFont.Medium, UIFont.Large
    local hS, hM, hL = fontH(S), fontH(M), fontH(Lf)
    local L = { s = s, erev = cfg.powertrain == "EREV", hS = hS, hM = hM, hL = hL, blocks = {}, cards = {} }
    L.powered = DashInfo.powered(v)
    L.charging = DashInfo.charging(v) ~= nil
    local pad, gap, side = Dashboard.CARD_PAD * s, Dashboard.CARD_GAP * s, Dashboard.SIDE * s
    L.top = (Dashboard.ICON_ROW_Y + Dashboard.ICON_SLOT + 8) * s
    local function add(name, b) b.name = name; L.blocks[name] = b; return b end

    -- middle card: battery (+ fuel) rows
    local rowH = math.max(hM, Dashboard.ICON * s)
    local rowGap = 14 * s      -- room for the fuel -> battery flow arrows (W10)
    local pctW = textW(M, "100%")
    local barsFixed = Dashboard.portW(s) + 10 * s + 8 * s + pctW
    local bars = add("bars", { rowH = rowH, rowGap = rowGap, h = L.erev and (rowH * 2 + rowGap) or rowH,
                               fixed = barsFixed, w = barsFixed + Dashboard.BAR_MIN_W * s, pctW = pctW })
    local chargeTxt = math.max(textW(S, T("IGUI_NEV_Dash_ChargeFast", "888")), textW(S, T("IGUI_NEV_Dash_ChargeSlow", "888")))

    local minW = Dashboard.MIN_W * s
    if L.powered then
        -- left card: gear + speed, mode label + cruise, mode buttons
        local reg = self.speedregulatorTex
        local gearW = 0
        for _, g in ipairs({ "P", "R", "N", "D" }) do gearW = math.max(gearW, textW(Lf, g)) end
        local gear = add("gear", { gearW = gearW, w = gearW + 8 * s + textW(Lf, "888") + 4 * s + textW(S, "km/h"), h = hL })
        local label = T("IGUI_NEV_Dash_ModeLabel")
        local cruise = reg and add("cruise", { w = reg:getWidth() + 5 * s + textW(M, "888"), h = math.max(reg:getHeight(), hM) }) or nil
        local rowB = add("modeLabel", { text = label, w = textW(S, label), h = math.max(hS, cruise and cruise.h or 0) })
        local rowBW = rowB.w + (cruise and (12 * s + cruise.w) or 0)
        local modes = nil
        if L.erev then
            local bh = hS + 10 * s
            local bw = math.max(bh + 6 * s, Dashboard.ICON * s + 16 * s)
            modes = add("modes", { w = bw * 3, h = bh, bw = bw, bh = bh })
        end
        local leftW = math.max(gear.w, rowBW, modes and modes.w or 0) + pad * 2
        local leftH = gear.h + 6 * s + rowB.h + (modes and (8 * s + modes.h) or 0) + pad * 2
        -- right card: label, range, date / time, temperatures (+ charging)
        local rlabel = T("IGUI_NEV_Dash_RangeLabel")
        local temps = T("IGUI_NEV_Dash_TempF", "-88") .. " / " .. T("IGUI_NEV_Dash_TempF", "-88")
        local rightIn = math.max(textW(S, rlabel), textW(Lf, "8888") + textW(S, " km"), textW(S, "12/31 23:59"),
                                 textW(S, "12/31 12:59 PM"), textW(S, temps), L.charging and chargeTxt or 0)
        local lines = hS + hL + hS + hS + (L.charging and hS or 0)
        add("range", { label = rlabel, w = rightIn, h = hS + hL })
        add("daily", { w = rightIn, h = hS * 2 })
        local rightW = rightIn + pad * 2
        local rightH = lines + 3 * 2 * s + pad * 2
        local midH = bars.h + pad * 2
        local cardH = math.max(leftH, midH, rightH)
        local midMin = bars.w + pad * 2
        local W = math.max(minW, side * 2 + leftW + midMin + rightW + gap * 2)
        local midW = W - side * 2 - leftW - rightW - gap * 2
        bars.w = midW - pad * 2
        L.W, L.H = W, L.top + cardH + Dashboard.BOTTOM * s
        local y = L.top
        L.cards.left = { x = side, y = y, w = leftW, h = cardH }
        L.cards.mid = { x = side + leftW + gap, y = y, w = midW, h = cardH }
        L.cards.right = { x = side + leftW + gap + midW + gap, y = y, w = rightW, h = cardH }
        -- left card contents
        local cl = L.cards.left
        gear.x, gear.y = cl.x + pad, cl.y + pad
        rowB.x, rowB.y = cl.x + pad, gear.y + gear.h + 6 * s
        if cruise then cruise.x, cruise.y = cl.x + cl.w - pad - cruise.w, rowB.y end
        if modes then modes.x, modes.y = cl.x + pad, cl.y + cl.h - pad - modes.h end
        -- middle: bars centred vertically
        local cm = L.cards.mid
        bars.x, bars.y = cm.x + pad, cm.y + (cm.h - bars.h) / 2
        -- right
        local cr = L.cards.right
        L.blocks.range.x, L.blocks.range.y = cr.x + pad, cr.y + pad
        L.blocks.daily.x, L.blocks.daily.y = cr.x + pad, cr.y + pad + hS + hL + 2 * 2 * s
        if L.charging then
            add("chargeInfo", { x = cr.x + pad, y = L.blocks.daily.y + hS * 2 + 2 * s, w = rightIn, h = hS })
        end
    elseif L.charging then
        -- off but charging (UI-DESIGN 19.3): the middle card alone, time left under the bars
        local inner = math.max(minW - side * 2 - pad * 2, bars.w, chargeTxt)
        bars.w = inner
        local cardH = bars.h + 4 * s + hS + pad * 2
        L.W = inner + pad * 2 + side * 2
        L.H = L.top + cardH + Dashboard.BOTTOM * s
        L.cards.mid = { x = side, y = L.top, w = inner + pad * 2, h = cardH }
        bars.x, bars.y = side + pad, L.top + pad
        add("chargeInfo", { x = side + pad, y = bars.y + bars.h + 4 * s, w = inner, h = hS })
    else
        L.blocks.bars = nil
    end
    L.collapsed = not L.powered and not L.charging
    if L.collapsed then
        L.W = minW
        L.H = Dashboard.COLLAPSED_H * s
        -- the plug (+ fuel) with its side badge on the icon row (#338 Q2); x once the groups are placed
        local n = L.erev and 2 or 1
        add("ports", { y = (Dashboard.ICON_ROW_Y + (Dashboard.ICON_SLOT - Dashboard.ICON) / 2) * s,
                       w = Dashboard.portW(s) * n + (n - 1) * Dashboard.PORTS_GAP * s, h = Dashboard.ICON * s })
    end
    -- icon row: left group from the left margin, right group + lights flush right
    local p = Dashboard.ICON_PITCH * s
    local slots = #Dashboard.ICON_GROUPS[2].names + Dashboard.LAMP_SLOTS
    local m = Dashboard.ICON_MARGIN * s
    L.groupX = { m, L.W - m - slots * p + (p - Dashboard.ICON_SLOT * s) }
    local ports = L.blocks.ports
    if ports then
        -- centred in the gap between the left icon group and the right one
        local leftEnd = m + #Dashboard.ICON_GROUPS[1].names * p - (p - Dashboard.ICON_SLOT * s)
        ports.x = (leftEnd + L.groupX[2] - ports.w) / 2
    end
    return L
end

-- Top-left corner of slot i (1-based) of icon group gi.
function Dashboard.iconSlot(self, gi, i)
    local s = Dashboard.scale(self)
    local x0 = (self.nevGroupX and self.nevGroupX[gi]) or 0
    return x0 + (i - 1) * Dashboard.ICON_PITCH * s, Dashboard.ICON_ROW_Y * s
end

-- Centres a vanilla icon in its slot of the NEV icon row.
function Dashboard.placeInSlot(self, name)
    local e = self[name]
    if not e or not self.nevGroupX then return end
    local s = Dashboard.scale(self)
    for gi, g in ipairs(Dashboard.ICON_GROUPS) do
        for i, n in ipairs(g.names) do
            if n == name then
                local sx, sy = Dashboard.iconSlot(self, gi, i)
                e:setX(sx + (Dashboard.ICON_SLOT * s - e:getWidth()) / 2)
                e:setY(sy + (Dashboard.ICON_SLOT * s - e:getHeight()) / 2)
                return
            end
        end
    end
end

---------------------------------------------------------------------------
-- The vanilla-style icons (the panel's own children, NEVLib/DashPanel)
---------------------------------------------------------------------------

-- The obsolete player patch (25.8) calls this from its own panel; the panel
-- has nothing of vanilla's left to hide, only the screen button.
function Dashboard.applyVisibility(self)
    Dashboard.applyScreenButton(self)
end

-- Radio button -> infotainment screen button (UI-DESIGN 13). Only the icon,
-- the tooltip and the size change; the click is the panel's onClickRadio.
-- Checked every frame, so installing / removing the item is seen.
function Dashboard.applyScreenButton(self)
    local b = self.radioTex
    if not b then return end
    local nev = isNEV(self)
    local screen = nev and DashInfo.hasScreen(self.vehicle)
    if screen then
        if not self.nevRadioOrig then
            self.nevRadioOrig = { texture = b.texture, tip = b.mouseovertext, w = b:getWidth(), h = b:getHeight(),
                                  sw = b.scaledWidth, sh = b.scaledHeight }
        end
        b.texture = tex("screen") or b.texture
        b.mouseovertext = T("IGUI_NEV_ScreenTip")
        -- vanilla draws the radio at 16 px; the screen button gets a full 20 px slot
        local size = Dashboard.ICON_SLOT * Dashboard.scale(self)
        if b:getWidth() ~= size or b:getHeight() ~= size then
            b:setWidth(size)
            b:setHeight(size)
            b.scaledWidth, b.scaledHeight = size, size
            Dashboard.placeInSlot(self, "radioTex")
        end
    elseif self.nevRadioOrig then
        local o = self.nevRadioOrig
        b.texture, b.mouseovertext = o.texture, o.tip
        b:setWidth(o.w)
        b:setHeight(o.h)
        b.scaledWidth, b.scaledHeight = o.sw, o.sh
        self.nevRadioOrig = nil
        if nev then Dashboard.placeInSlot(self, "radioTex") end
    end
end

local logged = false

-- Panel size / position and the vanilla icons' places for layout L.
function Dashboard.applySize(self, L)
    local num = self.playerNum or 0
    self.nevGroupX = L.groupX
    -- placed every time, not only when the size changes: the panel starts at (0, 0) with the collapsed size, which
    -- a layout may equal (25.3)
    self:setWidth(L.W)
    self:setX(getPlayerScreenLeft(num) + (getPlayerScreenWidth(num) - L.W) / 2)
    self:setHeight(L.H)
    self:setY(getPlayerScreenTop(num) + getPlayerScreenHeight(num) - L.H)
    for _, g in ipairs(Dashboard.ICON_GROUPS) do
        for _, name in ipairs(g.names) do Dashboard.placeInSlot(self, name) end
    end
    local reg = self.speedregulatorTex
    if reg then
        local b = L.blocks.cruise
        if b then
            -- the cruise speed (Medium) is drawn from the icon's top edge to
            -- its right (Dashboard.drawCruise), so the icon sits at the top of the block
            reg:setVisible(true)
            reg:setX(b.x)
            reg:setY(b.y)
        else
            -- collapsed: no cruise
            reg:setVisible(false)
            reg:setY(-1000)
        end
    end
end

-- Panel size and position, the icons' places: on a new vehicle and a
-- resolution / UI scale change (the panel's setVehicle / onResolutionChange).
function Dashboard.applyLayout(self)
    if not isNEV(self) then return end
    Dashboard.applyScreenButton(self)
    local L = Dashboard.measure(self)
    Dashboard.applySize(self, L)
    if not logged then
        -- real metrics for the next layout round
        logged = true
        Util.log("DASH", { fontS = L.hS, fontM = L.hM, fontL = L.hL, width = L.W, height = L.H, scale = L.s })
    end
end

---------------------------------------------------------------------------
-- Drawing helpers (ISUIElement API)
---------------------------------------------------------------------------

local function rect(self, x, y, w, h, c, a)
    self:drawRect(x, y, w, h, a or 1, c.r, c.g, c.b)
end

local function icon(self, name, x, y, size, c, a)
    local t = tex(name)
    if t then self:drawTextureScaled(t, x, y, size, size, a or 1, c.r, c.g, c.b) end
end

local function text(self, str, x, y, c, font, align, a)
    local fn = align == "center" and self.drawTextCentre or (align == "right" and self.drawTextRight or self.drawText)
    fn(self, str, x, y, c.r, c.g, c.b, a or 1, font)
end

local function levelColor(level) return C[level] or C.ok end

-- Animation clock in ms, advanced every frame by the time since the last UI
-- render - the way vanilla UI animates (UIManager.getMillisSinceLastRender).
-- Not the wall clock: in game getTimestampMs()-based blinking and the charge
-- flow stood still (round 4, X2 / Q3).
Dashboard.clock = 0
function Dashboard.tick()
    local dt = UIManager and UIManager.getMillisSinceLastRender and UIManager.getMillisSinceLastRender() or 16
    if type(dt) ~= "number" or dt < 0 or dt > 1000 then dt = 16 end
    Dashboard.clock = Dashboard.clock + dt
end

local function blink(ms)
    return (math.floor(Dashboard.clock / (ms or 400)) % 2) == 0 -- kahlua-mod-ok: operands never negative
end

-- `tip`: the text, or a function making it - most tips format numbers and look up texts, and only the one under the
-- mouse is ever shown, so they are made when drawn (#253-6: 1.3.1 built every tip on every frame). Dashboard.tipOf.
local function hit(self, x, y, w, h, action, tip)
    self.nevHits[#self.nevHits + 1] = { x = x, y = y, w = w, h = h, action = action, tip = tip }
end

function Dashboard.tipOf(h)
    if type(h.tip) == "function" then h.tip = h.tip() end
    return h.tip
end

local function pct(frac) return string.format("%d", math.floor(Util.clamp(frac, 0, 1) * 100 + 0.5)) end

-- #320 (user 10-20: 「A，仪表盘数字改成每 0.25 秒刷新，警告灯照旧实时」): the numbers - speed, battery and fuel
-- (percent and bar fill), range, date / time / temperatures, charge time left - are read every READ_MS of the UI
-- clock; the frames in between draw the last reading. The lights, the gear letter, the energy-mode buttons, the
-- regen / charging / range-extender animations and the blinking stay live every frame. A new car or a changed
-- layout (powered, charging) reads at once.
function Dashboard.readings(self, L)
    local v = self.vehicle
    local r = self.nevRead
    local now = Dashboard.clock
    if r and r.vehicle == v and r.layout == L and now >= r.at and now < r.at + Dashboard.READ_MS then return r end
    r = { vehicle = v, layout = L, at = now }
    r.kmh = tostring(math.floor(math.abs(v:getCurrentSpeedKmHour()) * BaseVehicle.getFakeSpeedModifier() + 0.5))
    r.soc, r.cap = Battery.getSoc(v), Battery.capacityKWh(v)
    if L.erev then r.fuelL, r.fuelCap = DashInfo.fuel(v) end
    r.rangeKm = math.floor(DashInfo.rangeKm(v) + 0.5)
    r.daily = L.blocks.daily and DashInfo.daily(v, self.character)
    r.charge = L.blocks.chargeInfo and DashInfo.charging(v)
    self.nevRead = r
    return r
end

-- Rounded rectangle from the deco_ corner / fill textures (UI-DESIGN 23.3),
-- tinted c with alpha a; squareBottom = bottom corners square (the panel sits
-- on the screen edge).
local function rrect(self, x, y, w, h, r, c, a, squareBottom)
    if w <= 0 or h <= 0 then return end
    -- whole pixels: fractional edges left 1 px seams between the pieces
    -- (preview of the 48 % fuel bar, 2026-10-08)
    local x1, y1 = math.floor(x + w + 0.5), math.floor(y + h + 0.5)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    w, h = x1 - x, y1 - y
    if w <= 0 or h <= 0 then return end
    r = math.floor(math.max(0, math.min(r, w / 2, h / 2)))
    a = a or 1
    local fill = tex("deco_fill")
    if not fill then
        self:drawRect(x, y, w, h, a, c.r, c.g, c.b)
        return
    end
    local function f(fx, fy, fw, fh)
        if fw > 0 and fh > 0 then self:drawTextureScaled(fill, fx, fy, fw, fh, a, c.r, c.g, c.b) end
    end
    local function corner(name, cx, cy)
        local t = tex(name)
        if t and r > 0 then self:drawTextureScaled(t, cx, cy, r, r, a, c.r, c.g, c.b) end
    end
    local bottomR = squareBottom and 0 or r
    f(x + r, y, w - 2 * r, r)                                  -- top band between the corners
    f(x, y + r, w, h - r - bottomR)                            -- body
    if bottomR > 0 then f(x + r, y + h - r, w - 2 * r, r) end  -- bottom band
    corner("deco_corner_tl", x, y)
    corner("deco_corner_tr", x + w - r, y)
    if bottomR > 0 then
        corner("deco_corner_bl", x, y + h - r)
        corner("deco_corner_br", x + w - r, y + h - r)
    end
end
Dashboard.rrect = rrect

---------------------------------------------------------------------------
-- Blocks
---------------------------------------------------------------------------

-- Panel: near-black glass, 1 px border, faint top sheen; the cards.
function Dashboard.drawBackground(self, L)
    local s = L.s
    local W, H = self:getWidth(), self:getHeight()
    local r = Dashboard.PANEL_R * s
    rrect(self, 0, 0, W, H, r, C.border, 1, true)
    rrect(self, 1, 1, W - 2, H - 1, r - 1, C.panelA, 0.94, true)
    local fill = tex("deco_fill")
    if fill then self:drawTextureScaled(fill, r, 1, W - 2 * r, 1, 0.11, 1, 1, 1) end
    for _, name in ipairs({ "left", "mid", "right" }) do
        local c = L.cards[name]
        if c then rrect(self, c.x, c.y, c.w, c.h, Dashboard.CARD_R * s, C.card, 1) end
    end
end

-- Access badge (UI-DESIGN 19): display only.
function Dashboard.drawBadge(self, L)
    local v = self.vehicle
    local a = DashInfo.access(v, self.character)
    local x, y = Dashboard.iconSlot(self, 1, 1)
    local size = Dashboard.ICON_SLOT * L.s
    local name, col, tip
    if a == "hacked" then
        name, col, tip = "hacked", C.orange, T("IGUI_NEV_Dash_Hacked")
    elseif a == "key" then
        name, col, tip = "key", L.powered and C.ok or C.text, T("IGUI_NEV_Dash_AccessKey")
    else
        name, col, tip = "key_none", C.off, T("IGUI_NEV_Dash_AccessNone")
    end
    icon(self, name, x, y, size, col)
    hit(self, x, y, size, size, nil, tip)
end

-- Left card, first line: gear letter, speed, unit (one line, UI-DESIGN 23.1).
function Dashboard.drawGear(self, L)
    local b = L.blocks.gear
    if not b then return end
    local v = self.vehicle
    local gear = DashInfo.gear(v)
    text(self, gear, b.x, b.y, C.text, UIFont.Large)   -- P too: the normal colour (#338)
    local kmh = Dashboard.readings(self, L).kmh
    local sx = b.x + b.gearW + 8 * L.s
    text(self, kmh, sx, b.y, C.text, UIFont.Large)
    text(self, "km/h", sx + textW(UIFont.Large, kmh) + 4 * L.s, b.y + L.hL - L.hS, C.dim, UIFont.Small)
    local m = L.blocks.modeLabel
    if m and L.erev then text(self, m.text, m.x, m.y, C.dim, UIFont.Small) end
end

-- One bar row: port icon with a side badge, thin continuous bar, percent.
-- opts: frac, color, iconName, side, regen, charging, tip
function Dashboard.drawBar(self, L, y, opts)
    local b = L.blocks.bars
    local s, h = L.s, b.rowH
    local isz = Dashboard.ICON * s
    local x0 = b.x
    local iy = y + (h - isz) / 2
    icon(self, opts.iconName, x0, iy, isz, C.text)
    Dashboard.drawPortSide(self, s, x0, y + h, opts.side)
    text(self, pct(opts.frac) .. "%", b.x + b.w, y + (h - L.hM) / 2, opts.color, UIFont.Medium, "right")
    local bx = x0 + Dashboard.portW(s) + 10 * s
    local bw = b.w - b.fixed
    local th = Dashboard.BAR_H * s
    local ty = y + (h - th) / 2
    local frac = Util.clamp(opts.frac, 0, 1)
    local fw = bw * frac
    rrect(self, bx, ty, bw, th, th / 2, C.barTrack, 1)
    if fw > 0 then
        local g = tex("glow")
        if g then self:drawTextureScaled(g, bx - 4 * s, ty - 5 * s, fw + 8 * s, th + 10 * s, 0.35, opts.color.r, opts.color.g, opts.color.b) end
        rrect(self, bx, ty, fw, th, th / 2, opts.color, 1)
    end
    -- regen: the end of the fill alternates cyan / track so it clearly blinks (X2)
    if opts.regen and fw > 0 then
        local sw = math.min(fw, math.max(6 * s, bw * 0.08))
        rect(self, bx + fw - sw, ty, sw, th, blink(250) and C.regen or C.barTrack, 1)
    end
    -- charging: a light pulse walks the empty part and back; above ~92 % the end blinks (Q3)
    if opts.charging and frac < 1 then
        local pw = math.max(8 * s, bw * 0.12)
        local room = bw - fw
        if frac >= 0.92 or room <= pw then
            if blink(250) then rect(self, bx + bw - math.min(pw, bw), ty, math.min(pw, bw), th, C.charge, 0.8) end
        else
            local period = 1800
            local t = (Dashboard.clock % period) / period -- kahlua-mod-ok: operands never negative
            local k = t < 0.5 and t * 2 or (1 - t) * 2
            rect(self, bx + fw + (room - pw) * k, ty, pw, th, C.charge, 0.8)
        end
    end
    hit(self, bx, y, bw, h, nil, opts.tip)
end

-- The side badge of a port icon at x: bottom right of the icon, half outside it so the direction reads clearly;
-- its top is 0.8 badge above `bottom` (the row's bottom; on the collapsed bar the icon's). None without a side.
function Dashboard.drawPortSide(self, s, x, bottom, side)
    if not side then return end
    local bd = Dashboard.BADGE_ARROW * s
    icon(self, side == "left" and "arrow_left" or "arrow_right", x + Dashboard.ICON * s - bd * 0.5, bottom - bd * 0.8, bd, C.warn)
end

local function batteryTip(rd)
    local soc, cap = rd.soc, rd.cap
    return function() return T("IGUI_NEV_Dash_BatteryTip", string.format("%.1f", soc * cap), string.format("%.1f", cap), pct(soc)) end
end

local function fuelTip(rd)
    local fuelL, fuelCap = rd.fuelL, rd.fuelCap
    local frac = fuelCap > 0 and fuelL / fuelCap or 0
    return function() return T("IGUI_NEV_Dash_FuelTip", string.format("%.1f", fuelL), string.format("%.0f", fuelCap), pct(frac)) end
end

-- Powered off (collapsed): the plug (+ fuel) with its side badge on the icon row, hover as on the bars (#338 Q2).
function Dashboard.drawPorts(self, L)
    local b = L.blocks.ports
    if not b then return end
    local v = self.vehicle
    local s = L.s
    local rd = Dashboard.readings(self, L)
    local items = { { "plug", DashInfo.chargePortSide(v), batteryTip(rd) } }
    if L.erev then items[2] = { "fuel", DashInfo.fuelPortSide(v), fuelTip(rd) } end
    local isz = Dashboard.ICON * s
    for i, it in ipairs(items) do
        local x = b.x + (i - 1) * (Dashboard.portW(s) + Dashboard.PORTS_GAP * s)
        icon(self, it[1], x, b.y, isz, C.text)
        Dashboard.drawPortSide(self, s, x, b.y + isz, it[2])
        hit(self, x, b.y, Dashboard.portW(s), isz, nil, it[3])
    end
end

function Dashboard.drawBars(self, L)
    local b = L.blocks.bars
    if not b then return end
    local v = self.vehicle
    local rd = Dashboard.readings(self, L)
    local soc, cap = rd.soc, rd.cap
    local slevel = DashInfo.socLevel(soc)
    -- frame-to-frame speed changes are tiny and noisy: hold the indication briefly
    local speed = v:getCurrentSpeedKmHour()
    local now = Dashboard.clock
    if DashInfo.regenActive(v:isEngineRunning(), self.nevLastSpeed, speed, v:isGasPedalPressed()) then
        self.nevRegenUntil = now + 600   -- long enough to see a blink (X2)
    elseif v:isGasPedalPressed() then
        self.nevRegenUntil = 0
    end
    self.nevLastSpeed = speed
    Dashboard.drawBar(self, L, b.y, {
        frac = soc, iconName = "plug", side = DashInfo.chargePortSide(v),
        color = slevel == "ok" and C.ok or levelColor(slevel),
        regen = (self.nevRegenUntil or 0) > now, charging = State.get(v).charge ~= nil,   -- = DashInfo.charging(v) ~= nil
        tip = batteryTip(rd),
    })
    if not L.erev then return end
    local fuelL, fuelCap = rd.fuelL, rd.fuelCap
    local frac = fuelCap > 0 and fuelL / fuelCap or 0
    local flevel = DashInfo.fuelLevel(frac)
    local fy = b.y + b.rowH + b.rowGap
    Dashboard.drawBar(self, L, fy, {
        frac = frac, iconName = "fuel", side = DashInfo.fuelPortSide(v),
        color = flevel == "ok" and C.fuel or levelColor(flevel),
        tip = fuelTip(rd),
    })
    -- range extender generating: three chevrons between the bars light up in turn (W10)
    if DashInfo.rexLamp(v) == "on" then
        local a = 11 * L.s
        local x0 = b.x + Dashboard.portW(L.s) + 10 * L.s
        local span = b.w - b.fixed
        local phase = (Dashboard.clock % 900) / 900 -- kahlua-mod-ok: operands never negative
        for k = 0, 2 do
            local ax = x0 + span * (k + 1) / 4 - a / 2
            local ay = b.y + b.rowH + (b.rowGap - a) / 2
            icon(self, "arrow_up", ax, ay, a, C.ok, 0.45 + 0.55 * math.abs(math.sin((phase + k / 3) * math.pi)))
        end
    end
end

-- Energy modes (W4) as a three-segment control (UI-DESIGN 23.1); the ones the
-- charge does not allow are dimmed (clicking tells why); fuel priority
-- without fuel is flagged (W11).
local MODES = {
    { mode = "ev", icon = "mode_ev", tip = "IGUI_NEV_Mode_EV" },
    { mode = "hybrid", icon = "mode_hybrid", tip = "IGUI_NEV_Mode_Hybrid" },
    { mode = "fuel", icon = "mode_fuel", tip = "IGUI_NEV_Mode_Fuel" },
}

function Dashboard.drawModes(self, L)
    local b = L.blocks.modes
    if not b then return end
    local v = self.vehicle
    local st = State.get(v)
    local soc = Battery.getSoc(v)
    local noFuel = DashInfo.rexLamp(v) == "noFuel"
    local player = self.character
    local s = L.s
    rrect(self, b.x, b.y, b.w, b.h, Dashboard.SEG_R * s, C.segBg, 1)
    for i, m in ipairs(MODES) do
        local x = b.x + (i - 1) * b.bw
        local active = st.mode == m.mode
        local ok, why = EnergyMode.allowed(m.mode, soc)
        local ic = ok and C.iconDim or C.off
        local tipKey, reason = m.tip, nil
        if active then
            local sel = C.segSel
            ic = C.ok
            if m.mode == "fuel" and noFuel then
                sel, ic = C.warn, C.panelA
                tipKey = "IGUI_NEV_Dash_FuelModeNoFuel"
            end
            rrect(self, x + 2 * s, b.y + 2 * s, b.bw - 4 * s, b.h - 4 * s, Dashboard.SEG_SEL_R * s, sel, 1)
        end
        if not ok then reason = Menu.REASON[why] or "IGUI_NEV_Reason_NotSupported" end
        local function tip() return reason and (T(tipKey) .. " - " .. T(reason)) or T(tipKey) end
        local isz = math.min(b.h, b.bw) - 10 * s
        icon(self, m.icon, x + (b.bw - isz) / 2, b.y + (b.h - isz) / 2, isz, ic)
        local mode = m.mode
        hit(self, x, b.y, b.bw, b.h, function() Menu.run(player, "setMode", v, { mode = mode }) end, tip)
    end
end

-- Right card, lower lines: date + time, temperatures (V2); tooltip with the full text.
function Dashboard.drawDaily(self, L)
    local b = L.blocks.daily
    if not b then return end
    local info = Dashboard.readings(self, L).daily
    text(self, info.line1, b.x, b.y, C.text, UIFont.Small)
    text(self, info.line2, b.x, b.y + L.hS, C.dim, UIFont.Small)
    hit(self, b.x, b.y, b.w, b.h, nil, info.tip)
end

-- Right card, top: "range" label, the number (blinks red when critical) + km.
function Dashboard.drawRange(self, L)
    local b = L.blocks.range
    if not b then return end
    local v = self.vehicle
    text(self, b.label, b.x, b.y, C.dim, UIFont.Small)
    local ny = b.y + L.hS
    local km = Dashboard.readings(self, L).rangeKm
    local rlevel = DashInfo.rangeLevel(km, Registry.get(v))
    local kmText = tostring(km)
    local nw = textW(UIFont.Large, kmText)
    if rlevel ~= "crit" or blink() then
        text(self, kmText, b.x, ny, rlevel == "ok" and C.text or levelColor(rlevel), UIFont.Large)
        text(self, " km", b.x + nw, ny + L.hL - L.hS, C.dim, UIFont.Small)
    end
    local erev = L.erev
    local function tip()
        local ev, fuelKm, per100 = DashInfo.rangeParts(v)
        if erev then
            return T("IGUI_NEV_Dash_RangeTip", tostring(math.floor(ev + 0.5)), tostring(math.floor(fuelKm + 0.5)), string.format("%.1f", per100))
        end
        return T("IGUI_NEV_Dash_RangeTipBEV", tostring(math.floor(ev + 0.5)), string.format("%.1f", per100))
    end
    hit(self, b.x, ny, nw + textW(UIFont.Small, " km"), L.hL, nil, tip)
end

-- Charging: the time left (right card when powered, under the bars when off).
function Dashboard.drawChargeInfo(self, L)
    local b = L.blocks.chargeInfo
    local charge = b and Dashboard.readings(self, L).charge
    if not charge then return end
    local info = T(charge.kind == "fast" and "IGUI_NEV_Dash_ChargeFast" or "IGUI_NEV_Dash_ChargeSlow", tostring(charge.minutes))
    text(self, info, b.x, b.y, C.charge, UIFont.Small)
end

-- Fridge / camping / air filter / range extender lights after the vanilla
-- right-hand icon group, same pitch and centre line.
function Dashboard.drawLamps(self, L)
    local v = self.vehicle
    local cfg = Registry.get(v)
    local st = State.get(v)
    local player = self.character
    local s = L.s
    local lamps = {}
    local fp = Fridge.part(v)
    if fp then
        local on = Fridge.isOn(fp)
        lamps[#lamps + 1] = { icon = "fridge", color = on and C.ok or C.off,
                              tip = on and "IGUI_NEV_FridgeOff" or "IGUI_NEV_FridgeOn",
                              action = function() Menu.run(player, "toggleFridge", v) end }
    end
    if cfg.camping then
        -- I-228 (UI-DESIGN 24): the slot shows the current mode - tent while camping, a steering
        -- wheel while driving; the tip names the mode and what a click does
        lamps[#lamps + 1] = { icon = st.camping and "camping" or "driving", color = st.camping and C.camping or C.ok,
                              tip = st.camping and "IGUI_NEV_Dash_Camping" or "IGUI_NEV_Dash_Driving",
                              action = function() Menu.run(player, "toggleCamping", v) end }
    end
    if cfg.airFilter ~= false then
        local air = AirFilter.state(v)
        lamps[#lamps + 1] = { icon = "air", color = ({ on = C.ok, unsealed = C.warn })[air] or C.off,
                              tip = ({ on = "IGUI_NEV_Dash_AirOn", unsealed = "IGUI_NEV_Dash_AirUnsealed" })[air]
                                      or "IGUI_NEV_Dash_AirOff" }
    end
    local rex = DashInfo.rexLamp(v)
    if rex then
        lamps[#lamps + 1] = { icon = "rex", color = ({ idle = C.off, on = C.ok, noFuel = C.warn, broken = C.crit })[rex] or C.off,
                              tip = "IGUI_NEV_Dash_Rex_" .. rex }
    end
    local size = Dashboard.LAMP * s
    local first = #Dashboard.ICON_GROUPS[2].names
    for i, l in ipairs(lamps) do
        local x, y = Dashboard.iconSlot(self, 2, first + i)
        x = x + (Dashboard.ICON_SLOT * s - size) / 2
        y = y + (Dashboard.ICON_SLOT * s - size) / 2
        icon(self, l.icon, x, y, size, l.color)
        local key = l.tip   -- a text key: looked up when shown
        hit(self, x, y, size, size, l.action, function() return T(key) end)
    end
end

-- Tooltip next to the mouse (W8), kept on screen.
function Dashboard.drawTooltip(self, L)
    if not self:isMouseOver() then return end
    local mx, my = self:getMouseX(), self:getMouseY()
    local h = Dashboard.hitAt(self, mx, my)
    local tip = h and Dashboard.tipOf(h)
    if not tip or tip == "" then return end
    local s = L.s
    local pad = 5 * s
    local tw = textW(UIFont.Small, tip) + pad * 2
    local th = L.hS + pad * 2
    local x, y = mx + 14 * s, my - th - 6 * s
    local ax, ay = self:getAbsoluteX(), self:getAbsoluteY()
    local sw = getCore():getScreenWidth()
    if ax + x + tw > sw then x = mx - tw - 6 * s end
    if ax + x < 0 then x = -ax end
    if ay + y < 0 then y = my + 20 * s end
    rect(self, x, y, tw, th, C.panel, 0.95)
    self:drawRectBorder(x, y, tw, th, 0.9, C.accent.r, C.accent.g, C.accent.b)
    text(self, tip, x + pad, y + pad, C.text, UIFont.Small)
end

function Dashboard.hitAt(self, x, y)
    local hits = self.nevHits or {}
    for i = #hits, 1, -1 do
        local h = hits[i]
        if x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h then return h end
    end
    return nil
end

-- Cruise speed next to its icon, as vanilla draws it (ISVehicleDashboard.lua:405-408): the set speed, green 0.8
-- while cruise control is on, white 0.3 while off; nothing while collapsed (no cruise block).
function Dashboard.drawCruise(self, L)
    local reg = self.speedregulatorTex
    if not reg or not L.blocks.cruise then return end
    local v = self.vehicle
    local str = v:getRegulatorSpeed() .. ""
    if v:isRegulator() then
        self:drawText(str, reg.x + reg:getWidth() + 5, reg.y, 0, 1, 0, 0.8, UIFont.Medium)
    else
        self:drawText(str, reg.x + reg:getWidth() + 5, reg.y, 1, 1, 1, 0.3, UIFont.Medium)
    end
end

---------------------------------------------------------------------------
-- Frame entry points (NEVLib/DashPanel calls them, guarded)
---------------------------------------------------------------------------

-- prerender: the panel background and cards; powered / charging change the
-- panel size, so follow it (re-measured on change)
function Dashboard.drawFrame(self)
    Dashboard.tick()
    Dashboard.applyScreenButton(self)
    local L = Dashboard.measureCached(self)
    if L.W ~= self:getWidth() or L.H ~= self:getHeight() then Dashboard.applySize(self, L) end
    self.nevLayout = L
    Dashboard.drawBackground(self, L)
end

-- render: everything on the cards, over the icons; the mouse hit areas are
-- rebuilt every frame
function Dashboard.drawContents(self)
    local L = self.nevLayout or Dashboard.measure(self)
    self.nevGroupX = L.groupX
    self.nevHits = {}
    Dashboard.drawBadge(self, L)
    Dashboard.drawLamps(self, L)
    Dashboard.drawGear(self, L)
    Dashboard.drawCruise(self, L)
    Dashboard.drawBars(self, L)
    Dashboard.drawPorts(self, L)
    Dashboard.drawModes(self, L)
    Dashboard.drawDaily(self, L)
    Dashboard.drawRange(self, L)
    Dashboard.drawChargeInfo(self, L)
    Dashboard.drawTooltip(self, L)
end

-- A click on one of our hit areas runs its action; true = consumed. Only the
-- action is guarded: the handler's own return value must not depend on the
-- guard (Util.guard passes up to three values through, but nil after an error).
local runAction = Util.guard("dashboardClick", function(action) action() end)

function Dashboard.click(self, x, y)
    if not isNEV(self) then return false end
    local h = Dashboard.hitAt(self, x, y)
    if h and h.action then
        runAction(h.action)
        return true
    end
    return false
end

return Dashboard
