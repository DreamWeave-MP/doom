--!strict
-- Headless CPU drawing helpers. The framebuffer is DOOM-style indexed 8-bit.
local paletteModule = require("@doom/palette")
local patchModule = require("@doom/patch")
local mapModule = require("@doom/map")
local textureModule = require("@doom/texture")

local module = {}
export type Frame = { pixels: buffer, width: number, height: number }

function module.frame(width: number?, height: number?, clear: number?): Frame
    local w, h = width or 320, height or 200
    local pixels = buffer.create(w * h)
    if clear and clear ~= 0 then buffer.fill(pixels, 0, clear, w * h) end
    return { pixels = pixels, width = w, height = h }
end

function module.title(wad: any): (Frame, any)
    local palette = paletteModule.fromPlaypal(wad:read("PLAYPAL"), 0)
    local patch = patchModule.open(wad:read("TITLEPIC"))
    local frame = module.frame(patch.width, patch.height, 0)
    patchModule.draw(frame.pixels, frame.width, frame.height, patch, 0, 0)
    return frame, palette
end

local function put(frame: Frame, x: number, y: number, color: number)
    x = math.floor(x + 0.5); y = math.floor(y + 0.5)
    if x >= 0 and x < frame.width and y >= 0 and y < frame.height then buffer.writeu8(frame.pixels, y * frame.width + x, color) end
end

local function line(frame: Frame, x0: number, y0: number, x1: number, y1: number, color: number)
    x0 = math.floor(x0 + 0.5); y0 = math.floor(y0 + 0.5); x1 = math.floor(x1 + 0.5); y1 = math.floor(y1 + 0.5)
    local dx, sx = math.abs(x1 - x0), if x0 < x1 then 1 else -1
    local dy, sy = -math.abs(y1 - y0), if y0 < y1 then 1 else -1
    local err = dx + dy
    while true do
        put(frame, x0, y0, color)
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 >= dy then err += dy; x0 += sx end
        if e2 <= dx then err += dx; y0 += sy end
    end
end

function module.automap(map: any, wad: any, trace: {{x: number, y: number}}?): (Frame, any)
    local palette = paletteModule.fromPlaypal(wad:read("PLAYPAL"), 0)
    local frame = module.frame(640, 400, palette:nearest(0, 0, 0))
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for _, v in map.vertices do minX = math.min(minX, v.x); maxX = math.max(maxX, v.x); minY = math.min(minY, v.y); maxY = math.max(maxY, v.y) end
    local spanX, spanY = math.max(1, maxX - minX), math.max(1, maxY - minY)
    local scale = math.min((frame.width - 20) / spanX, (frame.height - 20) / spanY)
    local padX, padY = (frame.width - spanX * scale) * 0.5, (frame.height - spanY * scale) * 0.5
    local function project(x: number, y: number): (number, number) return padX + (x - minX) * scale, frame.height - (padY + (y - minY) * scale) end
    local solid, twoSided, special = palette:nearest(176, 0, 0), palette:nearest(96, 96, 96), palette:nearest(255, 255, 64)
    for _, l in map.lines do
        local a, b = map.vertices[l.v1], map.vertices[l.v2]
        local x0, y0 = project(a.x, a.y); local x1, y1 = project(b.x, b.y)
        line(frame, x0, y0, x1, y1, if l.special ~= 0 then special elseif l.left == 65535 then solid else twoSided)
    end
    if trace and #trace > 1 then
        local path = palette:nearest(64, 255, 64)
        for i = 2, #trace do local a, b = trace[i - 1], trace[i]; local x0, y0 = project(a.x, a.y); local x1, y1 = project(b.x, b.y); line(frame, x0, y0, x1, y1, path) end
    end
    local playerColor = palette:nearest(255, 255, 255); local start = mapModule.playerStart(map, 1); local px, py = project(start.x, start.y)
    for d = -3, 3 do put(frame, px + d, py, playerColor); put(frame, px, py + d, playerColor) end
    return frame, palette
end

local function raySegment(px: number, py: number, rdx: number, rdy: number, ax: number, ay: number, bx: number, by: number): (number?, number?)
    local sx, sy = bx - ax, by - ay
    local den = rdx * sy - rdy * sx
    if math.abs(den) < 1e-9 then return nil, nil end
    local qx, qy = ax - px, ay - py
    local t = (qx * sy - qy * sx) / den
    local u = (qx * rdy - qy * rdx) / den
    if t > 0.01 and u >= 0 and u <= 1 then return t, u end
    return nil, nil
end

local function flatSample(wad: any, name: string, x: number, y: number): number?
    if name == "F_SKY1" then return nil end
    local lump = wad:find(name)
    if not lump or lump.size < 4096 then return nil end
    local xx = bit32.band(math.floor(x), 63)
    local yy = bit32.band(-math.floor(y), 63)
    return buffer.readu8(wad.data, lump.offset + yy * 64 + xx)
end

function module.view(map: any, wad: any, x: number, y: number, angle: number): (Frame, any)
    local palette = paletteModule.fromPlaypal(wad:read("PLAYPAL"), 0)
    local frame = module.frame(320, 200, 0)
    local bank = textureModule.load(wad)
    local colormap = wad:read("COLORMAP")
    local sector = mapModule.sectorAt(map, x, y)
    local eye = sector.floor + 41
    local focal, center = 160, 100
    local ang = math.rad(angle)

    -- Current-sector flat casting gives the frame genuine WAD floor/ceiling pixels.
    for sy = 0, frame.height - 1 do
        if sy ~= center then
            local planeZ = if sy > center then eye - sector.floor else sector.ceiling - eye
            local perp = math.abs(planeZ * focal / (sy - center))
            for sx = 0, frame.width - 1 do
                local delta = math.atan((sx + 0.5 - 160) / focal)
                local rayDist = perp / math.max(0.01, math.cos(delta))
                local ra = ang + delta
                local wx, wy = x + math.cos(ra) * rayDist, y + math.sin(ra) * rayDist
                local name = if sy > center then sector.floorTex else sector.ceilingTex
                local c = flatSample(wad, name, wx, wy)
                if c == nil then c = if sy > center then palette:nearest(48, 40, 32) else palette:nearest(56, 56, 64) end
                buffer.writeu8(frame.pixels, sy * frame.width + sx, c)
            end
        end
    end

    for sx = 0, frame.width - 1 do
        local delta = math.atan((sx + 0.5 - 160) / focal)
        local ra = ang + delta
        local rdx, rdy = math.cos(ra), math.sin(ra)
        local bestT, bestU, bestLine, bestSide = math.huge, 0, nil, nil
        for _, l in map.lines do
            -- One-sided geometry is solid. A two-sided middle texture is a masked/solid wall for this milestone.
            local sideIndex = 65535
            local playerCross = (map.vertices[l.v2].x - map.vertices[l.v1].x) * (y - map.vertices[l.v1].y) - (map.vertices[l.v2].y - map.vertices[l.v1].y) * (x - map.vertices[l.v1].x)
            if playerCross <= 0 then sideIndex = l.right else sideIndex = l.left end
            if sideIndex == 65535 then sideIndex = if l.right ~= 65535 then l.right else l.left end
            local side = if sideIndex ~= 65535 then map.sides[sideIndex + 1] else nil
            local solid = l.left == 65535 or l.right == 65535 or (side and side.middle ~= "" and side.middle ~= "-")
            if solid then
                local a, b = map.vertices[l.v1], map.vertices[l.v2]
                local t, u = raySegment(x, y, rdx, rdy, a.x, a.y, b.x, b.y)
                if t and t < bestT then bestT, bestU, bestLine, bestSide = t, u or 0, l, side end
            end
        end
        if bestLine and bestSide then
            local wallSector = map.sectors[bestSide.sector]
            local perp = bestT * math.cos(delta)
            local top = math.floor(center - (wallSector.ceiling - eye) * focal / perp)
            local bottom = math.ceil(center - (wallSector.floor - eye) * focal / perp)
            top = math.max(0, top); bottom = math.min(frame.height - 1, bottom)
            local texName = bestSide.middle
            if texName == "" or texName == "-" then texName = if bestSide.upper ~= "" and bestSide.upper ~= "-" then bestSide.upper else bestSide.lower end
            local tex = bank:get(texName)
            local a, b = map.vertices[bestLine.v1], map.vertices[bestLine.v2]
            local lineLen = math.sqrt((b.x - a.x)^2 + (b.y - a.y)^2)
            local tx = 0
            if tex then tx = math.floor(bestU * lineLen + bestSide.xOffset) % tex.width end
            local shade = math.clamp(math.floor(perp / 80) + math.floor((255 - wallSector.light) / 16), 0, 31)
            for sy = top, bottom do
                local color = palette:nearest(96, 80, 64)
                if tex then
                    local worldZ = eye + (center - sy) * perp / focal
                    local ty = math.floor(wallSector.ceiling - worldZ + bestSide.yOffset) % tex.height
                    local o = ty * tex.width + tx
                    if buffer.readu8(tex.opaque, o) ~= 0 then color = buffer.readu8(tex.pixels, o) end
                end
                if buffer.len(colormap) >= 32 * 256 then color = buffer.readu8(colormap, shade * 256 + color) end
                buffer.writeu8(frame.pixels, sy * frame.width + sx, color)
            end
        end
    end
    return frame, palette
end

function module.ppm(frame: Frame, palette: any): buffer return paletteModule.toPpm(frame.pixels, frame.width, frame.height, palette) end
return module
