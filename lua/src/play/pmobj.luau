--!nonstrict
--!native
-- p_mobj.c, p_inter.c, p_user.c, and p_pspr.c: map objects, damage and
-- pickups, player movement, and the weapon state machine.
local P: any = require('./core')

local G = P.G
local FixedMul, idiv, i32 = P.FixedMul, P.idiv, P.i32
local finesine, states, mobjinfo = P.finesine, P.states, P.mobjinfo
local MT, S = P.MT, P.S
local FRACUNIT, U32 = 65536, 4294967296
local band, bor, bnot = bit32.band, bit32.bor, bit32.bnot
local MF_SHOOTABLE, MF_MISSILE, MF_SKULLFLY, MF_CORPSE = P.MF_SHOOTABLE, P.MF_MISSILE, P.MF_SKULLFLY, P.MF_CORPSE
local ONFLOORZ, ONCEILINGZ = P.ONFLOORZ, P.ONCEILINGZ
local VIEWHEIGHT, MAXMOVE, GRAVITY = P.VIEWHEIGHT, P.MAXMOVE, P.GRAVITY
local ANG45 = P.ANG45

P.actions = {}

local actions = P.actions

local function setMobjState(mobj: any, state: number): boolean
  repeat
    if state == 0 then
      mobj.state = 0
      P.RemoveMobj(mobj)
      return false
    end

    local st = states[state]
    mobj.state, mobj.tics, mobj.sprite, mobj.frame = state, st.tics, st.sprite, st.frame
    if st.action then actions[st.action](mobj) end
    state = st.nextstate
  until mobj.tics ~= 0

  return true
end

P.SetMobjState = setMobjState

local function explodeMissile(mo: any): ()
  mo.momx, mo.momy, mo.momz = 0, 0, 0
  setMobjState(mo, mo.info.deathstate)
  mo.tics -= band(P.Random(), 3)
  if mo.tics < 1 then mo.tics = 1 end
  mo.flags = band(mo.flags, bnot(MF_MISSILE))
end

P.ExplodeMissile = explodeMissile

local function xyMovement(mo: any): ()
  if mo.momx == 0 and mo.momy == 0 then
    if band(mo.flags, MF_SKULLFLY) ~= 0 then
      mo.flags = band(mo.flags, bnot(MF_SKULLFLY))
      mo.momx, mo.momy, mo.momz = 0, 0, 0
      setMobjState(mo, mo.info.spawnstate)
    end

    return
  end

  local player = mo.player
  mo.momx = math.clamp(mo.momx, -MAXMOVE, MAXMOVE)
  mo.momy = math.clamp(mo.momy, -MAXMOVE, MAXMOVE)

  local xmove, ymove = mo.momx, mo.momy
  repeat
    local ptryx, ptryy
    if xmove > MAXMOVE / 2 or ymove > MAXMOVE / 2 then
      ptryx, ptryy = mo.x + idiv(xmove, 2), mo.y + idiv(ymove, 2)
      xmove //= 2
      ymove //= 2
    else
      ptryx, ptryy = mo.x + xmove, mo.y + ymove
      xmove, ymove = 0, 0
    end

    if not P.TryMove(mo, ptryx, ptryy) then
      if mo.player then
        P.SlideMove(mo)
      elseif band(mo.flags, MF_MISSILE) ~= 0 then
        local line = P.ceilingline
        if line and line.backsector and line.backsector.ceilingpic == 'F_SKY1' then
          P.RemoveMobj(mo)
          return
        end

        explodeMissile(mo)
      else
        mo.momx, mo.momy = 0, 0
      end
    end
  until xmove == 0 and ymove == 0

  if player and band(player.cheats, P.CF_NOMOMENTUM) ~= 0 then
    mo.momx, mo.momy = 0, 0
    return
  end

  if band(mo.flags, MF_MISSILE + MF_SKULLFLY) ~= 0 then return end
  if mo.z > mo.floorz then return end

  if band(mo.flags, MF_CORPSE) ~= 0 then
    if mo.momx > 16384 or mo.momx < -16384 or mo.momy > 16384 or mo.momy < -16384 then
      if mo.floorz ~= mo.subsector.sector.floorheight then return end
    end
  end

  if
    mo.momx > -0x1000
    and mo.momx < 0x1000
    and mo.momy > -0x1000
    and mo.momy < 0x1000
    and (not player or (player.cmd.forwardmove == 0 and player.cmd.sidemove == 0))
  then
    if player then
      local running = player.mo.state - S.S_PLAY_RUN1
      if running >= 0 and running < 4 then setMobjState(player.mo, S.S_PLAY) end
    end

    mo.momx, mo.momy = 0, 0
  else
    mo.momx, mo.momy = FixedMul(mo.momx, 0xe800), FixedMul(mo.momy, 0xe800)
  end
end

local function zMovement(mo: any): ()
  local player = mo.player
  if player and mo.z < mo.floorz then
    player.viewheight -= mo.floorz - mo.z
    player.deltaviewheight = (VIEWHEIGHT - player.viewheight) // 8
  end

  mo.z += mo.momz

  if band(mo.flags, P.MF_FLOAT) ~= 0 and mo.target then
    if band(mo.flags, MF_SKULLFLY + P.MF_INFLOAT) == 0 then
      local dist = P.AproxDistance(mo.x - mo.target.x, mo.y - mo.target.y)
      local delta = mo.target.z + mo.height // 2 - mo.z
      if delta < 0 and dist < -(delta * 3) then
        mo.z -= P.FLOATSPEED
      elseif delta > 0 and dist < delta * 3 then
        mo.z += P.FLOATSPEED
      end
    end
  end

  if mo.z <= mo.floorz then
    if band(mo.flags, MF_SKULLFLY) ~= 0 then mo.momz = -mo.momz end

    if mo.momz < 0 then
      if player and mo.momz < -GRAVITY * 8 then player.deltaviewheight = mo.momz // 8 end
      mo.momz = 0
    end

    mo.z = mo.floorz
    if band(mo.flags, MF_MISSILE) ~= 0 and band(mo.flags, P.MF_NOCLIP) == 0 then
      explodeMissile(mo)
      return
    end
  elseif band(mo.flags, P.MF_NOGRAVITY) == 0 then
    if mo.momz == 0 then
      mo.momz = -GRAVITY * 2
    else
      mo.momz -= GRAVITY
    end
  end

  if mo.z + mo.height > mo.ceilingz then
    if mo.momz > 0 then mo.momz = 0 end
    mo.z = mo.ceilingz - mo.height
    if band(mo.flags, MF_SKULLFLY) ~= 0 then mo.momz = -mo.momz end

    if band(mo.flags, MF_MISSILE) ~= 0 and band(mo.flags, P.MF_NOCLIP) == 0 then explodeMissile(mo) end
  end
end

local function mapThingAngle(mthing: any): number
  return (ANG45 * idiv(mthing.angle, 45)) % U32
end

local function nightmareRespawn(mobj: any): ()
  local x, y = mobj.spawnpoint.x * FRACUNIT, mobj.spawnpoint.y * FRACUNIT
  if not P.CheckPosition(mobj, x, y) then return end

  P.SpawnMobj(mobj.x, mobj.y, mobj.subsector.sector.floorheight, MT.MT_TFOG)
  P.SpawnMobj(x, y, P.PointInSubsector(x, y).sector.floorheight, MT.MT_TFOG)

  local mthing = mobj.spawnpoint
  local z = if band(mobj.info.flags, P.MF_SPAWNCEILING) ~= 0 then ONCEILINGZ else ONFLOORZ
  local mo = P.SpawnMobj(x, y, z, mobj.type)
  mo.spawnpoint = mthing
  mo.angle = mapThingAngle(mthing)
  if band(mthing.options, 8) ~= 0 then mo.flags = bor(mo.flags, P.MF_AMBUSH) end
  mo.reactiontime = 18
  P.RemoveMobj(mobj)
end

function P.think.mobj(mobj: any): ()
  if mobj.momx ~= 0 or mobj.momy ~= 0 or band(mobj.flags, MF_SKULLFLY) ~= 0 then
    xyMovement(mobj)
    if mobj.think == false then return end
  end

  if mobj.z ~= mobj.floorz or mobj.momz ~= 0 then
    zMovement(mobj)
    if mobj.think == false then return end
  end

  if mobj.tics ~= -1 then
    mobj.tics -= 1
    if mobj.tics == 0 then setMobjState(mobj, states[mobj.state].nextstate) end
    return
  end

  if band(mobj.flags, P.MF_COUNTKILL) == 0 then return end
  if not G.respawnmonsters then return end

  mobj.movecount += 1
  if mobj.movecount < 12 * 35 then return end
  if G.leveltime % 32 ~= 0 then return end
  if P.Random() > 4 then return end

  nightmareRespawn(mobj)
end

function P.SpawnMobj(x: number, y: number, z: number, type: number): any
  local info = mobjinfo[type]
  local st = states[info.spawnstate]
  local mobj = {
    think = 'mobj',
    type = type,
    info = info,
    x = x,
    y = y,
    z = 0,
    angle = 0,
    radius = info.radius,
    height = info.height,
    momx = 0,
    momy = 0,
    momz = 0,
    flags = info.flags,
    health = info.spawnhealth,
    reactiontime = if G.gameskill ~= 4 then info.reactiontime else 0,
    lastlook = P.Random() % 4,
    state = info.spawnstate,
    tics = st.tics,
    sprite = st.sprite,
    frame = st.frame,
    movedir = 0,
    movecount = 0,
    threshold = 0,
    floorz = 0,
    ceilingz = 0,
  }

  P.SetThingPosition(mobj)
  mobj.floorz = mobj.subsector.sector.floorheight
  mobj.ceilingz = mobj.subsector.sector.ceilingheight
  if z == ONFLOORZ then
    mobj.z = mobj.floorz
  elseif z == ONCEILINGZ then
    mobj.z = mobj.ceilingz - info.height
  else
    mobj.z = z
  end

  P.AddThinker(mobj)
  return mobj
end

local ITEMQUESIZE = 128

function P.RemoveMobj(mobj: any): ()
  if
    band(mobj.flags, P.MF_SPECIAL) ~= 0
    and band(mobj.flags, P.MF_DROPPED) == 0
    and mobj.type ~= MT.MT_INV
    and mobj.type ~= MT.MT_INS
  then
    G.itemrespawnque[G.iquehead] = mobj.spawnpoint
    G.itemrespawntime[G.iquehead] = G.leveltime
    G.iquehead = (G.iquehead + 1) % ITEMQUESIZE
    if G.iquehead == G.iquetail then G.iquetail = (G.iquetail + 1) % ITEMQUESIZE end
  end

  P.UnsetThingPosition(mobj)
  P.RemoveThinker(mobj)
end

local function typeForDoomednum(doomednum: number): number?
  for index = 0, #mobjinfo do
    if mobjinfo[index].doomednum == doomednum then return index end
  end

  return nil
end

function P.RespawnSpecials(): ()
  if G.deathmatch ~= 2 then return end
  if G.iquehead == G.iquetail then return end
  if G.leveltime - G.itemrespawntime[G.iquetail] < 30 * 35 then return end

  local mthing = G.itemrespawnque[G.iquetail]
  -- A dropped-in item with no map spawn point has nothing to come back to.
  local type = mthing and typeForDoomednum(mthing.type)
  if mthing and type then
    local x, y = mthing.x * FRACUNIT, mthing.y * FRACUNIT
    P.SpawnMobj(x, y, P.PointInSubsector(x, y).sector.floorheight, MT.MT_IFOG)
    local z = if band(mobjinfo[type].flags, P.MF_SPAWNCEILING) ~= 0 then ONCEILINGZ else ONFLOORZ
    local mo = P.SpawnMobj(x, y, z, type)
    mo.spawnpoint = mthing
    mo.angle = mapThingAngle(mthing)
  end

  G.iquetail = (G.iquetail + 1) % ITEMQUESIZE
end

function P.SpawnPlayer(mthing: any): ()
  local index = mthing.type - 1
  if not G.playeringame[index] then return end

  local player = G.players[index]
  if player.playerstate == P.PST_REBORN then P.PlayerReborn(index) end

  local mobj = P.SpawnMobj(mthing.x * FRACUNIT, mthing.y * FRACUNIT, ONFLOORZ, MT.MT_PLAYER)
  if mthing.type > 1 then mobj.flags = bor(mobj.flags, bit32.lshift(mthing.type - 1, P.MF_TRANSSHIFT)) end

  mobj.angle = mapThingAngle(mthing)
  mobj.player = player
  mobj.health = player.health
  player.mo = mobj
  player.playerstate = P.PST_LIVE
  player.refire = 0
  player.damagecount, player.bonuscount = 0, 0
  player.extralight, player.fixedcolormap = 0, 0
  player.viewheight = VIEWHEIGHT
  P.SetupPsprites(player)

  if G.deathmatch ~= 0 then
    for card = 0, 5 do
      player.cards[card] = true
    end
  end
end

function P.SpawnMapThing(mthing: any): ()
  if mthing.type == 11 then
    if #G.deathmatchstarts < 10 then table.insert(G.deathmatchstarts, mthing) end
    return
  end

  if mthing.type <= 4 then
    -- Types 0 and below index outside playerstarts in the original; no map
    -- relies on it.
    if mthing.type < 1 then return end

    G.playerstarts[mthing.type - 1] = mthing
    if G.deathmatch == 0 then P.SpawnPlayer(mthing) end
    return
  end

  if not G.netgame and band(mthing.options, 16) ~= 0 then return end

  local skill = G.gameskill
  local bit = if skill == 0 then 1 elseif skill == 4 then 4 else bit32.lshift(1, skill - 1)
  if band(mthing.options, bit) == 0 then return end

  local type = typeForDoomednum(mthing.type)
  if not type then return end

  local info = mobjinfo[type]
  if G.deathmatch ~= 0 and band(info.flags, P.MF_NOTDMATCH) ~= 0 then return end
  if G.nomonsters and (type == MT.MT_SKULL or band(info.flags, P.MF_COUNTKILL) ~= 0) then return end

  local z = if band(info.flags, P.MF_SPAWNCEILING) ~= 0 then ONCEILINGZ else ONFLOORZ
  local mobj = P.SpawnMobj(mthing.x * FRACUNIT, mthing.y * FRACUNIT, z, type)
  mobj.spawnpoint = mthing
  if mobj.tics > 0 then mobj.tics = 1 + P.Random() % mobj.tics end
  if band(mobj.flags, P.MF_COUNTKILL) ~= 0 then G.totalkills += 1 end
  if band(mobj.flags, P.MF_COUNTITEM) ~= 0 then G.totalitems += 1 end

  mobj.angle = mapThingAngle(mthing)
  if band(mthing.options, 8) ~= 0 then mobj.flags = bor(mobj.flags, P.MF_AMBUSH) end
end

function P.SpawnPuff(x: number, y: number, z: number): ()
  z += P.SubRandom() * 1024
  local th = P.SpawnMobj(x, y, z, MT.MT_PUFF)
  th.momz = FRACUNIT
  th.tics -= band(P.Random(), 3)
  if th.tics < 1 then th.tics = 1 end
  if P.attackrange == P.MELEERANGE then setMobjState(th, S.S_PUFF3) end
end

function P.SpawnBlood(x: number, y: number, z: number, damage: number): ()
  z += P.SubRandom() * 1024
  local th = P.SpawnMobj(x, y, z, MT.MT_BLOOD)
  th.momz = FRACUNIT * 2
  th.tics -= band(P.Random(), 3)
  if th.tics < 1 then th.tics = 1 end

  if damage <= 12 and damage >= 9 then
    setMobjState(th, S.S_BLOOD2)
  elseif damage < 9 then
    setMobjState(th, S.S_BLOOD3)
  end
end

local function checkMissileSpawn(th: any): ()
  th.tics -= band(P.Random(), 3)
  if th.tics < 1 then th.tics = 1 end

  th.x += th.momx // 2
  th.y += th.momy // 2
  th.z += th.momz // 2
  if not P.TryMove(th, th.x, th.y) then explodeMissile(th) end
end

P.CheckMissileSpawn = checkMissileSpawn

function P.SpawnMissile(source: any, dest: any, type: number): any
  local th = P.SpawnMobj(source.x, source.y, source.z + 32 * FRACUNIT, type)
  th.target = source
  local an = P.PointToAngle2(source.x, source.y, dest.x, dest.y)
  if band(dest.flags, P.MF_SHADOW) ~= 0 then an = (an + P.SubRandom() * 1048576) % U32 end

  th.angle = an
  local fine = an // 524288
  th.momx = FixedMul(th.info.speed, finesine[fine + 2049])
  th.momy = FixedMul(th.info.speed, finesine[fine + 1])

  local dist = idiv(P.AproxDistance(dest.x - source.x, dest.y - source.y), th.info.speed)
  if dist < 1 then dist = 1 end
  th.momz = idiv(dest.z - source.z, dist)
  checkMissileSpawn(th)
  return th
end

function P.SpawnPlayerMissile(source: any, type: number): ()
  local an = source.angle
  local slope = P.AimLineAttack(source, an, 16 * 64 * FRACUNIT)
  if not P.linetarget then
    an = (an + 67108864) % U32
    slope = P.AimLineAttack(source, an, 16 * 64 * FRACUNIT)
    if not P.linetarget then
      an = (an - 134217728) % U32
      slope = P.AimLineAttack(source, an, 16 * 64 * FRACUNIT)
    end

    if not P.linetarget then
      an = source.angle
      slope = 0
    end
  end

  local th = P.SpawnMobj(source.x, source.y, source.z + 32 * FRACUNIT, type)
  th.target = source
  th.angle = an
  th.momx = FixedMul(th.info.speed, finesine[an // 524288 + 2049])
  th.momy = FixedMul(th.info.speed, finesine[an // 524288 + 1])
  th.momz = FixedMul(th.info.speed, slope)
  checkMissileSpawn(th)
end

-- p_inter.c
local function giveAmmo(player: any, ammo: number, num: number): boolean
  if ammo == P.am_noammo then return false end
  if player.ammo[ammo] == player.maxammo[ammo] then return false end

  if num ~= 0 then
    num *= P.clipammo[ammo]
  else
    num = P.clipammo[ammo] // 2
  end

  if G.gameskill == 0 or G.gameskill == 4 then num *= 2 end

  local oldammo = player.ammo[ammo]
  player.ammo[ammo] = math.min(oldammo + num, player.maxammo[ammo])
  if oldammo ~= 0 then return true end

  local ready, owned = player.readyweapon, player.weaponowned
  if ammo == P.am_clip then
    if ready == P.wp_fist then player.pendingweapon = if owned[P.wp_chaingun] then P.wp_chaingun else P.wp_pistol end
  elseif ammo == P.am_shell then
    if (ready == P.wp_fist or ready == P.wp_pistol) and owned[P.wp_shotgun] then player.pendingweapon = P.wp_shotgun end
  elseif ammo == P.am_cell then
    if (ready == P.wp_fist or ready == P.wp_pistol) and owned[P.wp_plasma] then player.pendingweapon = P.wp_plasma end
  elseif ammo == P.am_misl then
    if ready == P.wp_fist and owned[P.wp_missile] then player.pendingweapon = P.wp_missile end
  end

  return true
end

P.GiveAmmo = giveAmmo

local function giveWeapon(player: any, weapon: number, dropped: boolean): boolean
  local ammo = P.weaponinfo[weapon].ammo
  if G.netgame and G.deathmatch ~= 2 and not dropped then
    if player.weaponowned[weapon] then return false end

    player.bonuscount += 6
    player.weaponowned[weapon] = true
    giveAmmo(player, ammo, if G.deathmatch ~= 0 then 5 else 2)
    player.pendingweapon = weapon
    return false
  end

  local gaveammo = false
  if ammo ~= P.am_noammo then gaveammo = giveAmmo(player, ammo, if dropped then 1 else 2) end

  local gaveweapon = false
  if not player.weaponowned[weapon] then
    gaveweapon = true
    player.weaponowned[weapon] = true
    player.pendingweapon = weapon
  end

  return gaveweapon or gaveammo
end

local function giveBody(player: any, num: number): boolean
  if player.health >= 100 then return false end

  player.health = math.min(player.health + num, 100)
  player.mo.health = player.health
  return true
end

local function giveArmor(player: any, armortype: number): boolean
  local hits = armortype * 100
  if player.armorpoints >= hits then return false end

  player.armortype, player.armorpoints = armortype, hits
  return true
end

local function givePower(player: any, power: number): boolean
  local powers = player.powers
  if power == P.pw_invulnerability then
    powers[power] = P.INVULNTICS
  elseif power == P.pw_invisibility then
    powers[power] = P.INVISTICS
    player.mo.flags = bor(player.mo.flags, P.MF_SHADOW)
  elseif power == P.pw_infrared then
    powers[power] = P.INFRATICS
  elseif power == P.pw_ironfeet then
    powers[power] = P.IRONTICS
  elseif power == P.pw_strength then
    giveBody(player, 100)
    powers[power] = 1
  else
    if powers[power] ~= 0 then return false end
    powers[power] = 1
  end

  return true
end

P.GivePower, P.GiveBody, P.GiveArmor, P.GiveWeapon = givePower, giveBody, giveArmor, giveWeapon

local Cards = { BKEY = 0, YKEY = 1, RKEY = 2, BSKU = 3, YSKU = 4, RSKU = 5 }
local Powers = { PINV = 0, PSTR = 1, PINS = 2, SUIT = 3, PMAP = 4, PVIS = 5 }
local Ammo = {
  AMMO = { 0, 5 },
  ROCK = { 3, 1 },
  BROK = { 3, 5 },
  CELL = { 2, 1 },
  CELP = { 2, 5 },
  SHEL = { 1, 1 },
  SBOX = { 1, 5 },
}
local Weapons = { BFUG = 6, MGUN = 3, CSAW = 7, LAUN = 4, PLAS = 5, SHOT = 2, SGN2 = 8 }
local DropAware = { MGUN = true, SHOT = true, SGN2 = true }

function P.TouchSpecialThing(special: any, toucher: any): ()
  local delta = special.z - toucher.z
  if delta > toucher.height or delta < -8 * FRACUNIT then return end

  local player = toucher.player
  if toucher.health <= 0 then return end

  local sprite = special.sprite
  local dropped = band(special.flags, P.MF_DROPPED) ~= 0
  if sprite == 'ARM1' then
    if not giveArmor(player, 1) then return end
  elseif sprite == 'ARM2' then
    if not giveArmor(player, 2) then return end
  elseif sprite == 'BON1' then
    player.health = math.min(player.health + 1, 200)
    player.mo.health = player.health
  elseif sprite == 'BON2' then
    player.armorpoints = math.min(player.armorpoints + 1, 200)
    if player.armortype == 0 then player.armortype = 1 end
  elseif sprite == 'SOUL' then
    player.health = math.min(player.health + 100, 200)
    player.mo.health = player.health
  elseif sprite == 'MEGA' then
    if not G.commercial then return end

    player.health = 200
    player.mo.health = 200
    giveArmor(player, 2)
  elseif Cards[sprite] then
    local card = Cards[sprite]
    if not player.cards[card] then
      player.bonuscount = 6
      player.cards[card] = true
    end

    if G.netgame then return end
  elseif sprite == 'STIM' then
    if not giveBody(player, 10) then return end
  elseif sprite == 'MEDI' then
    if not giveBody(player, 25) then return end
  elseif Powers[sprite] then
    if not givePower(player, Powers[sprite]) then return end
    if sprite == 'PSTR' and player.readyweapon ~= P.wp_fist then player.pendingweapon = P.wp_fist end
  elseif sprite == 'CLIP' then
    if not giveAmmo(player, 0, if dropped then 0 else 1) then return end
  elseif Ammo[sprite] then
    if not giveAmmo(player, Ammo[sprite][1], Ammo[sprite][2]) then return end
  elseif sprite == 'BPAK' then
    if not player.backpack then
      for ammo = 0, 3 do
        player.maxammo[ammo] *= 2
      end

      player.backpack = true
    end

    for ammo = 0, 3 do
      giveAmmo(player, ammo, 1)
    end
  elseif Weapons[sprite] then
    if not giveWeapon(player, Weapons[sprite], DropAware[sprite] == true and dropped) then return end
  else
    error(`P_SpecialThing: unknown gettable thing {sprite}`)
  end

  if band(special.flags, P.MF_COUNTITEM) ~= 0 then player.itemcount += 1 end
  P.RemoveMobj(special)
  player.bonuscount += 6
end

local DeathDrops = {
  [MT.MT_WOLFSS] = MT.MT_CLIP,
  [MT.MT_POSSESSED] = MT.MT_CLIP,
  [MT.MT_SHOTGUY] = MT.MT_SHOTGUN,
  [MT.MT_CHAINGUY] = MT.MT_CHAINGUN,
}

local function killMobj(source: any, target: any): ()
  target.flags = band(target.flags, bnot(MF_SHOOTABLE + P.MF_FLOAT + MF_SKULLFLY))
  if target.type ~= MT.MT_SKULL then target.flags = band(target.flags, bnot(P.MF_NOGRAVITY)) end
  target.flags = bor(target.flags, MF_CORPSE + P.MF_DROPOFF)
  target.height //= 4

  if source and source.player then
    if band(target.flags, P.MF_COUNTKILL) ~= 0 then source.player.killcount += 1 end
    if target.player then source.player.frags[target.player.index] += 1 end
  elseif not G.netgame and band(target.flags, P.MF_COUNTKILL) ~= 0 then
    G.players[0].killcount += 1
  end

  local player = target.player
  if player then
    if not source then player.frags[player.index] += 1 end
    target.flags = band(target.flags, bnot(P.MF_SOLID))
    player.playerstate = P.PST_DEAD
    P.DropWeapon(player)
  end

  if target.health < -target.info.spawnhealth and target.info.xdeathstate ~= 0 then
    setMobjState(target, target.info.xdeathstate)
  else
    setMobjState(target, target.info.deathstate)
  end

  target.tics -= band(P.Random(), 3)
  if target.tics < 1 then target.tics = 1 end

  local item = DeathDrops[target.type]
  if not item then return end

  local mo = P.SpawnMobj(target.x, target.y, ONFLOORZ, item)
  mo.flags = bor(mo.flags, P.MF_DROPPED)
end

function P.DamageMobj(target: any, inflictor: any, source: any, damage: number): ()
  if band(target.flags, MF_SHOOTABLE) == 0 then return end
  if target.health <= 0 then return end

  if band(target.flags, MF_SKULLFLY) ~= 0 then
    target.momx, target.momy, target.momz = 0, 0, 0
  end

  local player = target.player
  if player and G.gameskill == 0 then damage //= 2 end

  if
    inflictor
    and band(target.flags, P.MF_NOCLIP) == 0
    and (not source or not source.player or source.player.readyweapon ~= P.wp_chainsaw)
  then
    local ang = P.PointToAngle2(inflictor.x, inflictor.y, target.x, target.y)
    local thrust = idiv(i32(damage * 819200), target.info.mass)
    if damage < 40 and damage > target.health and target.z - inflictor.z > 64 * FRACUNIT and band(P.Random(), 1) ~= 0 then
      ang = (ang + 0x80000000) % U32
      thrust *= 4
    end

    local fine = ang // 524288
    target.momx += FixedMul(thrust, finesine[fine + 2049])
    target.momy += FixedMul(thrust, finesine[fine + 1])
  end

  if player then
    if target.subsector.sector.special == 11 and damage >= target.health then damage = target.health - 1 end

    if damage < 1000 and (band(player.cheats, P.CF_GODMODE) ~= 0 or player.powers[P.pw_invulnerability] ~= 0) then
      return
    end

    if player.armortype ~= 0 then
      local saved = if player.armortype == 1 then idiv(damage, 3) else idiv(damage, 2)
      if player.armorpoints <= saved then
        saved = player.armorpoints
        player.armortype = 0
      end

      player.armorpoints -= saved
      damage -= saved
    end

    player.health = math.max(player.health - damage, 0)
    player.attacker = source
    player.damagecount = math.min(player.damagecount + damage, 100)
  end

  target.health -= damage
  if target.health <= 0 then
    killMobj(source, target)
    return
  end

  if P.Random() < target.info.painchance and band(target.flags, MF_SKULLFLY) == 0 then
    target.flags = bor(target.flags, P.MF_JUSTHIT)
    setMobjState(target, target.info.painstate)
  end

  target.reactiontime = 0
  if
    (target.threshold == 0 or target.type == MT.MT_VILE)
    and source
    and source ~= target
    and source.type ~= MT.MT_VILE
  then
    target.target = source
    target.threshold = 100
    if target.state == target.info.spawnstate and target.info.seestate ~= 0 then
      setMobjState(target, target.info.seestate)
    end
  end
end

-- p_user.c
local onground = false

local function thrust(player: any, angle: number, move: number): ()
  local fine = angle // 524288
  player.mo.momx += FixedMul(move, finesine[fine + 2049])
  player.mo.momy += FixedMul(move, finesine[fine + 1])
end

local function calcHeight(player: any): ()
  local mo = player.mo
  player.bob = math.min((FixedMul(mo.momx, mo.momx) + FixedMul(mo.momy, mo.momy)) // 4, 0x100000)

  if band(player.cheats, P.CF_NOMOMENTUM) ~= 0 or not onground then
    player.viewz = mo.z + player.viewheight
    return
  end

  local angle = (409 * G.leveltime) % 8192
  local bob = FixedMul(idiv(player.bob, 2), finesine[angle + 1])

  if player.playerstate == P.PST_LIVE then
    player.viewheight += player.deltaviewheight
    if player.viewheight > VIEWHEIGHT then
      player.viewheight = VIEWHEIGHT
      player.deltaviewheight = 0
    end

    if player.viewheight < VIEWHEIGHT / 2 then
      player.viewheight = VIEWHEIGHT / 2
      if player.deltaviewheight <= 0 then player.deltaviewheight = 1 end
    end

    if player.deltaviewheight ~= 0 then
      player.deltaviewheight += FRACUNIT / 4
      if player.deltaviewheight == 0 then player.deltaviewheight = 1 end
    end
  end

  player.viewz = math.min(mo.z + player.viewheight + bob, mo.ceilingz - 4 * FRACUNIT)
end

local function movePlayer(player: any): ()
  local cmd, mo = player.cmd, player.mo
  mo.angle = (mo.angle + cmd.angleturn * 65536) % U32
  onground = mo.z <= mo.floorz

  if cmd.forwardmove ~= 0 and onground then thrust(player, mo.angle, cmd.forwardmove * 2048) end
  if cmd.sidemove ~= 0 and onground then thrust(player, (mo.angle - 0x40000000) % U32, cmd.sidemove * 2048) end
  if (cmd.forwardmove ~= 0 or cmd.sidemove ~= 0) and mo.state == S.S_PLAY then setMobjState(mo, S.S_PLAY_RUN1) end
end

local ANG5 = 0x40000000 // 18

local function deathThink(player: any): ()
  P.MovePsprites(player)

  if player.viewheight > 6 * FRACUNIT then player.viewheight -= FRACUNIT end
  if player.viewheight < 6 * FRACUNIT then player.viewheight = 6 * FRACUNIT end

  player.deltaviewheight = 0
  local mo = player.mo
  onground = mo.z <= mo.floorz
  calcHeight(player)

  local attacker = player.attacker
  if attacker and attacker ~= mo then
    local angle = P.PointToAngle2(mo.x, mo.y, attacker.x, attacker.y)
    local delta = (angle - mo.angle) % U32
    if delta < ANG5 or delta > U32 - ANG5 then
      mo.angle = angle
      if player.damagecount ~= 0 then player.damagecount -= 1 end
    elseif delta < 0x80000000 then
      mo.angle = (mo.angle + ANG5) % U32
    else
      mo.angle = (mo.angle - ANG5) % U32
    end
  elseif player.damagecount ~= 0 then
    player.damagecount -= 1
  end

  if band(player.cmd.buttons, P.BT_USE) ~= 0 then player.playerstate = P.PST_REBORN end
end

function P.PlayerThink(player: any): ()
  local mo, cmd = player.mo, player.cmd
  if band(player.cheats, P.CF_NOCLIP) ~= 0 then
    mo.flags = bor(mo.flags, P.MF_NOCLIP)
  else
    mo.flags = band(mo.flags, bnot(P.MF_NOCLIP))
  end

  if band(mo.flags, P.MF_JUSTATTACKED) ~= 0 then
    cmd.angleturn, cmd.forwardmove, cmd.sidemove = 0, 100, 0
    mo.flags = band(mo.flags, bnot(P.MF_JUSTATTACKED))
  end

  if player.playerstate == P.PST_DEAD then
    deathThink(player)
    return
  end

  if mo.reactiontime ~= 0 then
    mo.reactiontime -= 1
  else
    movePlayer(player)
  end

  calcHeight(player)
  if mo.subsector.sector.special ~= 0 then P.PlayerInSpecialSector(player) end

  if band(cmd.buttons, P.BT_SPECIAL) ~= 0 then cmd.buttons = 0 end

  if band(cmd.buttons, P.BT_CHANGE) ~= 0 then
    local newweapon = band(cmd.buttons, P.BT_WEAPONMASK) // 8
    if
      newweapon == P.wp_fist
      and player.weaponowned[P.wp_chainsaw]
      and not (player.readyweapon == P.wp_chainsaw and player.powers[P.pw_strength] ~= 0)
    then
      newweapon = P.wp_chainsaw
    end

    if
      G.commercial
      and newweapon == P.wp_shotgun
      and player.weaponowned[P.wp_supershotgun]
      and player.readyweapon ~= P.wp_supershotgun
    then
      newweapon = P.wp_supershotgun
    end

    if player.weaponowned[newweapon] and newweapon ~= player.readyweapon then
      if (newweapon ~= P.wp_plasma and newweapon ~= P.wp_bfg) or not G.shareware then player.pendingweapon = newweapon end
    end
  end

  if band(cmd.buttons, P.BT_USE) ~= 0 then
    if not player.usedown then
      P.UseLines(player)
      player.usedown = true
    end
  else
    player.usedown = false
  end

  P.MovePsprites(player)

  local powers = player.powers
  if powers[1] ~= 0 then powers[1] += 1 end
  if powers[0] ~= 0 then powers[0] -= 1 end
  if powers[2] ~= 0 then
    powers[2] -= 1
    if powers[2] == 0 then player.mo.flags = band(player.mo.flags, bnot(P.MF_SHADOW)) end
  end

  if powers[5] ~= 0 then powers[5] -= 1 end
  if powers[3] ~= 0 then powers[3] -= 1 end
  if player.damagecount ~= 0 then player.damagecount -= 1 end
  if player.bonuscount ~= 0 then player.bonuscount -= 1 end
end

-- p_pspr.c
local WEAPONBOTTOM, WEAPONTOP = 128 * FRACUNIT, 32 * FRACUNIT
local weaponinfo = P.weaponinfo

local function setPsprite(player: any, position: number, stnum: number): ()
  local psp = player.psprites[position]
  repeat
    if stnum == 0 then
      psp.state = nil
      break
    end

    local state = states[stnum]
    psp.state, psp.tics = stnum, state.tics
    if state.misc1 ~= 0 then
      psp.sx, psp.sy = state.misc1 * FRACUNIT, state.misc2 * FRACUNIT
    end

    if state.action then
      actions[state.action](player, psp)
      if not psp.state then break end
    end

    stnum = states[psp.state].nextstate
  until psp.tics ~= 0
end

local function bringUpWeapon(player: any): ()
  if player.pendingweapon == P.wp_nochange then player.pendingweapon = player.readyweapon end

  local newstate = weaponinfo[player.pendingweapon].upstate
  player.pendingweapon = P.wp_nochange
  player.psprites[0].sy = WEAPONBOTTOM
  setPsprite(player, 0, newstate)
end

local function checkAmmo(player: any): boolean
  local ready = player.readyweapon
  local ammo = weaponinfo[ready].ammo
  local count = if ready == P.wp_bfg then 40 elseif ready == P.wp_supershotgun then 2 else 1
  if ammo == P.am_noammo or player.ammo[ammo] >= count then return true end

  local owned, held = player.weaponowned, player.ammo
  if owned[P.wp_plasma] and held[2] ~= 0 and not G.shareware then
    player.pendingweapon = P.wp_plasma
  elseif owned[P.wp_supershotgun] and held[1] > 2 and G.commercial then
    player.pendingweapon = P.wp_supershotgun
  elseif owned[P.wp_chaingun] and held[0] ~= 0 then
    player.pendingweapon = P.wp_chaingun
  elseif owned[P.wp_shotgun] and held[1] ~= 0 then
    player.pendingweapon = P.wp_shotgun
  elseif held[0] ~= 0 then
    player.pendingweapon = P.wp_pistol
  elseif owned[P.wp_chainsaw] then
    player.pendingweapon = P.wp_chainsaw
  elseif owned[P.wp_missile] and held[3] ~= 0 then
    player.pendingweapon = P.wp_missile
  elseif owned[P.wp_bfg] and held[2] > 40 and not G.shareware then
    player.pendingweapon = P.wp_bfg
  else
    player.pendingweapon = P.wp_fist
  end

  setPsprite(player, 0, weaponinfo[ready].downstate)
  return false
end

local function fireWeapon(player: any): ()
  if not checkAmmo(player) then return end

  setMobjState(player.mo, S.S_PLAY_ATK1)
  setPsprite(player, 0, weaponinfo[player.readyweapon].atkstate)
  P.NoiseAlert(player.mo, player.mo)
end

function P.DropWeapon(player: any): ()
  setPsprite(player, 0, weaponinfo[player.readyweapon].downstate)
end

function actions.A_WeaponReady(player: any, psp: any): ()
  local mo = player.mo
  if mo.state == S.S_PLAY_ATK1 or mo.state == S.S_PLAY_ATK2 then setMobjState(mo, S.S_PLAY) end

  if player.pendingweapon ~= P.wp_nochange or player.health == 0 then
    setPsprite(player, 0, weaponinfo[player.readyweapon].downstate)
    return
  end

  if band(player.cmd.buttons, P.BT_ATTACK) ~= 0 then
    if not player.attackdown or (player.readyweapon ~= P.wp_missile and player.readyweapon ~= P.wp_bfg) then
      player.attackdown = true
      fireWeapon(player)
      return
    end
  else
    player.attackdown = false
  end

  local angle = (128 * G.leveltime) % 8192
  psp.sx = FRACUNIT + FixedMul(player.bob, finesine[angle + 2049])
  psp.sy = WEAPONTOP + FixedMul(player.bob, finesine[angle % 4096 + 1])
end

function actions.A_ReFire(player: any, _psp: any): ()
  if band(player.cmd.buttons, P.BT_ATTACK) ~= 0 and player.pendingweapon == P.wp_nochange and player.health ~= 0 then
    player.refire += 1
    fireWeapon(player)
  else
    player.refire = 0
    checkAmmo(player)
  end
end

function actions.A_CheckReload(player: any, _psp: any): ()
  checkAmmo(player)
end

function actions.A_Lower(player: any, psp: any): ()
  psp.sy += FRACUNIT * 6
  if psp.sy < WEAPONBOTTOM then return end

  if player.playerstate == P.PST_DEAD then
    psp.sy = WEAPONBOTTOM
    return
  end

  if player.health == 0 then
    setPsprite(player, 0, 0)
    return
  end

  player.readyweapon = player.pendingweapon
  bringUpWeapon(player)
end

function actions.A_Raise(player: any, psp: any): ()
  psp.sy -= FRACUNIT * 6
  if psp.sy > WEAPONTOP then return end

  psp.sy = WEAPONTOP
  setPsprite(player, 0, weaponinfo[player.readyweapon].readystate)
end

function actions.A_GunFlash(player: any, _psp: any): ()
  setMobjState(player.mo, S.S_PLAY_ATK2)
  setPsprite(player, 1, weaponinfo[player.readyweapon].flashstate)
end

function actions.A_Punch(player: any, _psp: any): ()
  local damage = (P.Random() % 10 + 1) * 2
  if player.powers[P.pw_strength] ~= 0 then damage *= 10 end

  local mo = player.mo
  local angle = (mo.angle + P.SubRandom() * 262144) % U32
  local slope = P.AimLineAttack(mo, angle, P.MELEERANGE)
  P.LineAttack(mo, angle, P.MELEERANGE, slope, damage)

  local target = P.linetarget
  if target then mo.angle = P.PointToAngle2(mo.x, mo.y, target.x, target.y) end
end

local SawTurn, SawSnap = 0x40000000 // 20, 0x40000000 // 21

function actions.A_Saw(player: any, _psp: any): ()
  local damage = 2 * (P.Random() % 10 + 1)
  local mo = player.mo
  local angle = (mo.angle + P.SubRandom() * 262144) % U32
  local slope = P.AimLineAttack(mo, angle, P.MELEERANGE + 1)
  P.LineAttack(mo, angle, P.MELEERANGE + 1, slope, damage)

  local target = P.linetarget
  if not target then return end

  angle = P.PointToAngle2(mo.x, mo.y, target.x, target.y)
  local delta = (angle - mo.angle) % U32
  if delta > 0x80000000 then
    if delta < U32 - SawTurn then
      mo.angle = (angle + SawSnap) % U32
    else
      mo.angle = (mo.angle - SawTurn) % U32
    end
  elseif delta > SawTurn then
    mo.angle = (angle - SawSnap) % U32
  else
    mo.angle = (mo.angle + SawTurn) % U32
  end

  mo.flags = bor(mo.flags, P.MF_JUSTATTACKED)
end

local function useAmmo(player: any, count: number): ()
  local ammo = weaponinfo[player.readyweapon].ammo
  player.ammo[ammo] -= count
end

function actions.A_FireMissile(player: any, _psp: any): ()
  useAmmo(player, 1)
  P.SpawnPlayerMissile(player.mo, MT.MT_ROCKET)
end

function actions.A_FireBFG(player: any, _psp: any): ()
  useAmmo(player, 40)
  P.SpawnPlayerMissile(player.mo, MT.MT_BFG)
end

function actions.A_FirePlasma(player: any, _psp: any): ()
  useAmmo(player, 1)
  setPsprite(player, 1, weaponinfo[player.readyweapon].flashstate + band(P.Random(), 1))
  P.SpawnPlayerMissile(player.mo, MT.MT_PLASMA)
end

local bulletslope = 0

local function bulletSlope(mo: any): ()
  local an = mo.angle
  bulletslope = P.AimLineAttack(mo, an, 16 * 64 * FRACUNIT)
  if P.linetarget then return end

  an = (an + 67108864) % U32
  bulletslope = P.AimLineAttack(mo, an, 16 * 64 * FRACUNIT)
  if P.linetarget then return end

  an = (an - 134217728) % U32
  bulletslope = P.AimLineAttack(mo, an, 16 * 64 * FRACUNIT)
end

local function gunShot(mo: any, accurate: boolean): ()
  local damage = 5 * (P.Random() % 3 + 1)
  local angle = mo.angle
  if not accurate then angle = (angle + P.SubRandom() * 262144) % U32 end
  P.LineAttack(mo, angle, P.MISSILERANGE, bulletslope, damage)
end

function actions.A_FirePistol(player: any, _psp: any): ()
  setMobjState(player.mo, S.S_PLAY_ATK2)
  useAmmo(player, 1)
  setPsprite(player, 1, weaponinfo[player.readyweapon].flashstate)
  bulletSlope(player.mo)
  gunShot(player.mo, player.refire == 0)
end

function actions.A_FireShotgun(player: any, _psp: any): ()
  setMobjState(player.mo, S.S_PLAY_ATK2)
  useAmmo(player, 1)
  setPsprite(player, 1, weaponinfo[player.readyweapon].flashstate)
  bulletSlope(player.mo)
  for _ = 1, 7 do
    gunShot(player.mo, false)
  end
end

function actions.A_FireShotgun2(player: any, _psp: any): ()
  local mo = player.mo
  setMobjState(mo, S.S_PLAY_ATK2)
  useAmmo(player, 2)
  setPsprite(player, 1, weaponinfo[player.readyweapon].flashstate)
  bulletSlope(mo)
  for _ = 1, 20 do
    local damage = 5 * (P.Random() % 3 + 1)
    local angle = (mo.angle + P.SubRandom() * 524288) % U32
    P.LineAttack(mo, angle, P.MISSILERANGE, bulletslope + P.SubRandom() * 32, damage)
  end
end

function actions.A_FireCGun(player: any, psp: any): ()
  if player.ammo[weaponinfo[player.readyweapon].ammo] == 0 then return end

  setMobjState(player.mo, S.S_PLAY_ATK2)
  useAmmo(player, 1)
  setPsprite(player, 1, weaponinfo[player.readyweapon].flashstate + psp.state - S.S_CHAIN1)
  bulletSlope(player.mo)
  gunShot(player.mo, player.refire == 0)
end

function actions.A_Light0(player: any, _psp: any): ()
  player.extralight = 0
end

function actions.A_Light1(player: any, _psp: any): ()
  player.extralight = 1
end

function actions.A_Light2(player: any, _psp: any): ()
  player.extralight = 2
end

function actions.A_BFGSpray(mo: any): ()
  for index = 0, 39 do
    local an = (mo.angle - 0x20000000 + 26843545 * index) % U32
    P.AimLineAttack(mo.target, an, 16 * 64 * FRACUNIT)

    local target = P.linetarget
    if not target then continue end

    P.SpawnMobj(target.x, target.y, target.z + target.height // 4, MT.MT_EXTRABFG)
    local damage = 0
    for _ = 1, 15 do
      damage += band(P.Random(), 7) + 1
    end

    P.DamageMobj(target, mo.target, mo.target, damage)
  end
end

function actions.A_BFGsound(_player: any, _psp: any): () end

-- The reload frames only play sounds.
actions.A_OpenShotgun2, actions.A_LoadShotgun2, actions.A_CloseShotgun2 = actions.A_BFGsound, actions.A_BFGsound, nil

function actions.A_CloseShotgun2(player: any, psp: any): ()
  actions.A_ReFire(player, psp)
end

function P.SetupPsprites(player: any): ()
  player.psprites = { [0] = { tics = 0, sx = 0, sy = 0 }, { tics = 0, sx = 0, sy = 0 } }
  player.pendingweapon = player.readyweapon
  bringUpWeapon(player)
end

function P.MovePsprites(player: any): ()
  local psprites = player.psprites
  for index = 0, 1 do
    local psp = psprites[index]
    if psp.state and psp.tics ~= -1 then
      psp.tics -= 1
      if psp.tics == 0 then setPsprite(player, index, states[psp.state].nextstate) end
    end
  end

  psprites[1].sx, psprites[1].sy = psprites[0].sx, psprites[0].sy
end

return P
