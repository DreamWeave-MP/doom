--!strict
-- Decoder/compositor for DOOM's column/post patch format (V_DrawPatch's data model).
local module = {}

export type Patch = {
    data: buffer,
    width: number,
    height: number,
    left: number,
    top: number,
}

function module.open(data: buffer): Patch
    if buffer.len(data) < 8 then error("patch: truncated header", 2) end
    local width = buffer.readi16(data, 0)
    local height = buffer.readi16(data, 2)
    if width <= 0 or height <= 0 or 8 + width * 4 > buffer.len(data) then
        error("patch: invalid dimensions", 2)
    end
    return {
        data = data,
        width = width,
        height = height,
        left = buffer.readi16(data, 4),
        top = buffer.readi16(data, 6),
    }
end

function module.draw(frame: buffer, screenWidth: number, screenHeight: number, patch: Patch, x: number?, y: number?): ()
    local ox = (x or 0) - patch.left
    local oy = (y or 0) - patch.top
    local data = patch.data
    for sx = 0, patch.width - 1 do
        local dx = ox + sx
        local at = buffer.readu32(data, 8 + sx * 4)
        if at < 0 or at >= buffer.len(data) then error("patch: invalid column offset", 2) end
        while true do
            if at >= buffer.len(data) then error("patch: unterminated column", 2) end
            local topDelta = buffer.readu8(data, at)
            at += 1
            if topDelta == 255 then break end
            if at + 2 > buffer.len(data) then error("patch: truncated post", 2) end
            local length = buffer.readu8(data, at)
            at += 2 -- length, then the unused leading byte
            if at + length + 1 > buffer.len(data) then error("patch: truncated pixels", 2) end
            if dx >= 0 and dx < screenWidth then
                for py = 0, length - 1 do
                    local dy = oy + topDelta + py
                    if dy >= 0 and dy < screenHeight then
                        buffer.writeu8(frame, dy * screenWidth + dx, buffer.readu8(data, at + py))
                    end
                end
            end
            at += length + 1 -- pixels plus unused trailing byte
        end
    end
end

return module
