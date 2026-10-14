--!strict
-- Headless CPU drawing helpers. The framebuffer is DOOM-style indexed 8-bit.
local paletteModule = require("@doom/palette")
local patchModule = require("@doom/patch")
local mapModule = require("@doom/map")
local rmain = require("./rmain")

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

function module.view(map: any, wad: any, x: number, y: number, angle: number, mobjs: {any}?): (Frame, any)
    return rmain.view(map, wad, x, y, angle, mobjs)
end

function module.ppm(frame: Frame, palette: any): buffer return paletteModule.toPpm(frame.pixels, frame.width, frame.height, palette) end
return module
