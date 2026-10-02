--!strict
--!native
-- Synthetic WAD bytes keep the suite independent of an installed game.
local demoModule = require '@doom/demo'
local doom = require '@doom'
local fixed = require '@doom/fixed'
local gameModule = require '@doom/game'
local info = require '@doom/info'
local mapModule = require '@doom/map'
local paletteModule = require '@doom/palette'
local random = require '@doom/random'
local save = require '@doom/save'
local state = require '@doom/state'
local tables = require '@doom/tables'
local test = require '@jess/test'
local wadModule = require '@doom/wad'
local expect = test.expect
local suite = test.new()
local fs = jess.fs

type LumpSpec = { name: string, data: string }

local TestPath = fs.join(fs.cwd(), 'target', 'doom-tests', 'synthetic.wad')

local function name8(name: string): string return string.sub(name .. string.rep('\0', 8), 1, 8) end

local function wadBytes(kind: string, lumps: { LumpSpec }): buffer
  local parts = { kind .. string.pack('<i4i4', #lumps, 0) }
  local offsets = {}
  local offset = 12

  for index, lump in lumps do
    offsets[index] = offset
    table.insert(parts, lump.data)
    offset += #lump.data
  end

  local directory = {}
  for index, lump in lumps do
    table.insert(directory, string.pack('<i4i4', offsets[index], #lump.data) .. name8(lump.name))
  end

  local result = buffer.fromstring(table.concat(parts) .. table.concat(directory))
  buffer.writei32(result, 8, offset)
  return result
end

local function writeFixture(data: buffer): string
  fs.write(TestPath, data)
  return TestPath
end

local function mapLumps(): { LumpSpec }
  local vertices = string.pack('<i2i2i2i2i2i2i2i2', -32, 0, 128, 0, 128, 128, -32, 128)
  local lines = string.pack('<I2I2I2I2I2I2I2', 0, 1, 1, 7, 9, 0, 0)
  local sides = string.pack('<i2i2', 3, -4)
    .. name8 'UPPER'
    .. name8 'LOWER'
    .. name8 'MID'
    .. string.pack('<I2', 0)
  local sectors = string.pack('<i2i2', -16, 128)
    .. name8 'FLOOR0'
    .. name8 'CEIL0'
    .. string.pack('<i2i2i2', 192, 2, 4)
  local things = string.pack('<i2i2i2I2I2', 16, 24, 90, 1, 7)
  local segs = string.pack('<I2I2i2I2I2i2', 0, 1, 0, 0, 0, 0)
  local subsectors = string.pack('<I2I2', 1, 0)
  local node = buffer.create(28)
  buffer.writei16(node, 0, 64)
  buffer.writei16(node, 6, 1)
  buffer.writeu16(node, 24, 0x8000)
  buffer.writeu16(node, 26, 0x8000)

  return {
    { name = 'VERTEXES', data = vertices },
    { name = 'LINEDEFS', data = lines },
    { name = 'SIDEDEFS', data = sides },
    { name = 'SECTORS', data = sectors },
    { name = 'THINGS', data = things },
    { name = 'SEGS', data = segs },
    { name = 'SSECTORS', data = subsectors },
    { name = 'NODES', data = buffer.tostring(node) },
  }
end

local function fixture(): buffer
  local demo = string.char(1, 2, 1, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0)
    .. string.char(10, 254, 3, 1, 251, 4, 9, 2)
    .. string.char(127, 128, 255, 7, 250, 6, 11, 8, 128)
  local lumps: { LumpSpec } = {
    { name = 'PAYLOAD', data = 'first' },
    { name = 'payload', data = 'second' },
    { name = 'DEMO1', data = demo },
    { name = 'E1M1', data = '' },
  }

  for _, lump in mapLumps() do
    table.insert(lumps, lump)
  end
  table.insert(lumps, { name = 'MAP02', data = '' })
  table.insert(lumps, { name = 'EMPTY', data = '' })
  return wadBytes('PWAD', lumps)
end

local function paletteBytes(): buffer
  local data = buffer.create(1536)
  for bank = 0, 1 do
    for index = 0, 255 do
      local at = bank * 768 + index * 3
      local color = if index == 42 then 255 else 0
      buffer.writeu8(data, at, color)
      buffer.writeu8(data, at + 1, color)
      buffer.writeu8(data, at + 2, color)
    end
  end

  buffer.writeu8(data, 1 * 768 + 7 * 3, 1)
  buffer.writeu8(data, 1 * 768 + 7 * 3 + 1, 2)
  buffer.writeu8(data, 1 * 768 + 7 * 3 + 2, 3)
  return data
end

local function fingerprint(data: buffer): string
  local hash = 2166136261
  for index = 0, buffer.len(data) - 1 do
    hash = bit32.bxor(hash, buffer.readu8(data, index))
    hash = (bit32.lshift(hash, 24) + hash * 403) % 4294967296
  end

  return string.format('%08x', hash)
end

suite.beforeEach(function() fs.remove(TestPath) end)
suite.afterEach(function() fs.remove(TestPath) end)

suite.describe('WAD directories', function()
  suite.it('reads names, duplicates, ranges, and bytes from synthetic data', function()
    local path = writeFixture(fixture())
    local wad = wadModule.open(path)

    expect(wad.kind).toBe 'PWAD'
    expect(#wad.lumps).toBe(14)
    expect(doom.info(path)).toEqual { kind = 'PWAD', lumps = 14, path = path }
    expect(wad:find 'payload' :: wadModule.Lump).toEqual {
      index = 2,
      name = 'PAYLOAD',
      offset = 17,
      size = 6,
    }
    expect(#wad:all 'PAYLOAD').toBe(2)
    expect(buffer.tostring(wad:read 'payload')).toBe 'second'
    expect(buffer.tostring(wad:read('payload', 1))).toBe 'first'
    expect(buffer.tostring(wad:read(wad:find('PAYLOAD', 1) :: wadModule.Lump))).toBe 'first'
    expect(wad:mapLump('E1M1', 'vertexes').name).toBe 'VERTEXES'
    expect({ wad:markerRange 'E1M1' }).toEqual { 5, 12 }
  end)

  suite.it('rejects malformed headers and lump bounds', function()
    local function open(data: buffer) wadModule.open(writeFixture(data)) end

    expect(function() open(buffer.create(11)) end).toThrow 'header is truncated'
    expect(function() open(buffer.fromstring('XXXX' .. string.pack('<i4i4', 0, 12))) end).toThrow 'bad magic'
    expect(function() open(buffer.fromstring('PWAD' .. string.pack('<i4i4', 1, -1))) end).toThrow 'invalid directory bounds'
    local bad = buffer.fromstring(
      'PWAD' .. string.pack('<i4i4', 1, 12) .. string.pack('<i4i4', 99, 1) .. name8 'BAD'
    )
    expect(function() open(bad) end).toThrow 'lump 1 is outside the file'
    expect(function() wadModule.open(TestPath .. '.missing') end).toThrow 'cannot read'
  end)
end)

suite.describe('demos', function()
  suite.it('decodes console-player tics and signed movement bytes', function()
    local wad = wadModule.open(writeFixture(fixture()))
    local header, tics = demoModule.parse(wad:read 'DEMO1')

    expect(header.players).toEqual { true, false, true, false }
    expect({ header.version, header.skill, header.consolePlayer }).toEqual { 1, 2, 0 }
    expect(tics).toEqual {
      { forward = 10, side = -2, turn = 3, buttons = 1 },
      { forward = 127, side = -128, turn = 255, buttons = 7 },
    }
  end)

  suite.it('rejects truncated, playerless, and partial demos', function()
    expect(function() demoModule.parse(buffer.create(12)) end).toThrow 'truncated header'
    expect(
      function()
        demoModule.parse(buffer.fromstring(string.char(1, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
      end
    ).toThrow 'no players'
    local partial = buffer.fromstring(string.char(1, 2, 1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 4, 5))
    expect(function() demoModule.parse(partial) end).toThrow 'truncated ticcmd'
  end)
end)

suite.describe('palettes', function()
  suite.it('finds nearest colors, writes PPM, and has a stable fingerprint', function()
    local palette = paletteModule.fromPlaypal(paletteBytes(), 1)
    local ppm = paletteModule.toPpm(buffer.fromstring(string.char(42, 7)), 2, 1, palette)

    expect(palette:nearest(255, 255, 255)).toBe(42)
    expect(palette:nearest(1, 2, 3)).toBe(7)
    expect(buffer.tostring(ppm)).toBe 'P6\n2 1\n255\n\255\255\255\1\2\3'
    expect(fingerprint(ppm)).toBe '16cb4715'
  end)

  suite.it('rejects invalid palette banks and short framebuffers', function()
    local playpal = paletteBytes()
    expect(function() paletteModule.fromPlaypal(playpal, -1) end).toThrow 'index out of range'
    expect(function() paletteModule.fromPlaypal(playpal, 2) end).toThrow 'index out of range'
    expect(
      function() paletteModule.toPpm(buffer.create(1), 2, 1, paletteModule.fromPlaypal(playpal)) end
    ).toThrow 'framebuffer is too small'
  end)
end)

suite.describe('maps', function()
  suite.it('decodes classic lumps and resolves a BSP subsector', function()
    local wad = wadModule.open(writeFixture(fixture()))
    local map = mapModule.load(wad, 'e1m1')

    expect(map.name).toBe 'E1M1'
    expect(map.vertices[1]).toEqual { x = -32, y = 0 }
    expect(map.lines[1]).toEqual {
      v1 = 1,
      v2 = 2,
      flags = 1,
      special = 7,
      tag = 9,
      right = 0,
      left = 0,
    }
    expect(map.sides[1]).toEqual {
      xOffset = 3,
      yOffset = -4,
      upper = 'UPPER',
      lower = 'LOWER',
      middle = 'MID',
      sector = 1,
    }
    expect(map.sectors[1]).toEqual {
      floor = -16,
      ceiling = 128,
      floorTex = 'FLOOR0',
      ceilingTex = 'CEIL0',
      light = 192,
      special = 2,
      tag = 4,
    }
    expect(map.things[1]).toEqual { x = 16, y = 24, angle = 90, kind = 1, flags = 7 }
    expect(map.segs[1]).toEqual { v1 = 1, v2 = 2, line = 1, side = 0 }
    expect(mapModule.subsector(map, 80, 20)).toEqual { count = 1, first = 1 }
    expect(mapModule.playerStart(map, 1)).toBe(map.things[1])
    expect(function() mapModule.playerStart(map, 2) end).toThrow 'no player 2 start'
  end)

  suite.it('resolves a sector through the empty-BSP fallback', function()
    local sector = {
      floor = 0,
      ceiling = 128,
      floorTex = 'FLOOR0',
      ceilingTex = 'CEIL0',
      light = 192,
      special = 0,
      tag = 0,
    }
    local map: mapModule.Map = {
      name = 'TEST',
      vertices = {},
      lines = { { v1 = 1, v2 = 1, flags = 0, special = 0, tag = 0, right = 0, left = 0 } },
      sides = { { xOffset = 0, yOffset = 0, upper = '', lower = '', middle = '', sector = 1 } },
      sectors = { sector },
      things = {},
      segs = { { v1 = 1, v2 = 1, line = 1, side = 0 } },
      subsectors = { { count = 1, first = 1 } },
      nodes = {},
    }

    expect(mapModule.sectorAt(map, 0, 0)).toBe(sector)
  end)
end)

suite.describe('deterministic core', function()
  suite.it('preserves fixed-point products, division, and saturation', function()
    expect(fixed.mul(fixed.FRACUNIT, fixed.FRACUNIT)).toBe(fixed.FRACUNIT)
    expect(fixed.mul(-1, fixed.FRACUNIT)).toBe(-1)
    expect(fixed.mul(-1, 1)).toBe(-1)
    expect(fixed.div(fixed.FRACUNIT, 2 * fixed.FRACUNIT)).toBe(32768)
    expect(fixed.div(fixed.MAXINT, 0)).toBe(fixed.MAXINT)
    expect(fixed.div(fixed.MININT, 0)).toBe(fixed.MININT)
  end)

  suite.it('uses separate vanilla random streams and canonical state bytes', function()
    local rng = random.new()
    expect(random.pRandom(rng)).toBe(8)
    expect(random.pRandom(rng)).toBe(109)
    expect(random.mRandom(rng)).toBe(8)
    expect(rng).toEqual({ mIndex = 1, pIndex = 2 })

    local value = { z = 3, a = { true, 7 } }
    local encoded = state.encode(value)
    expect(state.hash(value)).toBe(state.fnv1a64(encoded))
    expect(state.decode(encoded)).toEqual(value)
    expect(save.load(save.save(value))).toEqual(value)
  end)
end)

suite.describe('game tick', function()
  suite.it('spawns, advances, hashes, and saves a deterministic player', function()
    local wad = wadModule.open(writeFixture(fixture()))
    local map = mapModule.load(wad, 'E1M1')
    local game = gameModule.new(map, { spawnMonsters = false })
    local before = gameModule.stateHash(game)
    gameModule.step(game, { { forwardmove = 20, sidemove = 0, angleturn = 0, buttons = 0 } })
    expect(game.gametic).toBe(1)
    expect(gameModule.stateHash(game) ~= before).toBe(true)
    local restored = save.load(save.save(gameModule.snapshot(game)))
    expect(state.hash(restored)).toBe(state.hash(gameModule.snapshot(game)))
  end)
end)

suite.describe('actors and lookup tables', function()
  suite.it('uses exact table endpoints and metadata-backed actors', function()
    expect(tables.fineSine(0)).toBe(25)
    expect(tables.fineCosine(0)).toBe(65535)
    expect(tables.tanToAngle(0)).toBe(0)
    expect(info.monster(3001).name).toBe('imp')
    expect(info.monster(16).health).toBe(4000)
    expect(info.weapon(info.WP_SHOTGUN).pellets).toBe(7)
    expect(info.pickup(2001).weapon).toBe(info.WP_SHOTGUN)
  end)
end)

return suite
