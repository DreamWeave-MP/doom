--!strict
--!native
-- A column renderer following the useful part of the original R_RenderView:
-- traverse the map BSP front-to-back, project segs to columns, and draw wall
-- tiers through a Doom indexed texture/light table. It deliberately stops
-- short of sprites and visplanes; those are separate renderer slices.
local mapModule = require('@doom/map')
local rdata = require('./rdata')
local rthings = require('./rthings')

local module = {}

export type Frame = { pixels: buffer, width: number, height: number }

local Width = 320
local Height = 200
local CenterX = Width * 0.5
local CenterY = Height * 0.5
local Focal = CenterX
local Near = 0.01
local NoSide = 65535
local DontPegBottom = 8

local function cross(leftX: number, leftY: number, rightX: number, rightY: number): number
  return leftX * rightY - leftY * rightX
end

local function raySegment(
  originX: number,
  originY: number,
  rayX: number,
  rayY: number,
  startX: number,
  startY: number,
  finishX: number,
  finishY: number
): (number?, number?)
  local spanX, spanY = finishX - startX, finishY - startY
  local denominator = cross(rayX, rayY, spanX, spanY)
  if math.abs(denominator) < 1e-9 then return nil, nil end

  local offsetX, offsetY = startX - originX, startY - originY
  local along = cross(offsetX, offsetY, spanX, spanY) / denominator
  local across = cross(offsetX, offsetY, rayX, rayY) / denominator
  if along > Near and across >= 0 and across <= 1 then return along, across end

  return nil, nil
end

local function project(depth: number, right: number): number
  return CenterX + right * Focal / depth
end

-- Clips a seg, given as the depth and the offset to the right of each end, to the near plane.
local function clipDepth(
  startDepth: number,
  startRight: number,
  finishDepth: number,
  finishRight: number
): (number?, number?, number?, number?)
  if startDepth <= Near and finishDepth <= Near then return nil end

  if startDepth <= Near then
    local fraction = (Near - startDepth) / (finishDepth - startDepth)
    startDepth += (finishDepth - startDepth) * fraction
    startRight += (finishRight - startRight) * fraction
  elseif finishDepth <= Near then
    local fraction = (Near - finishDepth) / (startDepth - finishDepth)
    finishDepth += (startDepth - finishDepth) * fraction
    finishRight += (startRight - finishRight) * fraction
  end

  return startDepth, startRight, finishDepth, finishRight
end

-- What every pixel of a screen column shares in a view, four doubles a column: the cosine and
-- the sine of the column's ray, the cosine of the ray's angle off the view's axis, and that
-- cosine kept from zero for the planes, which divide by it.
local rays = buffer.create(Width * 32)

local function castRays(angle: number)
  for column = 0, Width - 1 do
    local delta = math.atan((column + 0.5 - CenterX) / Focal)
    local at = column * 32
    buffer.writef64(rays, at, math.cos(angle + delta))
    buffer.writef64(rays, at + 8, math.sin(angle + delta))
    buffer.writef64(rays, at + 16, math.cos(delta))
    buffer.writef64(rays, at + 24, math.max(0.01, math.cos(delta)))
  end
end

local function textureName(name: string): string?
  if name == '' or name == '-' then return nil end

  return name
end

local function drawTier(
  frame: Frame,
  data: rdata.Data,
  zbuffer: { number },
  column: number,
  depth: number,
  eye: number,
  topZ: number,
  bottomZ: number,
  tex: any,
  texU: number,
  texTop: number,
  light: number,
  solid: boolean,
  fallback: number
)
  if topZ <= bottomZ then return end

  local top = math.max(0, math.floor(CenterY - (topZ - eye) * Focal / depth))
  local bottom = math.min(Height - 1, math.ceil(CenterY - (bottomZ - eye) * Focal / depth))
  if top > bottom then return end

  local pixels, colormap = frame.pixels, data.colormap
  -- The light table is the same down the tier; it is looked up when the first pixel is drawn, as
  -- it was for every pixel.
  local shade = -1
  if not tex then
    for row = top, bottom do
      local offset = row * Width + column
      if not (depth < zbuffer[offset + 1]) then continue end
      if shade < 0 then shade = rdata.shade(data, light, depth) end

      buffer.writeu8(pixels, offset, buffer.readu8(colormap, shade + bit32.band(fallback, 255)))
      zbuffer[offset + 1] = depth
    end

    return
  end

  local texWidth, texHeight, texPixels, texOpaque = tex.width, tex.height, tex.pixels, tex.opaque
  local textureX = math.floor(texU + 0.5) % texWidth
  for row = top, bottom do
    local offset = row * Width + column
    if not (depth < zbuffer[offset + 1]) then continue end

    local worldZ = eye + (CenterY - row) * depth / Focal
    local textureY = math.floor(texTop - worldZ) % texHeight
    if textureY < 0 then textureY += texHeight end

    local textureOffset = textureY * texWidth + textureX
    local color = fallback
    if buffer.readu8(texOpaque, textureOffset) ~= 0 then
      color = buffer.readu8(texPixels, textureOffset)
    elseif not solid then
      continue
    end

    if shade < 0 then shade = rdata.shade(data, light, depth) end

    buffer.writeu8(pixels, offset, buffer.readu8(colormap, shade + bit32.band(color, 255)))
    zbuffer[offset + 1] = depth
  end
end

local function drawSeg(
  frame: Frame,
  data: rdata.Data,
  wad: any,
  map: any,
  zbuffer: { number },
  viewX: number,
  viewY: number,
  eye: number,
  angle: number,
  seg: any,
  fallback: number
)
  local start, finish = map.vertices[seg.v1], map.vertices[seg.v2]
  local cosAngle, sinAngle = math.cos(angle), math.sin(angle)
  local dx, dy = start.x - viewX, start.y - viewY
  local startDepth, startRight = dx * cosAngle + dy * sinAngle, -dx * sinAngle + dy * cosAngle
  dx, dy = finish.x - viewX, finish.y - viewY

  local finishDepth, finishRight = dx * cosAngle + dy * sinAngle, -dx * sinAngle + dy * cosAngle
  local clippedStartDepth, clippedStartRight, clippedFinishDepth, clippedFinishRight =
    clipDepth(startDepth, startRight, finishDepth, finishRight)
  if not clippedStartDepth or not clippedStartRight or not clippedFinishDepth or not clippedFinishRight then
    return
  end

  local startColumn = project(clippedStartDepth, clippedStartRight)
  local finishColumn = project(clippedFinishDepth, clippedFinishRight)
  if math.max(startColumn, finishColumn) < 0 or math.min(startColumn, finishColumn) >= Width then return end

  local first = math.max(0, math.floor(math.min(startColumn, finishColumn)))
  local last = math.min(Width - 1, math.ceil(math.max(startColumn, finishColumn)) - 1)
  if first > last then return end

  local line = map.lines[seg.line]
  local sideIndex = if seg.side == 0 then line.right else line.left
  if sideIndex == NoSide then return end

  local frontSide = map.sides[sideIndex + 1]
  if not frontSide then return end

  local front = map.sectors[frontSide.sector]
  local backSideIndex = if seg.side == 0 then line.left else line.right
  local backSide = if backSideIndex ~= NoSide then map.sides[backSideIndex + 1] else nil
  local back = if backSide then map.sectors[backSide.sector] else nil
  if not front then return end

  local lineLength = math.sqrt((finish.x - start.x) ^ 2 + (finish.y - start.y) ^ 2)
  local middle = data.textures:get(textureName(frontSide.middle) or '')
  local upper = data.textures:get(textureName(frontSide.upper) or '')
  local lower = data.textures:get(textureName(frontSide.lower) or '')

  for column = first, last do
    local ray = column * 32
    local along, across = raySegment(
      viewX,
      viewY,
      buffer.readf64(rays, ray),
      buffer.readf64(rays, ray + 8),
      start.x,
      start.y,
      finish.x,
      finish.y
    )
    if not along or not across then continue end

    local depth = along * buffer.readf64(rays, ray + 16)
    if not (depth > Near) then continue end

    local texU = across * lineLength + frontSide.xOffset
    local isClosed = not back or back.ceiling <= front.floor or back.floor >= front.ceiling
    if isClosed then
      local texTop = if bit32.band(line.flags, DontPegBottom) ~= 0 and middle
        then front.floor + middle.height
        else front.ceiling
      drawTier(
        frame,
        data,
        zbuffer,
        column,
        depth,
        eye,
        front.ceiling,
        front.floor,
        middle,
        texU,
        texTop + frontSide.yOffset,
        front.light,
        true,
        fallback
      )
    elseif back then
      if front.ceiling > back.ceiling then
        drawTier(
          frame,
          data,
          zbuffer,
          column,
          depth,
          eye,
          front.ceiling,
          back.ceiling,
          upper,
          texU,
          front.ceiling + frontSide.yOffset,
          front.light,
          true,
          fallback
        )
      end

      if front.floor < back.floor then
        local texTop = if lower then back.floor + lower.height else back.floor
        drawTier(
          frame,
          data,
          zbuffer,
          column,
          depth,
          eye,
          back.floor,
          front.floor,
          lower,
          texU,
          texTop + frontSide.yOffset,
          front.light,
          true,
          fallback
        )
      end

      if middle then
        drawTier(
          frame,
          data,
          zbuffer,
          column,
          depth,
          eye,
          math.min(front.ceiling, back.ceiling),
          math.max(front.floor, back.floor),
          middle,
          texU,
          front.ceiling + frontSide.yOffset,
          front.light,
          false,
          fallback
        )
      end
    end
  end
end

local function drawPlanes(
  frame: Frame,
  data: rdata.Data,
  wad: any,
  sector: any,
  viewX: number,
  viewY: number,
  eye: number
)
  local pixels, colormap, flats = frame.pixels, data.colormap, wad.data
  for row = 0, Height - 1 do
    if row == CenterY then continue end

    -- A row lies on one plane at one distance, so it has one flat and one light table.
    local below = row > CenterY
    local plane = if below then sector.floor else sector.ceiling
    local distance = math.abs((eye - plane) * Focal / (row - CenterY))
    local flat = rdata.flatOffset(wad, if below then sector.floorTex else sector.ceilingTex)
    if not flat then
      local color = data.palette:nearest(if below then 48 else 32, if below then 40 else 32, if below then 32 else 48)
      buffer.fill(pixels, row * Width, rdata.light(data, color, sector.light, distance), Width)
      continue
    end

    local shade = rdata.shade(data, sector.light, distance)
    for column = 0, Width - 1 do
      local rayDistance = distance / buffer.readf64(rays, column * 32 + 24)
      local worldX = viewX + buffer.readf64(rays, column * 32) * rayDistance
      local worldY = viewY + buffer.readf64(rays, column * 32 + 8) * rayDistance
      local texel = bit32.band(-math.floor(worldY), 63) * 64 + bit32.band(math.floor(worldX), 63)
      buffer.writeu8(pixels, row * Width + column, buffer.readu8(colormap, shade + buffer.readu8(flats, flat + texel)))
    end
  end
end

local function renderSubsector(
  frame: Frame,
  data: rdata.Data,
  wad: any,
  map: any,
  zbuffer: { number },
  viewX: number,
  viewY: number,
  eye: number,
  angle: number,
  index: number,
  fallback: number
)
  local subsector = map.subsectors[index]
  if not subsector then return end

  for offset = 0, subsector.count - 1 do
    local seg = map.segs[subsector.first + offset]
    if not seg then continue end

    local start, finish = map.vertices[seg.v1], map.vertices[seg.v2]
    -- Segs are oriented with their rendered/front sector on the right,
    -- just as R_AddLine's span >= ANG180 back-face test assumes.
    local side = cross(finish.x - start.x, finish.y - start.y, viewX - start.x, viewY - start.y)
    if side <= 0 then drawSeg(frame, data, wad, map, zbuffer, viewX, viewY, eye, angle, seg, fallback) end
  end
end

-- R_PointOnSide for a node of the map module: 0 when the point is in front.
local function nodeSide(node: mapModule.Node, pointX: number, pointY: number): number
  if node.dx == 0 then
    if node.dy > 0 then return if pointX <= node.x then 0 else 1 end

    return if pointX <= node.x then 1 else 0
  end

  if node.dy == 0 then
    if node.dx < 0 then return if pointY <= node.y then 0 else 1 end

    return if pointY <= node.y then 1 else 0
  end

  return if node.dy * (pointX - node.x) > (pointY - node.y) * node.dx then 0 else 1
end

function module.view(map: any, wad: any, x: number, y: number, angleDegrees: number, mobjs: { any }?): (Frame, any)
  local data = rdata.load(wad)
  local frame: Frame = { pixels = buffer.create(Width * Height), width = Width, height = Height }
  local sector = mapModule.sectorAt(map, x, y)
  local eye = sector.floor + 41
  local angle = math.rad(angleDegrees)
  castRays(angle)
  drawPlanes(frame, data, wad, sector, x, y, eye)

  -- What an untextured wall is drawn in.
  local fallback = data.palette:nearest(96, 80, 64)
  local zbuffer: { number } = table.create(Width * Height, math.huge)
  local function visit(child: number)
    if bit32.band(child, 0x8000) ~= 0 then
      renderSubsector(frame, data, wad, map, zbuffer, x, y, eye, angle, bit32.band(child, 0x7fff) + 1, fallback)
      return
    end

    local node = map.nodes[child + 1]
    if not node then return end

    local front = nodeSide(node, x, y)
    visit(if front == 0 then node.front else node.back)
    visit(if front == 0 then node.back else node.front)
  end

  if #map.nodes == 0 then
    renderSubsector(frame, data, wad, map, zbuffer, x, y, eye, angle, 1, fallback)
  else
    visit(#map.nodes - 1)
  end

  if mobjs then
    rthings.render(map, mobjs, data, frame, { x = x, y = y, z = eye, angle = angleDegrees }, zbuffer, { sky = true })
  end

  return frame, data.palette
end

return module
