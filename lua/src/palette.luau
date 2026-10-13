--!strict
--!native
local module = {}

export type Palette = {
  rgb: buffer,
  nearest: (self: Palette, red: number, green: number, blue: number) -> number,
}

local PaletteMethods = {}
PaletteMethods.__index = PaletteMethods

function PaletteMethods:nearest(red: number, green: number, blue: number): number
  local rgb = self.rgb
  local best = 0
  local bestDistance = math.huge
  for index = 0, 255 do
    local at = index * 3
    local redOff = buffer.readu8(rgb, at) - red
    local greenOff = buffer.readu8(rgb, at + 1) - green
    local blueOff = buffer.readu8(rgb, at + 2) - blue
    local distance = redOff * redOff + greenOff * greenOff + blueOff * blueOff
    if not (distance < bestDistance) then continue end

    bestDistance = distance
    best = index
    if distance == 0 then break end
  end

  return best
end

function module.fromPlaypal(playpal: buffer, index: number?): Palette
  local which = index or 0
  local at = which * 768
  if at < 0 or at + 768 > buffer.len(playpal) then error('palette: PLAYPAL index out of range', 2) end

  local rgb = buffer.create(768)
  buffer.copy(rgb, 0, playpal, at, 768)
  return setmetatable({ rgb = rgb }, PaletteMethods) :: any
end

function module.toPpm(indexed: buffer, width: number, height: number, palette: Palette): buffer
  if buffer.len(indexed) < width * height then error('palette: framebuffer is too small', 2) end

  local header = `P6\n{width} {height}\n255\n`
  local out = buffer.create(#header + width * height * 3)
  buffer.writestring(out, 0, header)

  local rgb = palette.rgb
  local offset = #header
  for index = 0, width * height - 1 do
    local color = buffer.readu8(indexed, index) * 3
    buffer.writeu8(out, offset, buffer.readu8(rgb, color))
    buffer.writeu8(out, offset + 1, buffer.readu8(rgb, color + 1))
    buffer.writeu8(out, offset + 2, buffer.readu8(rgb, color + 2))
    offset += 3
  end

  return out
end

return module
