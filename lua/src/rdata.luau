--!strict
--!native
-- Renderer data preparation. This is the small Luau equivalent of R_InitData:
-- keep the WAD's palette, light tables, flats, and composited wall textures in
-- one immutable object a view. The textures are shared by every view of a WAD.
local paletteModule = require('@doom/palette')
local textureModule = require('@doom/texture')
local wadModule = require('@doom/wad')

local module = {}

export type Data = {
  palette: any,
  colormap: buffer,
  textures: textureModule.Bank,
  wad: any,
}

-- A WAD's composited textures, kept for as long as the WAD is. Composing them is most of what
-- a view costs, a WAD never changes once it is open, and no bank leaves the renderer.
local banks = setmetatable({} :: { [wadModule.Wad]: textureModule.Bank }, { __mode = 'k' })

function module.load(wad: any): Data
  local colormap = wad:read('COLORMAP')
  if buffer.len(colormap) < 256 then error('rdata: COLORMAP is truncated', 2) end

  local palette = paletteModule.fromPlaypal(wad:read('PLAYPAL'), 0)
  local textures = banks[wad]
  if not textures then
    textures = textureModule.load(wad)
    banks[wad] = textures
  end

  return { palette = palette, colormap = colormap, textures = textures, wad = wad }
end

function module.flat(data: Data, wad: any, name: string, column: number, row: number): number?
  if name == 'F_SKY1' then return nil end

  local lump = wad:find(name)
  if not lump or lump.size < 4096 then return nil end

  local flatColumn = bit32.band(math.floor(column), 63)
  local flatRow = bit32.band(-math.floor(row), 63)
  return buffer.readu8(wad.data, lump.offset + flatRow * 64 + flatColumn)
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
