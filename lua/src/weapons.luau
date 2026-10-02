--!strict
-- Player weapon actions and selection for the existing game object. tick.luau
-- invokes these actions and advances their per-player state each tic.
local enemy = require './enemy'
local info = require './info'
local mobj = require './mobj'

local module = {}
module.BT_ATTACK = 0x1
module.BT_CHANGE = 0x4

local maxAmmo = { [info.AMMO_CLIP] = 200, [info.AMMO_SHELL] = 50, [info.AMMO_CELL] = 300, [info.AMMO_MISSILE] = 50 }
local halfClip = { [info.AMMO_CLIP] = 5, [info.AMMO_SHELL] = 2, [info.AMMO_CELL] = 10, [info.AMMO_MISSILE] = 0 }
local clipAmmo = { [info.AMMO_CLIP] = 10, [info.AMMO_SHELL] = 4, [info.AMMO_CELL] = 20, [info.AMMO_MISSILE] = 1 }
local attackCache: {[number]: info.Attack} = {}
for id, weapon in info.weapons do
    attackCache[id] = {
        kind = if weapon.ammo == nil and id ~= info.WP_FIST and id ~= info.WP_CHAINSAW then 'hitscan' else if weapon.ammo == nil then 'melee' else if weapon.id == info.WP_MISSILE or weapon.id == info.WP_BFG then 'missile' else 'hitscan',
        sides = weapon.damageSides,
        multiplier = weapon.damageMultiplier,
        fixed = if id == info.WP_PISTOL then 5 else nil,
        pellets = weapon.pellets,
        spread = weapon.spread,
        projectile = if weapon.id == info.WP_MISSILE then 'rocket' elseif weapon.id == info.WP_PLASMA then 'plasma' elseif weapon.id == info.WP_BFG then 'bfg' else nil,
    }
end

local function player(game: any, index: number): any
    return game.players[index]
end
local function object(game: any, index: number): any
    local value = player(game, index)
    return if value then game.mobjs[value.moId] else nil
end
local function owned(value: any, id: number): boolean
    return value.weaponowned[id + 1] == true
end
local function ammoEnough(value: any, weapon: info.Weapon): boolean
    return weapon.ammo == nil or (value.ammo[weapon.ammo] or 0) >= weapon.ammoPerShot
end

function module.ammoMax(game: any, playerIndex: number, ammo: number): number
    local value = player(game, playerIndex)
    if not value then return 0 end
    local limits = (value :: any).maxammo
    if not limits then
        limits = { [info.AMMO_CLIP] = 200, [info.AMMO_SHELL] = 50, [info.AMMO_CELL] = 300, [info.AMMO_MISSILE] = 50 }
        ;(value :: any).maxammo = limits
    end
    local base = limits[ammo] or maxAmmo[ammo] or 0
    return if (value :: any).backpack then base * 2 else base
end

function module.giveAmmo(game: any, playerIndex: number, ammo: number, clips: number?): number
    local value = player(game, playerIndex)
    if not value or not maxAmmo[ammo] then return 0 end
    local units = if clips == nil or clips == 0 then halfClip[ammo] else clips * clipAmmo[ammo]
    local limit = module.ammoMax(game, playerIndex, ammo)
    local before = value.ammo[ammo] or 0
    value.ammo[ammo] = math.min(limit, before + units)
    if before == 0 and value.ammo[ammo] > 0 then
        if ammo == info.AMMO_CLIP and owned(value, info.WP_CHAINGUN) then value.pendingweapon = info.WP_CHAINGUN end
        if ammo == info.AMMO_SHELL and owned(value, info.WP_SHOTGUN) then value.pendingweapon = info.WP_SHOTGUN end
        if ammo == info.AMMO_CELL and owned(value, info.WP_PLASMA) then value.pendingweapon = info.WP_PLASMA end
        if ammo == info.AMMO_MISSILE and owned(value, info.WP_MISSILE) then value.pendingweapon = info.WP_MISSILE end
    end
    return value.ammo[ammo] - before
end

function module.giveWeapon(game: any, playerIndex: number, weaponId: number, dropped: boolean?): boolean
    local value = player(game, playerIndex)
    local weapon = info.weapon(weaponId)
    if not value or not weapon or not owned(value, weapon.id) then
        if not value or not weapon then return false end
        value.weaponowned[weapon.id + 1] = true
        value.pendingweapon = weapon.id
        if weapon.ammo then module.giveAmmo(game, playerIndex, weapon.ammo, if dropped then 1 else 2) end
        return true
    end
    if weapon.ammo then return module.giveAmmo(game, playerIndex, weapon.ammo, if dropped then 1 else 2) > 0 end
    return false
end

local function selectable(value: any, id: number): boolean
    local weapon = info.weapon(id)
    return weapon ~= nil and owned(value, id) and ammoEnough(value, weapon :: info.Weapon)
end

function module.selectBest(game: any, playerIndex: number, exclude: number?): number
    local value = player(game, playerIndex)
    if not value then return info.WP_FIST end
    local preference = { info.WP_PLASMA, info.WP_SUPERSHOTGUN, info.WP_CHAINGUN, info.WP_SHOTGUN, info.WP_PISTOL, info.WP_CHAINSAW, info.WP_MISSILE, info.WP_BFG, info.WP_FIST }
    for _, id in preference do if id ~= exclude and selectable(value, id) then return id end end
    return info.WP_FIST
end

function module.checkAmmo(game: any, playerIndex: number, weaponId: number?): boolean
    local value = player(game, playerIndex)
    if not value then return false end
    local id = weaponId or value.readyweapon
    local weapon = info.weapon(id)
    if not weapon then return false end
    if ammoEnough(value, weapon) then return true end
    value.pendingweapon = module.selectBest(game, playerIndex, id)
    return false
end

function module.switch(game: any, playerIndex: number, weaponId: number): boolean
    local value = player(game, playerIndex)
    local weapon = info.weapon(weaponId)
    if not value or not weapon or not owned(value, weapon.id) then return false end
    value.pendingweapon = weapon.id
    return true
end

function module.completeSwitch(game: any, playerIndex: number): boolean
    local value = player(game, playerIndex)
    if not value or value.pendingweapon == nil or value.pendingweapon == value.readyweapon then return false end
    if not owned(value, value.pendingweapon) then value.pendingweapon = module.selectBest(game, playerIndex) end
    value.readyweapon = value.pendingweapon
    value.pendingweapon = value.readyweapon
    value.attackCooldown = 0
    return true
end

function module.fire(game: any, playerIndex: number, weaponId: number?): any
    local value = player(game, playerIndex)
    local shooter = object(game, playerIndex)
    if not value or not shooter or value.state == mobj.PST_DEAD then return { fired = false, reason = 'dead' } end
    local id = weaponId or value.readyweapon
    local weapon = info.weapon(id)
    if not weapon or not owned(value, id) then return { fired = false, reason = 'not-owned' } end
    if not ammoEnough(value, weapon) then
        module.checkAmmo(game, playerIndex, id)
        return { fired = false, reason = 'no-ammo', weapon = id } 
    end
    if value.attackCooldown and value.attackCooldown > 0 then return { fired = false, reason = 'cooldown', weapon = id } end
    if weapon.ammo then value.ammo[weapon.ammo] -= weapon.ammoPerShot end
    value.readyweapon = id
    value.attackCooldown = weapon.cooldown
    value.attackdown = true
    shooter.state = 'weapon_attack'
    shooter.tics = weapon.cooldown
    local attack = attackCache[id]
    local damage = 0
    if attack.kind == 'missile' then
        enemy.launch(game, shooter.id, shooter.angle, attack.projectile or 'rocket', attack)
    else
        damage = enemy.hitscan(game, shooter.id, shooter.angle, weapon.range * mobj.FRACUNIT, attack)
    end
    return { fired = true, weapon = id, ammo = weapon.ammo, damage = damage }
end

function module.release(game: any, playerIndex: number): ()
    local value = player(game, playerIndex)
    if value then value.attackdown = false end
end

function module.step(game: any): any
    for index, value in game.players do
        if value.attackCooldown and value.attackCooldown > 0 then value.attackCooldown -= 1 end
        if value.pendingweapon ~= value.readyweapon and not value.attackdown then module.completeSwitch(game, index) end
    end
    return game
end

module.tick = module.step
module.change = module.switch
module.pickup = module.giveWeapon
module.give_ammo = module.giveAmmo
module.give_weapon = module.giveWeapon
module.check_ammo = module.checkAmmo
module.switch_weapon = module.switch

return module
