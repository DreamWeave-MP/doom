--!strict
--!native
-- Classic DOOM PNAMES/TEXTURE1/TEXTURE2 compositor.
local module = {}

export type Texture = { name: string, width: number, height: number, pixels: buffer, opaque: buffer }
export type Bank = { textures: { [string]: Texture }, get: (self: Bank, name: string) -> Texture? }

local BankMethods = {}
BankMethods.__index = BankMethods

function BankMethods:get(name: string): Texture?
  return self.textures[string.upper(name)]
end

local function name8(data: buffer, at: number): string
  local text = buffer.readstring(data, at, 8)
  local zero = string.find(text, '\0', 1, true)
  if zero then text = string.sub(text, 1, zero - 1) end

  return string.upper(text)
end

local function patchNames(wad: any): { string }
  local data = wad:read('PNAMES')
  if buffer.len(data) < 4 then error('texture: truncated PNAMES', 2) end

  local count = buffer.readi32(data, 0)
  if count < 0 or count > math.floor((buffer.len(data) - 4) / 8) then error('texture: invalid PNAMES', 2) end

  local result = table.create(count)
  for index = 0, count - 1 do
    result[index + 1] = name8(data, 4 + index * 8)
  end

  return result
end

local function blitPatch(wad: any, patchName: string, target: Texture, originX: number, originY: number)
  local lump = wad:find(patchName)
  if not lump then error(`texture: missing patch '{patchName}'`, 2) end

  local data = wad:read(lump)
  local length = buffer.len(data)
  if length < 8 then error(`texture: patch '{patchName}' is truncated`, 2) end

  local width, height = buffer.readi16(data, 0), buffer.readi16(data, 2)
  if width <= 0 or height <= 0 or width > math.floor((length - 8) / 4) then
    error(`texture: patch '{patchName}' has invalid dimensions`, 2)
  end

  for column = 0, width - 1 do
    local targetColumn, at = originX + column, buffer.readu32(data, 8 + column * 4)
    if at < 8 or at >= length then error(`texture: patch '{patchName}' has an invalid column offset`, 2) end

    local ended = false
    while at < length do
      local top = buffer.readu8(data, at)
      at += 1
      if top == 255 then
        ended = true
        break
      end

      if at + 2 > length then error(`texture: patch '{patchName}' has a truncated post`, 2) end

      local count = buffer.readu8(data, at)
      at += 2
      if at + count + 1 > length then error(`texture: patch '{patchName}' has truncated pixels`, 2) end

      if targetColumn >= 0 and targetColumn < target.width then
        for row = 0, count - 1 do
          local targetRow = originY + top + row
          if targetRow < 0 or targetRow >= target.height then continue end

          local offset = targetRow * target.width + targetColumn
          buffer.writeu8(target.pixels, offset, buffer.readu8(data, at + row))
          buffer.writeu8(target.opaque, offset, 1)
        end
      end

      at += count + 1
    end

    if not ended then error(`texture: patch '{patchName}' has an unterminated column`, 2) end
  end
end

local function parseTextureLump(wad: any, data: buffer, pnames: { string }, textures: { [string]: Texture })
  local length = buffer.len(data)
  if length < 4 then error('texture: truncated TEXTURE lump', 2) end

  local count = buffer.readi32(data, 0)
  if count < 0 or count > math.floor((length - 4) / 4) then error('texture: invalid TEXTURE directory', 2) end

  local directoryEnd = 4 + count * 4
  for index = 0, count - 1 do
    local at = buffer.readi32(data, 4 + index * 4)
    if at < directoryEnd or at > length - 22 then error('texture: invalid texture offset', 2) end

    local width, height, patchCount =
      buffer.readi16(data, at + 12), buffer.readi16(data, at + 14), buffer.readi16(data, at + 20)
    if width <= 0 or height <= 0 or patchCount < 0 or patchCount > math.floor((length - at - 22) / 10) then
      error(`texture: invalid texture record {index + 1}`, 2)
    end

    local name = name8(data, at)
    local texture: Texture = {
      name = name,
      width = width,
      height = height,
      pixels = buffer.create(width * height),
      opaque = buffer.create(width * height),
    }

    for patch = 0, patchCount - 1 do
      local entry = at + 22 + patch * 10
      local patchName = pnames[buffer.readu16(data, entry + 4) + 1]
      if not patchName then error(`texture: texture '{name}' references missing PNAMES entry`, 2) end

      blitPatch(wad, patchName, texture, buffer.readi16(data, entry), buffer.readi16(data, entry + 2))
    end

    textures[name] = texture
  end
end

function module.load(wad: any): Bank
  local pnames = patchNames(wad)
  local textures: { [string]: Texture } = {}
  local one, two = wad:find('TEXTURE1'), wad:find('TEXTURE2')
  if one then parseTextureLump(wad, wad:read(one), pnames, textures) end
  if two then parseTextureLump(wad, wad:read(two), pnames, textures) end

  return setmetatable({ textures = textures }, BankMethods) :: any
end

return module
