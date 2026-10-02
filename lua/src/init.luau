--!strict
local fs = require("@jess/fs")
local wadModule = require("@doom/wad")
local mapModule = require("@doom/map")
local render = require("@doom/render")
local demo = require("@doom/demo")
local sim = require("@doom/sim")

local module = {}

function module.info(path: string): any
    local wad = wadModule.open(path)
    return { kind = wad.kind, lumps = #wad.lumps, path = path }
end

function module.renderTitle(path: string, output: string): any
    local wad = wadModule.open(path)
    local frame, palette = render.title(wad)
    fs.write(output, render.ppm(frame, palette))
    return { output = output, width = frame.width, height = frame.height, lump = "TITLEPIC" }
end

function module.renderMap(path: string, mapName: string, output: string, demoName: string?): any
    local wad = wadModule.open(path)
    local map = mapModule.load(wad, mapName)
    local trace = nil
    local demoTics = 0
    if demoName then
        local _, tics = demo.parse(wad:read(demoName))
        demoTics = #tics
        local p = sim.new(map)
        trace = { { x = p.x, y = p.y } }
        for i, cmd in tics do
            sim.tic(map, p, cmd.forward, cmd.side, cmd.turn)
            if i % 4 == 0 then table.insert(trace, { x = p.x, y = p.y }) end
        end
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

function module.renderView(path: string, mapName: string, output: string, demoName: string?, demoTics: number?): any
    local wad = wadModule.open(path)
    local map = mapModule.load(wad, mapName)
    local p = sim.new(map)
    local advanced = 0
    if demoName then
        local _, tics = demo.parse(wad:read(demoName))
        local limit = math.min(#tics, demoTics or 0)
        for i = 1, limit do
            local cmd = tics[i]
            sim.tic(map, p, cmd.forward, cmd.side, cmd.turn)
            advanced = i
        end
    end
    local frame, palette = render.view(map, wad, p.x, p.y, p.angle)
    fs.write(output, render.ppm(frame, palette))
    return { output = output, map = mapName, x = p.x, y = p.y, angle = p.angle, demoTics = advanced }
end

return module
