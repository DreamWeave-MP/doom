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

  local textureX = 0
  if tex then textureX = math.floor(texU + 0.5) % tex.width end

  for row = top, bottom do
    local offset = row * Width + column
    if not (depth < zbuffer[offset + 1]) then continue end

    local color = fallback
    local opaque = true
    if tex then
      local worldZ = eye + (CenterY - row) * depth / Focal
      local textureY = math.floor(texTop - worldZ) % tex.height
      if textureY < 0 then textureY += tex.height end

      local textureOffset = textureY * tex.width + textureX
      opaque = buffer.readu8(tex.opaque, textureOffset) ~= 0
      if opaque then color = buffer.readu8(tex.pixels, textureOffset) end
    end

    if not opaque and not solid then continue end
    if not opaque then color = fallback end

    color = rdata.light(data, color, light, depth)
    buffer.writeu8(frame.pixels, offset, color)
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
  seg: any
)
  local start, finish = map.vertices[seg.v1], map.vertices[seg.v2]
  local cosAngle, sinAngle = math.cos(angle), math.sin(angle)
  local function camera(vertex: any): (number, number)
    local dx, dy = vertex.x - viewX, vertex.y - viewY
    return dx * cosAngle + dy * sinAngle, -dx * sinAngle + dy * cosAngle
  end

  local startDepth, startRight = camera(start)
  local finishDepth, finishRight = camera(finish)
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
  local fallback = data.palette:nearest(96, 80, 64)

  for column = first, last do
    local delta = math.atan((column + 0.5 - CenterX) / Focal)
    local rayAngle = angle + delta
    local along, across =
      raySegment(viewX, viewY, math.cos(rayAngle), math.sin(rayAngle), start.x, start.y, finish.x, finish.y)
    if not along or not across then continue end

    local depth = along * math.cos(delta)
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
  eye: number,
  angle: number
)
  for row = 0, Height - 1 do
    if row == CenterY then continue end

    local plane = if row > CenterY then sector.floor else sector.ceiling
    local distance = math.abs((eye - plane) * Focal / (row - CenterY))
    for column = 0, Width - 1 do
      local delta = math.atan((column + 0.5 - CenterX) / Focal)
      local ray = angle + delta
      local rayDistance = distance / math.max(0.01, math.cos(delta))
      local worldX, worldY = viewX + math.cos(ray) * rayDistance, viewY + math.sin(ray) * rayDistance
      local name = if row > CenterY then sector.floorTex else sector.ceilingTex
      local color = rdata.flat(data, wad, name, worldX, worldY)
      if color == nil then
        color = data.palette:nearest(
          if row > CenterY then 48 else 32,
          if row > CenterY then 40 else 32,
          if row > CenterY then 32 else 48
        )
      end

      buffer.writeu8(frame.pixels, row * Width + column, rdata.light(data, color, sector.light, distance))
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
  index: number
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
    if side <= 0 then drawSeg(frame, data, wad, map, zbuffer, viewX, viewY, eye, angle, seg) end
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
  drawPlanes(frame, data, wad, sector, x, y, eye, angle)

  local zbuffer: { number } = table.create(Width * Height, math.huge)
  local function visit(child: number)
    if bit32.band(child, 0x8000) ~= 0 then
      renderSubsector(frame, data, wad, map, zbuffer, x, y, eye, angle, bit32.band(child, 0x7fff) + 1)
      return
    end

    local node = map.nodes[child + 1]
    if not node then return end

    local front = nodeSide(node, x, y)
    visit(if front == 0 then node.front else node.back)
    visit(if front == 0 then node.back else node.front)
  end

  if #map.nodes == 0 then
    renderSubsector(frame, data, wad, map, zbuffer, x, y, eye, angle, 1)
  else
    visit(#map.nodes - 1)
  end

  if mobjs then
    rthings.render(map, mobjs, data, frame, { x = x, y = y, z = eye, angle = angleDegrees }, zbuffer, { sky = true })
  end

  return frame, data.palette
end

return module
