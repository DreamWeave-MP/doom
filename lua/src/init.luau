--!nonstrict
-- @doom: the host-facing root. Opens WADs, runs the play simulation headless,
-- and draws the title, automap, and first-person view to indexed frames.
local fs = require('@jess/fs')
local wadModule = require('@doom/wad')
local mapModule = require('@doom/map')
local render = require('@doom/render')
local demoModule = require('@doom/demo')
local play = require('@doom/play')

local module = {}

local FracUnit = 65536

module.play = play

function module.info(path: string): any
  local wad = wadModule.open(path)
  return { kind = wad.kind, lumps = #wad.lumps, path = path }
end

function module.renderTitle(path: string, output: string): any
  local wad = wadModule.open(path)
  local frame, palette = render.title(wad)
  fs.write(output, render.ppm(frame, palette))
  return { output = output, width = frame.width, height = frame.height, lump = 'TITLEPIC' }
end

-- Starts `mapName` and runs `count` tics, fed by a demo lump's commands when
-- one is named. `eachTic(game, tic)` runs after every tic.
function module.run(path: string, mapName: string?, count: number?, demoName: string?, eachTic: ((any, number) -> ())?): any
  local wad = wadModule.open(path)
  local frames, options = nil, { mapName = mapName or 'E1M1' } :: any
  if demoName then
    local header
    header, frames = demoModule.parseFull(wad:read(demoName))
    options = {
      skill = header.skill,
      episode = header.episode,
      map = header.map,
      deathmatch = header.deathmatch,
      respawn = header.respawn ~= 0,
      fast = header.fast ~= 0,
      nomonsters = header.nomonsters ~= 0,
      consoleplayer = header.consolePlayer,
      players = header.players,
      netgame = header.players[2],
    }
  end

  local game = play.new(wad, options)
  local cmds = {}
  for tic = 1, count or (if frames then #frames else 35) do
    local frame = frames and frames[tic]
    for slot = 0, 3 do
      cmds[slot] = frame and frame[slot + 1]
    end

    play.tick(cmds)
    if eachTic then eachTic(game, tic) end
  end

  return game
end

module.step = play.tick
module.stateHash = play.hash
module.summary = play.summary

function module.save(path: string?): buffer
  local data = play.save()
  if path then fs.write(path, data) end
  return data
end

function module.load(path: string, source: string | buffer): any
  local data = if type(source) == 'string' then fs.readBuffer(source) else source
  if not data then error(`doom: cannot read save '{source}'`, 2) end

  play.load(path, data)
  return play.game
end

local function consoleView(game: any): (number, number, number)
  local mo = game.players[game.consoleplayer].mo
  return mo.x / FracUnit, mo.y / FracUnit, mo.angle * 360 / 4294967296
end

local function mobjList(game: any): { any }
  local list = {}
  local cap = game.thinkercap
  local thinker = cap.next
  local own = game.players[game.consoleplayer].mo
  while thinker ~= cap do
    if thinker.think == 'mobj' and thinker ~= own then table.insert(list, thinker) end
    thinker = thinker.next
  end

  return list
end

-- Draws the current game from the console player's eyes. The frame uses the
-- map's static geometry: sectors moved by doors and lifts draw where they began.
function module.render(output: string?): any
  local game = play.game
  local x, y, angle = consoleView(game)
  local map = mapModule.load(game.wad, game.mapname)
  local frame, palette = render.view(map, game.wad, x, y, angle, mobjList(game))
  if output then fs.write(output, render.ppm(frame, palette)) end
  return { output = output, map = game.mapname, x = x, y = y, angle = angle, width = frame.width, height = frame.height, frame = frame, palette = palette }
end

function module.renderView(path: string, mapName: string, output: string, demoName: string?, demoTics: number?): any
  local game = module.run(path, mapName, if demoName then demoTics else 1, demoName)
  local result = module.render(output)
  result.demoTics = if demoName then game.gametic else 0
  return result
end

function module.renderMap(path: string, mapName: string, output: string, demoName: string?): any
  local wad = wadModule.open(path)
  local map = mapModule.load(wad, mapName)
  local trace = nil
  local demoTics = 0
  if demoName then
    trace = {}
    local game = module.run(path, mapName, nil, demoName, function(game: any, tic: number): ()
      if tic % 4 ~= 0 then return end

      local x, y = consoleView(game)
      table.insert(trace, { x = x, y = y })
    end)
    demoTics = game.gametic
  end

  local frame, palette = render.automap(map, wad, trace)
  fs.write(output, render.ppm(frame, palette))
  return {
    output = output,
    map = mapName,
    vertices = #map.vertices,
    lines = #map.lines,
    sectors = #map.sectors,
    things = #map.things,
    demoTics = demoTics,
  }
end

return module
