--!strict
-- Versioned, deterministic state values. This is intentionally a small binary
-- format rather than JSON: map order is canonical and IEEE-754 numbers retain
-- their exact Luau representation.
local module = {}

export type Value = nil | boolean | number | string | buffer | {[any]: Value}

local Magic = 'DSTA\1'
local MaxU32 = 0xffffffff
local MaxDepth = 128

local function fail(message: string): never
    error(message, 2)
end

local function finite(value: number): boolean
    return value == value and value ~= math.huge and value ~= -math.huge
end

local function u32(value: number): string
    if value < 0 or value > MaxU32 or value ~= math.floor(value) then
        fail('state: length is outside u32 range')
    end

    return string.char(
        value % 0x100,
        math.floor(value / 0x100) % 0x100,
        math.floor(value / 0x10000) % 0x100,
        math.floor(value / 0x1000000) % 0x100
    )
end

local function f64(value: number): string
    local bytes = buffer.create(8)
    buffer.writef64(bytes, 0, value)
    return buffer.tostring(bytes)
end

local function encodedLength(value: string): string
    return u32(#value) .. value
end

local function scalarKey(value: any): boolean
    local kind = type(value)
    return kind == 'boolean' or kind == 'number' or kind == 'string'
end

local function encodeValue(value: any, active: {[any]: boolean}, depth: number): string
    if depth > MaxDepth then
        fail('state: maximum nesting depth exceeded')
    end

    local kind = type(value)
    if value == nil then
        return '\0'
    elseif kind == 'boolean' then
        return if value then '\2' else '\1'
    elseif kind == 'number' then
        if not finite(value) then
            fail('state: non-finite number is not canonical')
        end
        return '\3' .. f64(value)
    elseif kind == 'string' then
        return '\4' .. encodedLength(value)
    elseif kind == 'buffer' then
        return '\7' .. encodedLength(buffer.tostring(value))
    elseif kind ~= 'table' then
        fail(`state: unsupported value type '{kind}'`)
    end

    if active[value] then
        fail('state: cyclic table is not canonical')
    end
    active[value] = true

    -- A contiguous 1-based table is an array. Empty tables use the array form;
    -- maps with no entries therefore have one canonical representation.
    local count = 0
    while rawget(value, count + 1) ~= nil do
        count += 1
    end
    local sequence = true
    for key in value do
        if type(key) ~= 'number' or key ~= math.floor(key) or key < 1 or key > count then
            sequence = false
            break
        end
    end

    local result: string
    if sequence then
        local parts: {string} = {'\5', u32(count)}
        for index = 1, count do
            table.insert(parts, encodeValue(value[index], active, depth + 1))
        end
        result = table.concat(parts)
    else
        local entries: {{key: string, value: string}} = {}
        local size = 0
        for key, item in value do
            if not scalarKey(key) then
                active[value] = nil
                fail('state: map keys must be boolean, number, or string')
            end
            local keyBytes = encodeValue(key, active, depth + 1)
            table.insert(entries, {key = keyBytes, value = encodeValue(item, active, depth + 1)})
            size += 1
        end

        table.sort(entries, function(left, right): boolean
            return left.key < right.key
        end)

        local parts: {string} = {'\6', u32(size)}
        for _, entry in entries do
            table.insert(parts, entry.key)
            table.insert(parts, entry.value)
        end
        result = table.concat(parts)
    end

    active[value] = nil
    return result
end

function module.encode(value: any): buffer
    local body = encodeValue(value, {}, 0)
    return buffer.fromstring(Magic .. body)
end

module.canonical = module.encode
module.encodeCanonical = module.encode

type Reader = {data: buffer, at: number, length: number}

local function need(reader: Reader, size: number, what: string)
    if size < 0 or reader.at + size > reader.length then
        fail(`state: truncated {what}`)
    end
end

local function byte(reader: Reader, what: string): number
    need(reader, 1, what)
    local value = buffer.readu8(reader.data, reader.at)
    reader.at += 1
    return value
end

local function readU32(reader: Reader, what: string): number
    need(reader, 4, what)
    local at = reader.at
    local value = buffer.readu8(reader.data, at)
        + buffer.readu8(reader.data, at + 1) * 0x100
        + buffer.readu8(reader.data, at + 2) * 0x10000
        + buffer.readu8(reader.data, at + 3) * 0x1000000
    reader.at += 4
    return value
end

local function readString(reader: Reader, what: string): string
    local length = readU32(reader, `{what} length`)
    need(reader, length, what)
    local value = buffer.readstring(reader.data, reader.at, length)
    reader.at += length
    return value
end

local function decodeValue(reader: Reader, depth: number): any
    if depth > MaxDepth then
        fail('state: maximum nesting depth exceeded')
    end

    local tag = byte(reader, 'value tag')
    if tag == 0 then
        return nil
    elseif tag == 1 then
        return false
    elseif tag == 2 then
        return true
    elseif tag == 3 then
        need(reader, 8, 'number')
        local value = buffer.readf64(reader.data, reader.at)
        reader.at += 8
        if not finite(value) then
            fail('state: non-finite number in snapshot')
        end
        return value
    elseif tag == 4 then
        return readString(reader, 'string')
    elseif tag == 7 then
        return buffer.fromstring(readString(reader, 'buffer'))
    elseif tag == 5 then
        local count = readU32(reader, 'array count')
        if count > reader.length - reader.at then
            fail('state: impossible array count')
        end
        local result: {any} = {}
        for index = 1, count do
            result[index] = decodeValue(reader, depth + 1)
        end
        return result
    elseif tag == 6 then
        local count = readU32(reader, 'map count')
        if count > reader.length - reader.at then
            fail('state: impossible map count')
        end
        local result: {[any]: any} = {}
        local keys: {[any]: boolean} = {}
        for _ = 1, count do
            local key = decodeValue(reader, depth + 1)
            if not scalarKey(key) then
                fail('state: map key is not scalar')
            end

            if keys[key] then
                fail('state: duplicate map key')
            end
            keys[key] = true
            result[key] = decodeValue(reader, depth + 1)
        end
        return result
    end

    fail(`state: unknown value tag {tag}`)
end

function module.decode(data: buffer): any
    local length = buffer.len(data)
    if length < #Magic or buffer.readstring(data, 0, #Magic) ~= Magic then
        fail('state: bad canonical header')
    end

    local reader: Reader = {data = data, at = #Magic, length = length}
    local value = decodeValue(reader, 0)
    if reader.at ~= length then
        fail('state: trailing bytes after canonical value')
    end

    if buffer.tostring(module.encode(value)) ~= buffer.tostring(data) then
        fail('state: non-canonical value encoding')
    end
    return value
end

local function byteAt(data: buffer | string, at: number): number
    if type(data) == 'string' then
        local value = string.byte(data, at + 1)
        if value == nil then
            fail('state: invalid hash input')
        end
        return value
    end
    return buffer.readu8(data, at)
end

local function byteLength(data: buffer | string): number
    return if type(data) == 'string' then #data else buffer.len(data)
end

local function fnv64(data: buffer | string): string
    -- Four little-endian 16-bit limbs avoid lossy >2^53 multiplication.
    local a0, a1, a2, a3 = 0x2325, 0x8422, 0x9ce4, 0xcbf2
    for index = 0, byteLength(data) - 1 do
        a0 = bit32.bxor(a0, byteAt(data, index))
        local n0 = a0 * 0x1b3
        local r0 = n0 % 0x10000
        local carry = math.floor(n0 / 0x10000)
        local n1 = a1 * 0x1b3 + carry
        local r1 = n1 % 0x10000
        carry = math.floor(n1 / 0x10000)
        local n2 = a2 * 0x1b3 + a0 * 0x100 + carry
        local r2 = n2 % 0x10000
        carry = math.floor(n2 / 0x10000)
        local n3 = a3 * 0x1b3 + a1 * 0x100 + carry
        local r3 = n3 % 0x10000
        a0, a1, a2, a3 = r0, r1, r2, r3
    end
    return string.format('%04x%04x%04x%04x', a3, a2, a1, a0)
end

local function fnv32(data: buffer | string): string
    local lo, hi = 0x9dc5, 0x811c
    for index = 0, byteLength(data) - 1 do
        lo = bit32.bxor(lo, byteAt(data, index))
        local product = lo * 0x193
        local nextLo = product % 0x10000
        local carry = math.floor(product / 0x10000)
        local nextHi = (hi * 0x193 + lo * 0x100 + carry) % 0x10000
        lo, hi = nextLo, nextHi
    end
    return string.format('%04x%04x', hi, lo)
end

function module.fnv1a64(data: buffer | string): string
    return fnv64(data)
end

function module.fnv1a32(data: buffer | string): string
    return fnv32(data)
end

function module.hash(value: any): string
    return fnv64(module.encode(value))
end

function module.hash32(value: any): string
    return fnv32(module.encode(value))
end

module.hashState = module.hash

return module
