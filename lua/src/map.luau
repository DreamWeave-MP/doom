--!strict
local module = {}
export type Vertex = { x: number, y: number }
export type Line = { v1: number, v2: number, flags: number, special: number, tag: number, right: number, left: number }
export type Side = { xOffset: number, yOffset: number, upper: string, lower: string, middle: string, sector: number }
export type Sector = {
  floor: number,
  ceiling: number,
  floorTex: string,
  ceilingTex: string,
  light: number,
  special: number,
  tag: number,
}
export type Thing = { x: number, y: number, angle: number, kind: number, flags: number }
export type Seg = { v1: number, v2: number, line: number, side: number }
export type Subsector = { count: number, first: number }
export type Node = { x: number, y: number, dx: number, dy: number, front: number, back: number }
export type Blockmap = { originX: number, originY: number, width: number, height: number, cells: { { number } } }
export type Map = {
  name: string,
  vertices: { Vertex },
  lines: { Line },
  sides: { Side },
  sectors: { Sector },
  things: { Thing },
  segs: { Seg },
  subsectors: { Subsector },
  nodes: { Node },
  blockmap: Blockmap?,
  reject: buffer?,
}

local function name8(data: buffer, at: number): string
  local s = buffer.readstring(data, at, 8)
  local z = string.find(s, "\0", 1, true)
  if z then
    s = string.sub(s, 1, z - 1)
  end
  return string.upper(s)
end
local function records(data: buffer, size: number, name: string, required: boolean): number
  if buffer.len(data) % size ~= 0 then
    error(`map: {name} has a truncated record`, 2)
  end
  local count = buffer.len(data) / size
  if required and count == 0 then
    error(`map: {name} is empty`, 2)
  end
  return count
end
local function optionalLump(wad: any, marker: string, name: string): any
  local first, last = wad:markerRange(marker)
  name = string.upper(name)
  for i = last, first, -1 do
    if wad.lumps[i].name == name then
      return wad.lumps[i]
    end
  end
  return nil
end
local function parseBlockmap(data: buffer, lineCount: number): Blockmap
  local length = buffer.len(data)
  if length < 8 or length % 2 ~= 0 then
    error("map: invalid BLOCKMAP length", 2)
  end
  local words = length / 2
  local width, height = buffer.readu16(data, 4), buffer.readu16(data, 6)
  if width == 0 or height == 0 or width > math.floor((words - 4) / height) then
    error("map: invalid BLOCKMAP dimensions", 2)
  end
  local count = width * height
  local firstList = 4 + count
  local cells: { { number } } = table.create(count)
  for cell = 1, count do
    local offset = buffer.readi16(data, (cell + 3) * 2)
    if offset < firstList or offset >= words then
      error(`map: BLOCKMAP cell {cell} has an invalid list offset`, 2)
    end
    if buffer.readi16(data, offset * 2) ~= 0 then
      error(`map: BLOCKMAP cell {cell} has no list sentinel`, 2)
    end
    local list: { number } = {}
    local at = offset + 1
    local ended = false
    while at < words do
      local line = buffer.readi16(data, at * 2)
      at += 1
      if line == -1 then
        ended = true
        break
      end
      if line < 0 or line >= lineCount then
        error(`map: BLOCKMAP cell {cell} references line {line}`, 2)
      end
      table.insert(list, line + 1)
    end
    if not ended then
      error(`map: BLOCKMAP cell {cell} list is unterminated`, 2)
    end
    cells[cell] = list
  end
  return {
    originX = buffer.readi16(data, 0),
    originY = buffer.readi16(data, 2),
    width = width,
    height = height,
    cells = cells,
  }
end

function module.load(wad: any, marker: string): Map
  marker = string.upper(marker)
  local vd = wad:read(wad:mapLump(marker, "VERTEXES"))
  local ld = wad:read(wad:mapLump(marker, "LINEDEFS"))
  local sd = wad:read(wad:mapLump(marker, "SIDEDEFS"))
  local secd = wad:read(wad:mapLump(marker, "SECTORS"))
  local td = wad:read(wad:mapLump(marker, "THINGS"))
  local segd = wad:read(wad:mapLump(marker, "SEGS"))
  local ssd = wad:read(wad:mapLump(marker, "SSECTORS"))
  local nd = wad:read(wad:mapLump(marker, "NODES"))
  local vc = records(vd, 4, "VERTEXES", true)
  local lc = records(ld, 14, "LINEDEFS", true)
  local sc = records(sd, 30, "SIDEDEFS", true)
  local secCount = records(secd, 26, "SECTORS", true)
  records(td, 10, 'THINGS', false)
  local segCount = records(segd, 12, "SEGS", true)
  local ssc = records(ssd, 4, "SSECTORS", true)
  local nc = records(nd, 28, "NODES", false)
  local vertices: { Vertex } = [for at in range(0, buffer.len(vd) - 4, 4) => {
    x = buffer.readi16(vd, at),
    y = buffer.readi16(vd, at + 2),
  }]

  local lines: { Line } = table.create(lc)
  for at = 0, buffer.len(ld) - 14, 14 do
    local v1, v2, right, left =
      buffer.readu16(ld, at), buffer.readu16(ld, at + 2), buffer.readu16(ld, at + 10), buffer.readu16(ld, at + 12)
    if v1 >= vc or v2 >= vc then
      error("map: LINEDEFS references a missing vertex", 2)
    end
    if right ~= 0xffff and right >= sc then
      error("map: LINEDEFS references a missing right sidedef", 2)
    end
    if left ~= 0xffff and left >= sc then
      error("map: LINEDEFS references a missing left sidedef", 2)
    end
    table.insert(lines, {
      v1 = v1 + 1,
      v2 = v2 + 1,
      flags = buffer.readu16(ld, at + 4),
      special = buffer.readu16(ld, at + 6),
      tag = buffer.readu16(ld, at + 8),
      right = right,
      left = left,
    })
  end
  local sides: { Side } = table.create(sc)
  for at = 0, buffer.len(sd) - 30, 30 do
    local sector = buffer.readu16(sd, at + 28)
    if sector >= secCount then
      error("map: SIDEDEFS references a missing sector", 2)
    end
    table.insert(sides, {
      xOffset = buffer.readi16(sd, at),
      yOffset = buffer.readi16(sd, at + 2),
      upper = name8(sd, at + 4),
      lower = name8(sd, at + 12),
      middle = name8(sd, at + 20),
      sector = sector + 1,
    })
  end

  local sectors: { Sector } = [for at in range(0, buffer.len(secd) - 26, 26) => {
    floor = buffer.readi16(secd, at),
    ceiling = buffer.readi16(secd, at + 2),
    floorTex = name8(secd, at + 4),
    ceilingTex = name8(secd, at + 12),
    light = buffer.readi16(secd, at + 20),
    special = buffer.readi16(secd, at + 22),
    tag = buffer.readi16(secd, at + 24),
  }]

  local things: { Thing } = [for at in range(0, buffer.len(td) - 10, 10) => {
    x = buffer.readi16(td, at),
    y = buffer.readi16(td, at + 2),
    angle = buffer.readi16(td, at + 4),
    kind = buffer.readu16(td, at + 6),
    flags = buffer.readu16(td, at + 8),
  }]

  local segs: { Seg } = table.create(segCount)
  for at = 0, buffer.len(segd) - 12, 12 do
    local v1, v2, line, side =
      buffer.readu16(segd, at),
      buffer.readu16(segd, at + 2),
      buffer.readu16(segd, at + 6),
      buffer.readu16(segd, at + 8)
    if v1 >= vc or v2 >= vc or line >= lc then
      error("map: SEGS references a missing record", 2)
    end
    if side > 1 then
      error("map: SEGS has an invalid sidedef selector", 2)
    end
    local sideIndex = if side == 0 then lines[line + 1].right else lines[line + 1].left
    if sideIndex == 0xffff then
      error("map: SEGS selects a missing sidedef", 2)
    end
    table.insert(segs, { v1 = v1 + 1, v2 = v2 + 1, line = line + 1, side = side })
  end
  local subsectors: { Subsector } = table.create(ssc)
  for at = 0, buffer.len(ssd) - 4, 4 do
    local count, first = buffer.readu16(ssd, at), buffer.readu16(ssd, at + 2)
    if count == 0 or first >= segCount or count > segCount - first then
      error("map: SSECTORS references missing segs", 2)
    end
    table.insert(subsectors, { count = count, first = first + 1 })
  end
  local nodes: { Node } = table.create(nc)
  for at = 0, buffer.len(nd) - 28, 28 do
    local front, back = buffer.readu16(nd, at + 24), buffer.readu16(nd, at + 26)
    for _, child in { front, back } do
      local index = bit32.band(child, 0x7fff)
      if bit32.band(child, 0x8000) ~= 0 then
        if index >= ssc then
          error("map: NODES references a missing subsector", 2)
        end
      elseif index >= nc then
        error("map: NODES references a missing node", 2)
      end
    end
    table.insert(nodes, {
      x = buffer.readi16(nd, at),
      y = buffer.readi16(nd, at + 2),
      dx = buffer.readi16(nd, at + 4),
      dy = buffer.readi16(nd, at + 6),
      front = front,
      back = back,
    })
  end
  local bmLump = optionalLump(wad, marker, "BLOCKMAP")
  local blockmap = if bmLump then parseBlockmap(wad:read(bmLump), lc) else nil
  local rLump = optionalLump(wad, marker, "REJECT")
  local reject = if rLump then wad:read(rLump) else nil
  if reject and buffer.len(reject) < math.ceil(secCount * secCount / 8) then
    error("map: REJECT is truncated", 2)
  end
  return {
    name = marker,
    vertices = vertices,
    lines = lines,
    sides = sides,
    sectors = sectors,
    things = things,
    segs = segs,
    subsectors = subsectors,
    nodes = nodes,
    blockmap = blockmap,
    reject = reject,
  }
end
function module.playerStart(map: Map, player: number?): Thing
  local kind = player or 1
  for _, thing in map.things do
    if thing.kind == kind then
      return thing
    end
  end
  error(`map: {map.name} has no player {kind} start`, 2)
end
local function pointOnSide(x: number, y: number, node: Node): number
  if node.dx == 0 then
    if x <= node.x then
      return if node.dy > 0 then 1 else 0
    end
    return if node.dy < 0 then 1 else 0
  end
  if node.dy == 0 then
    if y <= node.y then
      return if node.dx < 0 then 1 else 0
    end
    return if node.dx > 0 then 1 else 0
  end
  return if (y - node.y) * node.dx < node.dy * (x - node.x) then 0 else 1
end
function module.subsector(map: Map, x: number, y: number): Subsector
  if #map.nodes == 0 then
    return map.subsectors[1]
  end
  local child = #map.nodes - 1
  local steps = 0
  while bit32.band(child, 0x8000) == 0 do
    steps += 1
    if steps > #map.nodes then
      error(`map: {map.name} has a cyclic BSP`, 2)
    end
    local node = map.nodes[child + 1]
    if not node then
      error(`map: {map.name} has an invalid BSP child`, 2)
    end
    child = if pointOnSide(x, y, node) == 0 then node.front else node.back
  end
  local result = map.subsectors[bit32.band(child, 0x7fff) + 1]
  if not result then
    error(`map: {map.name} has an invalid subsector`, 2)
  end
  return result
end
function module.sectorAt(map: Map, x: number, y: number): Sector
  local ss = module.subsector(map, x, y)
  local seg = map.segs[ss.first]
  if not seg then
    error(`map: {map.name} subsector has an invalid first seg`, 2)
  end
  local line = map.lines[seg.line]
  if not line then
    error(`map: {map.name} seg has an invalid linedef`, 2)
  end
  local sideIndex = if seg.side == 0 then line.right else line.left
  if sideIndex == 0xffff then
    sideIndex = if seg.side == 0 then line.left else line.right
  end
  if sideIndex == 0xffff then
    error(`map: {map.name} seg has no sidedef`, 2)
  end
  local side = map.sides[sideIndex + 1]
  if not side then
    error(`map: {map.name} has an invalid sidedef`, 2)
  end
  local sector = map.sectors[side.sector]
  if not sector then
    error(`map: {map.name} has an invalid sector`, 2)
  end
  return sector
end
return module
