--!strict
-- A deliberately small headless player-motion harness. It is useful for scripted
-- integration tests before the full P_* gameplay port exists; it does not claim demo sync.
local module = {}

export type Player = { x: number, y: number, angle: number, momX: number, momY: number }

local function signedByte(v: number): number
    return if v >= 128 then v - 256 else v
end

local function pointSegmentDistanceSquared(px: number, py: number, ax: number, ay: number, bx: number, by: number): number
    local dx, dy = bx - ax, by - ay
    local denom = dx * dx + dy * dy
    if denom == 0 then
        local x, y = px - ax, py - ay
        return x * x + y * y
    end
    local t = ((px - ax) * dx + (py - ay) * dy) / denom
    t = math.clamp(t, 0, 1)
    local qx, qy = ax + t * dx, ay + t * dy
    local x, y = px - qx, py - qy
    return x * x + y * y
end

local function blocked(map: any, x: number, y: number, radius: number): boolean
    local r2 = radius * radius
    for _, l in map.lines do
        -- One-sided lines and explicitly blocking lines are solid for this harness.
        if l.left == 65535 or bit32.band(l.flags, 1) ~= 0 then
            local a, b = map.vertices[l.v1], map.vertices[l.v2]
            if pointSegmentDistanceSquared(x, y, a.x, a.y, b.x, b.y) < r2 then return true end
        end
    end
    return false
end

function module.new(map: any): Player
    local start = require("@doom/map").playerStart(map, 1)
    return { x = start.x, y = start.y, angle = start.angle, momX = 0, momY = 0 }
end

function module.tic(map: any, p: Player, forward: number, side: number, turnByte: number): ()
    -- Demo angle byte corresponds to the high byte of signed angleturn: 360/256 degrees.
    p.angle = (p.angle + signedByte(turnByte) * (360 / 256)) % 360
    local rad = math.rad(p.angle)
    local sideRad = rad - math.pi * 0.5
    -- Preserve the character of DOOM acceleration/friction without claiming exact fixed-point sync.
    p.momX += math.cos(rad) * forward * 0.085 + math.cos(sideRad) * side * 0.085
    p.momY += math.sin(rad) * forward * 0.085 + math.sin(sideRad) * side * 0.085
    local nx, ny = p.x + p.momX, p.y + p.momY
    if not blocked(map, nx, p.y, 16) then p.x = nx else p.momX = 0 end
    if not blocked(map, p.x, ny, 16) then p.y = ny else p.momY = 0 end
    p.momX *= 0.90625
    p.momY *= 0.90625
end

return module
