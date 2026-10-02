--!strict
-- Canonical moving objects, players, and thinker records.  References between
-- records are integer ids so snapshots never depend on table identity.
local module = {}

export type Mobj = {
    id: number,
    kind: number,
    x: number,
    y: number,
    z: number,
    momx: number,
    momy: number,
    momz: number,
    angle: number,
    radius: number,
    height: number,
    floorz: number,
    ceilingz: number,
    health: number,
    flags: number,
    state: string,
    tics: number,
    reactiontime: number,
    playerId: number?,
    targetId: number?,
    removed: boolean,
    sprite: string?,
    frame: number,
    movedir: number,
    movecount: number,
    threshold: number,
    attackCooldown: number,
    projectile: boolean?,
    sourceId: number?,
}

export type Thinker = {
    id: number,
    kind: string,
    mobjId: number?,
    tics: number,
    removed: boolean,
}

export type Player = {
    index: number,
    moId: number,
    state: string,
    health: number,
    armor: number,
    armorType: number,
    damagecount: number,
    bonuscount: number,
    viewheight: number,
    viewz: number,
    angle: number,
    usedown: boolean,
    attackdown: boolean,
    attackCooldown: number,
    deathTics: number,
    deaths: number,
    kills: number,
    killcount: number,
    itemcount: number,
    secretcount: number,
    frags: {number},
    readyweapon: number,
    pendingweapon: number,
    ammo: {number},
    weaponowned: {boolean},
    powers: {[number]: number},
    cards: {[string]: boolean},
    backpack: boolean,
    maxammo: {number},
    cmd: {forwardmove: number, sidemove: number, angleturn: number, buttons: number},
    spawnX: number,
    spawnY: number,
    spawnAngle: number,
}

module.FRACUNIT = 0x10000
module.ANGLE_MAX = 0x100000000
module.ANG90 = 0x40000000
module.MT_PLAYER = 1
module.MF_SOLID = 0x1
module.MF_SHOOTABLE = 0x2
module.MF_PICKUP = 0x4
module.MF_NOCLIP = 0x8
module.MF_CORPSE = 0x10
module.MF_AMBUSH = 0x20
module.MF_DROPOFF = 0x400
module.MF_SHADOW = 0x40000
module.PST_LIVE = 'live'
module.PST_DEAD = 'dead'

local function normalizeAngle(angle: number): number
    angle %= module.ANGLE_MAX
    return if angle < 0 then angle + module.ANGLE_MAX else angle
end

function module.angleFromDegrees(degrees: number): number
    return normalizeAngle(math.floor(degrees * module.ANGLE_MAX / 360 + 0.5))
end

function module.angleToDegrees(angle: number): number
    return normalizeAngle(angle) * 360 / module.ANGLE_MAX
end

function module.newMobj(id: number, kind: number, x: number, y: number, angle: number, flags: number?, health: number?): Mobj
    return {
        id = id,
        kind = kind,
        x = x,
        y = y,
        z = 0,
        momx = 0,
        momy = 0,
        momz = 0,
        angle = normalizeAngle(angle),
        radius = 16 * module.FRACUNIT,
        height = 56 * module.FRACUNIT,
        floorz = 0,
        ceilingz = 128 * module.FRACUNIT,
        health = health or 100,
        flags = flags or bit32.bor(module.MF_SOLID, module.MF_SHOOTABLE),
        state = 'spawn',
        tics = 0,
        reactiontime = 0,
        playerId = nil,
        targetId = nil,
        removed = false,
        sprite = nil,
        frame = 0,
        movedir = 0,
        movecount = 0,
        threshold = 0,
        attackCooldown = 0,
        projectile = false,
        sourceId = nil,
    }
end

function module.newThinker(id: number, kind: string, mobjId: number?): Thinker
    return { id = id, kind = kind, mobjId = mobjId, tics = 0, removed = false }
end

function module.newPlayer(index: number, moId: number, x: number, y: number, angle: number): Player
    return {
        index = index,
        moId = moId,
        state = module.PST_LIVE,
        health = 100,
        armor = 0,
        armorType = 0,
        damagecount = 0,
        bonuscount = 0,
        viewheight = 41 * module.FRACUNIT,
        viewz = 41 * module.FRACUNIT,
        angle = normalizeAngle(angle),
        usedown = false,
        attackdown = false,
        attackCooldown = 0,
        deathTics = 0,
        deaths = 0,
        kills = 0,
        readyweapon = 1, -- pistol; the fist is represented by 0
        pendingweapon = 1,
        ammo = {50, 0, 0, 0},
        weaponowned = {true, true, false, false, false, false, false, false, false},
        cmd = {forwardmove = 0, sidemove = 0, angleturn = 0, buttons = 0},
        powers = {},
        cards = {},
        backpack = false,
        maxammo = { [1] = 200, [2] = 50, [3] = 300, [4] = 50 },
        psprites = {},
        frags = {0, 0, 0, 0},
        killcount = 0,
        itemcount = 0,
        secretcount = 0,
        spawnX = x,
        spawnY = y,
        spawnAngle = normalizeAngle(angle),
    }
end

function module.spawnPlayer(map: any, playerIndex: number, id: number): (Mobj, Player)
    local start = nil
    for _, thing in map.things do
        if thing.kind == playerIndex then
            start = thing
            break
        end
    end
    if not start then
        error(`mobj: map has no player {playerIndex} start`, 2)
    end

    local angle = module.angleFromDegrees(start.angle)
    local mo = module.newMobj(id, module.MT_PLAYER, start.x * module.FRACUNIT, start.y * module.FRACUNIT, angle)
    mo.flags = bit32.bor(mo.flags, module.MF_DROPOFF)
    local player = module.newPlayer(playerIndex, id, mo.x, mo.y, angle)
    mo.playerId = playerIndex
    return mo, player
end

module.new = module.newMobj
module.angle = module.angleFromDegrees

return module
