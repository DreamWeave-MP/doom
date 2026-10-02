--!strict
-- A column renderer following the useful part of the original R_RenderView:
-- traverse the map BSP front-to-back, project segs to columns, and draw wall
-- tiers through a Doom indexed texture/light table. It deliberately stops
-- short of sprites and visplanes; those are separate renderer slices.
local mapModule = require("@doom/map")
local rdata = require("./rdata")

local module = {}

export type Frame = { pixels: buffer, width: number, height: number }

local WIDTH = 320
local HEIGHT = 200
local CENTER_X = WIDTH * 0.5
local CENTER_Y = HEIGHT * 0.5
local FOCAL = CENTER_X
local NEAR = 0.01
local NO_SIDE = 65535
local DONT_PEG_BOTTOM = 8

local function cross(ax: number, ay: number, bx: number, by: number): number
    return ax * by - ay * bx
end

local function raySegment(px: number, py: number, rdx: number, rdy: number, ax: number, ay: number, bx: number, by: number): (number?, number?)
    local sx, sy = bx - ax, by - ay
    local denominator = cross(rdx, rdy, sx, sy)
    if math.abs(denominator) < 1e-9 then return nil, nil end
    local qx, qy = ax - px, ay - py
    local t = cross(qx, qy, sx, sy) / denominator
    local u = cross(qx, qy, rdx, rdy) / denominator
    if t > NEAR and u >= 0 and u <= 1 then return t, u end
    return nil, nil
end

local function project(depth: number, right: number): number
    return CENTER_X + right * FOCAL / depth
end

local function clipDepth(ax: number, ay: number, bx: number, by: number): (number?, number?, number?, number?)
    local ad = ax
    local bd = bx
    if ad <= NEAR and bd <= NEAR then return nil end
    if ad <= NEAR then
        local f = (NEAR - ad) / (bd - ad)
        ax += (bx - ax) * f
        ay += (by - ay) * f
    elseif bd <= NEAR then
        local f = (NEAR - bd) / (ad - bd)
        bx += (ax - bx) * f
        by += (ay - by) * f
    end
    return ax, ay, bx, by
end

local function textureName(name: string): string?
    if name == "" or name == "-" then return nil end
    return name
end

local function drawTier(frame: Frame, data: rdata.Data, zbuffer: {number}, x: number, depth: number, eye: number, topZ: number, bottomZ: number, tex: any, texU: number, texTop: number, light: number, solid: boolean, fallback: number)
    if topZ <= bottomZ then return end
    local top = math.max(0, math.floor(CENTER_Y - (topZ - eye) * FOCAL / depth))
    local bottom = math.min(HEIGHT - 1, math.ceil(CENTER_Y - (bottomZ - eye) * FOCAL / depth))
    if top > bottom then return end
    local textureX = 0
    if tex then textureX = math.floor(texU + 0.5) % tex.width end
    for y = top, bottom do
        local offset = y * WIDTH + x
        if depth < zbuffer[offset + 1] then
            local color = fallback
            local opaque = true
            if tex then
                local worldZ = eye + (CENTER_Y - y) * depth / FOCAL
                local textureY = math.floor(texTop - worldZ) % tex.height
                if textureY < 0 then textureY += tex.height end
                local textureOffset = textureY * tex.width + textureX
                opaque = buffer.readu8(tex.opaque, textureOffset) ~= 0
                if opaque then color = buffer.readu8(tex.pixels, textureOffset) end
            end
            if opaque or solid then
                if not opaque then color = fallback end
                color = rdata.light(data, color, light, depth)
                buffer.writeu8(frame.pixels, offset, color)
                if opaque or solid then zbuffer[offset + 1] = depth end
            end
        end
    end
end

local function drawSeg(frame: Frame, data: rdata.Data, wad: any, map: any, zbuffer: {number}, viewX: number, viewY: number, eye: number, angle: number, seg: any)
    local a, b = map.vertices[seg.v1], map.vertices[seg.v2]
    local cosAngle, sinAngle = math.cos(angle), math.sin(angle)
    local function camera(vertex: any): (number, number)
        local dx, dy = vertex.x - viewX, vertex.y - viewY
        return dx * cosAngle + dy * sinAngle, -dx * sinAngle + dy * cosAngle
    end
    local ad, ar = camera(a)
    local bd, br = camera(b)
    local clippedAd, clippedAr, clippedBd, clippedBr = clipDepth(ad, ar, bd, br)
    if not clippedAd or not clippedAr or not clippedBd or not clippedBr then return end
    ad, ar, bd, br = clippedAd, clippedAr, clippedBd, clippedBr
    local sx1, sx2 = project(ad, ar), project(bd, br)
    if math.max(sx1, sx2) < 0 or math.min(sx1, sx2) >= WIDTH then return end
    local first = math.max(0, math.floor(math.min(sx1, sx2)))
    local last = math.min(WIDTH - 1, math.ceil(math.max(sx1, sx2)) - 1)
    if first > last then return end

    local line = map.lines[seg.line]
    local sideIndex = if seg.side == 0 then line.right else line.left
    if sideIndex == NO_SIDE then return end
    local frontSide = map.sides[sideIndex + 1]
    if not frontSide then return end
    local front = map.sectors[frontSide.sector]
    local backSideIndex = if seg.side == 0 then line.left else line.right
    local backSide = if backSideIndex ~= NO_SIDE then map.sides[backSideIndex + 1] else nil
    local back = if backSide then map.sectors[backSide.sector] else nil
    if not front then return end

    local lineLength = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    local middle = data.textures:get(textureName(frontSide.middle) or "")
    local upper = data.textures:get(textureName(frontSide.upper) or "")
    local lower = data.textures:get(textureName(frontSide.lower) or "")
    local fallback = data.palette:nearest(96, 80, 64)

    for x = first, last do
        local delta = math.atan((x + 0.5 - CENTER_X) / FOCAL)
        local rayAngle = angle + delta
        local t, u = raySegment(viewX, viewY, math.cos(rayAngle), math.sin(rayAngle), a.x, a.y, b.x, b.y)
        if t and u then
            local depth = t * math.cos(delta)
            if depth > NEAR then
                local texU = u * lineLength + frontSide.xOffset
                local isClosed = not back or back.ceiling <= front.floor or back.floor >= front.ceiling
                if isClosed then
                    local texTop = if bit32.band(line.flags, DONT_PEG_BOTTOM) ~= 0 and middle then front.floor + middle.height else front.ceiling
                    drawTier(frame, data, zbuffer, x, depth, eye, front.ceiling, front.floor, middle, texU, texTop + frontSide.yOffset, front.light, true, fallback)
                elseif back then
                    if front.ceiling > back.ceiling then
                        local texTop = front.ceiling
                        drawTier(frame, data, zbuffer, x, depth, eye, front.ceiling, back.ceiling, upper, texU, texTop + frontSide.yOffset, front.light, true, fallback)
                    end
                    if front.floor < back.floor then
                        local texTop = if lower then back.floor + lower.height else back.floor
                        drawTier(frame, data, zbuffer, x, depth, eye, back.floor, front.floor, lower, texU, texTop + frontSide.yOffset, front.light, true, fallback)
                    end
                    if middle then
                        drawTier(frame, data, zbuffer, x, depth, eye, math.min(front.ceiling, back.ceiling), math.max(front.floor, back.floor), middle, texU, front.ceiling + frontSide.yOffset, front.light, false, fallback)
                    end
                end
            end
        end
    end
end

local function drawPlanes(frame: Frame, data: rdata.Data, wad: any, sector: any, x: number, y: number, eye: number, angle: number)
    for sy = 0, HEIGHT - 1 do
        if sy ~= CENTER_Y then
            local plane = if sy > CENTER_Y then sector.floor else sector.ceiling
            local distance = math.abs((eye - plane) * FOCAL / (sy - CENTER_Y))
            for sx = 0, WIDTH - 1 do
                local delta = math.atan((sx + 0.5 - CENTER_X) / FOCAL)
                local ray = angle + delta
                local rayDistance = distance / math.max(0.01, math.cos(delta))
                local wx, wy = x + math.cos(ray) * rayDistance, y + math.sin(ray) * rayDistance
                local name = if sy > CENTER_Y then sector.floorTex else sector.ceilingTex
                local color = rdata.flat(data, wad, name, wx, wy)
                if color == nil then
                    color = data.palette:nearest(if sy > CENTER_Y then 48 else 32, if sy > CENTER_Y then 40 else 32, if sy > CENTER_Y then 32 else 48)
                end
                buffer.writeu8(frame.pixels, sy * WIDTH + sx, rdata.light(data, color, sector.light, distance))
            end
        end
    end
end

local function renderSubsector(frame: Frame, data: rdata.Data, wad: any, map: any, zbuffer: {number}, viewX: number, viewY: number, eye: number, angle: number, index: number)
    local subsector = map.subsectors[index]
    if not subsector then return end
    for i = 0, subsector.count - 1 do
        local seg = map.segs[subsector.first + i]
        if seg then
            local a, b = map.vertices[seg.v1], map.vertices[seg.v2]
            -- Segs are oriented with their rendered/front sector on the right,
            -- just as R_AddLine's span >= ANG180 back-face test assumes.
            local side = cross(b.x - a.x, b.y - a.y, viewX - a.x, viewY - a.y)
            if side <= 0 then drawSeg(frame, data, wad, map, zbuffer, viewX, viewY, eye, angle, seg) end
        end
    end
end

function module.view(map: any, wad: any, x: number, y: number, angleDegrees: number): (Frame, any)
    local data = rdata.load(wad)
    local frame: Frame = { pixels = buffer.create(WIDTH * HEIGHT), width = WIDTH, height = HEIGHT }
    local sector = mapModule.sectorAt(map, x, y)
    local eye = sector.floor + 41
    local angle = math.rad(angleDegrees)
    drawPlanes(frame, data, wad, sector, x, y, eye, angle)

    local zbuffer: {number} = table.create(WIDTH * HEIGHT, math.huge)
    local function visit(child: number)
        if bit32.band(child, 0x8000) ~= 0 then
            renderSubsector(frame, data, wad, map, zbuffer, x, y, eye, angle, bit32.band(child, 0x7fff) + 1)
            return
        end
        local node = map.nodes[child + 1]
        if not node then return end
        local dx, dy = x - node.x, y - node.y
        local front = if node.dx == 0 then (if node.dy > 0 then (if x <= node.x then 0 else 1) else (if x <= node.x then 1 else 0)) elseif node.dy == 0 then (if node.dx < 0 then (if y <= node.y then 0 else 1) else (if y <= node.y then 1 else 0)) else (if node.dy * dx > dy * node.dx then 0 else 1)
        local nearChild = if front == 0 then node.front else node.back
        local farChild = if front == 0 then node.back else node.front
        visit(nearChild)
        visit(farChild)
    end
    if #map.nodes == 0 then
        renderSubsector(frame, data, wad, map, zbuffer, x, y, eye, angle, 1)
    else
        visit(#map.nodes - 1)
    end
    return frame, data.palette
end

return module
