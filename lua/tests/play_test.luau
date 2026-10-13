--!nonstrict
--!native
-- The play simulation, tested two ways: rules on a synthetic one-room WAD that
-- needs no game data, and whole-demo playback on the IWADs when they sit in the
-- working folder (they are never part of the package).
local agent = require '@doom/agent'
local bytes = require '@dream/bytes'
local play = require '@doom/play'
local test = require '@jess/test'
local wadModule = require '@doom/wad'
local expect = test.expect
local suite = test.new()
local fs = jess.fs

local TestPath = fs.join(fs.cwd(), 'target', 'doom-tests', 'play.wad')
local FRACUNIT = 65536

local function name8(name: string): string return string.sub(name .. string.rep('\0', 8), 1, 8) end

type Room = {
  things: { { number } },
  lineSpecials: { [number]: number }?,
  sectorSpecial: number?,
}

-- Writes { name, bytes } lumps as the test WAD and returns its path.
local function writeWad(lumps: { { string } }): string
  local parts, directory = {}, {}
  local offset = 12
  for _, lump in lumps do
    table.insert(directory, string.pack('<i4i4', offset, #lump[2]) .. name8(lump[1]))
    table.insert(parts, lump[2])
    offset += #lump[2]
  end

  fs.write(TestPath, 'PWAD' .. string.pack('<i4i4', #lumps, offset) .. table.concat(parts) .. table.concat(directory))
  return TestPath
end

-- One 512 by 512 room with its corner at the origin: four one-sided walls
-- (line 0 west, 1 north, 2 east, 3 south), one sector, one subsector, no nodes.
local function roomWad(room: Room): string
  local corners = { { 0, 0 }, { 0, 512 }, { 512, 512 }, { 512, 0 } }
  local vertexes, lines, sides, segs, things = {}, {}, {}, {}, {}
  local specials = room.lineSpecials or {}
  for index, corner in corners do
    table.insert(vertexes, string.pack('<i2i2', corner[1], corner[2]))
    table.insert(lines, string.pack('<I2I2I2I2I2i2i2', index - 1, index % 4, 1, specials[index - 1] or 0, 0, index - 1, -1))
    table.insert(sides, string.pack('<i2i2', 0, 0) .. name8 '-' .. name8 '-' .. name8 'WALL' .. string.pack('<I2', 0))
    table.insert(segs, string.pack('<I2I2i2I2I2i2', index - 1, index % 4, 0, index - 1, 0, 0))
  end

  for _, thing in room.things do
    table.insert(things, string.pack('<i2i2i2I2I2', thing[1], thing[2], thing[3], thing[4], thing[5] or 7))
  end

  local blockmap = { string.pack('<i2i2i2i2', 0, 0, 5, 5) }
  for _ = 1, 25 do
    table.insert(blockmap, string.pack('<I2', 29))
  end
  table.insert(blockmap, string.pack('<i2i2i2i2i2i2', 0, 0, 1, 2, 3, -1))

  return writeWad {
    { 'E1M1', '' },
    { 'THINGS', table.concat(things) },
    { 'LINEDEFS', table.concat(lines) },
    { 'SIDEDEFS', table.concat(sides) },
    { 'VERTEXES', table.concat(vertexes) },
    { 'SEGS', table.concat(segs) },
    { 'SSECTORS', string.pack('<I2I2', 4, 0) },
    { 'NODES', '' },
    { 'SECTORS', string.pack('<i2i2', 0, 128) .. name8 'FLOOR' .. name8 'CEIL' .. string.pack('<i2i2i2', 160, room.sectorSpecial or 0, 0) },
    { 'REJECT', '\0' },
    { 'BLOCKMAP', table.concat(blockmap) },
  }
end

-- The same room cut in two by a partition running north along x 256, with a one-sided wall
-- standing in the east half along x 384 from y 128 to y 448 (line 4). The west half is one
-- subsector and the east half, which holds the wall's seg, the other; `eastFirst` numbers the
-- east half and its segs first. The player starts in the west half.
local function splitRoomWad(eastFirst: boolean): string
  local vertexes, lines, sides, segs = {}, {}, {}, {}
  for _, spot in { { 0, 0 }, { 0, 512 }, { 512, 512 }, { 512, 0 }, { 256, 512 }, { 256, 0 }, { 384, 128 }, { 384, 448 } } do
    table.insert(vertexes, string.pack('<i2i2', spot[1], spot[2]))
  end

  for index, ends in { { 0, 1 }, { 1, 2 }, { 2, 3 }, { 3, 0 }, { 6, 7 } } do
    table.insert(lines, string.pack('<I2I2I2I2I2i2i2', ends[1], ends[2], 1, 0, 0, index - 1, -1))
    table.insert(sides, string.pack('<i2i2', 0, 0) .. name8 '-' .. name8 '-' .. name8 'WALL' .. string.pack('<I2', 0))
  end

  -- Each seg is { first vertex, last vertex, line }.
  local west = { { 0, 1, 0 }, { 1, 4, 1 }, { 5, 0, 3 } }
  local east = { { 4, 2, 1 }, { 2, 3, 2 }, { 3, 5, 3 }, { 6, 7, 4 } }
  local halves = if eastFirst then { east, west } else { west, east }
  for _, half in halves do
    for _, seg in half do
      table.insert(segs, string.pack('<I2I2i2I2I2i2', seg[1], seg[2], 0, seg[3], 0, 0))
    end
  end

  local blockmap = { string.pack('<i2i2i2i2', 0, 0, 5, 5) }
  for _ = 1, 25 do
    table.insert(blockmap, string.pack('<I2', 29))
  end

  table.insert(blockmap, string.pack('<i2i2i2i2i2i2i2', 0, 0, 1, 2, 3, 4, -1))

  -- East of a partition that runs north is its front, the first child.
  local eastChild = if eastFirst then 0x8000 else 0x8001
  local westChild = if eastFirst then 0x8001 else 0x8000
  return writeWad {
    { 'E1M1', '' },
    { 'THINGS', string.pack('<i2i2i2I2I2', 100, 256, 0, 1, 7) },
    { 'LINEDEFS', table.concat(lines) },
    { 'SIDEDEFS', table.concat(sides) },
    { 'VERTEXES', table.concat(vertexes) },
    { 'SEGS', table.concat(segs) },
    { 'SSECTORS', if eastFirst then string.pack('<I2I2I2I2', 4, 0, 3, 4) else string.pack('<I2I2I2I2', 3, 0, 4, 3) },
    { 'NODES', string.pack('<i2i2i2i2', 256, 0, 0, 512) .. string.rep('\0', 16) .. string.pack('<I2I2', eastChild, westChild) },
    { 'SECTORS', string.pack('<i2i2', 0, 128) .. name8 'FLOOR' .. name8 'CEIL' .. string.pack('<i2i2i2', 160, 0, 0) },
    { 'REJECT', '\0' },
    { 'BLOCKMAP', table.concat(blockmap) },
  }
end

local function run(tics: number, action: play.Action?): ()
  local cmds = { [0] = play.command(action or {}) }
  for _ = 1, tics do
    play.tick(cmds)
  end
end

local function countType(game: any, name: string): number
  local count = 0
  local thinker = game.thinkercap.next
  while thinker ~= game.thinkercap do
    if thinker.think == 'mobj' and thinker.info.name == name then count += 1 end
    thinker = thinker.next
  end

  return count
end

suite.afterEach(function() fs.remove(TestPath) end)

suite.describe('play rules on a synthetic room', function()
  suite.it('generates the full state and thing tables', function()
    local engine = play.engine
    expect(engine.S.S_PLAY).toBe(149)
    expect(engine.MT.MT_BARREL).toBe(30)
    expect(engine.states[966].sprite).toBe('TLP2')
    expect(engine.mobjinfo[engine.MT.MT_CYBORG].spawnhealth).toBe(4000)
    expect(engine.FixedMul(-1, 1)).toBe(-1)
    expect(engine.FixedDiv(FRACUNIT, 2 * FRACUNIT)).toBe(32768)
    expect(engine.PointToAngle2(0, 0, FRACUNIT, FRACUNIT)).toBe(0x1fffffff)
  end)

  suite.it('runs the player into a wall and stops at its radius', function()
    local game = play.new(roomWad { things = { { 256, 64, 90, 1 } } })
    local mo = game.players[0].mo
    expect(mo.z).toBe(0)

    run(140, { forward = 50 })
    expect(math.abs(mo.x - 256 * FRACUNIT) < FRACUNIT).toBe(true)
    expect(mo.y > 480 * FRACUNIT).toBe(true)
    expect(mo.y <= (512 - 16) * FRACUNIT).toBe(true)
  end)

  suite.it('kills a zombieman with the pistol, counts it, and picks up the dropped clip', function()
    local game = play.new(roomWad { things = { { 256, 64, 90, 1 }, { 256, 320, 270, 3004 } } })
    local player = game.players[0]
    expect(game.totalkills).toBe(1)

    for _ = 1, 350 do
      run(1, { attack = true })
      if player.killcount == 1 then break end
    end

    expect(player.killcount).toBe(1)
    expect(player.ammo[0] < 50).toBe(true)
    expect(countType(game, 'MT_CLIP')).toBe(1)

    local before = player.ammo[0]
    run(120, { forward = 50 })
    expect(countType(game, 'MT_CLIP')).toBe(0)
    expect(player.ammo[0]).toBe(before + 5)
  end)

  suite.it('gives a shotgun, switches to it, and fires shells', function()
    local game = play.new(roomWad { things = { { 256, 64, 90, 1 }, { 256, 128, 0, 2001 } } })
    local player = game.players[0]
    run(60, { forward = 25 })
    expect(player.weaponowned[2]).toBe(true)
    expect(player.readyweapon).toBe(2)
    expect(player.ammo[1]).toBe(8)
    expect(player.itemcount).toBe(0)

    run(40, { attack = true })
    expect(player.ammo[1] < 8).toBe(true)
  end)

  suite.it('lets monsters wake, attack, and kill an idle player', function()
    local things = { { 256, 64, 90, 1 } }
    for index = 0, 3 do
      table.insert(things, { 96 + index * 100, 400, 270, 9 })
    end

    local game = play.new(roomWad { things = things }, { skill = 3 })
    local player = game.players[0]
    for _ = 1, 2100 do
      run(1)
      if player.playerstate ~= 0 then break end
    end

    expect(player.health).toBe(0)
    expect(player.playerstate).toBe(play.engine.PST_DEAD)

    -- A single-player death reloads the level on use.
    run(1, { use = true })
    run(1)
    expect(game.players[0].health).toBe(100)
    expect(game.leveltime < 5).toBe(true)
  end)

  suite.it('hurts the player on a damaging floor', function()
    local game = play.new(roomWad { things = { { 256, 64, 90, 1 } }, sectorSpecial = 5 })
    run(70)
    expect(game.players[0].health).toBe(70)
  end)

  suite.it('leaves the level through an exit switch and ends a one-map game', function()
    local game = play.new(roomWad { things = { { 256, 470, 90, 1 } }, lineSpecials = { [1] = 11 } }, { intermissionTics = 5 })
    run(2)
    run(1, { use = true })
    expect(game.lines[2].special).toBe(0)

    run(1)
    expect(game.gamestate).toBe('intermission')
    expect(game.lastlevel.map).toBe('E1M1')

    run(10)
    expect(game.gamestate).toBe('finale')
  end)

  suite.it('scores deathmatch frags and respawns the loser at a deathmatch start', function()
    local things = { { 64, 64, 0, 1 }, { 448, 448, 180, 2 } }
    for _, spot in { { 64, 64 }, { 448, 448 }, { 64, 448 }, { 448, 64 } } do
      table.insert(things, { spot[1], spot[2], 0, 11 })
    end

    local game = play.new(roomWad { things = things }, { deathmatch = 1, players = { true, true }, nomonsters = true })
    expect(game.netgame).toBe(true)
    expect(game.players[0].cards[0]).toBe(true)

    for _ = 1, 3000 do
      local view = play.observe(0)
      local target
      for _, thing in view.things do
        if thing.kind == 'player' then target = thing end
      end

      local action: play.Action = { attack = true }
      if target then action.turn = math.clamp(target.bearing, -20, 20) end
      play.tick { [0] = play.command(action) }
      if game.players[0].frags[1] > 0 then break end
    end

    expect(game.players[0].frags[1]).toBe(1)
    expect(game.players[1].playerstate).toBe(play.engine.PST_DEAD)

    local corpse = game.players[1].mo
    play.tick { [1] = play.command { use = true } }
    play.tick {}
    expect(game.players[1].playerstate).toBe(play.engine.PST_LIVE)
    expect(game.players[1].health).toBe(100)
    expect(game.players[1].mo ~= corpse).toBe(true)
    expect(game.players[0].frags[1]).toBe(1)
  end)

  suite.it('restores a save to the same future', function()
    local path = roomWad { things = { { 256, 64, 90, 1 }, { 200, 400, 270, 3001 }, { 320, 400, 270, 3004 } } }
    play.new(path)
    run(90, { forward = 20, attack = true })
    local saved = play.save()
    run(200, { turn = 3, attack = true })
    local expected = play.hash()

    play.new(path)
    local game = play.load(path, saved)
    expect(game.gametic).toBe(90)
    run(200, { turn = 3, attack = true })
    expect(play.hash()).toBe(expected)
  end)

  suite.it('finds subsectors and checks sight through the BSP of whichever level is current', function()
    local engine = play.engine

    -- What CheckSight reads of a thing, standing at a spot given in map units.
    local function stand(east: number, north: number): any
      local thing: any = { height = 56 * FRACUNIT }
      thing.x, thing.y, thing.z = east * FRACUNIT, north * FRACUNIT, 0
      thing.subsector = engine.PointInSubsector(thing.x, thing.y)
      return thing
    end

    local function sees(fromEast: number, fromNorth: number, toEast: number, toNorth: number): boolean
      return engine.CheckSight(stand(fromEast, fromNorth), stand(toEast, toNorth))
    end

    local function expectTheSplitRoom(eastFirst: boolean)
      local game = play.game
      local west = game.subsectors[if eastFirst then 2 else 1]
      local east = game.subsectors[if eastFirst then 1 else 2]

      expect({ #game.nodes, #game.subsectors, #game.segs, west.numlines, east.numlines }).toEqual { 1, 2, 7, 3, 4 }
      expect(engine.PointInSubsector(100 * FRACUNIT, 256 * FRACUNIT)).toBe(west)
      expect(engine.PointInSubsector(400 * FRACUNIT, 30 * FRACUNIT)).toBe(east)
      expect(engine.PointInSubsector(257 * FRACUNIT, 500 * FRACUNIT)).toBe(east)
      expect(engine.PointInSubsector(256 * FRACUNIT, 40 * FRACUNIT)).toBe(west)
      expect(game.players[0].mo.subsector).toBe(west)

      -- The wall hides what lies across it, from inside its own half and from the other one.
      expect(sees(300, 250, 450, 262)).toBe(false)
      expect(sees(450, 262, 300, 250)).toBe(false)
      expect(sees(100, 250, 450, 262)).toBe(false)
      expect(sees(450, 400, 100, 100)).toBe(false)
      expect(sees(300, 200, 450, 200)).toBe(false)

      -- Past its ends, short of it, and beside it, nothing is hidden.
      expect(sees(300, 60, 450, 70)).toBe(true)
      expect(sees(450, 460, 300, 455)).toBe(true)
      expect(sees(100, 20, 450, 100)).toBe(true)
      expect(sees(100, 250, 300, 262)).toBe(true)
      expect(sees(100, 100, 110, 400)).toBe(true)
      expect(sees(300, 100, 310, 400)).toBe(true)
      expect(sees(400, 100, 400, 400)).toBe(true)

      -- P_DivlineSide compares a point's x with a level line's y, so a look due east along
      -- y 384 takes both ends of the wall at x 384 to be on it, and sees through.
      expect(sees(300, 384, 450, 384)).toBe(true)
    end

    -- Each level numbers its subsectors and segs the other way round from the one before it.
    local saves = {}
    for round, eastFirst in { false, true, false } do
      local wad = wadModule.open(splitRoomWad(eastFirst))
      play.new(wad, { nomonsters = true })
      expectTheSplitRoom(eastFirst)
      saves[round] = { wad = wad, eastFirst = eastFirst, data = play.save() }
    end

    -- A restored game brings its own level back, whatever was walked last.
    for _, saved in { saves[2], saves[1], saves[3], saves[2] } do
      play.load(saved.wad, saved.data)
      expectTheSplitRoom(saved.eastFirst)
    end

    -- A level with no nodes at all is its one subsector.
    local game = play.new(roomWad { things = { { 256, 64, 90, 1 } } })
    expect(engine.PointInSubsector(400 * FRACUNIT, 30 * FRACUNIT)).toBe(game.subsectors[1])
    expect(sees(300, 250, 450, 262)).toBe(true)
  end)

  suite.it('writes a save as numbered tables, a table numbering its keyed part before its array part', function()
    local path = roomWad { things = { { 256, 64, 90, 1 } } }
    local game = play.new(path)
    table.clear(game)

    local shared = { 7 }
    game[1], game[2], game[3], game[4] = 1.5, 'two', true, shared
    game.only = { false, shared, buffer.fromstring 'raw' }

    expect(bytes.toHex(play.save())).toBe(table.concat {
      -- The magic and the count of tables.
      '44504c5902',
      '03000000',
      -- The game, four in its array part and one keyed: 1.5, 'two', true and table 3, then
      -- 'only', which is table 2 though `shared` comes before it here.
      '04000000',
      '01000000',
      '01000000000000f83f',
      '020300000074776f',
      '03',
      '0503000000',
      '02040000006f6e6c79',
      '0502000000',
      -- `only`: false, table 3 and a buffer.
      '03000000',
      '00000000',
      '04',
      '0503000000',
      '0603000000726177',
      -- `shared`: 7.
      '01000000',
      '00000000',
      '010000000000001c40',
    })

    game.unsaved = print
    expect(function() play.save() end).toThrow 'doom save: cannot store a function'

    game.unsaved = nil
    local restored = play.load(path, play.save())
    expect(restored).toBe(game)
    expect({ restored[1], restored[2], restored[3] }).toEqual { 1.5, 'two', true }
    expect(restored.only[2]).toBe(restored[4])
    expect(buffer.tostring(restored.only[3])).toBe 'raw'
    expect(restored[4][1]).toBe(7)

    play.new(path)
  end)
end)

suite.describe('agent plans', function()
  suite.it('parses steps and spreads a turn across its tics', function()
    local steps = agent.parseSteps { 'forward=50 turn=90 for=4', 'attack weapon=shotgun for=2' }
    expect(agent.planTics(steps)).toBe(6)
    expect(steps[1].turn).toBe(16384)
    expect(function() agent.parseSteps { 'jump' } end).toThrow('unknown plan word')

    local plan = { seq = 1, steps = steps, at = 1, left = 4, turnLeft = 16384 }
    local turned = 0
    for _ = 1, 4 do
      local cmd = agent.nextCommand(plan)
      expect(cmd.forwardmove).toBe(50)
      turned += cmd.angleturn
    end

    expect(turned).toBe(16384)
    expect(agent.nextCommand(plan).buttons).toBe(1 + 4 + 2 * 8)
    expect(agent.nextCommand(plan).buttons).toBe(1)
    expect(agent.nextCommand(plan)).toBe(nil)
  end)

  suite.it('describes what a slot can see', function()
    play.new(roomWad { things = { { 256, 64, 90, 1 }, { 256, 320, 270, 3004 } } })
    local text = agent.describe(0)
    expect(string.find(text, 'ALIVE health 100', 1, true) ~= nil).toBe(true)
    expect(string.find(text, 'in sight: monster possessed distance 256 bearing 0', 1, true) ~= nil).toBe(true)
  end)
end)

-- { file, demo, map, tics, final hash, kills, final x, final y }, taken from the
-- 2024 re-release IWADs. Every one of these demos ends with the recording
-- player dead, which only happens when the whole playback stays in sync.
local Demos = {
  { 'doom.wad', 12996515, 'DEMO1', 'E1M5', 1710, '6c20fbaa' },
  { 'doom.wad', 12996515, 'DEMO2', 'E2M2', 2347, '003d1c36' },
  { 'doom.wad', 12996515, 'DEMO3', 'E3M5', 3863, '7dd89ed9' },
  { 'doom.wad', 12996515, 'DEMO4', 'E4M2', 818, 'afef115c' },
  { 'doom2.wad', 14951361, 'DEMO1', 'MAP11', 1205, 'd9b50444' },
  { 'doom2.wad', 14951361, 'DEMO2', 'MAP05', 2001, 'e7fa0857' },
  { 'doom2.wad', 14951361, 'DEMO3', 'MAP26', 4471, '41220657' },
  { 'plutonia.wad', 17704206, 'DEMO1', 'MAP17', 7403, '25111cb5' },
  { 'plutonia.wad', 17704206, 'DEMO2', 'MAP10', 3483, '3fb2e4d4' },
  { 'plutonia.wad', 17704206, 'DEMO3', 'MAP12', 5662, 'f28fd19a' },
  { 'tnt.wad', 18507237, 'DEMO1', 'MAP01', 4531, '42a8c70a' },
  { 'tnt.wad', 18507237, 'DEMO2', 'MAP12', 3653, '4c791c8c' },
  { 'tnt.wad', 18507237, 'DEMO3', 'MAP13', 3433, '50c73190' },
}

suite.describe('IWAD demos', function()
  suite.it('play every built-in demo to the recorded death', function()
    local wads = {}
    for _, demo in Demos do
      local path = fs.join(fs.cwd(), demo[1])
      if not fs.exists(path) then continue end

      wads[path] = wads[path] or wadModule.open(path)
      local result = play.playDemo(wads[path], demo[3])
      local player = result.summary.players[1]
      expect(result.summary.map).toBe(demo[4])
      expect(result.tics).toBe(demo[5])
      expect(player.alive).toBe(false)
      if fs.size(path) == demo[2] then expect(result.summary.hash).toBe(demo[6]) end
    end
  end)

  suite.it('walks a campaign from one map to the next', function()
    local path = fs.join(fs.cwd(), 'doom.wad')
    if not fs.exists(path) then return end

    local game = play.new(path, { mapName = 'E1M1', intermissionTics = 3 })
    game.players[0].ammo[0] = 37
    play.engine.ExitLevel()
    run(8)
    expect(game.mapname).toBe('E1M2')
    expect(game.gamestate).toBe('level')
    expect(game.players[0].ammo[0]).toBe(37)

    play.engine.SecretExitLevel()
    run(8)
    expect(game.mapname).toBe('E1M9')
    play.engine.ExitLevel()
    run(8)
    expect(game.mapname).toBe('E1M4')
  end)
end)

return suite
