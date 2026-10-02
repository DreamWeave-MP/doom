--!strict
-- Canonical gameplay data distilled from Linux Doom 1.10's info.c, info.h,
-- and d_items.c.  Names stay close to the C tables so state/debug output can
-- be compared without a translation layer.
local module = {}

export type State = {
    name: string,
    sprite: string,
    frame: number,
    tics: number,
    next: string,
    action: string?,
}

export type Attack = {
    kind: string,
    sides: number?,
    multiplier: number?,
    fixed: number?,
    pellets: number?,
    projectile: string?,
    spread: number?,
}

export type Monster = {
    name: string,
    doomednum: number,
    sprite: string,
    spawnState: string,
    seeState: string,
    meleeState: string?,
    missileState: string?,
    painState: string,
    deathState: string,
    health: number,
    speed: number,
    radius: number,
    height: number,
    mass: number,
    painChance: number,
    melee: Attack?,
    missile: Attack?,
    flags: number,
}

export type Weapon = {
    id: number,
    name: string,
    ammo: number?,
    ammoPerShot: number,
    damageSides: number,
    damageMultiplier: number,
    pellets: number,
    range: number,
    spread: number,
    cooldown: number,
    readyState: string,
    downState: string,
    upState: string,
    attackState: string,
    flashState: string?,
    pickup: string?,
}

export type Pickup = {
    name: string,
    kind: number,
    sprite: string,
    amount: number?,
    ammo: number?,
    weapon: number?,
    armor: number?,
    power: string?,
}

module.FRACUNIT = 0x10000
module.AMMO_CLIP = 1
module.AMMO_SHELL = 2
module.AMMO_CELL = 3
module.AMMO_MISSILE = 4
module.WP_FIST = 0
module.WP_PISTOL = 1
module.WP_SHOTGUN = 2
module.WP_CHAINGUN = 3
module.WP_MISSILE = 4
module.WP_PLASMA = 5
module.WP_BFG = 6
module.WP_CHAINSAW = 7
module.WP_SUPERSHOTGUN = 8

local states: {[string]: State} = {}
local function put(name: string, sprite: string, frame: number, tics: number, nextState: string, action: string?): ()
    states[name] = { name = name, sprite = sprite, frame = frame, tics = tics, next = nextState, action = action }
end

put('S_NULL', 'TROO', 0, -1, 'S_NULL')
local function standRun(prefix: string, sprite: string, runTics: number, runCount: number): ()
    put(`S_{prefix}_STND`, sprite, 0, 10, `S_{prefix}_STND2`)
    put(`S_{prefix}_STND2`, sprite, 1, 10, `S_{prefix}_STND`)
    for i = 1, runCount do
        local nextState = `S_{prefix}_RUN{if i == runCount then 1 else i + 1}`
        put(`S_{prefix}_RUN{i}`, sprite, math.floor((i - 1) / 2), runTics, nextState, 'chase')
    end
end

local function painDeath(prefix: string, sprite: string, painTics: number, deathCount: number): (string, string)
    put(`S_{prefix}_PAIN`, sprite, 6, painTics, `S_{prefix}_PAIN2`)
    put(`S_{prefix}_PAIN2`, sprite, 6, painTics, `S_{prefix}_RUN1`)
    for i = 1, deathCount do
        local nextState = if i == deathCount then 'S_NULL' else `S_{prefix}_DIE{i + 1}`
        put(`S_{prefix}_DIE{i}`, sprite, 7 + i, if i == deathCount then -1 else 6, nextState)
    end
    return `S_{prefix}_PAIN`, `S_{prefix}_DIE1`
end

local function attackStates(prefix: string, sprite: string, kind: string): (string?, string?)
    local melee: string? = nil
    local missile: string? = nil
    if kind == 'melee' or kind == 'both' then
        melee = `S_{prefix}_ATK1`
        put(`S_{prefix}_ATK1`, sprite, 4, 8, `S_{prefix}_ATK2`, 'face')
        put(`S_{prefix}_ATK2`, sprite, 5, 8, `S_{prefix}_ATK3`, 'face')
        put(`S_{prefix}_ATK3`, sprite, 6, 6, `S_{prefix}_RUN1`, 'melee')
    elseif kind == 'hitscan' then
        missile = `S_{prefix}_ATK1`
        put(`S_{prefix}_ATK1`, sprite, 4, 10, `S_{prefix}_ATK2`, 'face')
        put(`S_{prefix}_ATK2`, sprite, 5, 8, `S_{prefix}_ATK3`, 'hitscan')
        put(`S_{prefix}_ATK3`, sprite, 4, 8, `S_{prefix}_RUN1`)
    elseif kind == 'missile' then
        missile = `S_{prefix}_ATK1`
        put(`S_{prefix}_ATK1`, sprite, 1, 8, `S_{prefix}_ATK2`, 'face')
        put(`S_{prefix}_ATK2`, sprite, 2, 8, `S_{prefix}_ATK3`, 'missile')
        put(`S_{prefix}_ATK3`, sprite, 3, 8, `S_{prefix}_RUN1`)
    elseif kind == 'both_missile' then
        melee = `S_{prefix}_ATK1`
        missile = melee
        put(`S_{prefix}_ATK1`, sprite, 4, 8, `S_{prefix}_ATK2`, 'face')
        put(`S_{prefix}_ATK2`, sprite, 5, 8, `S_{prefix}_ATK3`, 'attack')
        put(`S_{prefix}_ATK3`, sprite, 6, 8, `S_{prefix}_RUN1`)
    end
    return melee, missile
end

-- The state rows below intentionally cover the states used by common actors;
-- decorative and finale-only rows do not affect combat simulation.
local function actorStates(prefix: string, sprite: string, runTics: number, runCount: number, attack: string): (string, string, string?, string?, string, string)
    standRun(prefix, sprite, runTics, runCount)
    local melee, missile = attackStates(prefix, sprite, attack)
    local pain, death = painDeath(prefix, sprite, 3, 5)
    return `S_{prefix}_STND`, `S_{prefix}_RUN1`, melee, missile, pain, death
end

local monsters: {[number]: Monster} = {}
local monsterNames: {[string]: Monster} = {}
local function addMonster(value: Monster): ()
    monsters[value.doomednum] = value
    monsterNames[string.upper(value.name)] = value
end

local function monster(name: string, doomednum: number, sprite: string, health: number, speed: number, radius: number, height: number, painChance: number, attackKind: string, melee: Attack?, missile: Attack?): ()
    local spawn, see, meleeState, missileState, pain, death = actorStates(sprite, sprite, if speed >= 12 then 2 else 3, if name == 'revenant' then 12 else 8, attackKind)
    local value: Monster = {
        name = name, doomednum = doomednum, sprite = sprite, spawnState = spawn, seeState = see,
        meleeState = meleeState, missileState = missileState, painState = pain, deathState = death,
        health = health, speed = speed, radius = radius, height = height, mass = if health >= 1000 then 1000 else 100,
        painChance = painChance, melee = melee, missile = missile, flags = 3,
    }
    addMonster(value)
end

local function dice(sides: number, multiplier: number?): Attack
    return { kind = 'melee', sides = sides, multiplier = multiplier or 1 }
end
local function fireball(projectile: string, sides: number, multiplier: number?): Attack
    return { kind = 'missile', projectile = projectile, sides = sides, multiplier = multiplier or 1 }
end
local function bullets(pellets: number): Attack
    return { kind = 'hitscan', sides = 3, multiplier = 1, fixed = 5, pellets = pellets, spread = 0x01000000 }
end

monster('zombieman', 3004, 'POSS', 20, 8, 20, 56, 200, 'hitscan', nil, bullets(1))
monster('shotgunner', 9, 'SPOS', 30, 8, 20, 56, 170, 'hitscan', nil, bullets(3))
monster('chaingunner', 65, 'CPOS', 70, 8, 20, 56, 170, 'hitscan', nil, bullets(1))
monster('imp', 3001, 'TROO', 60, 8, 20, 56, 200, 'both', dice(8, 3), fireball('troopshot', 8, 3))
monster('demon', 3002, 'SARG', 150, 10, 30, 56, 180, 'melee', dice(10, 4), nil)
monster('spectre', 58, 'SARG', 150, 10, 30, 56, 180, 'melee', dice(10, 4), nil)
monster('cacodemon', 3005, 'HEAD', 400, 8, 31, 56, 128, 'both_missile', dice(6, 10), fireball('headshot', 5, 1))
monster('baron', 3003, 'BOSS', 1000, 8, 24, 64, 50, 'both_missile', dice(8, 10), fireball('bruishot', 8, 1))
monster('hellknight', 69, 'BOS2', 500, 8, 24, 64, 50, 'both_missile', dice(8, 10), fireball('bruishot', 8, 1))
monster('lostsoul', 3006, 'SKULL', 100, 8, 16, 56, 256, 'melee', dice(20, 3), nil)
monster('revenant', 66, 'SKEL', 300, 10, 20, 56, 100, 'both_missile', dice(10, 6), fireball('tracer', 5, 1))
monster('mancubus', 67, 'FATT', 600, 8, 48, 64, 80, 'missile', nil, fireball('fatshot', 8, 1))
monster('arachnotron', 68, 'BSPI', 500, 12, 64, 64, 128, 'missile', nil, fireball('arachplaz', 5, 1))
monster('spidermastermind', 7, 'SPID', 3000, 12, 128, 100, 40, 'hitscan', nil, bullets(3))
monster('cyberdemon', 16, 'CYBR', 4000, 16, 40, 110, 20, 'missile', nil, fireball('rocket', 20, 1))
monster('pain elemental', 71, 'PAIN', 400, 8, 31, 56, 128, 'missile', nil, fireball('lostsoul', 20, 1))
monster('wolfss', 84, 'SSWV', 50, 8, 20, 56, 170, 'hitscan', nil, bullets(1))
monster('archvile', 64, 'VILE', 700, 15, 20, 56, 10, 'missile', nil, fireball('vilefire', 20, 1))

local weapons: {[number]: Weapon} = {}
local function weapon(value: Weapon): () weapons[value.id] = value end
weapon({ id = 0, name = 'fist', ammo = nil, ammoPerShot = 0, damageSides = 10, damageMultiplier = 2, pellets = 1, range = 64, spread = 0x02000000, cooldown = 8, readyState = 'S_PUNCH', downState = 'S_PUNCHDOWN', upState = 'S_PUNCHUP', attackState = 'S_PUNCH1', pickup = nil })
weapon({ id = 1, name = 'pistol', ammo = module.AMMO_CLIP, ammoPerShot = 1, damageSides = 3, damageMultiplier = 1, pellets = 1, range = 2048, spread = 0x01000000, cooldown = 4, readyState = 'S_PISTOL', downState = 'S_PISTOLDOWN', upState = 'S_PISTOLUP', attackState = 'S_PISTOL1', flashState = 'S_PISTOLFLASH' })
weapon({ id = 2, name = 'shotgun', ammo = module.AMMO_SHELL, ammoPerShot = 1, damageSides = 3, damageMultiplier = 5, pellets = 7, range = 2048, spread = 0x02000000, cooldown = 30, readyState = 'S_SGUN', downState = 'S_SGUNDOWN', upState = 'S_SGUNUP', attackState = 'S_SGUN1', flashState = 'S_SGUNFLASH1', pickup = 'shotgun' })
weapon({ id = 3, name = 'chaingun', ammo = module.AMMO_CLIP, ammoPerShot = 1, damageSides = 3, damageMultiplier = 5, pellets = 1, range = 2048, spread = 0x01000000, cooldown = 4, readyState = 'S_CHAIN', downState = 'S_CHAINDOWN', upState = 'S_CHAINUP', attackState = 'S_CHAIN1', flashState = 'S_CHAINFLASH1', pickup = 'chaingun' })
weapon({ id = 4, name = 'rocket launcher', ammo = module.AMMO_MISSILE, ammoPerShot = 1, damageSides = 20, damageMultiplier = 1, pellets = 1, range = 2048, spread = 0, cooldown = 30, readyState = 'S_MISSILE', downState = 'S_MISSILEDOWN', upState = 'S_MISSILEUP', attackState = 'S_MISSILE1', flashState = 'S_MISSILEFLASH1', pickup = 'rocket launcher' })
weapon({ id = 5, name = 'plasma rifle', ammo = module.AMMO_CELL, ammoPerShot = 1, damageSides = 5, damageMultiplier = 1, pellets = 1, range = 2048, spread = 0, cooldown = 3, readyState = 'S_PLASMA', downState = 'S_PLASMADOWN', upState = 'S_PLASMAUP', attackState = 'S_PLASMA1', flashState = 'S_PLASMAFLASH1', pickup = 'plasma rifle' })
weapon({ id = 6, name = 'bfg9000', ammo = module.AMMO_CELL, ammoPerShot = 40, damageSides = 100, damageMultiplier = 1, pellets = 1, range = 2048, spread = 0, cooldown = 70, readyState = 'S_BFG', downState = 'S_BFGDOWN', upState = 'S_BFGUP', attackState = 'S_BFG1', flashState = 'S_BFGFLASH1', pickup = 'bfg9000' })
weapon({ id = 7, name = 'chainsaw', ammo = nil, ammoPerShot = 0, damageSides = 10, damageMultiplier = 2, pellets = 1, range = 64, spread = 0x02000000, cooldown = 4, readyState = 'S_SAW', downState = 'S_SAWDOWN', upState = 'S_SAWUP', attackState = 'S_SAW1', pickup = 'chainsaw' })
weapon({ id = 8, name = 'super shotgun', ammo = module.AMMO_SHELL, ammoPerShot = 2, damageSides = 3, damageMultiplier = 5, pellets = 20, range = 2048, spread = 0x04000000, cooldown = 50, readyState = 'S_DSGUN', downState = 'S_DSGUNDOWN', upState = 'S_DSGUNUP', attackState = 'S_DSGUN1', flashState = 'S_DSGUNFLASH1', pickup = 'super shotgun' })

local function weaponStates(prefix: string, sprite: string): ()
    put(`S_{prefix}`, sprite, 0, 1, `S_{prefix}`)
    put(`S_{prefix}DOWN`, sprite, 0, 1, `S_{prefix}DOWN`)
    put(`S_{prefix}UP`, sprite, 0, 1, `S_{prefix}UP`)
end
weaponStates('PUNCH', 'PUNG'); weaponStates('PISTOL', 'PISG'); weaponStates('SGUN', 'SHTG'); weaponStates('CHAIN', 'CHGG')
weaponStates('MISSILE', 'MISG'); weaponStates('PLASMA', 'PLSG'); weaponStates('BFG', 'BFGG'); weaponStates('SAW', 'SAWG'); weaponStates('DSGUN', 'SHT2')
for _, w in weapons do
    put(w.attackState, string.sub(w.name, 1, 4):upper(), 0, w.cooldown, w.readyState, 'weapon')
    if w.flashState then put(w.flashState, 'PISF', 0, 4, 'S_LIGHTDONE') end
end
put('S_LIGHTDONE', 'SHTG', 0, 4, 'S_NULL')
-- Exact common weapon action chains from info.c.  The ready/up/down rows are
-- deliberately persistent; action rows return to ready after their animation.
put('S_PUNCH1', 'PUNG', 1, 4, 'S_PUNCH2')
put('S_PUNCH2', 'PUNG', 2, 4, 'S_PUNCH3', 'punch')
put('S_PUNCH3', 'PUNG', 3, 5, 'S_PUNCH4')
put('S_PUNCH4', 'PUNG', 2, 4, 'S_PUNCH5')
put('S_PUNCH5', 'PUNG', 1, 5, 'S_PUNCH', 'refire')
put('S_PISTOL1', 'PISG', 0, 4, 'S_PISTOL2')
put('S_PISTOL2', 'PISG', 1, 6, 'S_PISTOL3', 'pistol')
put('S_PISTOL3', 'PISG', 2, 4, 'S_PISTOL4')
put('S_PISTOL4', 'PISG', 1, 5, 'S_PISTOL', 'refire')
put('S_SGUN1', 'SHTG', 0, 3, 'S_SGUN2')
put('S_SGUN2', 'SHTG', 0, 7, 'S_SGUN3', 'shotgun')
put('S_SGUN3', 'SHTG', 1, 5, 'S_SGUN4'); put('S_SGUN4', 'SHTG', 2, 5, 'S_SGUN5')
put('S_SGUN5', 'SHTG', 3, 4, 'S_SGUN6'); put('S_SGUN6', 'SHTG', 2, 5, 'S_SGUN7')
put('S_SGUN7', 'SHTG', 1, 5, 'S_SGUN8'); put('S_SGUN8', 'SHTG', 0, 3, 'S_SGUN9')
put('S_SGUN9', 'SHTG', 0, 7, 'S_SGUN', 'refire')
put('S_CHAIN1', 'CHGG', 0, 4, 'S_CHAIN2', 'chaingun'); put('S_CHAIN2', 'CHGG', 1, 4, 'S_CHAIN3', 'chaingun'); put('S_CHAIN3', 'CHGG', 1, 0, 'S_CHAIN', 'refire')
put('S_MISSILE1', 'MISG', 1, 8, 'S_MISSILE2'); put('S_MISSILE2', 'MISG', 1, 12, 'S_MISSILE3', 'rocket'); put('S_MISSILE3', 'MISG', 1, 0, 'S_MISSILE', 'refire')
put('S_PLASMA1', 'PLSG', 0, 3, 'S_PLASMA2', 'plasma'); put('S_PLASMA2', 'PLSG', 1, 20, 'S_PLASMA', 'refire')
put('S_BFG1', 'BFGG', 0, 20, 'S_BFG2'); put('S_BFG2', 'BFGG', 1, 10, 'S_BFG3'); put('S_BFG3', 'BFGG', 1, 10, 'S_BFG4', 'bfg'); put('S_BFG4', 'BFGG', 1, 20, 'S_BFG', 'refire')
put('S_SAW1', 'SAWG', 0, 4, 'S_SAW2', 'saw'); put('S_SAW2', 'SAWG', 1, 4, 'S_SAW3', 'saw'); put('S_SAW3', 'SAWG', 1, 0, 'S_SAW', 'refire')
put('S_DSGUN1', 'SHT2', 0, 3, 'S_DSGUN2'); put('S_DSGUN2', 'SHT2', 0, 7, 'S_DSGUN3', 'super_shotgun')
put('S_DSGUN3', 'SHT2', 1, 7, 'S_DSGUN4'); put('S_DSGUN4', 'SHT2', 2, 7, 'S_DSGUN5')
put('S_DSGUN5', 'SHT2', 3, 7, 'S_DSGUN6'); put('S_DSGUN6', 'SHT2', 4, 7, 'S_DSGUN7')
put('S_DSGUN7', 'SHT2', 5, 7, 'S_DSGUN8'); put('S_DSGUN8', 'SHT2', 6, 6, 'S_DSGUN9')
put('S_DSGUN9', 'SHT2', 7, 6, 'S_DSGUN10'); put('S_DSGUN10', 'SHT2', 0, 5, 'S_DSGUN', 'refire')

local pickups: {[string]: Pickup} = {}
local pickupKinds: {[number]: Pickup} = {}
local pickupSprites: {[string]: Pickup} = {}
local function pickup(value: Pickup, ...): ()
    pickups[value.name] = value
    pickupSprites[value.sprite] = value
    for _, kind in { ... } do pickupKinds[kind] = value end
end
pickup({ name = 'green armor', kind = 2018, sprite = 'ARM1', armor = 1 }, 2018)
pickup({ name = 'blue armor', kind = 2019, sprite = 'ARM2', armor = 2 }, 2019)
pickup({ name = 'stimpack', kind = 2011, sprite = 'STIM', amount = 10 }, 2011)
pickup({ name = 'medikit', kind = 2012, sprite = 'MEDI', amount = 25 }, 2012)
pickup({ name = 'soulsphere', kind = 2013, sprite = 'SOUL', amount = 100, power = 'soul' }, 2013)
pickup({ name = 'megasphere', kind = 83, sprite = 'MEGA', amount = 200, armor = 2, power = 'mega' }, 83)
pickup({ name = 'clip', kind = 2007, sprite = 'CLIP', amount = 1, ammo = module.AMMO_CLIP }, 2007)
pickup({ name = 'ammo box', kind = 2048, sprite = 'AMMO', amount = 5, ammo = module.AMMO_CLIP }, 2048)
pickup({ name = 'shells', kind = 2008, sprite = 'SHEL', amount = 1, ammo = module.AMMO_SHELL }, 2008)
pickup({ name = 'shell box', kind = 2049, sprite = 'SBOX', amount = 5, ammo = module.AMMO_SHELL }, 2049)
pickup({ name = 'rocket', kind = 2010, sprite = 'ROCK', amount = 1, ammo = module.AMMO_MISSILE }, 2010)
pickup({ name = 'rocket box', kind = 2046, sprite = 'BROK', amount = 5, ammo = module.AMMO_MISSILE }, 2046)
pickup({ name = 'cell', kind = 2047, sprite = 'CELL', amount = 1, ammo = module.AMMO_CELL }, 2047)
pickup({ name = 'cell pack', kind = 17, sprite = 'CELP', amount = 5, ammo = module.AMMO_CELL }, 17)
pickup({ name = 'backpack', kind = 8, sprite = 'BPAK', amount = 1, power = 'backpack' }, 8)
pickup({ name = 'blue keycard', kind = 5, sprite = 'BKEY', power = 'bluecard' }, 5)
pickup({ name = 'red keycard', kind = 13, sprite = 'RKEY', power = 'redcard' }, 13)
pickup({ name = 'yellow keycard', kind = 6, sprite = 'YKEY', power = 'yellowcard' }, 6)
pickup({ name = 'berserk', kind = 2023, sprite = 'PSTR', power = 'berserk' }, 2023)
pickup({ name = 'invulnerability', kind = 2022, sprite = 'PINV', power = 'invulnerability' }, 2022)
pickup({ name = 'invisibility', kind = 2024, sprite = 'PINS', power = 'invisibility' }, 2024)
pickup({ name = 'radiation suit', kind = 2025, sprite = 'SUIT', power = 'radiation' }, 2025)
pickup({ name = 'computer map', kind = 2026, sprite = 'PMAP', power = 'allmap' }, 2026)
pickup({ name = 'light amplification', kind = 2042, sprite = 'PVIS', power = 'infrared' }, 2042)
pickup({ name = 'shotgun', kind = 2001, sprite = 'SHOT', weapon = module.WP_SHOTGUN }, 2001)
pickup({ name = 'chaingun', kind = 2002, sprite = 'MGUN', weapon = module.WP_CHAINGUN }, 2002)
pickup({ name = 'rocket launcher', kind = 2003, sprite = 'LAUN', weapon = module.WP_MISSILE }, 2003)
pickup({ name = 'plasma rifle', kind = 2004, sprite = 'PLAS', weapon = module.WP_PLASMA }, 2004)
pickup({ name = 'chainsaw', kind = 2005, sprite = 'CSAW', weapon = module.WP_CHAINSAW }, 2005)
pickup({ name = 'bfg9000', kind = 2006, sprite = 'BFUG', weapon = module.WP_BFG }, 2006)
pickup({ name = 'super shotgun', kind = 82, sprite = 'SGN2', weapon = module.WP_SUPERSHOTGUN }, 82)

module.states = states
module.monsters = monsters
module.monsterNames = monsterNames
module.weapons = weapons
module.pickups = pickups
module.pickupKinds = pickupKinds
module.pickupSprites = pickupSprites

function module.state(name: string): State?
    return states[name]
end
function module.monster(kind: number | string): Monster?
    if type(kind) == 'number' then return monsters[kind] end
    return monsterNames[string.upper(kind)]
end
function module.weapon(id: number | string): Weapon?
    if type(id) == 'number' then return weapons[id] end
    local wanted = string.upper(id)
    for _, value in weapons do if string.upper(value.name) == wanted then return value end end
    return nil
end
function module.pickup(kind: number | string): Pickup?
    if type(kind) == 'number' then return pickupKinds[kind] end
    return pickups[string.lower(kind)] or pickupSprites[string.upper(kind)]
end
function module.isMonster(kind: number): boolean
    return monsters[kind] ~= nil
end

return module
