--!nonstrict
--!native
-- Save games for the play simulation. The game is one object graph full of
-- cycles (thinker ring, sector thing lists, mobj targets), so a save is that
-- graph: every table numbered in discovery order, each written as its array
-- part followed by its keyed part, with references by number. Level geometry
-- is part of the graph, so a save restores without re-reading the map lumps.
local P: any = require('./core')
local bytes = require('@dream/bytes')

local G = P.G
local Magic = 'DPLY\2'

-- Rebuilt on load instead of stored: the WAD handle, its texture directory,
-- and each mobj's pointer into the shared mobjinfo table.
local RootSkip = { wad = true, textures = true }

local TagNumber, TagString, TagTrue, TagFalse, TagRef, TagBuffer = 1, 2, 3, 4, 5, 6

-- What is written by value. Anything else is a table, written as a reference, or refused.
local Plain = { number = true, string = true, boolean = true, buffer = true }

function P.Save(): buffer
  local ids: { [any]: number }, nodes = { [G] = 1 }, { G }
  local count = 1
  local out = buffer.create(65536)
  local capacity, size = 65536, #Magic + 4

  -- Numbers a table on first sight, and refuses what a save cannot hold.
  local function visit(item: unknown)
    if type(item) ~= 'table' then error(`doom save: cannot store a {type(item)}`) end
    if ids[item] then return end

    count += 1
    nodes[count] = item
    ids[item] = count
  end

  local function grow(needed: number)
    capacity = math.max(size + needed, capacity * 2)

    local grown = buffer.create(capacity)
    buffer.copy(grown, 0, out, 0, size)
    out = grown
  end

  local function write(item: unknown)
    if type(item) == 'number' then
      if size + 9 > capacity then grow(9) end

      buffer.writeu8(out, size, TagNumber)
      buffer.writef64(out, size + 1, item)
      size += 9
    elseif type(item) == 'string' then
      if size + 5 + #item > capacity then grow(5 + #item) end

      buffer.writeu8(out, size, TagString)
      buffer.writeu32(out, size + 1, #item)
      buffer.writestring(out, size + 5, item)
      size += 5 + #item
    elseif type(item) == 'boolean' then
      if size + 1 > capacity then grow(1) end

      buffer.writeu8(out, size, if item then TagTrue else TagFalse)
      size += 1
    elseif type(item) == 'buffer' then
      local length = buffer.len(item)
      if size + 5 + length > capacity then grow(5 + length) end

      buffer.writeu8(out, size, TagBuffer)
      buffer.writeu32(out, size + 1, length)
      buffer.copy(out, size + 5, item, 0, length)
      size += 5 + length
    else
      if size + 5 > capacity then grow(5) end

      buffer.writeu8(out, size, TagRef)
      buffer.writeu32(out, size + 1, ids[item])
      size += 5
    end
  end

  local index = 1
  while index <= count do
    local node = nodes[index]
    local isMobj = node.think == 'mobj'
    local length = 0
    while node[length + 1] ~= nil do
      length += 1
    end

    -- The tables a node refers to are numbered keyed part first, then array part, though the
    -- array part is written first: the order the format has always numbered them in.
    local keyed = 0
    for key, item in node do
      if type(key) == 'number' and key >= 1 and key <= length and key % 1 == 0 then continue end
      if (index == 1 and RootSkip[key]) or (isMobj and key == 'info') then continue end
      if not Plain[type(key)] then visit(key) end
      if not Plain[type(item)] then visit(item) end

      keyed += 1
    end

    for slot = 1, length do
      local item = node[slot]
      if not Plain[type(item)] then visit(item) end
    end

    if size + 8 > capacity then grow(8) end

    buffer.writeu32(out, size, length)
    buffer.writeu32(out, size + 4, keyed)
    size += 8
    for slot = 1, length do
      write(node[slot])
    end

    for key, item in node do
      if type(key) == 'number' and key >= 1 and key <= length and key % 1 == 0 then continue end
      if (index == 1 and RootSkip[key]) or (isMobj and key == 'info') then continue end

      write(key)
      write(item)
    end

    index += 1
  end

  buffer.writestring(out, 0, Magic)
  buffer.writeu32(out, #Magic, count)
  return bytes.slice(out, 0, size)
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
