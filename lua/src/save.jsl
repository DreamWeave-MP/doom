--!strict
-- Stable save/load envelope for canonical snapshot records. It is intentionally
-- byte-oriented; callers can persist the returned buffer through their own FS.
local state = require './state'
local module = {}

local Magic = 'DSAV\1'
local HashSize = 16 -- lower-case hexadecimal FNV-1a-64

local function fail(message: string): never
    error(message, 2)
end

local function u32(value: number): string
    return string.char(
        value % 0x100,
        math.floor(value / 0x100) % 0x100,
        math.floor(value / 0x10000) % 0x100,
        math.floor(value / 0x1000000) % 0x100
    )
end

local function readU32(data: buffer, at: number): number
    return buffer.readu8(data, at)
        + buffer.readu8(data, at + 1) * 0x100
        + buffer.readu8(data, at + 2) * 0x10000
        + buffer.readu8(data, at + 3) * 0x1000000
end

function module.save(record: any): buffer
    local payload = state.encode(record)
    local length = buffer.len(payload)
    local hash = state.fnv1a64(payload)
    local result = buffer.create(#Magic + 4 + HashSize + length)
    buffer.writestring(result, 0, Magic)
    buffer.writestring(result, #Magic, u32(length))
    buffer.writestring(result, #Magic + 4, hash)
    buffer.copy(result, #Magic + 4 + HashSize, payload, 0, length)
    return result
end

module.encode = module.save

function module.load(data: buffer): any
    local headerSize = #Magic + 4 + HashSize
    local length = buffer.len(data)
    if length < headerSize then
        fail('save: truncated header')
    end

    if buffer.readstring(data, 0, #Magic) ~= Magic then
        fail('save: bad header')
    end

    local payloadLength = readU32(data, #Magic)
    if payloadLength ~= length - headerSize then
        fail('save: invalid payload length')
    end
    local expected = buffer.readstring(data, #Magic + 4, HashSize)
    local payload = buffer.create(payloadLength)
    buffer.copy(payload, 0, data, headerSize, payloadLength)
    local actual = state.fnv1a64(payload)
    if actual ~= expected then
        fail('save: snapshot hash mismatch')
    end

    return state.decode(payload)
end

module.decode = module.load

function module.hash(record: any): string
    return state.hash(record)
end

return module
