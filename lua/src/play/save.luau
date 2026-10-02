--!nonstrict
--!native
-- Save games for the play simulation. The game is one object graph full of
-- cycles (thinker ring, sector thing lists, mobj targets), so a save is that
-- graph: every table numbered in discovery order, each written as its array
-- part followed by its keyed part, with references by number. Level geometry
-- is part of the graph, so a save restores without re-reading the map lumps.
local P: any = require('./core')

local G = P.G
local Magic = 'DPLY\2'

-- Rebuilt on load instead of stored: the WAD handle, its texture directory,
-- and each mobj's pointer into the shared mobjinfo table.
local RootSkip = { wad = true, textures = true }

local TagNumber, TagString, TagTrue, TagFalse, TagRef, TagBuffer = 1, 2, 3, 4, 5, 6

function P.Save(): buffer
  local ids: { [any]: number }, nodes = { [G] = 1 }, { G }
  local out = {}

  local function value(item: any): string
    local kind = type(item)
    if kind == 'number' then return string.pack('<Bd', TagNumber, item) end
    if kind == 'string' then return string.pack('<Bs4', TagString, item) end
    if kind == 'boolean' then return string.char(if item then TagTrue else TagFalse) end
    if kind == 'buffer' then return string.pack('<Bs4', TagBuffer, buffer.tostring(item)) end
    if kind ~= 'table' then error(`doom save: cannot store a {kind}`) end

    local id = ids[item]
    if not id then
      table.insert(nodes, item)
      id = #nodes
      ids[item] = id
    end

    return string.pack('<BI4', TagRef, id)
  end

  local index = 1
  while index <= #nodes do
    local node = nodes[index]
    local isMobj = node.think == 'mobj'
    local length = 0
    while node[length + 1] ~= nil do
      length += 1
    end

    local keyed = {}
    for key, item in node do
      if type(key) == 'number' and key >= 1 and key <= length and key % 1 == 0 then continue end
      if (index == 1 and RootSkip[key]) or (isMobj and key == 'info') then continue end

      table.insert(keyed, value(key))
      table.insert(keyed, value(item))
    end

    table.insert(out, string.pack('<I4I4', length, #keyed // 2))
    for slot = 1, length do
      table.insert(out, value(node[slot]))
    end

    table.insert(out, table.concat(keyed))
    index += 1
  end

  return buffer.fromstring(Magic .. string.pack('<I4', #nodes) .. table.concat(out))
end

function P.Restore(wad: any, data: buffer): ()
  local text = buffer.tostring(data)
  if string.sub(text, 1, #Magic) ~= Magic then error('doom save: not a play save, or an older format') end

  local at = #Magic + 1
  local count
  count, at = string.unpack('<I4', text, at)

  local nodes = table.create(count)
  nodes[1] = G
  for index = 2, count do
    nodes[index] = {}
  end

  local function value(): any
    local tag = string.byte(text, at)
    at += 1
    if tag == TagTrue then return true end
    if tag == TagFalse then return false end

    local item
    if tag == TagNumber then
      item, at = string.unpack('<d', text, at)
    elseif tag == TagString then
      item, at = string.unpack('<s4', text, at)
    elseif tag == TagBuffer then
      item, at = string.unpack('<s4', text, at)
      item = buffer.fromstring(item)
    elseif tag == TagRef then
      item, at = string.unpack('<I4', text, at)
      item = nodes[item]
      if not item then error('doom save: reference to a missing table') end
    else
      error('doom save: unknown value tag')
    end

    return item
  end

  table.clear(G)
  for index = 1, count do
    local node = nodes[index]
    local length, keyed
    length, keyed, at = string.unpack('<I4I4', text, at)
    for slot = 1, length do
      node[slot] = value()
    end

    for _ = 1, keyed do
      local key = value()
      node[key] = value()
    end
  end

  for _, node in nodes do
    if node.think == 'mobj' then node.info = P.mobjinfo[node.type] end
  end

  P.OpenWad(wad)
  P.SetFastTables(G.fastparm or G.gameskill == 4)
end

return P
