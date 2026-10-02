--!strict
-- P_Inter-style pickups and player-facing damage helpers.  The object layout is
-- the existing mobj/game layout; callers decide when to invoke touch/step.
local mobj = require './mobj'
local info = require './info'
local enemy = require './enemy'
local weapons = require './weapons'

local module = {}
local FRACUNIT = mobj.FRACUNIT
local TICRATE = 35

module.POWER_INVULNERABILITY = 1
module.POWER_STRENGTH = 2
module.POWER_INVISIBILITY = 3
module.POWER_IRONFEET = 4
module.POWER_ALLMAP = 5
module.POWER_INFRARED = 6
module.INVULNERABILITY_TICS = 30 * TICRATE
module.INVISIBILITY_TICS = 60 * TICRATE
module.INFRARED_TICS = 120 * TICRATE
module.IRONFEET_TICS = 60 * TICRATE

local powerSlot: {[string]: number} = {
    invulnerability = module.POWER_INVULNERABILITY,
    berserk = module.POWER_STRENGTH,
    invisibility = module.POWER_INVISIBILITY,
    radiation = module.POWER_IRONFEET,
    allmap = module.POWER_ALLMAP,
    infrared = module.POWER_INFRARED,
}
local powerDuration: {[string]: number} = {
    invulnerability = module.INVULNERABILITY_TICS,
    invisibility = module.INVISIBILITY_TICS,
    radiation = module.IRONFEET_TICS,
    infrared = module.INFRARED_TICS,
}
local timedPowerSlots = {
    module.POWER_INVULNERABILITY,
    module.POWER_INVISIBILITY,
    module.POWER_IRONFEET,
    module.POWER_INFRARED,
}

function module.power(player: any, name: string): number
    local slot = powerSlot[name]
    if not slot then return 0 end
    return (player.powers and player.powers[slot]) or 0
end

function module.hasPower(player: any, name: string): boolean
    return module.power(player, name) > 0
end

local function get(game: any, id: number): any return if id > 0 then game.mobjs[id] else nil end
local function playerFor(game: any, playerIndex: number): any return game.players[playerIndex] end

function module.spawn(game: any, kind: number, x: number, y: number, angle: number?): number
    local pickup = info.pickup(kind)
    if not pickup then error(`inter: unknown pickup kind {kind}`, 2) end
    local id = #game.mobjs + 1
    local object = mobj.newMobj(id, kind, x, y, angle or 0, mobj.MF_PICKUP, 1000)
    object.flags = mobj.MF_PICKUP
    object.radius, object.height = 16 * FRACUNIT, 16 * FRACUNIT
    object.state, object.tics = 'pickup', -1
    local raw = object :: any
    raw.pickupName = pickup.name
    table.insert(game.mobjs, object)
    return id
end

function module.giveAmmo(game: any, playerIndex: number, ammo: number, clips: number?): number
    return weapons.giveAmmo(game, playerIndex, ammo, clips)
end

function module.giveCard(game: any, playerIndex: number, card: string): boolean
    local player = playerFor(game, playerIndex)
    if not player then return false end
    local cards = (player :: any).cards
    if not cards then cards = {}; (player :: any).cards = cards end
    if cards[card] then return false end
    cards[card] = true
    player.bonuscount += 6
    return true
end

local function applyPower(game: any, playerIndex: number, power: string): boolean
    local player = playerFor(game, playerIndex)
    if not player then return false end
    local powers = (player :: any).powers
    if not powers then powers = {}; (player :: any).powers = powers end
    if power == 'mega' then
        player.health, player.armor, player.armorType = 200, 200, 2
    elseif power == 'soul' then
        player.health = math.min(200, player.health + 100)
    elseif power == 'berserk' then
        player.health = math.min(100, player.health + 100)
        powers[module.POWER_STRENGTH] = 1
        if player.readyweapon ~= info.WP_FIST then player.pendingweapon = info.WP_FIST end
    else
        local slot = powerSlot[power]
        if not slot then return false end
        if power == 'allmap' and powers[slot] then return false end
        powers[slot] = powerDuration[power] or 1
        if power == 'invisibility' then
            local object = get(game, player.moId)
            if object then object.flags = bit32.bor(object.flags, mobj.MF_SHADOW) end
        end
    end
    local object = get(game, player.moId)
    if object then object.health = player.health end
    return true
end

function module.tickPowers(game: any, playerIndex: number): ()
    local player = playerFor(game, playerIndex)
    if not player then return end
    local powers = player.powers or {}
    for _, slot in timedPowerSlots do
        local remaining = powers[slot] or 0
        if remaining > 0 then powers[slot] = remaining - 1 end
    end
    local strength = powers[module.POWER_STRENGTH] or 0
    if strength > 0 then powers[module.POWER_STRENGTH] = strength + 1 end
    local invisible = powers[module.POWER_INVISIBILITY] or 0
    if invisible == 0 then
        local object = get(game, player.moId)
        if object then object.flags = bit32.band(object.flags, bit32.bnot(mobj.MF_SHADOW)) end
    end
end

function module.touch(game: any, specialId: number, toucherId: number): boolean
    local special = get(game, specialId)
    local toucher = get(game, toucherId)
    if not special or not toucher or special.removed or toucher.removed or not toucher.playerId then return false end
    if toucher.health <= 0 then return false end
    local pickup = info.pickup((special :: any).pickupKind or special.kind)
    if not pickup then return false end
    if math.abs(special.z - toucher.z) > toucher.height + 8 * FRACUNIT then return false end
    local dx, dy = special.x - toucher.x, special.y - toucher.y
    local reach = special.radius + toucher.radius
    if dx * dx + dy * dy > reach * reach then return false end
    local playerIndex = toucher.playerId
    local player = playerFor(game, playerIndex)
    if not player then return false end
    local accepted = false
    if pickup.weapon then
        accepted = weapons.giveWeapon(game, playerIndex, pickup.weapon, bit32.band(special.flags, mobj.MF_CORPSE) ~= 0)
    elseif pickup.ammo then
        accepted = weapons.giveAmmo(game, playerIndex, pickup.ammo, pickup.amount) > 0
    elseif pickup.armor and pickup.power ~= 'mega' then
        local value = pickup.armor * 100
        if player.armor < value then player.armor, player.armorType, accepted = value, pickup.armor, true end
    elseif pickup.power then
        if pickup.power == 'bluecard' or pickup.power == 'redcard' or pickup.power == 'yellowcard' then
            accepted = module.giveCard(game, playerIndex, string.sub(pickup.power, 1, -5))
        elseif pickup.power == 'backpack' then
            local raw = player :: any
            if not raw.backpack then
                raw.backpack = true
                for ammo = info.AMMO_CLIP, info.AMMO_MISSILE do weapons.ammoMax(game, playerIndex, ammo) end
                accepted = true
            end
            for ammo = info.AMMO_CLIP, info.AMMO_MISSILE do weapons.giveAmmo(game, playerIndex, ammo, 1) end
        else
            accepted = applyPower(game, playerIndex, pickup.power)
        end
    elseif pickup.amount then
        if player.health >= 100 and pickup.name ~= 'soulsphere' then return false end
        local old = player.health
        player.health = math.min(if pickup.name == 'soulsphere' then 200 else 100, player.health + pickup.amount)
        accepted = player.health > old
        local object = get(game, player.moId)
        if object then object.health = player.health end
    end
    if accepted then
        special.removed, special.flags, special.state = true, 0, 'dead'
        player.bonuscount += 6
    end
    return accepted
end

function module.damage(game: any, targetId: number, amount: number, sourceId: number?): number
    return enemy.damage(game, targetId, amount, sourceId)
end

module.pickup = module.touch
module.touchSpecialThing = module.touch
module.givePower = applyPower
module.give_ammo = module.giveAmmo
module.damageMobj = module.damage

return module
