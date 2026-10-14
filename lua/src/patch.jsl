--!strict
--!native
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
  if buffer.len(data) < 8 then error('patch: truncated header', 2) end

  local width = buffer.readi16(data, 0)
  local height = buffer.readi16(data, 2)
  if width <= 0 or height <= 0 or 8 + width * 4 > buffer.len(data) then error('patch: invalid dimensions', 2) end

  return {
    data = data,
    width = width,
    height = height,
    left = buffer.readi16(data, 4),
    top = buffer.readi16(data, 6),
  }
end

function module.draw(
  frame: buffer,
  screenWidth: number,
  screenHeight: number,
  patch: Patch,
  left: number?,
  top: number?
): ()
  local originX = (left or 0) - patch.left
  local originY = (top or 0) - patch.top
  local data = patch.data
  -- A post at a whole row of a screen with a whole height is clipped once. Anything else, a
  -- fraction or no number at all, is tested a row at a time, as every post used to be.
  local whole = originY % 1 == 0 and screenHeight % 1 == 0
  for column = 0, patch.width - 1 do
    local screenColumn = originX + column
    local at = buffer.readu32(data, 8 + column * 4)
    if at < 0 or at >= buffer.len(data) then error('patch: invalid column offset', 2) end

    while true do
      if at >= buffer.len(data) then error('patch: unterminated column', 2) end

      local topDelta = buffer.readu8(data, at)
      at += 1
      if topDelta == 255 then break end
      if at + 2 > buffer.len(data) then error('patch: truncated post', 2) end

      local length = buffer.readu8(data, at)
      at += 2 -- length, then the unused leading byte
      if at + length + 1 > buffer.len(data) then error('patch: truncated pixels', 2) end

      local postTop = originY + topDelta
      local onScreen = screenColumn >= 0 and screenColumn < screenWidth
      if onScreen and whole then
        for row = math.max(0, -postTop), math.min(length - 1, screenHeight - 1 - postTop) do
          buffer.writeu8(frame, (postTop + row) * screenWidth + screenColumn, buffer.readu8(data, at + row))
        end
      elseif onScreen then
        for row = 0, length - 1 do
          local screenRow = postTop + row
          if screenRow >= 0 and screenRow < screenHeight then
            buffer.writeu8(frame, screenRow * screenWidth + screenColumn, buffer.readu8(data, at + row))
          end
        end
      end

      at += length + 1 -- pixels plus unused trailing byte
    end
  end
end

return module
