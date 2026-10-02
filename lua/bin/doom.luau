--!nonstrict
local doom = require('@doom')

local function usage(): ()
  print('doom.jpk headless harness')
  print('  info      <IWAD>')
  print('  title     <IWAD> <out.ppm>')
  print('  map       <IWAD> <E1M1|MAP01> <out.ppm> [DEMO1]')
  print('  view      <IWAD> <E1M1|MAP01> <out.ppm> [DEMO1] [tics]')
  print('  run       <IWAD> <MAP> [tics] [DEMO1]')
  print('  demo      <IWAD> <DEMO1|file.lmp>')
  print('  trace     <IWAD> <MAP> [DEMO1] [tics]')
  print('  statehash <IWAD> <MAP> [tics] [DEMO1]')
  print('  save      <IWAD> <MAP> <save> [tics] [DEMO1]')
  print('  load      <IWAD> <save> [tics] [out.ppm]')
end

local command = arg[1] or 'help'
local wad = arg[2]
if command == 'help' or not wad then
  usage()
  return
end

local function report(): ()
  local summary = doom.summary()
  print(`{summary.map} {summary.gamestate} at tic {summary.gametic} (level time {summary.leveltime}); state hash {summary.hash}`)
  for _, player in summary.players do
    print(
      `  player {player.slot}: {if player.alive then 'alive' else 'dead'} health {player.health} armor {player.armor}`
        .. ` weapon {player.weapon} at ({player.x}, {player.y}) kills {player.kills}/{summary.totalkills}`
        .. ` items {player.items}/{summary.totalitems} secrets {player.secrets}/{summary.totalsecret}`
    )
  end
end

if command == 'info' then
  local result = doom.info(wad)
  print(`{result.kind} {result.lumps} lumps: {result.path}`)
elseif command == 'title' then
  local result = doom.renderTitle(wad, arg[3] or 'doom-title.ppm')
  print(`wrote {result.output}: {result.width}x{result.height} {result.lump}`)
elseif command == 'view' then
  local result = doom.renderView(wad, arg[3] or 'E1M1', arg[4] or 'doom-view.ppm', arg[5], tonumber(arg[6] or ''))
  print(`wrote {result.output}: {result.map} at ({result.x}, {result.y}) angle {result.angle}, {result.demoTics} demo tics`)
elseif command == 'map' then
  local result = doom.renderMap(wad, arg[3] or 'E1M1', arg[4] or 'doom-map.ppm', arg[5])
  print(
    `wrote {result.output}: {result.map}, {result.vertices} vertices, {result.lines} lines, {result.sectors} sectors, {result.things} things,`
      .. ` {result.demoTics} demo tics`
  )
elseif command == 'run' then
  doom.run(wad, arg[3] or 'E1M1', tonumber(arg[4] or '35') or 35, arg[5])
  report()
elseif command == 'demo' then
  -- A demo is a lump name, or a .lmp file such as an arena match.
  local name = arg[3] or 'DEMO1'
  local result = doom.play.playDemo(wad, if jess.fs.isFile(name) then jess.fs.readBuffer(name) :: buffer else name)
  print(`played {result.tics} of {result.length} demo tics`)
  report()
elseif command == 'trace' then
  local demoName = if tonumber(arg[4] or '') then nil else arg[4]
  local count = tonumber((if demoName then arg[5] else arg[4]) or '')
  doom.run(wad, arg[3] or 'E1M1', count, demoName, function(game: any, tic: number): ()
    if tic % 4 ~= 0 then return end

    local mo = game.players[game.consoleplayer].mo
    print(`  {tic}: ({mo.x / 65536}, {mo.y / 65536})`)
  end)
  report()
elseif command == 'statehash' then
  doom.run(wad, arg[3] or 'E1M1', tonumber(arg[4] or '0') or 0, arg[5])
  print(doom.stateHash())
elseif command == 'save' then
  local savePath = arg[4]
  if not savePath then error('save requires <save>') end

  local game = doom.run(wad, arg[3] or 'E1M1', tonumber(arg[5] or '0') or 0, arg[6])
  doom.save(savePath)
  print(`saved {savePath}: tic {game.gametic}, state hash {doom.stateHash()}`)
elseif command == 'load' then
  local savePath = arg[3]
  if not savePath then error('load requires <save>') end

  local game = doom.load(wad, savePath)
  print(`loaded {savePath}: tic {game.gametic}, state hash {doom.stateHash()}`)
  for _ = 1, tonumber(arg[4] or '0') or 0 do
    doom.step()
  end

  report()
  if arg[5] then
    local rendered = doom.render(arg[5])
    print(`wrote {rendered.output}: {rendered.width}x{rendered.height}`)
  end
else
  error(`unknown command '{command}'`)
end
