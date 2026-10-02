--!strict
-- Deterministic actor simulation for the canonical game object. tick.luau drives
-- these actor actions; the modeled states and AI remain a documented subset of
-- Linux Doom 1.10 rather than a claim of demo-sync-complete behavior.
local mobj = require './mobj'
local physics = require './physics'
local angle = require './angle'
local info = require './info'
local random = require './random'

local module = {}
local FRACUNIT = mobj.FRACUNIT
local ANGLE_MAX = mobj.ANGLE_MAX
local ANG45 = 0x20000000
local MELEE_RANGE = 64 * FRACUNIT
local MISSILE_RANGE = 2048 * FRACUNIT

local directions = {
    { x = FRACUNIT, y = 0 }, { x = 47000, y = 47000 }, { x = 0, y = FRACUNIT }, { x = -47000, y = 47000 },
    { x = -FRACUNIT, y = 0 }, { x = -47000, y = -47000 }, { x = 0, y = -FRACUNIT }, { x = 47000, y = -47000 },
}

local function get(game: any, id: number): any
    return if id > 0 then game.mobjs[id] else nil
end

local function randomByte(game: any): number
    local index = (game.rngState or 0) % 256
    index = (index + 1) % 256
    game.rngState = index
    return random.rndTable[index + 1]
end

local function roll(game: any, sides: number, multiplier: number?): number
    local total = 0
    local count = multiplier or 1
    for _ = 1, count do total += randomByte(game) % sides + 1 end
    return total
end

local function distance(a: any, b: any): number
    local dx, dy = math.abs(a.x - b.x), math.abs(a.y - b.y)
    local major, minor = math.max(dx, dy), math.min(dx, dy)
    return major + math.floor(minor / 2)
end

local function canSee(game: any, a: any, b: any): boolean
    if not game.map or not game.map.lines then return true end
    return not physics.lineBlocksShot(game.map, a.x, a.y, b.x, b.y)
end

local function setState(object: any, name: string): boolean
    local state = info.state(name)
    if not state then return false end
    object.state = name
    object.tics = state.tics
    object.sprite = state.sprite
    object.frame = state.frame
    return true
end

local function followsState(root: string?, wanted: string): boolean
    if not root then return false end
    local seen: {[string]: boolean} = {}
    local current = root
    for _ = 1, 64 do
        if current == wanted then return true end
        if seen[current] then return false end
        seen[current] = true
        local state = info.state(current)
        if not state then return false end
        current = state.next
    end
    return false
end

local function inActionSequence(actor: any, meta: info.Monster): boolean
    return followsState(meta.seeState, actor.state)
        or followsState(meta.painState, actor.state)
        or followsState(meta.meleeState, actor.state)
        or followsState(meta.missileState, actor.state)
end

local function monsterFor(object: any): info.Monster?
    return info.monster(object.kind)
end

local function playerFor(game: any, object: any): any
    if not object.playerId then return nil end
    return game.players[object.playerId]
end

local function chooseTarget(game: any, actor: any): any
    if actor.targetId then
        local current = get(game, actor.targetId)
        if current and not current.removed and current.health > 0 and bit32.band(current.flags, mobj.MF_SHOOTABLE) ~= 0 then
            return current
        end
    end
    local best, bestDistance = nil, math.huge
    for _, player in game.players do
        local target = get(game, player.moId)
        if target and player.state ~= mobj.PST_DEAD and target.health > 0 and not target.removed then
            local d = distance(actor, target)
            if d < bestDistance then best, bestDistance = target, d end
        end
    end
    if best then actor.targetId = best.id end
    return best
end

local function lineDamage(game: any, source: any, target: any, attack: info.Attack, shotAngle: number): number
    local sides = attack.sides or 1
    local multiplier = attack.multiplier or 1
    local damage = if attack.fixed then attack.fixed * (randomByte(game) % sides + 1) else roll(game, sides, multiplier)
    return module.damage(game, target.id, damage, source.id)
end

local function hitTarget(game: any, source: any, shotAngle: number, range: number, attack: info.Attack?): any
    local dx, dy = physics.cosFixed(shotAngle), physics.sinFixed(shotAngle)
    local best, bestAlong = nil, range + 1
    for _, candidate in game.mobjs do
        if candidate ~= source and not candidate.removed and candidate.health > 0
            and bit32.band(candidate.flags, mobj.MF_SHOOTABLE) ~= 0 then
            local vx, vy = candidate.x - source.x, candidate.y - source.y
            local along = math.floor((vx * dx + vy * dy) / FRACUNIT)
            if along > 0 and along < bestAlong then
                local cross = math.abs(math.floor((vx * dy - vy * dx) / FRACUNIT))
                local radius = candidate.radius + 2 * FRACUNIT
                if cross * cross <= radius * radius and (not game.map or not physics.lineBlocksShot(game.map, source.x, source.y, candidate.x, candidate.y)) then
                    best, bestAlong = candidate, along
                end
            end
        end
    end
    return best
end

local function spawnProjectile(game: any, source: any, target: any, projectile: string, shotAngle: number, attack: info.Attack): number
    local projectileSpeeds = { troopshot = 10, headshot = 10, bruishot = 15, tracer = 10, fatshot = 20, arachplaz = 25, rocket = 20, lostsoul = 20, vilefire = 0 }
    local speed = projectileSpeeds[projectile] or 10
    local id = #game.mobjs + 1
    local object = mobj.newMobj(id, 0, source.x, source.y, shotAngle, 0, 1000)
    object.z = source.z + 32 * FRACUNIT
    if game.map and game.map.sectors then object.floorz, object.ceilingz = physics.floorAndCeiling(game.map, source.x, source.y) end
    object.height = 8 * FRACUNIT
    object.radius = if projectile == 'rocket' then 11 * FRACUNIT else 6 * FRACUNIT
    object.flags = 0
    object.state = 'projectile'
    object.tics = -1
    object.targetId = target.id
    local raw = object :: any
    raw.projectile = true
    raw.projectileKind = projectile
    raw.sourceId = source.id
    raw.projectileDamage = roll(game, attack.sides or 1, attack.multiplier or 1)
    raw.projectileSpeed = speed * FRACUNIT
    raw.splashRadius = if projectile == 'rocket' then 128 * FRACUNIT elseif projectile == 'bfg' then 1024 * FRACUNIT else 0
    raw.momx = physics.fixedMul(raw.projectileSpeed, physics.cosFixed(shotAngle))
    raw.momy = physics.fixedMul(raw.projectileSpeed, physics.sinFixed(shotAngle))
    raw.momz = 0
    table.insert(game.mobjs, object)
    if game.thinkers then table.insert(game.thinkers, mobj.newThinker(id, 'projectile', id)) end
    return id
end

local function explode(game: any, projectile: any, directTarget: any?): number
    local sourceId = (projectile :: any).sourceId
    local damage = (projectile :: any).projectileDamage or 0
    local dealt = 0
    if directTarget and directTarget.health > 0 then dealt += module.damage(game, directTarget.id, damage, sourceId) end
    local radius = (projectile :: any).splashRadius or 0
    if radius > 0 then
        for _, candidate in game.mobjs do
            if candidate ~= projectile and candidate ~= directTarget and candidate.health > 0 and not candidate.removed
                and bit32.band(candidate.flags, mobj.MF_SHOOTABLE) ~= 0 and distance(projectile, candidate) <= radius then
                local scaled = math.max(1, damage - math.floor(distance(projectile, candidate) / (8 * FRACUNIT)))
                dealt += module.damage(game, candidate.id, scaled, sourceId)
            end
        end
    end
    projectile.removed = true
    projectile.flags = 0
    projectile.momx, projectile.momy, projectile.momz = 0, 0, 0
    projectile.state, projectile.tics = 'dead', 0
    return dealt
end

local function updateProjectile(game: any, projectile: any): number
    local nx, ny = projectile.x + projectile.momx, projectile.y + projectile.momy
    if game.map and not physics.tryMove(game.map, projectile, nx, ny) then return explode(game, projectile, nil) end
    projectile.x, projectile.y = nx, ny
    local target = get(game, projectile.targetId or 0)
    for _, candidate in game.mobjs do
        if candidate ~= projectile and candidate.health > 0 and not candidate.removed
            and candidate.id ~= projectile.sourceId and bit32.band(candidate.flags, mobj.MF_SHOOTABLE) ~= 0
            and distance(projectile, candidate) <= projectile.radius + candidate.radius then
            return explode(game, projectile, candidate)
        end
    end
    if target and target.health <= 0 then projectile.targetId = nil end
    return 0
end

local function meleeRange(actor: any, target: any): boolean
    return distance(actor, target) < MELEE_RANGE - 20 * FRACUNIT + target.radius
end

local function missileRange(game: any, actor: any, target: any, meta: info.Monster): boolean
    if not canSee(game, actor, target) or actor.reactiontime > 0 then return false end
    local d = math.floor((distance(actor, target) - 64 * FRACUNIT) / FRACUNIT)
    if not meta.melee then d -= 128 end
    if meta.name == 'archvile' and d > 14 * 64 then return false end
    if meta.name == 'revenant' then
        if d < 196 then return false end
        d = math.floor(d / 2)
    elseif meta.name == 'cyberdemon' then
        d = math.floor(d / 2)
        if d > 160 then d = 160 end
    elseif meta.name == 'spidermastermind' or meta.name == 'lostsoul' then
        d = math.floor(d / 2)
    end
    d = math.max(0, math.min(200, d))
    return randomByte(game) >= d
end

function module.spawn(game: any, kind: number, x: number, y: number, actorAngle: number?, options: any?): number
    local meta = info.monster(kind)
    if not meta then error(`enemy: unknown monster kind {kind}`, 2) end
    local id = #game.mobjs + 1
    local object = mobj.newMobj(id, kind, x, y, actorAngle or 0, meta.flags, meta.health)
    object.radius, object.height = meta.radius * FRACUNIT, meta.height * FRACUNIT
    if game.map and game.map.sectors then
        object.floorz, object.ceilingz = physics.floorAndCeiling(game.map, x, y)
        object.z = object.floorz
    end
    setState(object, meta.spawnState)
    object.reactiontime = if options and options.reactiontime then options.reactiontime else 0
    local raw = object :: any
    raw.movedir, raw.movecount, raw.threshold, raw.attackCooldown = 0, 0, 0, 0
    table.insert(game.mobjs, object)
    if game.thinkers then table.insert(game.thinkers, mobj.newThinker(id, 'actor', id)) end
    return id
end

function module.face(game: any, actorId: number, targetId: number?): boolean
    local actor = get(game, actorId)
    local target = get(game, targetId or (actor and actor.targetId) or 0)
    if not actor or not target then return false end
    actor.targetId = target.id
    actor.angle = angle.vectorToAngle(target.x - actor.x, target.y - actor.y)
    return true
end

function module.hitscan(game: any, sourceId: number, shotAngle: number?, range: number?, attack: info.Attack?): number
    local source = get(game, sourceId)
    if not source or source.removed then return 0 end
    local useAttack = attack or { kind = 'hitscan', sides = 3, multiplier = 3, pellets = 1, spread = 0 }
    local count = useAttack.pellets or 1
    local total = 0
    local base = shotAngle or source.angle
    for pellet = 1, count do
        local spread = useAttack.spread or 0
        local offset = if spread == 0 then 0 else (randomByte(game) - randomByte(game)) * math.floor(spread / 128)
        local target = hitTarget(game, source, (base + offset) % ANGLE_MAX, range or MISSILE_RANGE, useAttack)
        if target then total += lineDamage(game, source, target, useAttack, base + offset) end
    end
    return total
end

function module.melee(game: any, actorId: number): number
    local actor = get(game, actorId)
    local meta = actor and monsterFor(actor)
    local target = actor and get(game, actor.targetId or 0)
    if not actor or not meta or not target or not meta.melee or target.health <= 0 or not meleeRange(actor, target) or not canSee(game, actor, target) then return 0 end
    module.face(game, actorId, target.id)
    return module.damage(game, target.id, roll(game, meta.melee.sides or 1, meta.melee.multiplier or 1), actor.id)
end

function module.missile(game: any, actorId: number): number
    local actor = get(game, actorId)
    local meta = actor and monsterFor(actor)
    local target = actor and get(game, actor.targetId or 0)
    if not actor or not meta or not target or not meta.missile or target.health <= 0 then return 0 end
    module.face(game, actorId, target.id)
    local attack = meta.missile
    if attack.kind == 'hitscan' then return module.hitscan(game, actor.id, actor.angle, MISSILE_RANGE, attack) end
    if attack.projectile == 'fatshot' then
        local first = 0
        for _, turn in { -0x08000000, 0, 0x08000000 } do
            local id = spawnProjectile(game, actor, target, attack.projectile, (actor.angle + turn) % ANGLE_MAX, attack)
            if first == 0 then first = id end
        end
        return first
    end
    if attack.projectile == 'lostsoul' then
        actor.momx = physics.fixedMul(20 * FRACUNIT, physics.cosFixed(actor.angle))
        actor.momy = physics.fixedMul(20 * FRACUNIT, physics.sinFixed(actor.angle))
        local raw = actor :: any
        raw.skullfly = true
        return 0
    end
    return spawnProjectile(game, actor, target, attack.projectile or 'troopshot', actor.angle, attack)
end

function module.launch(game: any, sourceId: number, shotAngle: number, projectile: string, attack: info.Attack?): number
    local source = get(game, sourceId)
    if not source then return 0 end
    local useAttack = attack or { kind = 'missile', sides = 1, multiplier = 1, projectile = projectile }
    local target = hitTarget(game, source, shotAngle, MISSILE_RANGE, useAttack) or source
    return spawnProjectile(game, source, target, projectile, shotAngle, useAttack)
end

function module.chase(game: any, actorId: number, targetId: number?): string
    local actor = get(game, actorId)
    local meta = actor and monsterFor(actor)
    if not actor or not meta or actor.removed or actor.health <= 0 then return 'dead' end
    local target = if targetId then get(game, targetId) else chooseTarget(game, actor)
    if not target or target.health <= 0 then
        if not followsState(meta.spawnState, actor.state) then setState(actor, meta.spawnState) end
        return 'idle'
    end
    actor.targetId = target.id
    if actor.reactiontime > 0 then actor.reactiontime -= 1 end
    local raw = actor :: any
    if raw.attackCooldown and raw.attackCooldown > 0 then raw.attackCooldown -= 1; return 'attack-cooldown' end
    if meta.melee and meleeRange(actor, target) and canSee(game, actor, target) then
        setState(actor, meta.meleeState or meta.missileState or meta.seeState)
        raw.attackCooldown = math.max(1, actor.tics)
        module.melee(game, actorId)
        return 'melee'
    end
    if meta.missile and missileRange(game, actor, target, meta) then
        setState(actor, meta.missileState or meta.seeState)
        raw.attackCooldown = math.max(1, actor.tics)
        module.missile(game, actorId)
        return if meta.missile.kind == 'hitscan' then 'hitscan' else 'missile'
    end
    local wanted = angle.vectorToAngle(target.x - actor.x, target.y - actor.y)
    local dir = math.floor((wanted + ANG45 / 2) / ANG45) % 8
    raw.movedir = dir
    raw.movecount = math.max(1, (randomByte(game) % 16) + 1)
    local step = directions[dir + 1]
    local speed = meta.speed * FRACUNIT
    local nx = actor.x + physics.fixedMul(speed, step.x)
    local ny = actor.y + physics.fixedMul(speed, step.y)
    local moved = if game.map then physics.tryMove(game.map, actor, nx, ny) else false
    if not moved then
        raw.movedir = (dir + 1 + randomByte(game) % 7) % 8
    end
    -- The run states form a cycle. Re-entering the first frame on every AI tic
    -- freezes the actor's animation; only leave the current action when it is no
    -- longer on the see/pain/attack state chain.
    if not inActionSequence(actor, meta) then setState(actor, meta.seeState) end
    return if moved then 'move' else 'blocked'
end

function module.damage(game: any, targetId: number, amount: number, sourceId: number?): number
    local target = get(game, targetId)
    if not target or target.removed or target.health <= 0 or bit32.band(target.flags, mobj.MF_SHOOTABLE) == 0 then return 0 end
    local damage = math.max(0, math.floor(amount))
    local player = playerFor(game, target)
    if player then
        local powers = (player :: any).powers
        if powers and powers.invulnerability and damage < 1000 then return 0 end
        local saved = 0
        if player.armorType and player.armorType > 0 then saved = math.floor(damage / if player.armorType == 1 then 3 else 2) end
        saved = math.min(saved, player.armor or 0)
        player.armor -= saved
        damage -= saved
        player.health = math.max(0, player.health - damage)
        player.damagecount = math.min(100, player.damagecount + damage)
        target.health = player.health
    else
        target.health = math.max(0, target.health - damage)
    end
    local source = get(game, sourceId or 0)
    if target.health <= 0 then
        target.flags = bit32.bor(bit32.band(target.flags, bit32.bnot(mobj.MF_SHOOTABLE)), mobj.MF_CORPSE)
        target.state = 'dead'
        target.tics = -1
        target.momx, target.momy, target.momz = 0, 0, 0
        if player then player.state, player.health, player.deathTics = mobj.PST_DEAD, 0, 0 end
        if source and source.playerId then
            local owner = game.players[source.playerId]
            if owner then owner.kills += 1 end
        end
    else
        local meta = monsterFor(target)
        if meta and randomByte(game) < meta.painChance then setState(target, meta.painState) end
        if source and source.id ~= target.id and (not target.targetId or not get(game, target.targetId)) then target.targetId = source.id end
    end
    return damage
end

local function advanceState(object: any): ()
    if object.tics == -1 then return end
    if object.tics > 0 then object.tics -= 1 end
    if object.tics == 0 then
        local state = info.state(object.state)
        if state then setState(object, state.next) end
    end
end

function module.step(game: any): any
    local count = #game.mobjs
    for id = 1, count do
        local object = game.mobjs[id]
        if object and not object.removed then
            if (object :: any).projectile then
                physics.zMove(object)
                updateProjectile(game, object)
            elseif monsterFor(object) then
                physics.zMove(object)
                advanceState(object)
                if object.health > 0 then module.chase(game, id) end
            end
        end
    end
    return game
end

module.tick = module.step
module.update = module.step
module.randomByte = randomByte
module.checkMeleeRange = function(game: any, actorId: number, targetId: number): boolean
    local actor, target = get(game, actorId), get(game, targetId)
    return actor ~= nil and target ~= nil and meleeRange(actor, target) and canSee(game, actor, target)
end
module.checkMissileRange = function(game: any, actorId: number, targetId: number): boolean
    local actor, target = get(game, actorId), get(game, targetId)
    local meta = actor and monsterFor(actor)
    return actor ~= nil and target ~= nil and meta ~= nil and missileRange(game, actor, target, meta)
end
module.fireHitscan = module.hitscan
module.spawnMissile = module.launch
module.damageMobj = module.damage
module.setState = function(game: any, actorId: number, stateName: string): boolean
    local object = get(game, actorId)
    return if object then setState(object, stateName) else false
end

return module
