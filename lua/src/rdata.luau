--!strict
-- Renderer data preparation. This is the small Luau equivalent of R_InitData:
-- keep the WAD's palette, light tables, flats, and composited wall textures in
-- one immutable view-local object.
local paletteModule = require("@doom/palette")
local textureModule = require("@doom/texture")

local module = {}

export type Data = {
    palette: any,
    colormap: buffer,
    textures: textureModule.Bank,
}

function module.load(wad: any): Data
    local colormap = wad:read("COLORMAP")
    if buffer.len(colormap) < 256 then error("rdata: COLORMAP is truncated", 2) end
    return {
        palette = paletteModule.fromPlaypal(wad:read("PLAYPAL"), 0),
        colormap = colormap,
        textures = textureModule.load(wad),
    }
end

function module.flat(data: Data, wad: any, name: string, x: number, y: number): number?
    if name == "F_SKY1" then return nil end
    local lump = wad:find(name)
    if not lump or lump.size < 4096 then return nil end
    local xx = bit32.band(math.floor(x), 63)
    local yy = bit32.band(-math.floor(y), 63)
    return buffer.readu8(wad.data, lump.offset + yy * 64 + xx)
end

function module.light(data: Data, color: number, light: number, distance: number): number
    -- Vanilla uses a light-level table selected by projected distance. The
    -- compact table below preserves that ordering while retaining the original
    -- 32 COLORMAP levels instead of converting through RGB.
    local level = math.floor((255 - light) / 16) + math.floor(distance / 80)
    level = math.clamp(level, 0, math.floor(buffer.len(data.colormap) / 256) - 1)
    return buffer.readu8(data.colormap, level * 256 + bit32.band(color, 255))
end

return module
