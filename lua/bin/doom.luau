--!strict
local doom = require("@doom")

local function usage(): ()
    print("doom.jpk headless harness")
    print("  title     <IWAD> <out.ppm>")
    print("  map       <IWAD> <E1M1|MAP01> <out.ppm> [DEMO1]")
    print("  view      <IWAD> <E1M1|MAP01> <out.ppm> [DEMO1] [tics]")
    print("  info      <IWAD>")
    print("  run       <IWAD> <MAP> [tics] [DEMO1]")
    print("  trace     <IWAD> <MAP> [DEMO1] [tics]")
    print("  statehash <IWAD> <MAP> [tics] [DEMO1]")
    print("  save      <IWAD> <MAP> <save> [tics] [DEMO1]")
    print("  load      <IWAD> <MAP> <save> [out.ppm]")
    print("  net       <connect-token> [bind]  (client only; requires dream.net host API)")
end

local command = arg[1] or "help"
local wad = arg[2]
if command == "help" or (not wad and command ~= "net") then
    usage()
    return
end

if command == "info" then
    local r = doom.info(wad)
    print(`{r.kind} {r.lumps} lumps: {r.path}`)
elseif command == "title" then
    local out = arg[3] or "doom-title.ppm"
    local r = doom.renderTitle(wad, out)
    print(`wrote {r.output}: {r.width}x{r.height} {r.lump}`)
elseif command == "view" then
    local mapName = arg[3] or "E1M1"
    local out = arg[4] or "doom-view.ppm"
    local demoName = arg[5]
    local tics = tonumber(arg[6] or "0") or 0
    local r = doom.renderView(wad, mapName, out, demoName, tics)
    print(`wrote {r.output}: {r.map} at ({r.x}, {r.y}) angle {r.angle}, {r.demoTics} demo tics`)
elseif command == "map" then
    local mapName = arg[3] or "E1M1"
    local out = arg[4] or "doom-map.ppm"
    local demoName = arg[5]
    local r = doom.renderMap(wad, mapName, out, demoName)
    print(`wrote {r.output}: {r.map}, {r.vertices} vertices, {r.lines} lines, {r.sectors} sectors, {r.things} things, {r.demoTics} demo tics`)
elseif command == "run" then
    local mapName = arg[3] or "E1M1"
    local count = tonumber(arg[4] or "35") or 35
    local demoName = arg[5]
    local game = doom.run(wad, mapName, count, demoName)
    print(`ran {game.gametic} tics on {game.map.name}; state hash {doom.stateHash(game)}`)
elseif command == "trace" then
    local mapName = arg[3] or "E1M1"
    local demoName = if tonumber(arg[4] or "") then nil else arg[4]
    local count = if demoName then (if arg[5] then tonumber(arg[5]) else nil) else tonumber(arg[4])
    local r = doom.trace(wad, mapName, demoName, count)
    print(`trace {r.map}: {r.tics} tics, {#r.points} points, state hash {r.stateHash}`)
    for index, point in r.points do print(`  {index}: ({point.x}, {point.y})`) end
elseif command == "statehash" then
    local mapName = arg[3] or "E1M1"
    local count = tonumber(arg[4] or "0") or 0
    local demoName = arg[5]
    local game = doom.run(wad, mapName, count, demoName)
    print(doom.stateHash(game))
elseif command == "save" then
    local mapName = arg[3] or "E1M1"
    local savePath = arg[4]
    if not savePath then error("save requires <save>") end
    local count = tonumber(arg[5] or "0") or 0
    local demoName = arg[6]
    local game = doom.run(wad, mapName, count, demoName)
    doom.save(game, savePath)
    print(`saved {savePath}: tic {game.gametic}, state hash {doom.stateHash(game)}`)
elseif command == "load" then
    local mapName = arg[3] or "E1M1"
    local savePath = arg[4]
    if not savePath then error("load requires <save>") end
    local game = doom.load(wad, mapName, savePath)
    local output = arg[5]
    local rendered = if output then doom.render(game, output) else nil
    print(`loaded {savePath}: tic {game.gametic}, state hash {doom.stateHash(game)}`)
    if rendered then print(`wrote {rendered.output}: {rendered.width}x{rendered.height}`) end
elseif command == "net" then
    -- This path only uses the existing client-side protocol. A server handle is
    -- intentionally not fabricated; the host remains responsible for hosting it.
    local token = arg[2]
    if not token then error("net requires <connect-token>") end
    local net = require("@doom/net")
    local protocol = net.protocol()
    local client = net.newClient(protocol, { bind = arg[3] })
    net.clientConnect(client, token)
    net.clientUpdate(client)
    net.clientFlush(client)
    local event = net.clientPoll(client, buffer.create(net.POLL_BUFFER_SIZE))
    print(if event then `net client event: {event.kind}` else "net client connected request queued")
else
    error(`unknown command '{command}'`)
end
