--!strict
local fs = require("@jess/fs")
local wadModule = require("@doom/wad")
local mapModule = require("@doom/map")
local render = require("@doom/render")
local demo = require("@doom/demo")
local sim = require("@doom/sim")
local gameModule = require("@doom/game")
local mobj = require("@doom/mobj")
local saveModule = require("@doom/save")
local stateModule = require("@doom/state")
local tick = require("@doom/tick")

local module = {}

local function openMap(path: string, mapName: string): any
    local wad = wadModule.open(path)
    local map = mapModule.load(wad, mapName)
    return wad, map
end

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
    local wad, map = openMap(path, mapName)
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
    local wad, map = openMap(path, mapName)
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

-- Load a WAD map into the deterministic gameplay container. If source is a
-- save path or buffer, its canonical snapshot is restored after map creation.
function module.load(path: string, mapName: string?, source: any?): any
    local wad, map = openMap(path, mapName or "E1M1")
    local options = if type(source) == "table" then source else nil
    local game: any = gameModule.new(map, options)
    game.wad = wad
    game.wadPath = path
    game.mapName = map.name

    if type(source) == "string" or type(source) == "buffer" then
        local data = if type(source) == "string" then fs.readBuffer(source) else source
        local snapshot = saveModule.load(data)
        if snapshot.map ~= map.name then
            error(`doom: save map '{snapshot.map}' does not match '{map.name}'`, 2)
        end
        game.leveltime = snapshot.leveltime
        game.gametic = snapshot.gametic
        game.rngState = snapshot.rngState
        game.players = snapshot.players
        game.mobjs = snapshot.mobjs
        game.thinkers = snapshot.thinkers
        for _, object in game.mobjs do
            if object.playerId == 0 then object.playerId = nil end
            if object.targetId == 0 then object.targetId = nil end
        end
    end
    return game
end

function module.step(game: any, commands: any?): any
    return gameModule.step(game, commands)
end

module.tick = module.step
module.tic = module.step

function module.stateSnapshot(game: any): any
    return gameModule.snapshot(game)
end

function module.stateHash(game: any): string
    return gameModule.stateHash(game)
end

function module.save(game: any, path: string?): buffer
    local data = saveModule.save(gameModule.snapshot(game))
    if path then fs.write(path, data) end
    return data
end

module.saveState = module.save

local function gameView(game: any, playerIndex: number?): any
    local player = game.players[playerIndex or 1]
    if not player then error("doom: player is not present", 2) end
    local object = game.mobjs[player.moId]
    if not object then error("doom: player mobj is not present", 2) end
    local x = object.x / mobj.FRACUNIT
    local y = object.y / mobj.FRACUNIT
    local angle = mobj.angleToDegrees(object.angle)
    local frame, palette = render.view(game.map, game.wad, x, y, angle)
    return frame, palette, x, y, angle
end

function module.render(game: any, output: string?, playerIndex: number?): any
    local frame, palette, x, y, angle = gameView(game, playerIndex)
    if output then fs.write(output, render.ppm(frame, palette)) end
    return {
        output = output,
        map = game.map.name,
        x = x,
        y = y,
        angle = angle,
        width = frame.width,
        height = frame.height,
        frame = if output then nil else frame,
        palette = if output then nil else palette,
    }
end

module.renderGame = module.render

function module.trace(path: string, mapName: string?, demoName: string?, limit: number?): any
    local wad, map = openMap(path, mapName or "E1M1")
    local game = module.load(path, map.name, { spawnMonsters = false })
    local points = {}
    local commands = {}
    if demoName then
        local _, parsed = demo.parse(wad:read(demoName))
        commands = parsed
    end
    local count = limit or #commands
    if count < 0 then count = 0 end
    table.insert(points, { x = game.mobjs[game.players[1].moId].x / mobj.FRACUNIT, y = game.mobjs[game.players[1].moId].y / mobj.FRACUNIT })
    for index = 1, count do
        local command = commands[index]
        module.step(game, { command })
        if index % 4 == 0 or index == count then
            local object = game.mobjs[game.players[1].moId]
            table.insert(points, { x = object.x / mobj.FRACUNIT, y = object.y / mobj.FRACUNIT })
        end
    end
    return { map = map.name, tics = count, points = points, stateHash = module.stateHash(game) }
end

function module.run(path: string, mapName: string?, count: number, demoName: string?): any
    local wad = wadModule.open(path)
    local game = module.load(path, mapName or "E1M1")
    local commands = {}
    if demoName then
        local _, tics = demo.parse(wad:read(demoName))
        commands = tics
    end
    for index = 1, count do module.step(game, { commands[index] }) end
    return game
end

-- Keep the format modules available through the root API without making the
-- root responsible for constructing a dream.net server handle.
module.state = stateModule
module.saveFormat = saveModule
module.tickModule = tick

return module
