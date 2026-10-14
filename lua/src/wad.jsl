--!strict
--!native
-- DOOM WAD directory/lump reader. Files are loaded in order; later lumps
-- override earlier names, matching W_InitMultipleFiles/W_CheckNumForName.
local fs = require('@jess/fs')
local bytes = require('@dream/bytes')

export type Lump = { index: number, name: string, offset: number, size: number }
export type Wad = {
  path: string,
  paths: { string },
  kind: string,
  data: buffer,
  lumps: { Lump },
  byName: { [string]: { Lump } },
  find: (self: Wad, name: string, fromIndex: number?) -> Lump?,
  all: (self: Wad, name: string) -> { Lump },
  read: (self: Wad, lump: Lump | string, fromIndex: number?) -> buffer,
  markerRange: (self: Wad, marker: string) -> (number, number),
  mapLump: (self: Wad, marker: string, name: string) -> Lump,
}

local WadMethods = {}
WadMethods.__index = WadMethods

local function cleanName(data: buffer, offset: number): string
  local raw = buffer.readstring(data, offset, 8)
  local zero = string.find(raw, '\0', 1, true)
  if zero then raw = string.sub(raw, 1, zero - 1) end

  return string.upper(raw)
end

local function parseFile(data: buffer, path: string): (string, { Lump })
  local length = buffer.len(data)
  if length < 12 then error(`wad: '{path}' header is truncated`, 2) end

  local kind = buffer.readstring(data, 0, 4)
  if kind ~= 'IWAD' and kind ~= 'PWAD' then error(`wad: '{path}' has bad magic '{kind}'`, 2) end

  local count = buffer.readi32(data, 4)
  local directory = buffer.readi32(data, 8)
  if count < 0 or directory < 12 or directory > length or count > math.floor((length - directory) / 16) then
    error(`wad: '{path}' has invalid directory bounds`, 2)
  end

  local lumps: { Lump } = table.create(count)
  for index = 1, count do
    local at = directory + (index - 1) * 16
    local offset, size = buffer.readi32(data, at), buffer.readi32(data, at + 4)
    if offset < 0 or size < 0 or offset > length or size > length - offset then
      error(`wad: '{path}' lump {index} is outside the file`, 2)
    end

    lumps[index] = { index = index, name = cleanName(data, at + 8), offset = offset, size = size }
  end

  return kind, lumps
end

function WadMethods:find(name: string, fromIndex: number?): Lump?
  local list = self.byName[string.upper(name)]
  if not list then return nil end
  if not fromIndex then return list[#list] end

  for _, lump in list do
    if lump.index >= fromIndex then return lump end
  end

  return nil
end

function WadMethods:all(name: string): { Lump }
  return self.byName[string.upper(name)] or {}
end

function WadMethods:read(which: Lump | string, fromIndex: number?): buffer
  local lump: Lump?
  if type(which) == 'string' then
    lump = self:find(which, fromIndex)
    if not lump then error(`wad: lump '{which}' not found`, 2) end
  else
    lump = which
  end

  if
    lump.offset < 0
    or lump.size < 0
    or lump.offset > buffer.len(self.data)
    or lump.size > buffer.len(self.data) - lump.offset
  then
    error(`wad: lump '{lump.name}' has invalid bounds`, 2)
  end

  return bytes.slice(self.data, lump.offset, lump.size)
end

local function isMapMarker(name: string): boolean
  return string.match(name, '^E%dM%d$') ~= nil or string.match(name, '^MAP%d%d$') ~= nil
end

function WadMethods:markerRange(marker: string): (number, number)
  local lump = self:find(marker)
  if not lump then error(`wad: map marker '{marker}' not found`, 2) end

  local start, finish = lump.index + 1, #self.lumps
  for index = start, #self.lumps do
    if self.lumps[index].size == 0 and isMapMarker(self.lumps[index].name) then
      finish = index - 1
      break
    end
  end

  return start, finish
end

function WadMethods:mapLump(marker: string, name: string): Lump
  local start, finish = self:markerRange(marker)
  local upper = string.upper(name)
  for index = finish, start, -1 do
    if self.lumps[index].name == upper then return self.lumps[index] end
  end

  error(`wad: map '{marker}' has no {name} lump`, 2)
end

local module = {}

function module.open(paths: string | { string }, overlays: { string }?): Wad
  local requested: { string } = {}
  if type(paths) == 'string' then
    table.insert(requested, paths)
    if overlays then
      for _, path in overlays do
        table.insert(requested, path)
      end
    end
  else
    if overlays then error('wad: overlays cannot follow a path list', 2) end

    for _, path in paths do
      table.insert(requested, path)
    end
  end

  if #requested == 0 then error('wad: no files supplied', 2) end

  local files: { { path: string, kind: string, data: buffer, lumps: { Lump } } } = {}
  local total = 0
  for _, path in requested do
    local data = fs.readBuffer(path)
    if not data then error(`wad: cannot read '{path}'`, 2) end

    local kind, lumps = parseFile(data, path)
    table.insert(files, { path = path, kind = kind, data = data, lumps = lumps })
    total += buffer.len(data)
  end

  -- One file is its own image; several are laid end to end in a new one.
  local combined = if #files == 1 then files[1].data else buffer.create(total)
  local lumps: { Lump } = {}
  local byName: { [string]: { Lump } } = {}
  local base = 0
  for _, file in files do
    if #files > 1 then buffer.copy(combined, base, file.data, 0, buffer.len(file.data)) end

    for _, old in file.lumps do
      local lump: Lump = { index = #lumps + 1, name = old.name, offset = base + old.offset, size = old.size }
      table.insert(lumps, lump)

      local list = byName[lump.name]
      if not list then
        list = {}
        byName[lump.name] = list
      end

      table.insert(list, lump)
    end

    base += buffer.len(file.data)
  end

  local first = files[1]
  local path = if #requested == 1 then requested[1] else table.concat(requested, ';')
  return setmetatable(
    { path = path, paths = requested, kind = first.kind, data = combined, lumps = lumps, byName = byName },
    WadMethods
  ) :: any
end

return module
