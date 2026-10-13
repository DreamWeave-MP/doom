--!strict
--!native
-- Flat copies of a level's BSP and of its segs' linedefs for the two walks the simulation makes
-- most, point location and line of sight.
--
-- A node is eight doubles, 64 bytes: the partition line's x, y, dx and dy at 0, 8, 16 and 24; dx
-- and dy in whole map units, which both side tests multiply by, at 32 and 40; the front and the
-- back child at 48 and 56. A seg is four doubles, 32 bytes: where its linedef starts (x, y) and
-- where it ends.
--
-- The copies are derived from the game's nodes and segs, which nothing changes once a level is
-- set up, and are remade whenever the game holds another table of them (a new level, a restored
-- save), so they are never part of a save.
local module = {}

export type Node = { x: number, y: number, dx: number, dy: number, children: { number } }
export type Vertex = { x: number, y: number }
export type Line = { v1: Vertex, v2: Vertex, validcount: number, flags: number }
export type Seg = { linedef: Line }

local nodesFrom: { Node }? = nil
local flatNodes = buffer.create(0)

local function packNodes(nodes: { Node }): buffer
  local out = buffer.create(#nodes * 64)

  into(out, 'f64@64')[for node in nodes => node.x]
  into(out, 'f64@64', 8)[for node in nodes => node.y]
  into(out, 'f64@64', 16)[for node in nodes => node.dx]
  into(out, 'f64@64', 24)[for node in nodes => node.dy]
  into(out, 'f64@64', 32)[for node in nodes => node.dx // 65536]
  into(out, 'f64@64', 40)[for node in nodes => node.dy // 65536]
  into(out, 'f64@64', 48)[for node in nodes => node.children[1]]
  into(out, 'f64@64', 56)[for node in nodes => node.children[2]]

  nodesFrom, flatNodes = nodes, out
  return out
end

--- The flat copy of `nodes`, which is the game's current nodes table.
function module.nodes(nodes: { Node }): buffer
  if nodes ~= nodesFrom then return packNodes(nodes) end

  return flatNodes
end

local segsFrom: { Seg }? = nil
local lineEnds = buffer.create(0)
local segLines: { Line } = {}

local function packSegs(segs: { Seg }): (buffer, { Line })
  local out = buffer.create(#segs * 32)

  into(out, 'f64@32')[for seg in segs => seg.linedef.v1.x]
  into(out, 'f64@32', 8)[for seg in segs => seg.linedef.v1.y]
  into(out, 'f64@32', 16)[for seg in segs => seg.linedef.v2.x]
  into(out, 'f64@32', 24)[for seg in segs => seg.linedef.v2.y]

  segsFrom, lineEnds, segLines = segs, out, [for seg in segs => seg.linedef]
  return lineEnds, segLines
end

--- The ends of each seg's linedef, and the linedefs themselves, by seg: for `segs`, which is the
--- game's current segs table.
function module.segs(segs: { Seg }): (buffer, { Line })
  if segs ~= segsFrom then return packSegs(segs) end

  return lineEnds, segLines
end

return module
