--!strict
-- Fixed-point player movement and deterministic, conservative linedef collision.
local mobj = require './mobj'
local module = {}

local fixedModule: any = nil
local angleModule: any = nil
local mapModule: any = nil
local ok, value = pcall(require, '@doom/fixed')
if ok then fixedModule = value end
ok, value = pcall(require, '@doom/angle')
if ok then angleModule = value end
ok, value = pcall(require, '@doom/map')
if ok then mapModule = value end

module.FRACUNIT = mobj.FRACUNIT
module.FRICTION = 0xe800
module.STOPSPEED = 0x1000
module.MAXMOVE = 30 * module.FRACUNIT
module.PLAYER_RADIUS = 16 * module.FRACUNIT
module.PLAYER_HEIGHT = 56 * module.FRACUNIT
module.MAX_STEP = 24 * module.FRACUNIT

local function trunc(value: number): number
    return if value < 0 then math.ceil(value) else math.floor(value)
end

function module.fixedMul(a: number, b: number): number
    if fixedModule then
        local f = fixedModule.fixedMul or fixedModule.mul
        if type(f) == 'function' then
            local worked, result = pcall(f, a, b)
            if worked and type(result) == 'number' then return trunc(result) end
        end
    end
    return trunc(a * b / module.FRACUNIT)
end

function module.fixedDiv(a: number, b: number): number
    if b == 0 then error('physics: fixed divide by zero', 2) end
    if fixedModule then
        local f = fixedModule.fixedDiv or fixedModule.div
        if type(f) == 'function' then
            local worked, result = pcall(f, a, b)
            if worked and type(result) == 'number' then return trunc(result) end
        end
    end
    return trunc(a * module.FRACUNIT / b)
end

function module.toFixed(value: number): number
    return trunc(value * module.FRACUNIT)
end

function module.toInt(value: number): number
    return trunc(value / module.FRACUNIT)
end

local TrigSize = 4096
local Trig: {number} = table.create(TrigSize)
for i = 0, TrigSize - 1 do
    Trig[i + 1] = math.floor(math.cos(i * 2 * math.pi / TrigSize) * module.FRACUNIT + 0.5)
end

local function externalTrig(name: string, angle: number): number?
    if not angleModule then return nil end
    local f = angleModule[name]
    if type(f) ~= 'function' then return nil end
    local worked, result = pcall(f, angle)
    if not worked or type(result) ~= 'number' then return nil end
    if result >= -2 and result <= 2 then result *= module.FRACUNIT end
    return trunc(result)
end

local function trig(angle: number, offset: number): number
    local result = externalTrig(if offset == 0 then 'cosFixed' else 'sinFixed', angle)
    if result ~= nil then return result end
    result = externalTrig(if offset == 0 then 'cos' else 'sin', angle)
    if result ~= nil then return result end
    result = externalTrig(if offset == 0 then 'cosine' else 'sine', angle)
    if result ~= nil then return result end
    local index = math.floor((angle % mobj.ANGLE_MAX) * TrigSize / mobj.ANGLE_MAX + 0.5) % TrigSize
    index = (index + offset) % TrigSize
    return Trig[index + 1]
end

function module.cosFixed(angle: number): number
    return trig(angle, 0)
end

function module.sinFixed(angle: number): number
    return trig(angle, TrigSize / 4)
end

function module.thrust(object: mobj.Mobj, angle: number, amount: number): ()
    object.momx += module.fixedMul(amount, module.cosFixed(angle))
    object.momy += module.fixedMul(amount, module.sinFixed(angle))
end

local function pointSegmentDistanceSquared(px: number, py: number, ax: number, ay: number, bx: number, by: number): number
    local dx, dy = bx - ax, by - ay
    local denom = dx * dx + dy * dy
    if denom == 0 then
        local x, y = px - ax, py - ay
        return x * x + y * y
    end
    local dot = (px - ax) * dx + (py - ay) * dy
    if dot <= 0 then
        local x, y = px - ax, py - ay
        return x * x + y * y
    elseif dot >= denom then
        local x, y = px - bx, py - by
        return x * x + y * y
    end
    local qx = ax + trunc(dx * dot / denom)
    local qy = ay + trunc(dy * dot / denom)
    local x, y = px - qx, py - qy
    return x * x + y * y
end

local function segmentHit(x0: number, y0: number, x1: number, y1: number, ax: number, ay: number, bx: number, by: number, radius: number): boolean
    -- Sampling at <= radius/2 makes the swept circle conservative while keeping
    -- all calculations integer and stable.  Doom's MAXMOVE is only 30 units.
    local distance = math.max(math.abs(x1 - x0), math.abs(y1 - y0))
    local steps = math.max(1, math.ceil(distance / math.max(1, radius / 2)))
    if steps > 128 then steps = 128 end
    local r2 = radius * radius
    for step = 0, steps do
        local x = x0 + trunc((x1 - x0) * step / steps)
        local y = y0 + trunc((y1 - y0) * step / steps)
        if pointSegmentDistanceSquared(x, y, ax, ay, bx, by) <= r2 then return true end
    end
    return false
end

local function orientation(ax: number, ay: number, bx: number, by: number, cx: number, cy: number): number
    local value = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
    if value == 0 then return 0 end
    return if value < 0 then -1 else 1
end

local function onSegment(ax: number, ay: number, bx: number, by: number, px: number, py: number): boolean
    return px >= math.min(ax, bx) and px <= math.max(ax, bx)
        and py >= math.min(ay, by) and py <= math.max(ay, by)
end

local function segmentsIntersect(ax: number, ay: number, bx: number, by: number, cx: number, cy: number, dx: number, dy: number): boolean
    local first = orientation(ax, ay, bx, by, cx, cy)
    local second = orientation(ax, ay, bx, by, dx, dy)
    local third = orientation(cx, cy, dx, dy, ax, ay)
    local fourth = orientation(cx, cy, dx, dy, bx, by)
    if first ~= second and third ~= fourth then return true end
    if first == 0 and onSegment(ax, ay, bx, by, cx, cy) then return true end
    if second == 0 and onSegment(ax, ay, bx, by, dx, dy) then return true end
    if third == 0 and onSegment(cx, cy, dx, dy, ax, ay) then return true end
    return fourth == 0 and onSegment(cx, cy, dx, dy, bx, by)
end

function module.lineBlocksShot(map: any, x0: number, y0: number, x1: number, y1: number): boolean
    for _, line in map.lines do
        local a, b = map.vertices[line.v1], map.vertices[line.v2]
        if a and b and (line.left == 0xffff or bit32.band(line.flags, 1) ~= 0) then
            if segmentsIntersect(x0, y0, x1, y1, a.x * module.FRACUNIT, a.y * module.FRACUNIT, b.x * module.FRACUNIT, b.y * module.FRACUNIT) then
                return true
            end
        end
    end
    return false
end

local function sectorAt(map: any, x: number, y: number): any
    if mapModule and type(mapModule.sectorAt) == 'function' then
        local worked, sector = pcall(mapModule.sectorAt, map, module.toInt(x), module.toInt(y))
        if worked and sector then return sector end
    end
    return {floor = 0, ceiling = 128}
end

local function lineSectors(map: any, line: any): (any?, any?)
    local right = nil
    local left = nil
    if line.right ~= 0xffff and map.sides[line.right + 1] then
        right = map.sectors[map.sides[line.right + 1].sector]
    end
    if line.left ~= 0xffff and map.sides[line.left + 1] then
        left = map.sectors[map.sides[line.left + 1].sector]
    end
    return right, left
end

local function openEnough(map: any, line: any, object: mobj.Mobj, currentFloor: number): boolean
    local right, left = lineSectors(map, line)
    if not right or not left then return false end
    local bottom = math.max(right.floor, left.floor) * module.FRACUNIT
    local top = math.min(right.ceiling, left.ceiling) * module.FRACUNIT
    if top - bottom < object.height then return false end
    if bottom - currentFloor > module.MAX_STEP then return false end
    if object.z < bottom or object.z + object.height > top then return false end
    return true
end

function module.floorAndCeiling(map: any, x: number, y: number): (number, number)
    local sector = sectorAt(map, x, y)
    return sector.floor * module.FRACUNIT, sector.ceiling * module.FRACUNIT
end

function module.tryMove(map: any, object: mobj.Mobj, x: number, y: number): boolean
    if bit32.band(object.flags, mobj.MF_NOCLIP) ~= 0 then
        object.x, object.y = x, y
        object.floorz, object.ceilingz = module.floorAndCeiling(map, x, y)
        return true
    end

    local currentFloor = object.floorz
    local targetFloor, targetCeiling = module.floorAndCeiling(map, x, y)
    for _, line in map.lines do
        local a, b = map.vertices[line.v1], map.vertices[line.v2]
        if a and b then
            local ax, ay = a.x * module.FRACUNIT, a.y * module.FRACUNIT
            local bx, by = b.x * module.FRACUNIT, b.y * module.FRACUNIT
            if segmentHit(object.x, object.y, x, y, ax, ay, bx, by, object.radius) then
                local blocking = line.left == 0xffff or bit32.band(line.flags, 1) ~= 0
                if blocking or not openEnough(map, line, object, currentFloor) then
                    return false
                end
            end
        end
    end
    if targetFloor - currentFloor > module.MAX_STEP then return false end
    if targetCeiling - targetFloor < object.height then return false end
    object.x, object.y = x, y
    object.floorz, object.ceilingz = targetFloor, targetCeiling
    if object.z < targetFloor then object.z = targetFloor end
    return true
end

function module.move(map: any, object: mobj.Mobj): boolean
    local max = module.MAXMOVE
    if object.momx > max then object.momx = max elseif object.momx < -max then object.momx = -max end
    if object.momy > max then object.momy = max elseif object.momy < -max then object.momy = -max end
    if object.momx == 0 and object.momy == 0 then return true end

    local nx, ny = object.x + object.momx, object.y + object.momy
    if not module.tryMove(map, object, nx, ny) then
        -- This is the useful player subset of P_SlideMove: try each component
        -- independently, retaining the component that was not blocked.
        local movedX = module.tryMove(map, object, nx, object.y)
        if not movedX then object.momx = 0 end
        local movedY = module.tryMove(map, object, object.x, ny)
        if not movedY then object.momy = 0 end
        if not movedX and not movedY then object.momx, object.momy = 0, 0 end
    end

    if object.z <= object.floorz and bit32.band(object.flags, mobj.MF_CORPSE) == 0 then
        if math.abs(object.momx) < module.STOPSPEED and math.abs(object.momy) < module.STOPSPEED then
            object.momx, object.momy = 0, 0
        else
            object.momx = module.fixedMul(object.momx, module.FRICTION)
            object.momy = module.fixedMul(object.momy, module.FRICTION)
        end
    end
    return true
end

module.fixed_mul = module.fixedMul
module.fixed_div = module.fixedDiv
module.try_move = module.tryMove
module.line_blocks_shot = module.lineBlocksShot

return module

