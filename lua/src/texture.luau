--!strict
-- Classic DOOM PNAMES/TEXTURE1/TEXTURE2 compositor. Produces column-addressable
-- indexed textures directly from WAD patch posts.

local module = {}

export type Texture = { name: string, width: number, height: number, pixels: buffer, opaque: buffer }
export type Bank = { textures: {[string]: Texture}, get: (self: Bank, name: string) -> Texture? }

local BankMethods = {}
BankMethods.__index = BankMethods

function BankMethods:get(name: string): Texture?
    return self.textures[string.upper(name)]
end

local function name8(data: buffer, at: number): string
    local s = buffer.readstring(data, at, 8)
    local z = string.find(s, "\0", 1, true)
    if z then s = string.sub(s, 1, z - 1) end
    return string.upper(s)
end

local function patchNames(wad: any): {string}
    local data = wad:read("PNAMES")
    local count = buffer.readi32(data, 0)
    if count < 0 or 4 + count * 8 > buffer.len(data) then error("texture: invalid PNAMES", 2) end
    local out = table.create(count)
    for i = 0, count - 1 do out[i + 1] = name8(data, 4 + i * 8) end
    return out
end

local function blitPatch(wad: any, patchName: string, target: Texture, originX: number, originY: number)
    local lump = wad:find(patchName)
    if not lump then return end
    local data = wad:read(lump)
    if buffer.len(data) < 8 then return end
    local pw = buffer.readi16(data, 0)
    if pw <= 0 or 8 + pw * 4 > buffer.len(data) then return end
    for sx = 0, pw - 1 do
        local dx = originX + sx
        local at = buffer.readu32(data, 8 + sx * 4)
        if at >= 0 and at < buffer.len(data) then
            while at < buffer.len(data) do
                local top = buffer.readu8(data, at)
                at += 1
                if top == 255 then break end
                if at + 2 > buffer.len(data) then break end
                local len = buffer.readu8(data, at)
                at += 2
                if at + len + 1 > buffer.len(data) then break end
                if dx >= 0 and dx < target.width then
                    for py = 0, len - 1 do
                        local dy = originY + top + py
                        if dy >= 0 and dy < target.height then
                            local o = dy * target.width + dx
                            buffer.writeu8(target.pixels, o, buffer.readu8(data, at + py))
                            buffer.writeu8(target.opaque, o, 1)
                        end
                    end
                end
                at += len + 1
            end
        end
    end
end

local function parseTextureLump(wad: any, data: buffer, pnames: {string}, textures: {[string]: Texture})
    if buffer.len(data) < 4 then return end
    local count = buffer.readi32(data, 0)
    if count < 0 or 4 + count * 4 > buffer.len(data) then error("texture: invalid TEXTURE directory", 2) end
    for i = 0, count - 1 do
        local at = buffer.readi32(data, 4 + i * 4)
        if at < 0 or at + 22 > buffer.len(data) then error("texture: invalid texture offset", 2) end
        local name = name8(data, at)
        local width = buffer.readi16(data, at + 12)
        local height = buffer.readi16(data, at + 14)
        local patchCount = buffer.readi16(data, at + 20)
        if width > 0 and height > 0 and patchCount >= 0 and at + 22 + patchCount * 10 <= buffer.len(data) then
            local tex: Texture = { name = name, width = width, height = height, pixels = buffer.create(width * height), opaque = buffer.create(width * height) }
            for p = 0, patchCount - 1 do
                local q = at + 22 + p * 10
                local ox = buffer.readi16(data, q)
                local oy = buffer.readi16(data, q + 2)
                local patchIndex = buffer.readu16(data, q + 4) + 1
                local patchName = pnames[patchIndex]
                if patchName then blitPatch(wad, patchName, tex, ox, oy) end
            end
            textures[name] = tex
        end
    end
end

function module.load(wad: any): Bank
    local pnames = patchNames(wad)
    local textures: {[string]: Texture} = {}
    local one = wad:find("TEXTURE1")
    if one then parseTextureLump(wad, wad:read(one), pnames, textures) end
    local two = wad:find("TEXTURE2")
    if two then parseTextureLump(wad, wad:read(two), pnames, textures) end
    return setmetatable({ textures = textures }, BankMethods) :: any
end

return module
