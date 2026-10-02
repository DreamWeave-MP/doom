--!nonstrict
--!native
-- The play simulation, tested two ways: rules on a synthetic one-room WAD that
-- needs no game data, and whole-demo playback on the IWADs when they sit in the
-- working folder (they are never part of the package).
local agent = require '@doom/agent'
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

  local lumps = {
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
