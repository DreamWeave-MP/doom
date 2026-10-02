--!strict
local doom = require("@doom")

local command = arg[1] or "help"
local wad = arg[2]
if command == "help" or not wad then
    print("doom.jpk headless harness")
    print("  title <IWAD> <out.ppm>")
    print("  map   <IWAD> <E1M1|MAP01> <out.ppm> [DEMO1]")
    print("  view  <IWAD> <E1M1|MAP01> <out.ppm> [DEMO1] [tics]")
    print("  info  <IWAD>")
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
else
    error(`unknown command '{command}'`)
end
