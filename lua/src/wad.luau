--!strict
-- DOOM WAD directory/lump reader.  All offsets and sizes are the original
-- little-endian on-disk representation; no preprocessing or extraction.

local fs = require("@jess/fs")
local bytes = require("@dream/bytes")

export type Lump = {
    index: number,
    name: string,
    offset: number,
    size: number,
}

export type Wad = {
    path: string,
    kind: string,
    data: buffer,
    lumps: {Lump},
    byName: {[string]: {Lump}},
    find: (self: Wad, name: string, fromIndex: number?) -> Lump?,
    all: (self: Wad, name: string) -> {Lump},
    read: (self: Wad, lump: Lump | string, fromIndex: number?) -> buffer,
    markerRange: (self: Wad, marker: string) -> (number, number),
    mapLump: (self: Wad, marker: string, name: string) -> Lump,
}

local WadMethods = {}
WadMethods.__index = WadMethods

local function cleanName(data: buffer, offset: number): string
    local raw = buffer.readstring(data, offset, 8)
    local zero = string.find(raw, "\0", 1, true)
    if zero then raw = string.sub(raw, 1, zero - 1) end
    return string.upper(raw)
end

function WadMethods:find(name: string, fromIndex: number?): Lump?
    local upper = string.upper(name)
    local list = self.byName[upper]
    if not list then return nil end
    if fromIndex == nil then return list[#list] end
    for _, lump in list do
        if lump.index >= fromIndex then return lump end
    end
    return nil
end

function WadMethods:all(name: string): {Lump}
    return self.byName[string.upper(name)] or {}
end

function WadMethods:read(which: Lump | string, fromIndex: number?): buffer
    local lump: Lump?
    if type(which) == "string" then
        lump = self:find(which, fromIndex)
        if not lump then error(`wad: lump '{which}' not found`, 2) end
    else
        lump = which
    end
    return bytes.slice(self.data, lump.offset, lump.size)
end

function WadMethods:markerRange(marker: string): (number, number)
    local lump = self:find(marker)
    if not lump then error(`wad: map marker '{marker}' not found`, 2) end
    local start = lump.index + 1
    local finish = #self.lumps
    for i = start, #self.lumps do
        local e = self.lumps[i]
        if e.size == 0 and (string.match(e.name, "^E%dM%d$") or string.match(e.name, "^MAP%d%d$")) then
            finish = i - 1
            break
        end
    end
    return start, finish
end

function WadMethods:mapLump(marker: string, name: string): Lump
    local start, finish = self:markerRange(marker)
    local upper = string.upper(name)
    for i = start, finish do
        local lump = self.lumps[i]
        if lump.name == upper then return lump end
    end
    error(`wad: map '{marker}' has no {name} lump`, 2)
end

local module = {}

function module.open(path: string): Wad
    local data = fs.readBuffer(path)
    if not data then error(`wad: cannot read '{path}'`, 2) end
    if buffer.len(data) < 12 then error("wad: header is truncated", 2) end

    local kind = buffer.readstring(data, 0, 4)
    if kind ~= "IWAD" and kind ~= "PWAD" then
        error(`wad: bad magic '{kind}'`, 2)
    end

    local count = buffer.readi32(data, 4)
    local directory = buffer.readi32(data, 8)
    if count < 0 or directory < 0 or directory + count * 16 > buffer.len(data) then
        error("wad: invalid directory bounds", 2)
    end

    local lumps: {Lump} = table.create(count)
    local byName: {[string]: {Lump}} = {}
    for i = 1, count do
        local at = directory + (i - 1) * 16
        local offset = buffer.readi32(data, at)
        local size = buffer.readi32(data, at + 4)
        if offset < 0 or size < 0 or offset + size > buffer.len(data) then
            error(`wad: lump {i} is outside the file`, 2)
        end
        local name = cleanName(data, at + 8)
        local lump: Lump = { index = i, name = name, offset = offset, size = size }
        lumps[i] = lump
        local list = byName[name]
        if not list then
            list = {}
            byName[name] = list
        end
        table.insert(list, lump)
    end

    return setmetatable({ path = path, kind = kind, data = data, lumps = lumps, byName = byName }, WadMethods) :: any
end

return module
