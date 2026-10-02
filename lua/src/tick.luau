--!strict
-- One deterministic 35 Hz gameplay step: player input, movement, hitscan,
-- damage/death, thinker pass, and level time.  No renderer or IO is involved.
local mobj = require './mobj'
local gameModule = require './game'
local physics = require './physics'
local enemy = require './enemy'
local weapons = require './weapons'
local inter = require './inter'
local specials = require './specials'

local randomModule = require('@doom/random')
local module = {}

module.BT_ATTACK = 0x1
module.BT_USE = 0x2
module.BT_CHANGE = 0x4
module.BT_WEAPONMASK = 0x38
module.BT_WEAPONSHIFT = 3
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
    return enemy.damage(game, targetId, amount, sourceId)
end

local function fire(game: any, player: any, shooter: mobj.Mobj): boolean
    local result = weapons.fire(game, player.index)
    return result.fired == true
end

local function respawn(game: any, player: any): any
    gameModule.respawn(game, player.index)
    return game.players[player.index]
end

local useLines: any

local function playerThink(game: any, player: any, command: any?): ()
    local object = getMobj(game, player.moId)
    if not object then return end
    local cmd = normalizeCommand(command)
    player.cmd = cmd

    if player.state == mobj.PST_DEAD then
        player.deathTics += 1
        if bit32.band(cmd.buttons, module.BT_USE) ~= 0 and not player.usedown then
            player = respawn(game, player)
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
    physics.move(game.map, object, game)
    physics.zMove(object)
    player.viewz = object.z + player.viewheight
    if player.damagecount > 0 then player.damagecount -= 1 end

    if bit32.band(cmd.buttons, module.BT_CHANGE) ~= 0 then
        local weaponId = bit32.band(bit32.rshift(cmd.buttons, module.BT_WEAPONSHIFT), 7)
        weapons.switch(game, player.index, weaponId)
    end

    local attack = bit32.band(cmd.buttons, module.BT_ATTACK) ~= 0
    if player.attackdown and not attack then player.attackdown = false end
    if attack then
        -- Kept as an edge marker for callers that inspect the canonical player
        -- record; cooldown below controls held-fire deterministically.
        player.attackdown = true
        if player.attackCooldown <= 0 then
            fire(game, player, object)
        else
            player.attackCooldown -= 1
        end
    else
        player.attackCooldown = 0
    end
    local use = bit32.band(cmd.buttons, module.BT_USE) ~= 0
    if use and not player.usedown then useLines(game, object) end
    player.usedown = use
    inter.tickPowers(game, player.index)
end

local function touchPickups(game: any, player: any): ()
    local object = getMobj(game, player.moId)
    if not object then return end
    for _, candidate in game.mobjs do
        if candidate ~= object and bit32.band(candidate.flags, mobj.MF_PICKUP) ~= 0 then
            inter.touch(game, candidate.id, object.id)
        end
    end
end

useLines = function(game: any, object: mobj.Mobj): boolean
    if not game.specials then return false end
    local rayX, rayY = physics.cosFixed(object.angle), physics.sinFixed(object.angle)
    local nearestSpecial: number? = nil
    local nearestSpecialIndex: number? = nil
    local nearestSpecialSide = 0
    local nearestBlock: number? = nil
    for index, line in game.map.lines do
        local a, b = game.map.vertices[line.v1], game.map.vertices[line.v2]
        if a and b then
            local ax, ay = a.x * mobj.FRACUNIT, a.y * mobj.FRACUNIT
            local bx, by = b.x * mobj.FRACUNIT, b.y * mobj.FRACUNIT
            local lineX, lineY = bx - ax, by - ay
            local offsetX, offsetY = ax - object.x, ay - object.y
            local denominator = rayX * lineY - rayY * lineX
            if denominator ~= 0 then
                local distance = (offsetX * lineY - offsetY * lineX) / denominator
                local along = (offsetX * rayY - offsetY * rayX) / denominator
                if distance >= 0 and distance <= 64 * mobj.FRACUNIT and along >= 0 and along <= 1 then
                    local twoSided = line.left ~= 0xffff
                    local blocking = not twoSided or bit32.band(line.flags, 1) ~= 0
                    if twoSided and not blocking then
                        local rightSide, leftSide = game.map.sides[line.right + 1], game.map.sides[line.left + 1]
                        local right = rightSide and game.map.sectors[rightSide.sector]
                        local left = leftSide and game.map.sectors[leftSide.sector]
                        if not right or not left then
                            blocking = true
                        else
                            local bottom = math.max(right.floor, left.floor) * mobj.FRACUNIT
                            local top = math.min(right.ceiling, left.ceiling) * mobj.FRACUNIT
                            blocking = top - bottom < object.height or bottom - object.floorz > physics.MAX_STEP
                        end
                    end
                    if blocking and (nearestBlock == nil or distance < nearestBlock) then nearestBlock = distance end
                    if line.special ~= 0 and (nearestSpecial == nil or distance < nearestSpecial) then
                        nearestSpecial, nearestSpecialIndex = distance, index
                        local side = lineX * (object.y - ay) - lineY * (object.x - ax)
                        nearestSpecialSide = if side < 0 then 0 else 1
                    end
                end
            end
        end
    end
    if nearestSpecialIndex == nil or (nearestBlock ~= nil and nearestBlock < (nearestSpecial or 0)) then return false end
    return specials.useLine(game.specials, nearestSpecialIndex, object, nearestSpecialSide)
end

function module.step(game: any, commands: any?): any
    commands = commands or {}
    for index, player in game.players do
        local command = commands[index]
        if index == 1 and commands.buttons ~= nil then command = commands end
        playerThink(game, player, command)
        touchPickups(game, player)
    end
    weapons.step(game)
    enemy.step(game)
    if game.specials then specials.tick(game.specials) end
    for _, thinker in game.thinkers do
        if not thinker.removed and thinker.tics > 0 then thinker.tics -= 1 end
    end
    game.gametic += 1
    if not game.specials then game.leveltime += 1 end
    return game
end

module.tic = module.step
module.tick = module.step
module.fire = fire
module.respawn = respawn
module.randomByte = randomByte
module.normalizeCommand = normalizeCommand

return module
