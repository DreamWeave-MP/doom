--!strict
-- Standalone launcher distributed beside doom.jpk.
local doom = require("@doom")

local command = arg[1] or "help"
local wad = arg[2]

if command == "help" or (not wad and command ~= "net") then
    print("doom.jpk headless harness")
    print("  info <IWAD>")
    print("  title <IWAD> <out.ppm>")
    print("  map <IWAD> <MAP> <out.ppm> [DEMO]")
    print("  view <IWAD> <MAP> <out.ppm> [DEMO] [tics]")
    print("  run <IWAD> <MAP> [tics] [DEMO]")
    print("  statehash <IWAD> <MAP> [tics] [DEMO]")
    return
end

if command == "info" then
    local result = doom.info(wad)
    print(`{result.kind} {result.lumps} lumps: {result.path}`)
elseif command == "title" then
    local result = doom.renderTitle(wad, arg[3] or "doom-title.ppm")
    print(`wrote {result.output}: {result.width}x{result.height}`)
elseif command == "map" then
    local result = doom.renderMap(wad, arg[3] or "E1M1", arg[4] or "doom-map.ppm", arg[5])
    print(`wrote {result.output}: {result.map}, {result.vertices} vertices, {result.lines} lines`)
elseif command == "view" then
    local result = doom.renderView(wad, arg[3] or "E1M1", arg[4] or "doom-view.ppm", arg[5], tonumber(arg[6]))
    print(`wrote {result.output}: {result.map} at ({result.x}, {result.y}), {result.demoTics} tics`)
elseif command == "run" then
    local game = doom.run(wad, arg[3] or "E1M1", tonumber(arg[4] or "35") or 35, arg[5])
    print(`ran {game.gametic} tics on {game.map.name}; state hash {doom.stateHash(game)}`)
elseif command == "statehash" then
    local game = doom.run(wad, arg[3] or "E1M1", tonumber(arg[4] or "0") or 0, arg[5])
    print(doom.stateHash(game))
else
    error(`unknown command '{command}'`)
end
