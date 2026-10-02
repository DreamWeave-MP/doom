--!strict
-- Gameplay container and canonical snapshot surface.  The actual per-tic rules
-- live in tick.luau so callers can drive them without a renderer or a WAD FS.
local mobj = require './mobj'
local physics = require './physics'
local info = require './info'
local enemy = require './enemy'
local inter = require './inter'
local specials = require './specials'

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

local function spawnThing(game: Game, thing: any, settings: any): ()
    if info.monster(thing.kind) then
        if settings.spawnMonsters == false then return end
        enemy.spawn(
            game,
            thing.kind,
            thing.x * mobj.FRACUNIT,
            thing.y * mobj.FRACUNIT,
            mobj.angleFromDegrees(thing.angle),
            { ambush = bit32.band(thing.flags, 8) ~= 0 }
        )
        game.totalKills = (game.totalKills or 0) + 1
    elseif info.pickup(thing.kind) then
        if settings.deathmatch == true and info.notInDeathmatch(thing.kind) then return end
        inter.spawn(game, thing.kind, thing.x * mobj.FRACUNIT, thing.y * mobj.FRACUNIT, mobj.angleFromDegrees(thing.angle))
        game.totalItems = (game.totalItems or 0) + 1
    end
end

function module.new(map: any, options: any?): Game
    local settings = options or {}
    local skill = settings.skill or 2 -- Doom's default is Hurt Me Plenty.
    if skill < 0 or skill > 4 or skill ~= math.floor(skill) then error('game: skill must be an integer in [0, 4]', 2) end
    local game: Game = {
        map = map,
        leveltime = 0,
        gametic = 0,
        rngState = settings.seed or 0x12345678,
        skill = skill,
        deathmatch = settings.deathmatch == true,
        netgame = settings.netgame == true,
        totalKills = 0,
        totalItems = 0,
        players = {},
        mobjs = {},
        thinkers = {},
    }
    local count = settings.playerCount or 1
    if count < 1 then count = 1 end
    if count > 4 then count = 4 end
    for index = 1, count do spawnPlayer(game, index) end
    local skillMask = if skill <= 1 then 1 elseif skill == 2 then 2 else 4
    for _, thing in map.things do
        local flags = thing.flags or 0
        local inSkill = bit32.band(flags, skillMask) ~= 0
        local singleOnly = bit32.band(flags, 16) ~= 0
        if inSkill and (settings.netgame == true or not singleOnly) then
            spawnThing(game, thing, settings)
        end
    end
    game.specials = specials.init(game, settings)
    return game
end

function module.spawnPlayer(game: Game, index: number): mobj.Player
    if game.players[index] then return game.players[index] end
    return spawnPlayer(game, index)
end

function module.resetPlayerForReborn(game: Game, index: number): mobj.Player?
    local old = game.players[index]
    if not old then return nil end
    local reborn = mobj.newPlayer(index, old.moId, old.spawnX, old.spawnY, old.spawnAngle)
    -- G_PlayerReborn preserves level counters and frag totals, but resets
    -- weapons, ammo, armor, cards, backpack and power timers.
    reborn.deaths = old.deaths or 0
    reborn.kills = old.kills or 0
    reborn.frags = table.clone(old.frags or { 0, 0, 0, 0 })
    reborn.killcount = old.killcount or old.kills or 0
    reborn.itemcount = old.itemcount or 0
    reborn.secretcount = old.secretcount or 0
    local flow = (game :: any).flow
    if flow and flow.frags and flow.frags[index] then reborn.frags = flow.frags[index] end
    game.players[index] = reborn
    return reborn
end

function module.respawn(game: Game, index: number): boolean
    local player = game.players[index]
    if not player then return false end
    local object = game.mobjs[player.moId]
    if not object then return false end
    player = module.resetPlayerForReborn(game, index) or player
    object.x, object.y, object.angle = player.spawnX, player.spawnY, player.spawnAngle
    object.floorz, object.ceilingz = physics.floorAndCeiling(game.map, object.x, object.y)
    object.z = object.floorz
    object.momx, object.momy, object.momz = 0, 0, 0
    object.health = 100
    object.flags = bit32.bor(bit32.band(object.flags, bit32.bnot(mobj.MF_CORPSE)), mobj.MF_SOLID, mobj.MF_SHOOTABLE)
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
        attackCooldown = player.attackCooldown, deathTics = player.deathTics, deathSourceId = player.deathSourceId,
        deaths = player.deaths, kills = player.kills,
        readyweapon = player.readyweapon, pendingweapon = player.pendingweapon,
        ammo = {player.ammo[1], player.ammo[2], player.ammo[3], player.ammo[4]},
        weaponowned = {table.unpack(player.weaponowned)},
        cmd = {
            forwardmove = player.cmd.forwardmove, sidemove = player.cmd.sidemove,
            angleturn = player.cmd.angleturn, buttons = player.cmd.buttons,
        },
        spawnX = player.spawnX, spawnY = player.spawnY, spawnAngle = player.spawnAngle,
        powers = table.clone(player.powers), cards = table.clone(player.cards), backpack = player.backpack,
        maxammo = table.clone(player.maxammo), frags = table.clone(player.frags),
        killcount = player.killcount, itemcount = player.itemcount, secretcount = player.secretcount,
    }
end

function module.normalizePlayers(game: Game): ()
    for index, player in game.players do
        local raw = player :: any
        raw.powers = raw.powers or {}
        raw.cards = raw.cards or {}
        raw.backpack = raw.backpack == true
        raw.maxammo = raw.maxammo or { [1] = 200, [2] = 50, [3] = 300, [4] = 50 }
        raw.frags = raw.frags or { 0, 0, 0, 0 }
        raw.killcount = raw.killcount or player.kills or 0
        raw.itemcount = raw.itemcount or 0
        raw.secretcount = raw.secretcount or 0
        raw.deathSourceId = raw.deathSourceId or 0
        raw.index = raw.index or index
    end
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
        skill = (game :: any).skill or 2,
        players = players,
        mobjs = objects,
        thinkers = thinkers,
        specials = if game.specials then specials.snapshot(game.specials) else nil,
    }
end

local stateModule = require('./state')

function module.hash(game: Game): string
    local value = module.snapshot(game)
    return stateModule.hash(value)
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
