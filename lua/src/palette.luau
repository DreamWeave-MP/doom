--!strict
local module = {}

export type Palette = {
    rgb: buffer,
    nearest: (self: Palette, r: number, g: number, b: number) -> number,
}

local PaletteMethods = {}
PaletteMethods.__index = PaletteMethods

function PaletteMethods:nearest(r: number, g: number, b: number): number
    local best = 0
    local bestDist = math.huge
    for i = 0, 255 do
        local p = i * 3
        local dr = buffer.readu8(self.rgb, p) - r
        local dg = buffer.readu8(self.rgb, p + 1) - g
        local db = buffer.readu8(self.rgb, p + 2) - b
        local d = dr * dr + dg * dg + db * db
        if d < bestDist then
            bestDist = d
            best = i
            if d == 0 then break end
        end
    end
    return best
end

function module.fromPlaypal(playpal: buffer, index: number?): Palette
    local which = index or 0
    local at = which * 768
    if at < 0 or at + 768 > buffer.len(playpal) then error("palette: PLAYPAL index out of range", 2) end
    local rgb = buffer.create(768)
    buffer.copy(rgb, 0, playpal, at, 768)
    return setmetatable({ rgb = rgb }, PaletteMethods) :: any
end

function module.toPpm(indexed: buffer, width: number, height: number, palette: Palette): buffer
    if buffer.len(indexed) < width * height then error("palette: framebuffer is too small", 2) end
    local header = `P6\n{width} {height}\n255\n`
    local out = buffer.create(#header + width * height * 3)
    buffer.writestring(out, 0, header)
    local o = #header
    for i = 0, width * height - 1 do
        local c = buffer.readu8(indexed, i) * 3
        buffer.writeu8(out, o, buffer.readu8(palette.rgb, c))
        buffer.writeu8(out, o + 1, buffer.readu8(palette.rgb, c + 1))
        buffer.writeu8(out, o + 2, buffer.readu8(palette.rgb, c + 2))
        o += 3
    end
    return out
end

return module
