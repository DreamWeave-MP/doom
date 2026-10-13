--!strict
--!native
-- A flat copy of a level's BSP for the two walks the simulation makes most, point location and
-- line of sight. A node is eight doubles, 64 bytes: the partition line's x, y, dx and dy at 0, 8,
-- 16 and 24; dx and dy in whole map units, which both side tests multiply by, at 32 and 40; the
-- front and the back child at 48 and 56. The copy is derived from the game's nodes, which nothing
-- changes once a level is set up, and is remade whenever the game holds another nodes table (a
-- new level, a restored save), so it is never part of a save.
local module = {}

export type Node = { x: number, y: number, dx: number, dy: number, children: { number } }

local packedFrom: { Node }? = nil
local packed = buffer.create(0)

local function pack(nodes: { Node }): buffer
  local out = buffer.create(#nodes * 64)

  into(out, 'f64@64')[for node in nodes => node.x]
  into(out, 'f64@64', 8)[for node in nodes => node.y]
  into(out, 'f64@64', 16)[for node in nodes => node.dx]
  into(out, 'f64@64', 24)[for node in nodes => node.dy]
  into(out, 'f64@64', 32)[for node in nodes => node.dx // 65536]
  into(out, 'f64@64', 40)[for node in nodes => node.dy // 65536]
  into(out, 'f64@64', 48)[for node in nodes => node.children[1]]
  into(out, 'f64@64', 56)[for node in nodes => node.children[2]]

  packedFrom, packed = nodes, out
  return out
end

--- The flat copy of `nodes`, which is the game's current nodes table.
function module.nodes(nodes: { Node }): buffer
  if nodes ~= packedFrom then return pack(nodes) end

  return packed
end

return module
