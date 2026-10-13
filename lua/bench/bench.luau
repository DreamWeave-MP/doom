--!strict
--!native
-- The Doom package, timed from Luau: the WAD, map, texture and patch readers, the indexed
-- renderer, demo playback, play saves, observations, the canonical state encoder, and the wire
-- codec. Run on a release build as
--   jess run --package lua --package-path .. --capability filesystem.read
--     --capability network.transport lua/bench/bench.luau [wad folder] [filter] [pin]
-- It prints one line per workload: its name, a tab, and the seconds one call takes. The WAD
-- workloads need `doom.wad` in the folder given (the working folder by default) and are left out
-- without it. Every workload's result is checked: against the value pinned below when the WAD is
-- the 2024 re-release the tests know, and against its own first result otherwise, so a path that
-- stopped doing the work, or a save that changed a byte, fails here. `pin` as the third argument
-- prints each result instead of timing it.
local agent = require '@doom/agent'
local bytes = require '@dream/bytes'
local demoModule = require '@doom/demo'
local doom = require '@doom'
local mapModule = require '@doom/map'
local net = require '@doom/net'
local paletteModule = require '@doom/palette'
local play = require '@doom/play'
local render = require '@doom/render'
local save = require '@doom/save'
local state = require '@doom/state'
local textureModule = require '@doom/texture'
local wadModule = require '@doom/wad'

-- A build without the verified toolchain runs Luau slower than a release does, so a number from
-- one says nothing about what ships.
if not jess.bench.verified then
  error('doom bench: this jess was built without the verified toolchain: measure on a release build', 0)
end

local folder: string?, filter: string?, mode: string? = ...
local only = if filter and filter ~= '' then filter else nil
local pinning = mode == 'pin'
local fs = jess.fs
local wadPath = fs.join(folder or fs.cwd(), 'doom.wad')

-- The size of the 2024 re-release's doom.wad, the one the pinned results below were taken from.
local KnownSize = 12996515

-- What each WAD workload returns on that file.
local Pinned: { [string]: number | string } = {
  ['wad: open'] = 2308,
  ['wad: read 256 lumps'] = 1126052,
  ['map: load E1M1'] = 2695,
  ['map: sectorAt, 1024 points of E1M1'] = -21544,
  ['demo: parse DEMO1'] = 1710,
  ['texture: load every texture'] = 4056978402,
  ['patch: draw the title'] = 2215895150,
  ['palette: frame to PPM'] = 2867125536,
  ['palette: nearest, 512 colours'] = 76526,
  ['render: automap of E1M1'] = 2280236154,
  ['render: view of E1M1'] = 3229234356,
  ['render: view with things, E1M5 at tic 800'] = 2574146364,
  ['play: DEMO1, 1710 tics of E1M5'] = '6c20fbaa',
  ['play: DEMO3, 3863 tics of E3M5'] = '7dd89ed9',
  ['play: save at tic 800'] = 3600806443,
  ['play: load a save'] = 'f418ff4f',
  ['play: hash'] = 'f418ff4f',
  ['play: observe'] = 5693,
  ['agent: describe'] = 2643029435,
}

local function median(samples: { number }): number
  table.sort(samples)
  return samples[(#samples + 1) // 2]
end

-- A full collection, run between batches, so one batch's garbage is not the next one's collection.
local collect = jess.bench.collect

--- Seconds per call of `body`: warmed up, then the median of seven batches of a size that takes
--- about a tenth of a second. `verify` is given the result of the first call and of one more
--- after the last batch, outside the time.
local function measure(body: () -> unknown, verify: (result: unknown) -> ()): number
  collect()
  verify(body())

  local start = os.clock()
  body()

  local once = math.max(os.clock() - start, 1e-7)
  local iterations = math.max(1, math.floor(0.1 / once))
  local samples = {}
  for batch = 1, 7 do
    collect()
    start = os.clock()
    for _ = 1, iterations do
      body()
    end

    samples[batch] = (os.clock() - start) / iterations
  end

  verify(body())
  return median(samples)
end

local rows: { string } = {}

--- Times the workload `make` returns. Its every call must return `expected`, or, with none, what
--- its first call returned.
local function workload(name: string, make: () -> () -> unknown, expected: (number | string)?)
  if only and not string.find(name, only, 1, true) then return end

  local body = make()
  if pinning then
    table.insert(rows, `{name}\t{body()}`)
    return
  end

  local first: unknown = expected
  local function verify(result: unknown)
    if first == nil then first = result end
    if result ~= first then error(`doom bench: {name} returned {result}, not {first}`, 0) end
  end

  table.insert(rows, `{name}\t{string.format('%.9f', measure(body, verify))}`)
end

local function checksum(data: buffer): number
  return bytes.crc32(data)
end

--- A record shaped like a small game snapshot: nested tables, mixed keys, text and a buffer.
local function snapshot(): { [string]: unknown }
  local actors = {}
  for index = 1, 400 do
    actors[index] = {
      id = index,
      kind = `actor-{index % 17}`,
      east = index * 65536 + 0.5,
      north = -index * 4096,
      alive = index % 3 ~= 0,
      inventory = { index % 5, index % 7, index % 11 },
      flags = { solid = true, shootable = index % 2 == 0 },
    }
  end

  local pixels = buffer.create(16384)
  for offset = 0, 16383 do
    buffer.writeu8(pixels, offset, (offset * 31 + 7) % 256)
  end

  return { version = 3, map = 'E1M1', tic = 4200, actors = actors, pixels = pixels }
end

local function stateWorkloads()
  local record = snapshot()
  local encoded = state.encode(record)

  workload('state: encode a snapshot', function()
    return function(): unknown
      return checksum(state.encode(record))
    end
  end, 3185065094)

  workload('state: decode a snapshot', function()
    return function(): unknown
      return #state.decode(encoded).actors
    end
  end, 400)

  workload('state: fnv1a64 of an encoded snapshot', function()
    return function(): unknown
      return state.fnv1a64(encoded)
    end
  end, '4a8f73c5fbe12341')

  workload('state: fnv1a32 of an encoded snapshot', function()
    return function(): unknown
      return state.fnv1a32(encoded)
    end
  end, '1a2055e1')

  workload('save: envelope round trip', function()
    return function(): unknown
      return save.load(save.save(record)).tic
    end
  end, 4200)
end

local function netWorkloads()
  local bundle = { firstTic = 1000, player = 2, commands = {} }
  for index = 1, net.MAX_BUNDLE_TICS do
    bundle.commands[index] = {
      forward = index * 4 - 25,
      side = 25 - index * 3,
      angleTurn = index * 512 - 3072,
      consistency = index * 97,
      chat = 0,
      buttons = index % 4,
    }
  end

  workload('net: pack and unpack 64 tic bundles', function()
    return function(): unknown
      local total = 0
      for _ = 1, 64 do
        local unpacked = net.unpackTicBundle(net.packTicBundle(bundle))
        total += unpacked.commands[7].angleTurn + #unpacked.commands
      end

      return total
    end
  end, 33536)
end

local function readerWorkloads(wad: wadModule.Wad)
  workload('wad: open', function()
    return function(): unknown
      return #wadModule.open(wadPath).lumps
    end
  end, Pinned['wad: open'])

  workload('wad: read 256 lumps', function()
    local names = {}
    for index = 1, 256 do
      names[index] = wad.lumps[index * 9].name
    end

    return function(): unknown
      local total = 0
      for _, name in names do
        total += buffer.len(wad:read(name))
      end

      return total
    end
  end, Pinned['wad: read 256 lumps'])

  workload('map: load E1M1', function()
    return function(): unknown
      local map = mapModule.load(wad, 'E1M1')
      return #map.vertices + #map.lines + #map.sides + #map.sectors + #map.segs + #map.nodes
    end
  end, Pinned['map: load E1M1'])

  workload('map: sectorAt, 1024 points of E1M1', function()
    local map = mapModule.load(wad, 'E1M1')
    return function(): unknown
      local total = 0
      for row = 0, 31 do
        for column = 0, 31 do
          total += mapModule.sectorAt(map, -700 + column * 140, -4800 + row * 80).floor
        end
      end

      return total
    end
  end, Pinned['map: sectorAt, 1024 points of E1M1'])

  workload('demo: parse DEMO1', function()
    local data = wad:read('DEMO1')
    return function(): unknown
      local _, frames = demoModule.parseFull(data)
      return #frames
    end
  end, Pinned['demo: parse DEMO1'])
end

--- One number for every texture of a bank: the checksums of their pixels and masks, by name.
local function bankChecksum(bank: textureModule.Bank): number
  local names = {}
  for name in bank.textures do
    table.insert(names, name)
  end

  table.sort(names)

  local total = 0
  for _, name in names do
    local texture = bank.textures[name]
    total = (total * 31 + checksum(texture.pixels) + checksum(texture.opaque) + texture.width) % 4294967296
  end

  return total
end

local function renderWorkloads(wad: wadModule.Wad)
  workload('texture: load every texture', function()
    local first = true
    return function(): unknown
      local bank = textureModule.load(wad)
      if not first then return Pinned['texture: load every texture'] end

      -- The checksum is taken once: it costs as much as the load it checks.
      first = false
      return bankChecksum(bank)
    end
  end, Pinned['texture: load every texture'])

  workload('patch: draw the title', function()
    return function(): unknown
      return checksum((render.title(wad)).pixels)
    end
  end, Pinned['patch: draw the title'])

  workload('palette: frame to PPM', function()
    local frame, palette = render.title(wad)
    return function(): unknown
      return checksum(render.ppm(frame, palette))
    end
  end, Pinned['palette: frame to PPM'])

  workload('palette: nearest, 512 colours', function()
    local palette = paletteModule.fromPlaypal(wad:read('PLAYPAL'), 0)
    return function(): unknown
      local total = 0
      for index = 0, 511 do
        total += palette:nearest(index % 256, (index * 7) % 256, (index * 13) % 256)
      end

      return total
    end
  end, Pinned['palette: nearest, 512 colours'])

  workload('render: automap of E1M1', function()
    local map = mapModule.load(wad, 'E1M1')
    return function(): unknown
      return checksum((render.automap(map, wad)).pixels)
    end
  end, Pinned['render: automap of E1M1'])

  workload('render: view of E1M1', function()
    local map = mapModule.load(wad, 'E1M1')
    local start = mapModule.playerStart(map, 1)
    return function(): unknown
      return checksum((render.view(map, wad, start.x, start.y, start.angle)).pixels)
    end
  end, Pinned['render: view of E1M1'])
end

local function playWorkloads(wad: wadModule.Wad)
  workload('play: DEMO1, 1710 tics of E1M5', function()
    return function(): unknown
      return play.playDemo(wad, 'DEMO1').summary.hash
    end
  end, Pinned['play: DEMO1, 1710 tics of E1M5'])

  workload('play: DEMO3, 3863 tics of E3M5', function()
    return function(): unknown
      return play.playDemo(wad, 'DEMO3').summary.hash
    end
  end, Pinned['play: DEMO3, 3863 tics of E3M5'])

  -- The workloads below share one game: DEMO1 stopped at tic 800, mid-fight.
  local function midDemo()
    play.playDemo(wad, 'DEMO1', 800)
  end

  workload('play: save at tic 800', function()
    midDemo()
    return function(): unknown
      return checksum(play.save())
    end
  end, Pinned['play: save at tic 800'])

  workload('play: load a save', function()
    midDemo()

    local saved = play.save()
    return function(): unknown
      play.load(wad, saved)
      return play.hash()
    end
  end, Pinned['play: load a save'])

  workload('play: hash', function()
    midDemo()
    return function(): unknown
      return play.hash()
    end
  end, Pinned['play: hash'])

  workload('play: observe', function()
    midDemo()
    return function(): unknown
      local view = play.observe(0)
      local total = #view.things * 1000
      for _, wall in view.walls do
        total += wall.clear
      end

      for _, thing in view.things do
        total += thing.distance
      end

      return total
    end
  end, Pinned['play: observe'])

  workload('agent: describe', function()
    midDemo()
    return function(): unknown
      return bytes.crc32(agent.describe(0))
    end
  end, Pinned['agent: describe'])

  workload('render: view with things, E1M5 at tic 800', function()
    midDemo()
    return function(): unknown
      return checksum(doom.render().frame.pixels)
    end
  end, Pinned['render: view with things, E1M5 at tic 800'])
end

stateWorkloads()
netWorkloads()

if fs.exists(wadPath) then
  -- Another doom.wad is still timed; its results are only held to their own first call.
  if fs.size(wadPath) ~= KnownSize then table.clear(Pinned) end

  local wad = wadModule.open(wadPath)
  readerWorkloads(wad)
  renderWorkloads(wad)
  playWorkloads(wad)
end

for _, row in rows do
  print(row)
end

return rows
