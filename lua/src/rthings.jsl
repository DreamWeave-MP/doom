--!strict
-- Doom thing and masked-patch rendering.  This is deliberately independent of
-- rmain: the caller owns the framebuffer and z buffer, so sprites can be added
-- after the wall pass without introducing renderer globals.
local patchModule = require("./patch")
local rdataModule = require("./rdata")
local mapModule = require("@doom/map")

local module = {}

export type Frame = { pixels: buffer, width: number, height: number }
export type View = {
    x: number,
    y: number,
    angle: number,
    z: number?,
    fixed: boolean?,
    angleRadians: boolean?,
    angleUnits: string?,
    focal: number?,
    centerX: number?,
    centerY: number?,
}
export type Options = {
    fixedObjects: boolean?,
    near: number?,
    light: number?,
    sky: boolean?,
    overwriteSky: boolean?,
}
export type Result = {
    drawn: number,
    skipped: number,
    skyPixels: number,
}

type Patch = {
    data: buffer,
    width: number,
    height: number,
    left: number,
    top: number,
}
type Slot = { name: string, flip: boolean }
type SpriteFrame = { slots: { [number]: Slot } }
type SpriteDef = { frames: { [string]: SpriteFrame } }
type SpriteIndex = { defs: { [string]: SpriteDef } }
type Post = { top: number, length: number, pixels: number }
type Projected = {
    object: any,
    patch: Patch,
    flip: boolean,
    depth: number,
    originX: number,
    topY: number,
    scale: number,
    light: number,
    fullbright: boolean,
    id: number,
}

local FIXED = 65536
local ANGLE_MAX = 4294967296
local PI2 = math.pi * 2
local NEAR = 0.01
local SKY_ROTATIONS = 4

-- These are only defaults for the small gameplay container.  A host can supply
-- data.mobjInfo or object.sprite/object.frame for a complete mobjinfo table.
local DEFAULT_SPRITES: { [number]: string } = {
    [1] = "PLAY",
    [64] = "VILE",
    [65] = "CPOS",
    [66] = "SKEL",
    [67] = "FATT",
    [68] = "BSPI",
    [69] = "BOS2",
    [71] = "SPID",
    [84] = "SSWV",
    [88] = "BSPI",
    [3001] = "TROO",
    [3002] = "SARG",
    [3003] = "BOSS",
    [3004] = "POSS",
    [3005] = "HEAD",
    [3006] = "SKUL",
    [3007] = "SPID",
}

local function normalAngle(angle: number): number
    angle %= PI2
    return if angle < 0 then angle + PI2 else angle
end

local function viewAngle(view: View): number
    if view.angleRadians then return normalAngle(view.angle) end
    if view.angleUnits == "doom" then return normalAngle(view.angle * PI2 / ANGLE_MAX) end
    return normalAngle(math.rad(view.angle))
end

local function objectAngle(object: any): number
    if type(object.angleRadians) == "number" then return normalAngle(object.angleRadians) end
    if type(object.angleDegrees) == "number" then return normalAngle(math.rad(object.angleDegrees)) end
    return normalAngle((object.angle or 0) * PI2 / ANGLE_MAX)
end

local function objectCoordinate(value: number, options: Options?): number
    if options and options.fixedObjects == false then return value end
    return value / FIXED
end

local function makeSlot(value: any, defaultFlip: boolean?): Slot?
    if type(value) == "string" then return { name = string.upper(value), flip = defaultFlip or false } end
    if type(value) ~= "table" then return nil end
    local name = value.name or value.patch or value.lump
    if type(name) ~= "string" then return nil end
    return { name = string.upper(name), flip = if type(value.flip) == "boolean" then value.flip else (defaultFlip or false) }
end

local function addLump(defs: { [string]: SpriteDef }, lumpName: string): ()
    local prefix, frame, rotation, flippedFrame, flippedRotation = string.match(
        string.upper(lumpName),
        "^([A-Z0-9_][A-Z0-9_][A-Z0-9_][A-Z0-9_])([A-Z])([0-8])([A-Z]?)([0-8]?)$"
    )
    if not prefix or not frame or not rotation then return end
    local definition = defs[prefix]
    if not definition then
        definition = { frames = {} }
        defs[prefix] = definition
    end
    local spriteFrame = definition.frames[frame]
    if not spriteFrame then
        spriteFrame = { slots = {} }
        definition.frames[frame] = spriteFrame
    end
    local firstRotation = tonumber(rotation)
    if not firstRotation then return end
    if firstRotation == 0 then
        spriteFrame.slots[0] = { name = string.upper(lumpName), flip = false }
    else
        spriteFrame.slots[firstRotation] = { name = string.upper(lumpName), flip = false }
    end
    if flippedFrame ~= "" and flippedRotation ~= "" then
        local secondRotation = tonumber(flippedRotation)
        if secondRotation then
            local secondFrame = definition.frames[flippedFrame]
            if not secondFrame then
                secondFrame = { slots = {} }
                definition.frames[flippedFrame] = secondFrame
            end
            secondFrame.slots[secondRotation] = { name = string.upper(lumpName), flip = true }
        end
    end
end

local function spriteIndex(data: any): SpriteIndex
    local defs: { [string]: SpriteDef } = {}
    local wad = data.wad or data.source
    if wad and wad.lumps then
        for _, lump in wad.lumps do addLump(defs, lump.name) end
    end

    -- A raw sprite patch map is useful to callers that do not want rthings to
    -- retain a WAD.  Sort its names because table iteration order is not part
    -- of the deterministic Luau contract.
    local patchMap = data.spritePatches or data.patches
    if type(patchMap) == "table" then
        local names: { string } = {}
        for name, _ in patchMap do
            if type(name) == "string" then table.insert(names, name) end
        end
        table.sort(names)
        for _, name in names do addLump(defs, name) end
    end
    return { defs = defs }
end

local function explicitSlot(data: any, sprite: string, frame: string, rotation: number): Slot?
    local definitions = data.spriteDefs
    if type(definitions) ~= "table" then return nil end
    local definition = definitions[sprite]
    if type(definition) ~= "table" then return nil end
    local frames = definition.frames or definition
    local spriteFrame = frames[frame]
    if type(spriteFrame) ~= "table" then return nil end
    local slots = spriteFrame.slots or spriteFrame.lumps or spriteFrame
    local slot = makeSlot(slots[rotation + 1])
    if slot then return slot end
    slot = makeSlot(slots[rotation])
    if slot then return slot end
    return makeSlot(slots[0])
end

local function indexedSlot(index: SpriteIndex, sprite: string, frame: string, rotation: number): Slot?
    local definition = index.defs[sprite]
    if not definition then return nil end
    local spriteFrame = definition.frames[frame]
    if not spriteFrame then return nil end
    return spriteFrame.slots[rotation + 1] or spriteFrame.slots[0]
end

local function spriteNameAndFrame(data: any, object: any): (string?, string?, boolean)
    local sprite: any = object.sprite or object.spriteName
    local frame: any = object.frameName
    local fullbright = object.fullbright == true
    local info: any
    if type(data.mobjInfo) == "table" then info = data.mobjInfo[object.kind] end
    if type(info) ~= "table" and type(data.spriteByKind) == "table" then
        local value = data.spriteByKind[object.kind]
        info = if type(value) == "table" then value else nil
        if type(value) == "string" then sprite = value end
    end
    if type(info) == "table" then
        sprite = sprite or info.sprite
        if not frame then frame = info.frame end
        if info.fullbright == true then fullbright = true end
    end
    if type(sprite) ~= "string" then sprite = DEFAULT_SPRITES[object.kind] end
    if type(frame) == "number" then
        fullbright = fullbright or bit32.band(frame, 0x8000) ~= 0
        frame = string.char(65 + bit32.band(frame, 0x1f))
    elseif type(frame) ~= "string" then
        frame = "A"
    end
    if type(sprite) ~= "string" then return nil, nil, fullbright end
    return string.upper(sprite), string.upper(frame), fullbright
end

local function patchSource(data: any, name: string): Patch?
    local patchMap = data.spritePatches or data.patches
    local source: any = if type(patchMap) == "table" then patchMap[name] else nil
    local wad = data.wad or data.source
    if source == nil and wad and wad.find and wad.read then
        local lump = wad:find(name)
        if lump then source = wad:read(lump) end
    end
    if source == nil then return nil end
    if type(source) == "buffer" then return patchModule.open(source) end
    if type(source) == "table" and type(source.data) == "buffer" then
        return source :: Patch
    end
    return nil
end

local function postsForColumn(patch: Patch, sourceX: number): { Post }
    local posts: { Post } = {}
    if sourceX < 0 or sourceX >= patch.width then return posts end
    local data = patch.data
    local at = buffer.readu32(data, 8 + sourceX * 4)
    if at < 8 or at >= buffer.len(data) then error("rthings: invalid patch column offset", 2) end
    while true do
        if at >= buffer.len(data) then error("rthings: unterminated patch column", 2) end
        local top = buffer.readu8(data, at)
        at += 1
        if top == 255 then break end
        if at + 2 > buffer.len(data) then error("rthings: truncated patch post", 2) end
        local length = buffer.readu8(data, at)
        at += 2
        if at + length + 1 > buffer.len(data) then error("rthings: truncated patch pixels", 2) end
        table.insert(posts, { top = top, length = length, pixels = at })
        at += length + 1
    end
    return posts
end

local function samplePost(patch: Patch, posts: { Post }, sourceY: number): number?
    for _, post in posts do
        if sourceY >= post.top and sourceY < post.top + post.length then
            return buffer.readu8(patch.data, post.pixels + sourceY - post.top)
        end
    end
    return nil
end

local function lit(data: any, color: number, light: number, distance: number, fullbright: boolean): number
    if fullbright or type(data.colormap) ~= "buffer" then return color end
    return rdataModule.light(data, color, light, distance)
end

type Bounds = { minX: number, maxX: number, minY: number, maxY: number }

-- The box around a map's vertices. One render asks for it once, however many things it lights.
local function mapBounds(map: mapModule.Map): Bounds
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for _, vertex in map.vertices do
        minX, maxX = math.min(minX, vertex.x), math.max(maxX, vertex.x)
        minY, maxY = math.min(minY, vertex.y), math.max(maxY, vertex.y)
    end

    return { minX = minX, maxX = maxX, minY = minY, maxY = maxY }
end

local function sectorLight(map: any, bounds: Bounds, east: number, north: number): number
    if bounds.minX == math.huge then return 160 end
    if east < bounds.minX or east > bounds.maxX or north < bounds.minY or north > bounds.maxY then return 160 end

    local sector = mapModule.sectorAt(map, east, north)
    if type(sector) == "table" and type(sector.light) == "number" then return sector.light end
    return 160
end

local function drawProjected(frame: Frame, zbuffer: { number }, data: any, projected: Projected): number
    local patch = projected.patch
    local firstX = math.max(0, math.floor(projected.originX))
    local lastX = math.min(frame.width - 1, math.ceil(projected.originX + patch.width * projected.scale) - 1)
    if firstX > lastX then return 0 end
    local drawn = 0
    local columns: { [number]: { Post } } = {}
    for x = firstX, lastX do
        local sourceX = math.floor((x + 0.5 - projected.originX) / projected.scale)
        if projected.flip then sourceX = patch.width - 1 - sourceX end
        if sourceX >= 0 and sourceX < patch.width then
            local posts = columns[sourceX]
            if not posts then
                posts = postsForColumn(patch, sourceX)
                columns[sourceX] = posts
            end
            if #posts > 0 then
                local firstY = math.max(0, math.floor(projected.topY))
                local lastY = math.min(frame.height - 1, math.ceil(projected.topY + patch.height * projected.scale) - 1)
                for y = firstY, lastY do
                    local sourceY = math.floor((y + 0.5 - projected.topY) / projected.scale)
                    if sourceY >= 0 and sourceY < patch.height then
                        local color = samplePost(patch, posts, sourceY)
                        local offset = y * frame.width + x
                        local oldDepth = zbuffer[offset + 1] or math.huge
                        if color ~= nil and projected.depth < oldDepth then
                            buffer.writeu8(frame.pixels, offset, lit(
                                data, color, projected.light, projected.depth, projected.fullbright
                            ))
                            zbuffer[offset + 1] = projected.depth
                            drawn += 1
                        end
                    end
                end
            end
        end
    end
    return drawn
end

-- The data argument is intentionally any here.  rdata.Data predates sprite
-- loading and hosts can attach `wad`, `spritePatches`, `spriteDefs`, or
-- `mobjInfo` without changing that immutable renderer-data interface.
function module.render(
    map: any,
    mobjs: { any },
    data: any,
    frame: Frame,
    view: View,
    zbuffer: { number },
    options: Options?
): Result
    local count = frame.width * frame.height
    if buffer.len(frame.pixels) < count then error("rthings: framebuffer is too small", 2) end
    if #zbuffer < count then error("rthings: zbuffer is too small", 2) end
    local settings = options or {}
    local angle = viewAngle(view)
    local viewX, viewY = view.x, view.y
    local viewZ = view.z or 41
    if view.fixed then viewX, viewY, viewZ = viewX / FIXED, viewY / FIXED, viewZ / FIXED end
    local centerX = view.centerX or frame.width * 0.5
    local centerY = view.centerY or frame.height * 0.5
    local focal = view.focal or frame.width * 0.5
    local near = settings.near or NEAR
    if focal <= 0 then error("rthings: focal length must be positive", 2) end

    local index = spriteIndex(data)
    local bounds: Bounds? = nil
    local projected: { Projected } = {}
    for order, object in mobjs do
        if not object.removed then
            local sprite, frameName, fullbright = spriteNameAndFrame(data, object)
            if sprite and frameName then
                local dx = objectCoordinate(object.x, settings) - viewX
                local dy = objectCoordinate(object.y, settings) - viewY
                local cosAngle, sinAngle = math.cos(angle), math.sin(angle)
                local depth = dx * cosAngle + dy * sinAngle
                if depth > near then
                    local right = -dx * sinAngle + dy * cosAngle
                    local definitionRotation = normalAngle(math.atan(viewY - objectCoordinate(object.y, settings), viewX - objectCoordinate(object.x, settings)) - objectAngle(object))
                    local rotation = math.floor((definitionRotation + math.pi / 8) / (math.pi / 4)) % 8
                    local slot = explicitSlot(data, sprite, frameName, rotation) or indexedSlot(index, sprite, frameName, rotation)
                    if slot then
                        local patch = patchSource(data, slot.name)
                        if patch then
                            local scale = focal / depth
                            local objectZ = objectCoordinate(object.z or 0, settings)
                            local originX = centerX + (right - patch.left) * scale
                            local topY = centerY - (objectZ + patch.top - viewZ) * scale
                            local edgeRight = originX + patch.width * scale
                            if edgeRight >= 0 and originX < frame.width then
                                local light = if type(object.light) == 'number' then object.light else settings.light
                                if not light then
                                    local east, north = objectCoordinate(object.x, settings), objectCoordinate(object.y, settings)
                                    bounds = bounds or mapBounds(map)
                                    light = sectorLight(map, bounds, east, north)
                                end

                                table.insert(projected, {
                                    object = object,
                                    patch = patch,
                                    flip = slot.flip,
                                    depth = depth,
                                    originX = originX,
                                    topY = topY,
                                    scale = scale,
                                    light = light,
                                    fullbright = fullbright,
                                    id = if type(object.id) == "number" then object.id else order,
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    -- Draw far to near for the same ordering as R_SortVisSprites.  The z test
    -- is still authoritative, which also handles overlapping masked posts.
    table.sort(projected, function(a: Projected, b: Projected): boolean
        if a.depth ~= b.depth then return a.depth > b.depth end
        return a.id < b.id
    end)
    local drawn = 0
    for _, sprite in projected do drawn += drawProjected(frame, zbuffer, data, sprite) end

    local skyPixels = 0
    if settings.sky ~= false then
        local sky: any = data.skyTexture
        if not sky and data.textures and data.textures.get then sky = data.textures:get(data.skyName or "SKY1") end
        local skyColor = data.skyColor
        if type(skyColor) ~= "number" and data.palette and data.palette.nearest then
            skyColor = data.palette:nearest(32, 32, 48)
        end
        if type(skyColor) ~= "number" then skyColor = 0 end
        for y = 0, frame.height - 1 do
            for x = 0, frame.width - 1 do
                local offset = y * frame.width + x
                if (zbuffer[offset + 1] or math.huge) == math.huge and (settings.overwriteSky or buffer.readu8(frame.pixels, offset) == 0) then
                    local color = skyColor
                    if type(sky) == "table" and type(sky.width) == "number" and type(sky.height) == "number" and type(sky.pixels) == "buffer" then
                        local ray = math.atan((x + 0.5 - centerX) / focal)
                        local u = math.floor((normalAngle(angle + ray) / PI2) * sky.width * SKY_ROTATIONS) % sky.width
                        local v = math.floor(y * sky.height / frame.height)
                        local skyOffset = v * sky.width + u
                        if type(sky.opaque) ~= "buffer" or buffer.readu8(sky.opaque, skyOffset) ~= 0 then
                            color = buffer.readu8(sky.pixels, skyOffset)
                        end
                    end
                    buffer.writeu8(frame.pixels, offset, color)
                    skyPixels += 1
                end
            end
        end
    end
    return { drawn = drawn, skipped = #mobjs - #projected, skyPixels = skyPixels }
end

-- Explicit-coordinate convenience form for the existing rmain call style.
function module.renderAt(
    map: any,
    mobjs: { any },
    data: any,
    frame: Frame,
    x: number,
    y: number,
    angle: number,
    zbuffer: { number },
    options: Options?
): Result
    return module.render(map, mobjs, data, frame, { x = x, y = y, angle = angle }, zbuffer, options)
end

module.draw = module.render
module.drawSprites = module.render
module.renderSprites = module.render

return module
