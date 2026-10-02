--!strict
local module = {}

export type Vertex = { x: number, y: number }
export type Line = { v1: number, v2: number, flags: number, special: number, tag: number, right: number, left: number }
export type Side = { xOffset: number, yOffset: number, upper: string, lower: string, middle: string, sector: number }
export type Sector = { floor: number, ceiling: number, floorTex: string, ceilingTex: string, light: number, special: number, tag: number }
export type Thing = { x: number, y: number, angle: number, kind: number, flags: number }
export type Seg = { v1: number, v2: number, line: number, side: number }
export type Subsector = { count: number, first: number }
export type Node = { x: number, y: number, dx: number, dy: number, front: number, back: number }
export type Map = { name: string, vertices: {Vertex}, lines: {Line}, sides: {Side}, sectors: {Sector}, things: {Thing}, segs: {Seg}, subsectors: {Subsector}, nodes: {Node} }

local function name8(data: buffer, at: number): string
    local s = buffer.readstring(data, at, 8)
    local z = string.find(s, "\0", 1, true)
    if z then s = string.sub(s, 1, z - 1) end
    return s
end

function module.load(wad: any, marker: string): Map
    marker = string.upper(marker)
    local verticesData = wad:read(wad:mapLump(marker, "VERTEXES"))
    local linesData = wad:read(wad:mapLump(marker, "LINEDEFS"))
    local sidesData = wad:read(wad:mapLump(marker, "SIDEDEFS"))
    local sectorsData = wad:read(wad:mapLump(marker, "SECTORS"))
    local thingsData = wad:read(wad:mapLump(marker, "THINGS"))
    local segsData = wad:read(wad:mapLump(marker, "SEGS"))
    local subsectorsData = wad:read(wad:mapLump(marker, "SSECTORS"))
    local nodesData = wad:read(wad:mapLump(marker, "NODES"))

    local vertices: {Vertex} = table.create(math.floor(buffer.len(verticesData) / 4))
    for at = 0, buffer.len(verticesData) - 4, 4 do table.insert(vertices, { x = buffer.readi16(verticesData, at), y = buffer.readi16(verticesData, at + 2) }) end

    local lines: {Line} = table.create(math.floor(buffer.len(linesData) / 14))
    for at = 0, buffer.len(linesData) - 14, 14 do
        table.insert(lines, { v1 = buffer.readu16(linesData, at) + 1, v2 = buffer.readu16(linesData, at + 2) + 1, flags = buffer.readu16(linesData, at + 4), special = buffer.readu16(linesData, at + 6), tag = buffer.readu16(linesData, at + 8), right = buffer.readu16(linesData, at + 10), left = buffer.readu16(linesData, at + 12) })
    end

    local sides: {Side} = table.create(math.floor(buffer.len(sidesData) / 30))
    for at = 0, buffer.len(sidesData) - 30, 30 do
        table.insert(sides, { xOffset = buffer.readi16(sidesData, at), yOffset = buffer.readi16(sidesData, at + 2), upper = name8(sidesData, at + 4), lower = name8(sidesData, at + 12), middle = name8(sidesData, at + 20), sector = buffer.readu16(sidesData, at + 28) + 1 })
    end

    local sectors: {Sector} = table.create(math.floor(buffer.len(sectorsData) / 26))
    for at = 0, buffer.len(sectorsData) - 26, 26 do
        table.insert(sectors, { floor = buffer.readi16(sectorsData, at), ceiling = buffer.readi16(sectorsData, at + 2), floorTex = name8(sectorsData, at + 4), ceilingTex = name8(sectorsData, at + 12), light = buffer.readi16(sectorsData, at + 20), special = buffer.readi16(sectorsData, at + 22), tag = buffer.readi16(sectorsData, at + 24) })
    end

    local things: {Thing} = table.create(math.floor(buffer.len(thingsData) / 10))
    for at = 0, buffer.len(thingsData) - 10, 10 do table.insert(things, { x = buffer.readi16(thingsData, at), y = buffer.readi16(thingsData, at + 2), angle = buffer.readi16(thingsData, at + 4), kind = buffer.readu16(thingsData, at + 6), flags = buffer.readu16(thingsData, at + 8) }) end

    local segs: {Seg} = table.create(math.floor(buffer.len(segsData) / 12))
    for at = 0, buffer.len(segsData) - 12, 12 do table.insert(segs, { v1 = buffer.readu16(segsData, at) + 1, v2 = buffer.readu16(segsData, at + 2) + 1, line = buffer.readu16(segsData, at + 6) + 1, side = buffer.readu16(segsData, at + 8) }) end

    local subsectors: {Subsector} = table.create(math.floor(buffer.len(subsectorsData) / 4))
    for at = 0, buffer.len(subsectorsData) - 4, 4 do table.insert(subsectors, { count = buffer.readu16(subsectorsData, at), first = buffer.readu16(subsectorsData, at + 2) + 1 }) end

    local nodes: {Node} = table.create(math.floor(buffer.len(nodesData) / 28))
    for at = 0, buffer.len(nodesData) - 28, 28 do table.insert(nodes, { x = buffer.readi16(nodesData, at), y = buffer.readi16(nodesData, at + 2), dx = buffer.readi16(nodesData, at + 4), dy = buffer.readi16(nodesData, at + 6), front = buffer.readu16(nodesData, at + 24), back = buffer.readu16(nodesData, at + 26) }) end

    return { name = marker, vertices = vertices, lines = lines, sides = sides, sectors = sectors, things = things, segs = segs, subsectors = subsectors, nodes = nodes }
end

function module.playerStart(map: Map, player: number?): Thing
    local kind = player or 1
    for _, thing in map.things do if thing.kind == kind then return thing end end
    error(`map: {map.name} has no player {kind} start`, 2)
end

local function pointOnSide(x: number, y: number, node: Node): number
    if node.dx == 0 then
        if x <= node.x then return if node.dy > 0 then 1 else 0 end
        return if node.dy < 0 then 1 else 0
    end
    if node.dy == 0 then
        if y <= node.y then return if node.dx < 0 then 1 else 0 end
        return if node.dx > 0 then 1 else 0
    end
    local left = node.dy * (x - node.x)
    local right = (y - node.y) * node.dx
    return if right < left then 0 else 1
end

function module.subsector(map: Map, x: number, y: number): Subsector
    if #map.nodes == 0 then return map.subsectors[1] end
    local child = #map.nodes - 1 -- zero-based node index
    while bit32.band(child, 0x8000) == 0 do
        local node = map.nodes[child + 1]
        local side = pointOnSide(x, y, node)
        child = if side == 0 then node.front else node.back
    end
    local index = bit32.band(child, 0x7fff) + 1
    return map.subsectors[index]
end

function module.sectorAt(map: Map, x: number, y: number): Sector
    local ss = module.subsector(map, x, y)
    local seg = map.segs[ss.first]
    local line = map.lines[seg.line]
    local sideIndex = if seg.side == 0 then line.right else line.left
    if sideIndex == 65535 then sideIndex = if seg.side == 0 then line.left else line.right end
    local side = map.sides[sideIndex + 1]
    return map.sectors[side.sector]
end

return module
