--!nonstrict
--!native
-- p_enemy.c: monster movement, targeting, and every monster state action.
-- Sound calls are gone, but the P_Random draws that picked a sound stay, since
-- they advance the shared random stream.
local P: any = require('./core')

local G = P.G
local FixedMul, idiv = P.FixedMul, P.idiv
local {finesine, mobjinfo} = P
local MT, S = P.MT, P.S
local actions = P.actions
local FRACUNIT, U32 = 65536, 4294967296
local band, bor, bnot = bit32.band, bit32.bor, bit32.bnot
local MELEERANGE, MISSILERANGE = P.MELEERANGE, P.MISSILERANGE
local BLOCK = 8388608
local DI_NODIR = 8

local Opposite = { [0] = 4, 5, 6, 7, 0, 1, 2, 3, 8 }
local Diags = { [0] = 3, 1, 5, 7 }
local XSpeed = { [0] = FRACUNIT, 47000, 0, -47000, -FRACUNIT, -47000, 0, 47000 }
local YSpeed = { [0] = 0, 47000, FRACUNIT, 47000, 0, -47000, -FRACUNIT, -47000 }

local function hasSound(sound: any): boolean
  return sound ~= 0 and sound ~= 'None'
end

local soundtarget: any

local function recursiveSound(sector: any, soundblocks: number): ()
  if sector.validcount == G.validcount and sector.soundtraversed <= soundblocks + 1 then return end

  sector.validcount = G.validcount
  sector.soundtraversed = soundblocks + 1
  sector.soundtarget = soundtarget

  for _, check in sector.lines do
    if band(check.flags, 4) == 0 then continue end

    P.LineOpening(check)
    if P.openrange <= 0 then continue end

    local other = if check.frontsector == sector then check.backsector else check.frontsector
    if band(check.flags, 64) ~= 0 then
      if soundblocks == 0 then recursiveSound(other, 1) end
    else
      recursiveSound(other, soundblocks)
    end
  end
end

function P.NoiseAlert(target: any, emitter: any): ()
  soundtarget = target
  G.validcount += 1
  recursiveSound(emitter.subsector.sector, 0)
end

local function checkMeleeRange(actor: any): boolean
  local target = actor.target
  if not target then return false end

  local dist = P.AproxDistance(target.x - actor.x, target.y - actor.y)
  if dist >= MELEERANGE - 20 * FRACUNIT + target.info.radius then return false end
  return P.CheckSight(actor, target)
end

local function checkMissileRange(actor: any): boolean
  if not P.CheckSight(actor, actor.target) then return false end

  if band(actor.flags, P.MF_JUSTHIT) ~= 0 then
    actor.flags = band(actor.flags, bnot(P.MF_JUSTHIT))
    return true
  end

  if actor.reactiontime ~= 0 then return false end

  local dist = P.AproxDistance(actor.x - actor.target.x, actor.y - actor.target.y) - 64 * FRACUNIT
  if actor.info.meleestate == 0 then dist -= 128 * FRACUNIT end
  dist //= 65536

  local type = actor.type
  if type == MT.MT_VILE and dist > 14 * 64 then return false end

  if type == MT.MT_UNDEAD then
    if dist < 196 then return false end
    dist //= 2
  end

  if type == MT.MT_CYBORG or type == MT.MT_SPIDER or type == MT.MT_SKULL then dist //= 2 end
  if dist > 200 then dist = 200 end
  if type == MT.MT_CYBORG and dist > 160 then dist = 160 end

  return P.Random() >= dist
end

local function move(actor: any): boolean
  if actor.movedir == DI_NODIR then return false end

  local tryx = actor.x + actor.info.speed * XSpeed[actor.movedir]
  local tryy = actor.y + actor.info.speed * YSpeed[actor.movedir]
  if not P.TryMove(actor, tryx, tryy) then
    if band(actor.flags, P.MF_FLOAT) ~= 0 and P.floatok then
      if actor.z < P.tmfloorz then
        actor.z += P.FLOATSPEED
      else
        actor.z -= P.FLOATSPEED
      end

      actor.flags = bor(actor.flags, P.MF_INFLOAT)
      return true
    end

    if P.numspechit == 0 then return false end

    actor.movedir = DI_NODIR
    local good = false
    while P.numspechit > 0 do
      local line = P.spechit[P.numspechit]
      P.numspechit -= 1
      if P.UseSpecialLine(actor, line, 0) then good = true end
    end

    return good
  end

  actor.flags = band(actor.flags, bnot(P.MF_INFLOAT))
  if band(actor.flags, P.MF_FLOAT) == 0 then actor.z = actor.floorz end
  return true
end

local function tryWalk(actor: any): boolean
  if not move(actor) then return false end

  actor.movecount = band(P.Random(), 15)
  return true
end

local function newChaseDir(actor: any): ()
  local olddir = actor.movedir
  local turnaround = Opposite[olddir]
  local deltax, deltay = actor.target.x - actor.x, actor.target.y - actor.y
  local d1 = if deltax > 10 * FRACUNIT then 0 elseif deltax < -10 * FRACUNIT then 4 else DI_NODIR
  local d2 = if deltay < -10 * FRACUNIT then 6 elseif deltay > 10 * FRACUNIT then 2 else DI_NODIR

  if d1 ~= DI_NODIR and d2 ~= DI_NODIR then
    actor.movedir = Diags[(if deltay < 0 then 2 else 0) + (if deltax > 0 then 1 else 0)]
    if actor.movedir ~= turnaround and tryWalk(actor) then return end
  end

  if P.Random() > 200 or math.abs(deltay) > math.abs(deltax) then
    d1, d2 = d2, d1
  end

  if d1 == turnaround then d1 = DI_NODIR end
  if d2 == turnaround then d2 = DI_NODIR end

  if d1 ~= DI_NODIR then
    actor.movedir = d1
    if tryWalk(actor) then return end
  end

  if d2 ~= DI_NODIR then
    actor.movedir = d2
    if tryWalk(actor) then return end
  end

  if olddir ~= DI_NODIR then
    actor.movedir = olddir
    if tryWalk(actor) then return end
  end

  local first, last, step = 0, 7, 1
  if band(P.Random(), 1) == 0 then
    first, last, step = 7, 0, -1
  end

  for tdir = first, last, step do
    if tdir ~= turnaround then
      actor.movedir = tdir
      if tryWalk(actor) then return end
    end
  end

  if turnaround ~= DI_NODIR then
    actor.movedir = turnaround
    if tryWalk(actor) then return end
  end

  actor.movedir = DI_NODIR
end

local function lookForPlayers(actor: any, allaround: boolean): boolean
  local c = 0
  local stop = (actor.lastlook - 1) % 4
  while true do
    local lastlook = actor.lastlook
    if G.playeringame[lastlook] then
      if c == 2 or lastlook == stop then return false end
      c += 1

      local player = G.players[lastlook]
      local mo = player.mo
      local visible = player.health > 0 and P.CheckSight(actor, mo)
      if visible and not allaround then
        local an = (P.PointToAngle2(actor.x, actor.y, mo.x, mo.y) - actor.angle) % U32
        if an > 0x40000000 and an < 0xC0000000 then
          if P.AproxDistance(mo.x - actor.x, mo.y - actor.y) > MELEERANGE then visible = false end
        end
      end

      if visible then
        actor.target = mo
        return true
      end
    end

    actor.lastlook = (lastlook + 1) % 4
  end
end

P.LookForPlayers = lookForPlayers

local function othersAlive(mo: any): boolean
  local cap = G.thinkercap
  local th = cap.next
  while th ~= cap do
    if th.think == 'mobj' and th ~= mo and th.type == mo.type and th.health > 0 then return true end
    th = th.next
  end

  return false
end

function actions.A_Fall(actor: any): ()
  actor.flags = band(actor.flags, bnot(P.MF_SOLID))
end

function actions.A_KeenDie(mo: any): ()
  actions.A_Fall(mo)
  if othersAlive(mo) then return end

  P.DoDoor({ tag = 666 }, 'open')
end

function actions.A_Look(actor: any): ()
  actor.threshold = 0
  local targ = actor.subsector.sector.soundtarget
  local seen = false
  if targ and band(targ.flags, P.MF_SHOOTABLE) ~= 0 then
    actor.target = targ
    seen = band(actor.flags, P.MF_AMBUSH) == 0 or P.CheckSight(actor, targ)
  end

  if not seen and not lookForPlayers(actor, false) then return end

  local sound = actor.info.seesound
  if sound == 'posit1' or sound == 'posit2' or sound == 'posit3' or sound == 'bgsit1' or sound == 'bgsit2' then P.Random() end

  P.SetMobjState(actor, actor.info.seestate)
end

function actions.A_Chase(actor: any): ()
  if actor.reactiontime ~= 0 then actor.reactiontime -= 1 end

  if actor.threshold ~= 0 then
    if not actor.target or actor.target.health <= 0 then
      actor.threshold = 0
    else
      actor.threshold -= 1
    end
  end

  if actor.movedir < 8 then
    actor.angle = band(actor.angle, 0xE0000000)
    local delta = P.i32(actor.angle - actor.movedir * 0x20000000)
    if delta > 0 then
      actor.angle = (actor.angle - 0x20000000) % U32
    elseif delta < 0 then
      actor.angle = (actor.angle + 0x20000000) % U32
    end
  end

  local target = actor.target
  if not target or band(target.flags, P.MF_SHOOTABLE) == 0 then
    if lookForPlayers(actor, true) then return end

    P.SetMobjState(actor, actor.info.spawnstate)
    return
  end

  local fast = G.gameskill == 4 or G.fastparm
  if band(actor.flags, P.MF_JUSTATTACKED) ~= 0 then
    actor.flags = band(actor.flags, bnot(P.MF_JUSTATTACKED))
    if not fast then newChaseDir(actor) end
    return
  end

  if actor.info.meleestate ~= 0 and checkMeleeRange(actor) then
    P.SetMobjState(actor, actor.info.meleestate)
    return
  end

  if actor.info.missilestate ~= 0 and (fast or actor.movecount == 0) and checkMissileRange(actor) then
    P.SetMobjState(actor, actor.info.missilestate)
    actor.flags = bor(actor.flags, P.MF_JUSTATTACKED)
    return
  end

  if G.netgame and actor.threshold == 0 and not P.CheckSight(actor, actor.target) then
    if lookForPlayers(actor, true) then return end
  end

  actor.movecount -= 1
  if actor.movecount < 0 or not move(actor) then newChaseDir(actor) end

  if hasSound(actor.info.activesound) then P.Random() end
end

local function faceTarget(actor: any): ()
  local target = actor.target
  if not target then return end

  actor.flags = band(actor.flags, bnot(P.MF_AMBUSH))
  actor.angle = P.PointToAngle2(actor.x, actor.y, target.x, target.y)
  if band(target.flags, P.MF_SHADOW) ~= 0 then actor.angle = (actor.angle + P.SubRandom() * 2097152) % U32 end
end

actions.A_FaceTarget = faceTarget

local function bullet(actor: any, bangle: number, slope: number): ()
  local angle = (bangle + P.SubRandom() * 1048576) % U32
  local damage = (P.Random() % 5 + 1) * 3
  P.LineAttack(actor, angle, MISSILERANGE, slope, damage)
end

function actions.A_PosAttack(actor: any): ()
  if not actor.target then return end

  faceTarget(actor)
  bullet(actor, actor.angle, P.AimLineAttack(actor, actor.angle, MISSILERANGE))
end

function actions.A_SPosAttack(actor: any): ()
  if not actor.target then return end

  faceTarget(actor)
  local bangle = actor.angle
  local slope = P.AimLineAttack(actor, bangle, MISSILERANGE)
  for _ = 1, 3 do
    bullet(actor, bangle, slope)
  end
end

actions.A_CPosAttack = actions.A_PosAttack

local function refire(actor: any, chance: number): ()
  faceTarget(actor)
  if P.Random() < chance then return end

  local target = actor.target
  if not target or target.health <= 0 or not P.CheckSight(actor, target) then P.SetMobjState(actor, actor.info.seestate) end
end

function actions.A_CPosRefire(actor: any): ()
  refire(actor, 40)
end

function actions.A_SpidRefire(actor: any): ()
  refire(actor, 10)
end

local function missileAttack(type: number, meleeSides: number?, meleeScale: number?, face: boolean?): (any) -> ()
  return function(actor: any): ()
    if not actor.target then return end
    if face ~= false then faceTarget(actor) end

    if meleeSides and checkMeleeRange(actor) then
      local damage = (P.Random() % meleeSides + 1) * (meleeScale :: number)
      P.DamageMobj(actor.target, actor, actor, damage)
      return
    end

    P.SpawnMissile(actor, actor.target, type)
  end
end

actions.A_BspiAttack = missileAttack(MT.MT_ARACHPLAZ)
actions.A_TroopAttack = missileAttack(MT.MT_TROOPSHOT, 8, 3)
actions.A_HeadAttack = missileAttack(MT.MT_HEADSHOT, 6, 10)
actions.A_CyberAttack = missileAttack(MT.MT_ROCKET)
actions.A_BruisAttack = missileAttack(MT.MT_BRUISERSHOT, 8, 10, false)

local function meleeAttack(sides: number, scale: number): (any) -> ()
  return function(actor: any): ()
    if not actor.target then return end

    faceTarget(actor)
    if checkMeleeRange(actor) then
      local damage = (P.Random() % sides + 1) * scale
      P.DamageMobj(actor.target, actor, actor, damage)
    end
  end
end

actions.A_SargAttack = meleeAttack(10, 4)
actions.A_SkelFist = meleeAttack(10, 6)

function actions.A_SkelMissile(actor: any): ()
  if not actor.target then return end

  faceTarget(actor)
  actor.z += 16 * FRACUNIT
  local mo = P.SpawnMissile(actor, actor.target, MT.MT_TRACER)
  actor.z -= 16 * FRACUNIT
  mo.x += mo.momx
  mo.y += mo.momy
  mo.tracer = actor.target
end

local TRACEANGLE = 0xc000000

function actions.A_Tracer(actor: any): ()
  if G.gametic % 4 ~= 0 then return end

  P.SpawnPuff(actor.x, actor.y, actor.z)
  local th = P.SpawnMobj(actor.x - actor.momx, actor.y - actor.momy, actor.z, MT.MT_SMOKE)
  th.momz = FRACUNIT
  th.tics -= band(P.Random(), 3)
  if th.tics < 1 then th.tics = 1 end

  local dest = actor.tracer
  if not dest or dest.health <= 0 then return end

  local exact = P.PointToAngle2(actor.x, actor.y, dest.x, dest.y)
  if exact ~= actor.angle then
    if (exact - actor.angle) % U32 > 0x80000000 then
      actor.angle = (actor.angle - TRACEANGLE) % U32
      if (exact - actor.angle) % U32 < 0x80000000 then actor.angle = exact end
    else
      actor.angle = (actor.angle + TRACEANGLE) % U32
      if (exact - actor.angle) % U32 > 0x80000000 then actor.angle = exact end
    end
  end

  local fine = actor.angle // 524288
  actor.momx = FixedMul(actor.info.speed, finesine[fine + 2049])
  actor.momy = FixedMul(actor.info.speed, finesine[fine + 1])

  local dist = idiv(P.AproxDistance(dest.x - actor.x, dest.y - actor.y), actor.info.speed)
  if dist < 1 then dist = 1 end

  local slope = idiv(dest.z + 40 * FRACUNIT - actor.z, dist)
  if slope < actor.momz then
    actor.momz -= FRACUNIT / 8
  else
    actor.momz += FRACUNIT / 8
  end
end

function actions.A_SkelWhoosh(actor: any): ()
  if actor.target then faceTarget(actor) end
end

local corpsehit: any
local viletryx, viletryy = 0, 0

local function vileCheck(thing: any): boolean
  if band(thing.flags, P.MF_CORPSE) == 0 then return true end
  if thing.tics ~= -1 then return true end
  if thing.info.raisestate == 0 then return true end

  local maxdist = thing.info.radius + mobjinfo[MT.MT_VILE].radius
  if math.abs(thing.x - viletryx) > maxdist or math.abs(thing.y - viletryy) > maxdist then return true end

  corpsehit = thing
  thing.momx, thing.momy = 0, 0
  thing.height *= 4
  local check = P.CheckPosition(thing, thing.x, thing.y)
  thing.height //= 4
  return not check
end

function actions.A_VileChase(actor: any): ()
  if actor.movedir ~= DI_NODIR then
    viletryx = actor.x + actor.info.speed * XSpeed[actor.movedir]
    viletryy = actor.y + actor.info.speed * YSpeed[actor.movedir]

    local reach = P.MAXRADIUS * 2
    local xl, xh = (viletryx - G.bmaporgx - reach) // BLOCK, (viletryx - G.bmaporgx + reach) // BLOCK
    local yl, yh = (viletryy - G.bmaporgy - reach) // BLOCK, (viletryy - G.bmaporgy + reach) // BLOCK
    for bx = xl, xh do
      for by = yl, yh do
        if P.BlockThingsIterator(bx, by, vileCheck) then continue end

        local temp = actor.target
        actor.target = corpsehit
        faceTarget(actor)
        actor.target = temp
        P.SetMobjState(actor, S.S_VILE_HEAL1)

        local info = corpsehit.info
        P.SetMobjState(corpsehit, info.raisestate)
        corpsehit.height *= 4
        corpsehit.flags = info.flags
        corpsehit.health = info.spawnhealth
        corpsehit.target = nil
        return
      end
    end
  end

  actions.A_Chase(actor)
end

function actions.A_VileStart(_actor: any): () end

local function fire(actor: any): ()
  local dest = actor.tracer
  if not dest then return end
  if not P.CheckSight(actor.target, dest) then return end

  local fine = dest.angle // 524288
  P.UnsetThingPosition(actor)
  actor.x = dest.x + FixedMul(24 * FRACUNIT, finesine[fine + 2049])
  actor.y = dest.y + FixedMul(24 * FRACUNIT, finesine[fine + 1])
  actor.z = dest.z
  P.SetThingPosition(actor)
end

actions.A_Fire, actions.A_StartFire, actions.A_FireCrackle = fire, fire, fire

function actions.A_VileTarget(actor: any): ()
  local target = actor.target
  if not target then return end

  faceTarget(actor)
  -- The original passes target->x for both coordinates.
  local fog = P.SpawnMobj(target.x, target.x, target.z, MT.MT_FIRE)
  actor.tracer = fog
  fog.target = actor
  fog.tracer = target
  fire(fog)
end

function actions.A_VileAttack(actor: any): ()
  local target = actor.target
  if not target then return end

  faceTarget(actor)
  if not P.CheckSight(actor, target) then return end

  P.DamageMobj(target, actor, actor, 20)
  target.momz = idiv(1000 * FRACUNIT, target.info.mass)

  local flame = actor.tracer
  if not flame then return end

  local fine = actor.angle // 524288
  flame.x = target.x - FixedMul(24 * FRACUNIT, finesine[fine + 2049])
  flame.y = target.y - FixedMul(24 * FRACUNIT, finesine[fine + 1])
  P.RadiusAttack(flame, actor, 70)
end

local FATSPREAD = 0x40000000 // 8

local function fatShot(actor: any, turn: number): ()
  local mo = P.SpawnMissile(actor, actor.target, MT.MT_FATSHOT)
  mo.angle = (mo.angle + turn) % U32
  local fine = mo.angle // 524288
  mo.momx = FixedMul(mo.info.speed, finesine[fine + 2049])
  mo.momy = FixedMul(mo.info.speed, finesine[fine + 1])
end

actions.A_FatRaise = faceTarget

function actions.A_FatAttack1(actor: any): ()
  faceTarget(actor)
  actor.angle = (actor.angle + FATSPREAD) % U32
  P.SpawnMissile(actor, actor.target, MT.MT_FATSHOT)
  fatShot(actor, FATSPREAD)
end

function actions.A_FatAttack2(actor: any): ()
  faceTarget(actor)
  actor.angle = (actor.angle - FATSPREAD) % U32
  P.SpawnMissile(actor, actor.target, MT.MT_FATSHOT)
  fatShot(actor, -FATSPREAD * 2)
end

function actions.A_FatAttack3(actor: any): ()
  faceTarget(actor)
  fatShot(actor, -FATSPREAD / 2)
  fatShot(actor, FATSPREAD / 2)
end

local SKULLSPEED = 20 * FRACUNIT

local function skullAttack(actor: any): ()
  local dest = actor.target
  if not dest then return end

  actor.flags = bor(actor.flags, P.MF_SKULLFLY)
  faceTarget(actor)
  local fine = actor.angle // 524288
  actor.momx = FixedMul(SKULLSPEED, finesine[fine + 2049])
  actor.momy = FixedMul(SKULLSPEED, finesine[fine + 1])

  local dist = idiv(P.AproxDistance(dest.x - actor.x, dest.y - actor.y), SKULLSPEED)
  if dist < 1 then dist = 1 end
  actor.momz = idiv(dest.z + dest.height // 2 - actor.z, dist)
end

actions.A_SkullAttack = skullAttack

local function painShootSkull(actor: any, angle: number): ()
  local count = 0
  local cap = G.thinkercap
  local th = cap.next
  while th ~= cap do
    if th.think == 'mobj' and th.type == MT.MT_SKULL then count += 1 end
    th = th.next
  end

  if count > 20 then return end

  local fine = (angle % U32) // 524288
  local prestep = 4 * FRACUNIT + idiv(3 * (actor.info.radius + mobjinfo[MT.MT_SKULL].radius), 2)
  local x = actor.x + FixedMul(prestep, finesine[fine + 2049])
  local y = actor.y + FixedMul(prestep, finesine[fine + 1])
  local newmobj = P.SpawnMobj(x, y, actor.z + 8 * FRACUNIT, MT.MT_SKULL)
  if not P.TryMove(newmobj, newmobj.x, newmobj.y) then
    P.DamageMobj(newmobj, actor, actor, 10000)
    return
  end

  newmobj.target = actor.target
  skullAttack(newmobj)
end

function actions.A_PainAttack(actor: any): ()
  if not actor.target then return end

  faceTarget(actor)
  painShootSkull(actor, actor.angle)
end

function actions.A_PainDie(actor: any): ()
  actions.A_Fall(actor)
  painShootSkull(actor, actor.angle + 0x40000000)
  painShootSkull(actor, actor.angle + 0x80000000)
  painShootSkull(actor, actor.angle + 0xC0000000)
end

function actions.A_Scream(actor: any): ()
  local sound = actor.info.deathsound
  if sound == 'podth1' or sound == 'podth2' or sound == 'podth3' or sound == 'bgdth1' or sound == 'bgdth2' then P.Random() end
end

function actions.A_XScream(_actor: any): () end

actions.A_Pain, actions.A_PlayerScream, actions.A_BrainPain = actions.A_XScream, actions.A_XScream, actions.A_XScream

function actions.A_Explode(thingy: any): ()
  P.RadiusAttack(thingy, thingy.target, 128)
end

function actions.A_BossDeath(mo: any): ()
  local map, episode, type = G.gamemap, G.gameepisode, mo.type
  if G.commercial then
    if map ~= 7 then return end
    if type ~= MT.MT_FATSO and type ~= MT.MT_BABY then return end
  elseif episode == 1 then
    if map ~= 8 or type ~= MT.MT_BRUISER then return end
  elseif episode == 2 then
    if map ~= 8 or type ~= MT.MT_CYBORG then return end
  elseif episode == 3 then
    if map ~= 8 or type ~= MT.MT_SPIDER then return end
  elseif episode == 4 then
    if map == 6 then
      if type ~= MT.MT_CYBORG then return end
    elseif map == 8 then
      if type ~= MT.MT_SPIDER then return end
    else
      return
    end
  elseif map ~= 8 then
    return
  end

  local alive = false
  for index = 0, 3 do
    if G.playeringame[index] and G.players[index].health > 0 then
      alive = true
      break
    end
  end

  if not alive then return end
  if othersAlive(mo) then return end

  if G.commercial then
    if type == MT.MT_FATSO then return P.DoFloor({ tag = 666 }, 'lowerFloorToLowest') end
    if type == MT.MT_BABY then return P.DoFloor({ tag = 667 }, 'raiseToTexture') end
  elseif episode == 1 then
    return P.DoFloor({ tag = 666 }, 'lowerFloorToLowest')
  elseif episode == 4 then
    if map == 6 then return P.DoDoor({ tag = 666 }, 'blazeOpen') end
    if map == 8 then return P.DoFloor({ tag = 666 }, 'lowerFloorToLowest') end
  end

  P.ExitLevel()
end

actions.A_Hoof, actions.A_Metal, actions.A_BabyMetal = actions.A_Chase, actions.A_Chase, actions.A_Chase

function actions.A_BrainAwake(_mo: any): ()
  local targets = {}
  local cap = G.thinkercap
  local th = cap.next
  while th ~= cap do
    if th.think == 'mobj' and th.type == MT.MT_BOSSTARGET then table.insert(targets, th) end
    th = th.next
  end

  G.braintargets, G.braintargeton = targets, 0
end

local function brainExplosion(x: number, y: number): ()
  local z = 128 + P.Random() * 2 * FRACUNIT
  local th = P.SpawnMobj(x, y, z, MT.MT_ROCKET)
  th.momz = P.Random() * 512
  P.SetMobjState(th, S.S_BRAINEXPLODE1)
  th.tics -= band(P.Random(), 7)
  if th.tics < 1 then th.tics = 1 end
end

function actions.A_BrainScream(mo: any): ()
  for x = mo.x - 196 * FRACUNIT, mo.x + 320 * FRACUNIT - 1, FRACUNIT * 8 do
    brainExplosion(x, mo.y - 320 * FRACUNIT)
  end
end

function actions.A_BrainExplode(mo: any): ()
  brainExplosion(mo.x + P.SubRandom() * 2048, mo.y)
end

function actions.A_BrainDie(_mo: any): ()
  P.ExitLevel()
end

function actions.A_BrainSpit(mo: any): ()
  G.braineasy = not G.braineasy
  if G.gameskill <= 1 and not G.braineasy then return end

  local targets = G.braintargets
  if not targets or #targets == 0 then return end

  local targ = targets[G.braintargeton + 1]
  G.braintargeton = (G.braintargeton + 1) % #targets

  local newmobj = P.SpawnMissile(mo, targ, MT.MT_SPAWNSHOT)
  newmobj.target = targ
  -- A cube fired along the x axis divides by zero in the original.
  local steps = if newmobj.momy == 0 then 0 else idiv(targ.y - mo.y, newmobj.momy)
  newmobj.reactiontime = idiv(steps, P.states[newmobj.state].tics)
end

local SpawnTable = {
  { 50, MT.MT_TROOP },
  { 90, MT.MT_SERGEANT },
  { 120, MT.MT_SHADOWS },
  { 130, MT.MT_PAIN },
  { 160, MT.MT_HEAD },
  { 162, MT.MT_VILE },
  { 172, MT.MT_UNDEAD },
  { 192, MT.MT_BABY },
  { 222, MT.MT_FATSO },
  { 246, MT.MT_KNIGHT },
  { 256, MT.MT_BRUISER },
}

local function spawnFly(mo: any): ()
  mo.reactiontime -= 1
  if mo.reactiontime ~= 0 then return end

  local targ = mo.target
  P.SpawnMobj(targ.x, targ.y, targ.z, MT.MT_SPAWNFIRE)

  local r = P.Random()
  local type = MT.MT_BRUISER
  for _, entry in SpawnTable do
    if r < entry[1] then
      type = entry[2]
      break
    end
  end

  local newmobj = P.SpawnMobj(targ.x, targ.y, targ.z, type)
  if lookForPlayers(newmobj, true) then P.SetMobjState(newmobj, newmobj.info.seestate) end

  P.TeleportMove(newmobj, newmobj.x, newmobj.y)
  P.RemoveMobj(mo)
end

actions.A_SpawnFly, actions.A_SpawnSound = spawnFly, spawnFly

return P
