--!strict
-- One deterministic 35 Hz gameplay step: player input, movement, hitscan,
-- damage/death, thinker pass, and level time.  No renderer or IO is involved.
local mobj = require './mobj'
local physics = require './physics'

local randomModule = require('@doom/random')
local module = {}

module.BT_ATTACK = 0x1
module.BT_USE = 0x2
module.BT_CHANGE = 0x4
module.TICRATE = 35
module.ATTACK_COOLDOWN = 4
module.PISTOL_DAMAGE = 3

local function signedByte(value: number): number
    value %= 256
    return if value >= 128 then value - 256 else value
end

local function normalizeCommand(command: any?): {forwardmove: number, sidemove: number, angleturn: number, buttons: number}
    command = command or {}
    local turn = command.angleturn
    if turn == nil then
        local byte = command.turnByte
        if byte == nil then byte = command.turn end
        turn = if byte == nil then 0 else signedByte(byte) * 256
    end
    return {
        forwardmove = command.forwardmove or command.forward or 0,
        sidemove = command.sidemove or command.side or 0,
        angleturn = turn,
        buttons = command.buttons or 0,
    }
end

local function randomByte(game: any): number
    -- The state is explicit rather than hidden in a module global, which makes
    -- replay and snapshot hashes independent of call order outside the tic.
    local stream = {mIndex = 0, pIndex = game.rngState % 256}
    local value = randomModule.pRandom(stream)
    game.rngState = stream.pIndex
    return value
end

local function getMobj(game: any, id: number): mobj.Mobj?
    return game.mobjs[id]
end

local function kill(game: any, target: mobj.Mobj, source: mobj.Mobj?): ()
    if target.playerId then
        local player = game.players[target.playerId]
        if player and player.state ~= mobj.PST_DEAD then
            player.state = mobj.PST_DEAD
            player.health = 0
            player.deaths += 1
            player.attackCooldown = 0
            player.deathTics = 0
            player.attackdown = false
        end
    end
    target.health = 0
    target.state = 'dead'
    target.momx, target.momy, target.momz = 0, 0, 0
    target.flags = bit32.band(target.flags, bit32.bnot(mobj.MF_SHOOTABLE))
    if target.playerId == nil then target.flags = bit32.bor(target.flags, mobj.MF_CORPSE) end
    if source and source.playerId then
        local player = game.players[source.playerId]
        if player then player.kills += 1 end
    end
end

function module.damage(game: any, targetId: number, amount: number, sourceId: number?): number
    local target = getMobj(game, targetId)
    if not target or target.removed or target.health <= 0 then return 0 end
    if amount < 0 then amount = 0 end
    local applied = amount
    if target.playerId then
        local player = game.players[target.playerId]
        if player and player.armor > 0 then
            local absorbed = math.min(player.armor, math.floor(amount / 2))
            player.armor -= absorbed
            applied -= absorbed
        end
        if applied < 1 then applied = 1 end
        if player then
            player.damagecount = math.min(100, player.damagecount + applied)
            player.health = math.max(0, player.health - applied)
            target.health = player.health
        end
    else
        target.health = math.max(0, target.health - applied)
    end
    local source = if sourceId then getMobj(game, sourceId) else nil
    if target.health <= 0 then kill(game, target, source) end
    return applied
end

local function fire(game: any, player: any, shooter: mobj.Mobj): boolean
    local dx, dy = physics.cosFixed(shooter.angle), physics.sinFixed(shooter.angle)
    local best: mobj.Mobj? = nil
    local bestAlong = math.huge
    for _, candidate in game.mobjs do
        if candidate ~= shooter and not candidate.removed and candidate.health > 0
            and bit32.band(candidate.flags, mobj.MF_SHOOTABLE) ~= 0 then
            local vx, vy = candidate.x - shooter.x, candidate.y - shooter.y
            local along = math.floor((vx * dx + vy * dy) / mobj.FRACUNIT)
            if along > 0 and along < 2048 * mobj.FRACUNIT and along < bestAlong then
                local cross = math.abs(math.floor((vx * dy - vy * dx) / mobj.FRACUNIT))
                local radius = candidate.radius + 2 * mobj.FRACUNIT
                if cross * cross <= radius * radius
                    and not physics.lineBlocksShot(game.map, shooter.x, shooter.y, candidate.x, candidate.y) then
                    best, bestAlong = candidate, along
                end
            end
        end
    end
    if not best then return false end
    module.damage(game, best.id, (randomByte(game) % 8 + 1) * module.PISTOL_DAMAGE, shooter.id)
    return true
end

local function respawn(game: any, player: any, object: mobj.Mobj): ()
    object.x, object.y, object.angle = player.spawnX, player.spawnY, player.spawnAngle
    object.floorz, object.ceilingz = physics.floorAndCeiling(game.map, object.x, object.y)
    object.z = object.floorz
    object.momx, object.momy, object.momz = 0, 0, 0
    object.health = 100
    object.flags = bit32.bor(object.flags, mobj.MF_SOLID, mobj.MF_SHOOTABLE)
    object.state, object.removed = 'spawn', false
    player.state, player.health = mobj.PST_LIVE, 100
    player.viewheight, player.viewz = 41 * mobj.FRACUNIT, object.z + 41 * mobj.FRACUNIT
    player.usedown, player.attackdown, player.deathTics = false, false, 0
end

local function playerThink(game: any, player: any, command: any?): ()
    local object = getMobj(game, player.moId)
    if not object then return end
    local cmd = normalizeCommand(command)
    player.cmd = cmd

    if player.state == mobj.PST_DEAD then
        player.deathTics += 1
        if bit32.band(cmd.buttons, module.BT_USE) ~= 0 and not player.usedown then
            respawn(game, player, object)
            player.usedown = true
        else
            player.usedown = bit32.band(cmd.buttons, module.BT_USE) ~= 0
        end
        if player.damagecount > 0 then player.damagecount -= 1 end
        return
    end

    player.angle = (player.angle + cmd.angleturn * 0x10000) % mobj.ANGLE_MAX
    object.angle = player.angle
    if object.reactiontime > 0 then object.reactiontime -= 1 else
        physics.thrust(object, player.angle, cmd.forwardmove * 2048)
        physics.thrust(object, (player.angle - mobj.ANG90) % mobj.ANGLE_MAX, cmd.sidemove * 2048)
    end
    physics.move(game.map, object)
    player.viewz = object.z + player.viewheight
    if player.damagecount > 0 then player.damagecount -= 1 end

    local attack = bit32.band(cmd.buttons, module.BT_ATTACK) ~= 0
    if player.attackdown and not attack then player.attackdown = false end
    if attack and player.readyweapon == 1 and player.ammo[1] > 0 then
        -- Kept as an edge marker for callers that inspect the canonical player
        -- record; cooldown below controls held-fire deterministically.
        player.attackdown = true
        if player.attackCooldown <= 0 then
            fire(game, player, object)
            player.ammo[1] -= 1
            player.attackCooldown = module.ATTACK_COOLDOWN
        else
            player.attackCooldown -= 1
        end
    else
        player.attackCooldown = 0
    end
    if bit32.band(cmd.buttons, module.BT_USE) ~= 0 then player.usedown = true else player.usedown = false end
end

function module.step(game: any, commands: any?): any
    commands = commands or {}
    for index, player in game.players do
        local command = commands[index]
        if index == 1 and commands.buttons ~= nil then command = commands end
        playerThink(game, player, command)
    end
    -- Thinkers are deliberately visited in spawn order, just like the vanilla
    -- linked list.  This slice has inert monster thinkers but keeps the record
    -- and order available for later AI/state ports.
    for _, thinker in game.thinkers do
        if not thinker.removed and thinker.tics > 0 then thinker.tics -= 1 end
    end
    game.gametic += 1
    game.leveltime += 1
    return game
end

module.tic = module.step
module.tick = module.step
module.fire = fire
module.respawn = respawn
module.randomByte = randomByte
module.normalizeCommand = normalizeCommand

return module
