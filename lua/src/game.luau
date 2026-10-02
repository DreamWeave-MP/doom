--!strict
-- Gameplay container and canonical snapshot surface.  The actual per-tic rules
-- live in tick.luau so callers can drive them without a renderer or a WAD FS.
local mobj = require './mobj'
local physics = require './physics'

local module = {}
export type Game = {
    map: any,
    leveltime: number,
    gametic: number,
    rngState: number,
    players: {mobj.Player},
    mobjs: {mobj.Mobj},
    thinkers: {mobj.Thinker},
}

local monsterKinds: {[number]: boolean} = {
    [64] = true, [65] = true, [66] = true, [67] = true, [68] = true,
    [69] = true, [71] = true, [84] = true, [88] = true,
    [3001] = true, [3002] = true, [3003] = true, [3004] = true,
    [3005] = true, [3006] = true, [3007] = true,
}

local function findThing(map: any, kind: number): any
    for _, thing in map.things do
        if thing.kind == kind then return thing end
    end
    return nil
end

local function spawnPlayer(game: Game, index: number): mobj.Player
    local id = #game.mobjs + 1
    local object, player = mobj.spawnPlayer(game.map, index, id)
    object.floorz, object.ceilingz = physics.floorAndCeiling(game.map, object.x, object.y)
    object.z = object.floorz
    table.insert(game.mobjs, object)
    table.insert(game.players, player)
    table.insert(game.thinkers, mobj.newThinker(id, 'player', id))
    return player
end

local function spawnMonster(game: Game, thing: any): ()
    local id = #game.mobjs + 1
    local object = mobj.newMobj(
        id,
        thing.kind,
        thing.x * mobj.FRACUNIT,
        thing.y * mobj.FRACUNIT,
        mobj.angleFromDegrees(thing.angle),
        bit32.bor(mobj.MF_SOLID, mobj.MF_SHOOTABLE),
        if thing.kind == 3002 or thing.kind == 3003 then 150 else 20
    )
    object.floorz, object.ceilingz = physics.floorAndCeiling(game.map, object.x, object.y)
    object.z = object.floorz
    table.insert(game.mobjs, object)
    table.insert(game.thinkers, mobj.newThinker(id, 'mobj', id))
end

function module.new(map: any, options: any?): Game
    local settings = options or {}
    local game: Game = {
        map = map,
        leveltime = 0,
        gametic = 0,
        rngState = settings.seed or 0x12345678,
        players = {},
        mobjs = {},
        thinkers = {},
    }
    local count = settings.playerCount or 1
    if count < 1 then count = 1 end
    if count > 4 then count = 4 end
    for index = 1, count do spawnPlayer(game, index) end
    if settings.spawnMonsters ~= false then
        for _, thing in map.things do
            if monsterKinds[thing.kind] then spawnMonster(game, thing) end
        end
    end
    return game
end

function module.spawnPlayer(game: Game, index: number): mobj.Player
    if game.players[index] then return game.players[index] end
    return spawnPlayer(game, index)
end

function module.respawn(game: Game, index: number): boolean
    local player = game.players[index]
    if not player then return false end
    local object = game.mobjs[player.moId]
    if not object then return false end
    object.x, object.y, object.angle = player.spawnX, player.spawnY, player.spawnAngle
    object.floorz, object.ceilingz = physics.floorAndCeiling(game.map, object.x, object.y)
    object.z = object.floorz
    object.momx, object.momy, object.momz = 0, 0, 0
    object.health = 100
    object.flags = bit32.bor(object.flags, mobj.MF_SOLID, mobj.MF_SHOOTABLE)
    object.state, object.tics, object.removed = 'spawn', 0, false
    player.state, player.health, player.damagecount = mobj.PST_LIVE, 100, 0
    player.viewheight, player.viewz = 41 * mobj.FRACUNIT, object.z + 41 * mobj.FRACUNIT
    player.usedown, player.attackdown, player.attackCooldown, player.deathTics = false, false, 0, 0
    return true
end

local function snapshotMobj(object: mobj.Mobj): any
    return {
        id = object.id, kind = object.kind, x = object.x, y = object.y, z = object.z,
        momx = object.momx, momy = object.momy, momz = object.momz, angle = object.angle,
        radius = object.radius, height = object.height, floorz = object.floorz,
        ceilingz = object.ceilingz, health = object.health, flags = object.flags,
        state = object.state, tics = object.tics, reactiontime = object.reactiontime,
        playerId = object.playerId or 0, targetId = object.targetId or 0, removed = object.removed,
    }
end

local function snapshotPlayer(player: mobj.Player): any
    return {
        index = player.index, moId = player.moId, state = player.state, health = player.health,
        armor = player.armor, armorType = player.armorType, damagecount = player.damagecount,
        bonuscount = player.bonuscount, viewheight = player.viewheight, viewz = player.viewz,
        angle = player.angle, usedown = player.usedown, attackdown = player.attackdown,
        attackCooldown = player.attackCooldown, deathTics = player.deathTics, deaths = player.deaths, kills = player.kills,
        readyweapon = player.readyweapon, pendingweapon = player.pendingweapon,
        ammo = {player.ammo[1], player.ammo[2], player.ammo[3], player.ammo[4]},
        weaponowned = {table.unpack(player.weaponowned)},
        cmd = {
            forwardmove = player.cmd.forwardmove, sidemove = player.cmd.sidemove,
            angleturn = player.cmd.angleturn, buttons = player.cmd.buttons,
        },
        spawnX = player.spawnX, spawnY = player.spawnY, spawnAngle = player.spawnAngle,
    }
end

function module.snapshot(game: Game): any
    local players, objects, thinkers = {}, {}, {}
    for _, player in game.players do table.insert(players, snapshotPlayer(player)) end
    for _, object in game.mobjs do table.insert(objects, snapshotMobj(object)) end
    for _, thinker in game.thinkers do
        table.insert(thinkers, {
            id = thinker.id, kind = thinker.kind, mobjId = thinker.mobjId or 0,
            tics = thinker.tics, removed = thinker.removed,
        })
    end
    return {
        version = 1,
        map = game.map.name or '',
        gametic = game.gametic,
        leveltime = game.leveltime,
        rngState = game.rngState,
        players = players,
        mobjs = objects,
        thinkers = thinkers,
    }
end

local stateModule: any = nil
local stateLoaded, stateValue = pcall(require, './state')
if stateLoaded then stateModule = stateValue end

local function fallbackHash(value: any): string
    -- Keep the fallback useful even when @doom/state is not in the package graph.
    -- Every field is appended in record order; no table address enters the hash.
    local parts = {tostring(value.version), tostring(value.map), tostring(value.gametic), tostring(value.leveltime), tostring(value.rngState)}
    local function add(...: any): ()
        for _, item in {...} do table.insert(parts, tostring(item)) end
    end
    for _, player in value.players do
        add('p', player.index, player.moId, player.state, player.health, player.armor,
            player.armorType, player.damagecount, player.bonuscount, player.viewheight,
            player.viewz, player.angle, player.usedown, player.attackdown,
            player.attackCooldown, player.deathTics, player.deaths, player.kills,
            player.readyweapon, player.pendingweapon, player.spawnX, player.spawnY, player.spawnAngle)
        for _, ammo in player.ammo do add('ammo', ammo) end
        for _, owned in player.weaponowned do add('weapon', owned) end
        add('cmd', player.cmd.forwardmove, player.cmd.sidemove, player.cmd.angleturn, player.cmd.buttons)
    end
    for _, object in value.mobjs do
        add('m', object.id, object.kind, object.x, object.y, object.z, object.momx,
            object.momy, object.momz, object.angle, object.radius, object.height,
            object.floorz, object.ceilingz, object.health, object.flags, object.state,
            object.tics, object.reactiontime, object.playerId, object.targetId, object.removed)
    end
    for _, thinker in value.thinkers do add('t', thinker.id, thinker.kind, thinker.mobjId, thinker.tics, thinker.removed) end
    local text = table.concat(parts, '|')
    local hash = 2166136261
    for i = 1, #text do hash = bit32.band((bit32.bxor(hash, string.byte(text, i)) * 16777619), 0xffffffff) end
    return string.format('%08x', hash)
end

function module.hash(game: Game): string
    local value = module.snapshot(game)
    if stateModule and type(stateModule.hash) == 'function' then return stateModule.hash(value) end
    return fallbackHash(value)
end

module.stateSnapshot = module.snapshot
module.stateHash = module.hash

function module.step(game: Game, commands: any?): any
    return require('./tick').step(game, commands)
end

module.tick = module.step
module.tic = module.step
module.newGame = module.new

return module

