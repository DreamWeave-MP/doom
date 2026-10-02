--!nonstrict
--!native
-- p_spec.c, p_doors.c, p_floor.c, p_ceilng.c, p_plats.c, p_lights.c,
-- p_switch.c, and p_telept.c: sector movers, lights, and every line special.
local P: any = require('./core')

local G = P.G
local MT = P.MT
local think = P.think
local FRACUNIT = 65536
local band = bit32.band
local FLOORSPEED, CEILSPEED, PLATSPEED, VDOORSPEED = FRACUNIT, FRACUNIT, FRACUNIT, FRACUNIT * 2
local VDOORWAIT, PLATWAIT = 150, 3
local MAXACTIVE, MAXBUTTONS = 30, 16
local OK, CRUSHED, PASTDEST = 0, 1, 2
local UP, DOWN, WAITING, IN_STASIS = 0, 1, 2, 3

local function getNextSector(line: any, sector: any): any
  if band(line.flags, 4) == 0 then return nil end
  if line.frontsector == sector then return line.backsector end
  return line.frontsector
end

local function findLowestFloorSurrounding(sector: any): number
  local floor = sector.floorheight
  for _, check in sector.lines do
    local other = getNextSector(check, sector)
    if other and other.floorheight < floor then floor = other.floorheight end
  end

  return floor
end

local function findHighestFloorSurrounding(sector: any): number
  local floor = -500 * FRACUNIT
  for _, check in sector.lines do
    local other = getNextSector(check, sector)
    if other and other.floorheight > floor then floor = other.floorheight end
  end

  return floor
end

local function findNextHighestFloor(sector: any, currentheight: number): number
  local min: number? = nil
  for _, check in sector.lines do
    local other = getNextSector(check, sector)
    if other and other.floorheight > currentheight and (not min or other.floorheight < min) then min = other.floorheight end
  end

  return min or currentheight
end

local function findLowestCeilingSurrounding(sector: any): number
  local height = 2147483647
  for _, check in sector.lines do
    local other = getNextSector(check, sector)
    if other and other.ceilingheight < height then height = other.ceilingheight end
  end

  return height
end

local function findHighestCeilingSurrounding(sector: any): number
  local height = 0
  for _, check in sector.lines do
    local other = getNextSector(check, sector)
    if other and other.ceilingheight > height then height = other.ceilingheight end
  end

  return height
end

-- Returns the next sector index after `start` carrying the line's tag, or -1.
local function findSectorFromLineTag(line: any, start: number): number
  local sectors = G.sectors
  for index = start + 1, #sectors - 1 do
    if sectors[index + 1].tag == line.tag then return index end
  end

  return -1
end

local function findMinSurroundingLight(sector: any, max: number): number
  local min = max
  for _, line in sector.lines do
    local check = getNextSector(line, sector)
    if check and check.lightlevel < min then min = check.lightlevel end
  end

  return min
end

local function movePlane(sector: any, speed: number, dest: number, crush: boolean, ceiling: boolean, direction: number): number
  local key = if ceiling then 'ceilingheight' else 'floorheight'
  local lastpos = sector[key]
  local past
  if direction == -1 then
    past = lastpos - speed < dest
  else
    past = lastpos + speed > dest
  end

  if past then
    sector[key] = dest
    if P.ChangeSector(sector, crush) then
      sector[key] = lastpos
      P.ChangeSector(sector, crush)
    end

    return PASTDEST
  end

  sector[key] = lastpos + speed * direction
  local blocked = P.ChangeSector(sector, crush)
  if ceiling and direction == 1 then return OK end
  if not blocked then return OK end

  -- A floor going down always backs off; the other two stay put when crushing.
  if (ceiling or direction == 1) and crush then return CRUSHED end

  sector[key] = lastpos
  P.ChangeSector(sector, crush)
  return CRUSHED
end

-- Floors.
function think.floor(floor: any): ()
  local res = movePlane(floor.sector, floor.speed, floor.floordestheight, floor.crush, false, floor.direction)
  if res ~= PASTDEST then return end

  local sector = floor.sector
  sector.specialdata = nil
  if (floor.direction == 1 and floor.type == 'donutRaise') or (floor.direction == -1 and floor.type == 'lowerAndChange') then
    sector.special = floor.newspecial
    sector.floorpic = floor.texture
  end

  P.RemoveThinker(floor)
end

local function newFloor(sector: any, type: string, direction: number, speed: number): any
  local floor = {
    think = 'floor',
    type = type,
    crush = false,
    sector = sector,
    direction = direction,
    speed = speed,
    newspecial = 0,
    texture = sector.floorpic,
    floordestheight = 0,
  }
  P.AddThinker(floor)
  sector.specialdata = floor
  return floor
end

function P.DoFloor(line: any, floortype: string): boolean
  local secnum, rtn = -1, false
  while true do
    secnum = findSectorFromLineTag(line, secnum)
    if secnum < 0 then break end

    local sec = G.sectors[secnum + 1]
    if sec.specialdata then continue end

    rtn = true
    local floor = newFloor(sec, floortype, 1, FLOORSPEED)
    if floortype == 'lowerFloor' then
      floor.direction = -1
      floor.floordestheight = findHighestFloorSurrounding(sec)
    elseif floortype == 'lowerFloorToLowest' then
      floor.direction = -1
      floor.floordestheight = findLowestFloorSurrounding(sec)
    elseif floortype == 'turboLower' then
      floor.direction = -1
      floor.speed = FLOORSPEED * 4
      floor.floordestheight = findHighestFloorSurrounding(sec)
      if floor.floordestheight ~= sec.floorheight then floor.floordestheight += 8 * FRACUNIT end
    elseif floortype == 'raiseFloorCrush' or floortype == 'raiseFloor' then
      floor.crush = floortype == 'raiseFloorCrush'
      floor.floordestheight = math.min(findLowestCeilingSurrounding(sec), sec.ceilingheight)
      if floor.crush then floor.floordestheight -= 8 * FRACUNIT end
    elseif floortype == 'raiseFloorTurbo' then
      floor.speed = FLOORSPEED * 4
      floor.floordestheight = findNextHighestFloor(sec, sec.floorheight)
    elseif floortype == 'raiseFloorToNearest' then
      floor.floordestheight = findNextHighestFloor(sec, sec.floorheight)
    elseif floortype == 'raiseFloor24' then
      floor.floordestheight = sec.floorheight + 24 * FRACUNIT
    elseif floortype == 'raiseFloor512' then
      floor.floordestheight = sec.floorheight + 512 * FRACUNIT
    elseif floortype == 'raiseFloor24AndChange' then
      floor.floordestheight = sec.floorheight + 24 * FRACUNIT
      sec.floorpic = line.frontsector.floorpic
      sec.special = line.frontsector.special
    elseif floortype == 'raiseToTexture' then
      -- Texture 0 counts, as the original's `>= 0` test lets it.
      local minsize = 2147483647
      local heights = G.textures.heights
      for _, check in sec.lines do
        if band(check.flags, 4) == 0 then continue end

        for side = 1, 2 do
          local height = heights[G.sides[check.sidenum[side] + 1].bottomtexture]
          if height and height < minsize then minsize = height end
        end
      end

      floor.floordestheight = P.i32(sec.floorheight + minsize)
    elseif floortype == 'lowerAndChange' then
      floor.direction = -1
      floor.floordestheight = findLowestFloorSurrounding(sec)
      floor.texture = sec.floorpic
      for _, check in sec.lines do
        if band(check.flags, 4) == 0 then continue end

        local other = if check.frontsector == sec then check.backsector else check.frontsector
        if other.floorheight == floor.floordestheight then
          floor.texture = other.floorpic
          floor.newspecial = other.special
          break
        end
      end
    end
  end

  return rtn
end

function P.BuildStairs(line: any, type: string): boolean
  local secnum, rtn = -1, false
  local speed = if type == 'build8' then FLOORSPEED / 4 else FLOORSPEED * 4
  local stairsize = if type == 'build8' then 8 * FRACUNIT else 16 * FRACUNIT
  while true do
    secnum = findSectorFromLineTag(line, secnum)
    if secnum < 0 then break end

    local sec = G.sectors[secnum + 1]
    if sec.specialdata then continue end

    rtn = true
    local floor = newFloor(sec, 'lowerFloor', 1, speed)
    local height = sec.floorheight + stairsize
    floor.floordestheight = height

    local texture = sec.floorpic
    local ok
    repeat
      ok = false
      for _, check in sec.lines do
        if band(check.flags, 4) == 0 then continue end
        if check.frontsector ~= sec then continue end

        local tsec = check.backsector
        if tsec.floorpic ~= texture then continue end

        height += stairsize
        if tsec.specialdata then continue end

        sec = tsec
        secnum = tsec.index
        floor = newFloor(sec, 'lowerFloor', 1, speed)
        floor.floordestheight = height
        ok = true
        break
      end
    until not ok
  end

  return rtn
end

local function doDonut(line: any): boolean
  local secnum, rtn = -1, false
  while true do
    secnum = findSectorFromLineTag(line, secnum)
    if secnum < 0 then break end

    local s1 = G.sectors[secnum + 1]
    if s1.specialdata then continue end

    rtn = true
    local s2 = getNextSector(s1.lines[1], s1)
    if not s2 then continue end

    for _, check in s2.lines do
      local s3 = check.backsector
      if s3 == s1 or not s3 then continue end

      local floor = newFloor(s2, 'donutRaise', 1, FLOORSPEED / 2)
      floor.texture = s3.floorpic
      floor.floordestheight = s3.floorheight

      floor = newFloor(s1, 'lowerFloor', -1, FLOORSPEED / 2)
      floor.floordestheight = s3.floorheight
      break
    end
  end

  return rtn
end

-- Ceilings.
local function removeActive(list: any, mover: any): ()
  for slot = 1, MAXACTIVE do
    if list[slot] == mover then
      mover.sector.specialdata = nil
      P.RemoveThinker(mover)
      list[slot] = nil
      return
    end
  end
end

local function addActive(list: any, mover: any): ()
  for slot = 1, MAXACTIVE do
    if not list[slot] then
      list[slot] = mover
      return
    end
  end
end

function think.ceiling(ceiling: any): ()
  local type = ceiling.type
  if ceiling.direction == 1 then
    local res = movePlane(ceiling.sector, ceiling.speed, ceiling.topheight, false, true, 1)
    if res ~= PASTDEST then return end

    if type == 'raiseToHighest' then
      removeActive(G.activeceilings, ceiling)
    elseif type == 'silentCrushAndRaise' or type == 'fastCrushAndRaise' or type == 'crushAndRaise' then
      ceiling.direction = -1
    end
  elseif ceiling.direction == -1 then
    local res = movePlane(ceiling.sector, ceiling.speed, ceiling.bottomheight, ceiling.crush, true, -1)
    if res == PASTDEST then
      if type == 'silentCrushAndRaise' or type == 'crushAndRaise' then
        ceiling.speed = CEILSPEED
        ceiling.direction = 1
      elseif type == 'fastCrushAndRaise' then
        ceiling.direction = 1
      elseif type == 'lowerAndCrush' or type == 'lowerToFloor' then
        removeActive(G.activeceilings, ceiling)
      end
    elseif res == CRUSHED then
      if type == 'silentCrushAndRaise' or type == 'crushAndRaise' or type == 'lowerAndCrush' then
        ceiling.speed = CEILSPEED / 8
      end
    end
  end
end

local function doCeiling(line: any, type: string): boolean
  local secnum, rtn = -1, false
  if type == 'fastCrushAndRaise' or type == 'silentCrushAndRaise' or type == 'crushAndRaise' then
    for slot = 1, MAXACTIVE do
      local ceiling = G.activeceilings[slot]
      if ceiling and ceiling.tag == line.tag and ceiling.direction == 0 then
        ceiling.direction = ceiling.olddirection
        ceiling.think = 'ceiling'
      end
    end
  end

  while true do
    secnum = findSectorFromLineTag(line, secnum)
    if secnum < 0 then break end

    local sec = G.sectors[secnum + 1]
    if sec.specialdata then continue end

    rtn = true
    local ceiling = {
      think = 'ceiling',
      sector = sec,
      crush = false,
      type = type,
      tag = sec.tag,
      direction = -1,
      olddirection = 0,
      speed = CEILSPEED,
      topheight = 0,
      bottomheight = 0,
    }
    P.AddThinker(ceiling)
    sec.specialdata = ceiling

    if type == 'fastCrushAndRaise' then
      ceiling.crush = true
      ceiling.topheight = sec.ceilingheight
      ceiling.bottomheight = sec.floorheight + 8 * FRACUNIT
      ceiling.speed = CEILSPEED * 2
    elseif type == 'raiseToHighest' then
      ceiling.topheight = findHighestCeilingSurrounding(sec)
      ceiling.direction = 1
    else
      if type == 'silentCrushAndRaise' or type == 'crushAndRaise' then
        ceiling.crush = true
        ceiling.topheight = sec.ceilingheight
      end

      ceiling.bottomheight = sec.floorheight
      if type ~= 'lowerToFloor' then ceiling.bottomheight += 8 * FRACUNIT end
    end

    addActive(G.activeceilings, ceiling)
  end

  return rtn
end

local function ceilingCrushStop(line: any): boolean
  local rtn = false
  for slot = 1, MAXACTIVE do
    local ceiling = G.activeceilings[slot]
    if ceiling and ceiling.tag == line.tag and ceiling.direction ~= 0 then
      ceiling.olddirection = ceiling.direction
      ceiling.think = nil
      ceiling.direction = 0
      rtn = true
    end
  end

  return rtn
end

-- Platforms.
function think.plat(plat: any): ()
  local status = plat.status
  if status == UP then
    local res = movePlane(plat.sector, plat.speed, plat.high, plat.crush, false, 1)
    if res == CRUSHED and not plat.crush then
      plat.count = plat.wait
      plat.status = DOWN
    elseif res == PASTDEST then
      plat.count = plat.wait
      plat.status = WAITING
      if plat.type ~= 'perpetualRaise' then removeActive(G.activeplats, plat) end
    end
  elseif status == DOWN then
    local res = movePlane(plat.sector, plat.speed, plat.low, false, false, -1)
    if res == PASTDEST then
      plat.count = plat.wait
      plat.status = WAITING
    end
  elseif status == WAITING then
    plat.count -= 1
    if plat.count == 0 then plat.status = if plat.sector.floorheight == plat.low then UP else DOWN end
  end
end

local function doPlat(line: any, type: string, amount: number): boolean
  local secnum, rtn = -1, false
  if type == 'perpetualRaise' then
    for slot = 1, MAXACTIVE do
      local plat = G.activeplats[slot]
      if plat and plat.tag == line.tag and plat.status == IN_STASIS then
        plat.status = plat.oldstatus
        plat.think = 'plat'
      end
    end
  end

  while true do
    secnum = findSectorFromLineTag(line, secnum)
    if secnum < 0 then break end

    local sec = G.sectors[secnum + 1]
    if sec.specialdata then continue end

    rtn = true
    local plat = {
      think = 'plat',
      type = type,
      sector = sec,
      crush = false,
      tag = line.tag,
      speed = PLATSPEED,
      low = 0,
      high = 0,
      wait = 0,
      count = 0,
      status = UP,
      oldstatus = UP,
    }
    P.AddThinker(plat)
    sec.specialdata = plat

    if type == 'raiseToNearestAndChange' then
      plat.speed = PLATSPEED / 2
      sec.floorpic = line.frontsector.floorpic
      plat.high = findNextHighestFloor(sec, sec.floorheight)
      sec.special = 0
    elseif type == 'raiseAndChange' then
      plat.speed = PLATSPEED / 2
      sec.floorpic = line.frontsector.floorpic
      plat.high = sec.floorheight + amount * FRACUNIT
    else
      plat.low = math.min(findLowestFloorSurrounding(sec), sec.floorheight)
      plat.high = sec.floorheight
      plat.wait = 35 * PLATWAIT
      plat.status = DOWN
      if type == 'downWaitUpStay' then
        plat.speed = PLATSPEED * 4
      elseif type == 'blazeDWUS' then
        plat.speed = PLATSPEED * 8
      else
        plat.high = math.max(findHighestFloorSurrounding(sec), sec.floorheight)
        plat.status = band(P.Random(), 1)
      end
    end

    addActive(G.activeplats, plat)
  end

  return rtn
end

local function stopPlat(line: any): ()
  for slot = 1, MAXACTIVE do
    local plat = G.activeplats[slot]
    if plat and plat.status ~= IN_STASIS and plat.tag == line.tag then
      plat.oldstatus = plat.status
      plat.status = IN_STASIS
      plat.think = nil
    end
  end
end

-- Doors.
function think.door(door: any): ()
  local direction, type = door.direction, door.type
  if direction == 0 then
    door.topcountdown -= 1
    if door.topcountdown ~= 0 then return end

    if type == 'blazeRaise' or type == 'normal' then
      door.direction = -1
    elseif type == 'close30ThenOpen' then
      door.direction = 1
    end
  elseif direction == 2 then
    door.topcountdown -= 1
    if door.topcountdown ~= 0 then return end

    if type == 'raiseIn5Mins' then
      door.direction = 1
      door.type = 'normal'
    end
  elseif direction == -1 then
    local res = movePlane(door.sector, door.speed, door.sector.floorheight, false, true, -1)
    if res == PASTDEST then
      if type == 'blazeRaise' or type == 'blazeClose' or type == 'normal' or type == 'close' then
        door.sector.specialdata = nil
        P.RemoveThinker(door)
      elseif type == 'close30ThenOpen' then
        door.direction = 0
        door.topcountdown = 35 * 30
      end
    elseif res == CRUSHED then
      if type ~= 'blazeClose' and type ~= 'close' then door.direction = 1 end
    end
  elseif direction == 1 then
    local res = movePlane(door.sector, door.speed, door.topheight, false, true, 1)
    if res ~= PASTDEST then return end

    if type == 'blazeRaise' or type == 'normal' then
      door.direction = 0
      door.topcountdown = door.topwait
    elseif type == 'close30ThenOpen' or type == 'blazeOpen' or type == 'open' then
      door.sector.specialdata = nil
      P.RemoveThinker(door)
    end
  end
end

local function newDoor(sector: any, type: string): any
  local door = {
    think = 'door',
    sector = sector,
    type = type,
    topwait = VDOORWAIT,
    speed = VDOORSPEED,
    direction = 1,
    topheight = 0,
    topcountdown = 0,
  }
  P.AddThinker(door)
  sector.specialdata = door
  return door
end

function P.DoDoor(line: any, type: string): boolean
  local secnum, rtn = -1, false
  while true do
    secnum = findSectorFromLineTag(line, secnum)
    if secnum < 0 then break end

    local sec = G.sectors[secnum + 1]
    if sec.specialdata then continue end

    rtn = true
    local door = newDoor(sec, type)
    if type == 'close30ThenOpen' then
      door.topheight = sec.ceilingheight
      door.direction = -1
    else
      door.topheight = findLowestCeilingSurrounding(sec) - 4 * FRACUNIT
      if type == 'blazeClose' or type == 'close' then door.direction = -1 end
      if type == 'blazeClose' or type == 'blazeRaise' or type == 'blazeOpen' then door.speed = VDOORSPEED * 4 end
    end
  end

  return rtn
end

-- Card pairs by the specials that need them: blue, yellow, red.
local LockedDoors = { [99] = 0, [133] = 0, [134] = 2, [135] = 2, [136] = 1, [137] = 1 }
local ManualLocks = { [26] = 0, [32] = 0, [27] = 1, [34] = 1, [28] = 2, [33] = 2 }

local function hasKey(player: any, card: number): boolean
  return player.cards[card] or player.cards[card + 3]
end

local function doLockedDoor(line: any, type: string, thing: any): boolean
  local player = thing.player
  if not player then return false end

  local card = LockedDoors[line.special]
  if card and not hasKey(player, card) then return false end
  return P.DoDoor(line, type)
end

local function verticalDoor(line: any, thing: any): ()
  local player = thing.player
  local special = line.special
  local card = ManualLocks[special]
  if card then
    if not player then return end
    if not hasKey(player, card) then return end
  end

  -- A one-sided door line has no back side to open.
  if line.sidenum[2] == -1 then return end

  local sec = G.sides[line.sidenum[2] + 1].sector
  local door = sec.specialdata
  if door and (special == 1 or special == 26 or special == 27 or special == 28 or special == 117) then
    if door.direction == -1 then
      door.direction = 1
    else
      if not player then return end
      door.direction = -1
    end

    return
  end

  door = newDoor(sec, 'normal')
  if special == 31 or special == 32 or special == 33 or special == 34 then
    door.type = 'open'
    line.special = 0
  elseif special == 117 then
    door.type = 'blazeRaise'
    door.speed = VDOORSPEED * 4
  elseif special == 118 then
    door.type = 'blazeOpen'
    line.special = 0
    door.speed = VDOORSPEED * 4
  end

  door.topheight = findLowestCeilingSurrounding(sec) - 4 * FRACUNIT
end

-- Lights.
function think.flicker(flick: any): ()
  flick.count -= 1
  if flick.count ~= 0 then return end

  local amount = band(P.Random(), 3) * 16
  local sector = flick.sector
  sector.lightlevel = if sector.lightlevel - amount < flick.minlight then flick.minlight else flick.maxlight - amount
  flick.count = 4
end

function think.flash(flash: any): ()
  flash.count -= 1
  if flash.count ~= 0 then return end

  local sector = flash.sector
  if sector.lightlevel == flash.maxlight then
    sector.lightlevel = flash.minlight
    flash.count = band(P.Random(), flash.mintime) + 1
  else
    sector.lightlevel = flash.maxlight
    flash.count = band(P.Random(), flash.maxtime) + 1
  end
end

function think.strobe(flash: any): ()
  flash.count -= 1
  if flash.count ~= 0 then return end

  local sector = flash.sector
  if sector.lightlevel == flash.minlight then
    sector.lightlevel = flash.maxlight
    flash.count = flash.brighttime
  else
    sector.lightlevel = flash.minlight
    flash.count = flash.darktime
  end
end

function think.glow(glow: any): ()
  local sector = glow.sector
  if glow.direction == -1 then
    sector.lightlevel -= 8
    if sector.lightlevel <= glow.minlight then
      sector.lightlevel += 8
      glow.direction = 1
    end
  else
    sector.lightlevel += 8
    if sector.lightlevel >= glow.maxlight then
      sector.lightlevel -= 8
      glow.direction = -1
    end
  end
end

local function spawnStrobeFlash(sector: any, darktime: number, inSync: boolean): ()
  local flash = {
    think = 'strobe',
    sector = sector,
    darktime = darktime,
    brighttime = 5,
    maxlight = sector.lightlevel,
    minlight = findMinSurroundingLight(sector, sector.lightlevel),
    count = 1,
  }
  P.AddThinker(flash)
  if flash.minlight == flash.maxlight then flash.minlight = 0 end

  sector.special = 0
  if not inSync then flash.count = band(P.Random(), 7) + 1 end
end

local function lightTurnOn(line: any, bright: number): ()
  for _, sector in G.sectors do
    if sector.tag ~= line.tag then continue end

    if bright == 0 then
      for _, check in sector.lines do
        local other = getNextSector(check, sector)
        if other and other.lightlevel > bright then bright = other.lightlevel end
      end
    end

    sector.lightlevel = bright
  end
end

local function turnTagLightsOff(line: any): ()
  for _, sector in G.sectors do
    if sector.tag == line.tag then sector.lightlevel = findMinSurroundingLight(sector, sector.lightlevel) end
  end
end

local function startLightStrobing(line: any): ()
  local secnum = -1
  while true do
    secnum = findSectorFromLineTag(line, secnum)
    if secnum < 0 then break end

    local sec = G.sectors[secnum + 1]
    if not sec.specialdata then spawnStrobeFlash(sec, 35, false) end
  end
end

-- Teleporters.
local function teleport(line: any, side: number, thing: any): boolean
  if band(thing.flags, P.MF_MISSILE) ~= 0 then return false end
  if side == 1 then return false end

  local cap = G.thinkercap
  for _, sector in G.sectors do
    if sector.tag ~= line.tag then continue end

    local m = cap.next
    while m ~= cap do
      if m.think == 'mobj' and m.type == MT.MT_TELEPORTMAN and m.subsector.sector == sector then
        local oldx, oldy, oldz = thing.x, thing.y, thing.z
        if not P.TeleportMove(thing, m.x, m.y) then return false end

        thing.z = thing.floorz
        local player = thing.player
        if player then player.viewz = thing.z + player.viewheight end

        P.SpawnMobj(oldx, oldy, oldz, MT.MT_TFOG)
        local fine = m.angle // 524288
        P.SpawnMobj(m.x + 20 * P.finesine[fine + 2049], m.y + 20 * P.finesine[fine + 1], thing.z, MT.MT_TFOG)
        if player then thing.reactiontime = 18 end

        thing.angle = m.angle
        thing.momx, thing.momy, thing.momz = 0, 0, 0
        return true
      end

      m = m.next
    end
  end

  return false
end

-- Switches. Any SW1/SW2 texture pair toggles; the pair list is the WAD's own.
local function changeSwitchTexture(line: any, useAgain: boolean): ()
  if not useAgain then line.special = 0 end

  local side = G.sides[line.sidenum[1] + 1]
  local textures = G.textures
  for _, where in { 'toptexture', 'midtexture', 'bottomtexture' } do
    local name = textures.names[side[where]]
    if not name then continue end

    local prefix = string.sub(name, 1, 3)
    if prefix ~= 'SW1' and prefix ~= 'SW2' then continue end

    local other = textures.numbers[(if prefix == 'SW1' then 'SW2' else 'SW1') .. string.sub(name, 4)]
    if not other then continue end

    local previous = side[where]
    side[where] = other
    if not useAgain then return end

    local buttons = G.buttons
    for slot = 1, MAXBUTTONS do
      local button = buttons[slot]
      if button and button.line == line then return end
    end

    for slot = 1, MAXBUTTONS do
      if not buttons[slot] then
        buttons[slot] = { line = line, where = where, texture = previous, timer = 35 }
        return
      end
    end

    return
  end
end

-- Line specials as tables: { handler, argument, ... }.
local function door(type: string): any
  return function(line: any): boolean
    return P.DoDoor(line, type)
  end
end

local function floor(type: string): any
  return function(line: any): boolean
    return P.DoFloor(line, type)
  end
end

local function ceiling(type: string): any
  return function(line: any): boolean
    return doCeiling(line, type)
  end
end

local function plat(type: string, amount: number?): any
  return function(line: any): boolean
    return doPlat(line, type, amount or 0)
  end
end

local function stairs(type: string): any
  return function(line: any): boolean
    return P.BuildStairs(line, type)
  end
end

local function light(bright: number): any
  return function(line: any): boolean
    lightTurnOn(line, bright)
    return true
  end
end

local function call(func: (any) -> any): any
  return function(line: any): boolean
    func(line)
    return true
  end
end

local function both(first: any, second: any): any
  return function(line: any): boolean
    first(line)
    second(line)
    return true
  end
end

-- Walk triggers: once (W1) and repeatable (WR).
local CrossOnce = {
  [2] = door('open'),
  [3] = door('close'),
  [4] = door('normal'),
  [5] = floor('raiseFloor'),
  [6] = ceiling('fastCrushAndRaise'),
  [8] = stairs('build8'),
  [10] = plat('downWaitUpStay'),
  [12] = light(0),
  [13] = light(255),
  [16] = door('close30ThenOpen'),
  [17] = call(startLightStrobing),
  [19] = floor('lowerFloor'),
  [22] = plat('raiseToNearestAndChange'),
  [25] = ceiling('crushAndRaise'),
  [30] = floor('raiseToTexture'),
  [35] = light(35),
  [36] = floor('turboLower'),
  [37] = floor('lowerAndChange'),
  [38] = floor('lowerFloorToLowest'),
  [40] = both(ceiling('raiseToHighest'), floor('lowerFloorToLowest')),
  [44] = ceiling('lowerAndCrush'),
  [53] = plat('perpetualRaise'),
  [54] = call(stopPlat),
  [56] = floor('raiseFloorCrush'),
  [57] = call(ceilingCrushStop),
  [58] = floor('raiseFloor24'),
  [59] = floor('raiseFloor24AndChange'),
  [104] = call(turnTagLightsOff),
  [108] = door('blazeRaise'),
  [109] = door('blazeOpen'),
  [100] = stairs('turbo16'),
  [110] = door('blazeClose'),
  [119] = floor('raiseFloorToNearest'),
  [121] = plat('blazeDWUS'),
  [130] = floor('raiseFloorTurbo'),
  [141] = ceiling('silentCrushAndRaise'),
}

local CrossRepeat = {
  [72] = ceiling('lowerAndCrush'),
  [73] = ceiling('crushAndRaise'),
  [74] = call(ceilingCrushStop),
  [75] = door('close'),
  [76] = door('close30ThenOpen'),
  [77] = ceiling('fastCrushAndRaise'),
  [79] = light(35),
  [80] = light(0),
  [81] = light(255),
  [82] = floor('lowerFloorToLowest'),
  [83] = floor('lowerFloor'),
  [84] = floor('lowerAndChange'),
  [86] = door('open'),
  [87] = plat('perpetualRaise'),
  [88] = plat('downWaitUpStay'),
  [89] = call(stopPlat),
  [90] = door('normal'),
  [91] = floor('raiseFloor'),
  [92] = floor('raiseFloor24'),
  [93] = floor('raiseFloor24AndChange'),
  [94] = floor('raiseFloorCrush'),
  [95] = plat('raiseToNearestAndChange'),
  [96] = floor('raiseToTexture'),
  [98] = floor('turboLower'),
  [105] = door('blazeRaise'),
  [106] = door('blazeOpen'),
  [107] = door('blazeClose'),
  [120] = plat('blazeDWUS'),
  [128] = floor('raiseFloorToNearest'),
  [129] = floor('raiseFloorTurbo'),
}

local NoCrossTypes = {
  [MT.MT_ROCKET] = true,
  [MT.MT_PLASMA] = true,
  [MT.MT_BFG] = true,
  [MT.MT_TROOPSHOT] = true,
  [MT.MT_HEADSHOT] = true,
  [MT.MT_BRUISERSHOT] = true,
}
local MonsterCross = { [39] = true, [97] = true, [125] = true, [126] = true, [4] = true, [10] = true, [88] = true }

function P.CrossSpecialLine(line: any, side: number, thing: any): ()
  local special = line.special
  if not thing.player then
    if NoCrossTypes[thing.type] then return end
    if not MonsterCross[special] then return end
  end

  local once = CrossOnce[special]
  if once then
    once(line)
    line.special = 0
    return
  end

  local again = CrossRepeat[special]
  if again then
    again(line)
  elseif special == 39 then
    teleport(line, side, thing)
    line.special = 0
  elseif special == 97 then
    teleport(line, side, thing)
  elseif special == 125 then
    if not thing.player then
      teleport(line, side, thing)
      line.special = 0
    end
  elseif special == 126 then
    if not thing.player then teleport(line, side, thing) end
  elseif special == 52 then
    P.ExitLevel()
  elseif special == 124 then
    P.SecretExitLevel()
  end
end

function P.ShootSpecialLine(thing: any, line: any): ()
  local special = line.special
  if not thing.player and special ~= 46 then return end

  if special == 24 then
    P.DoFloor(line, 'raiseFloor')
    changeSwitchTexture(line, false)
  elseif special == 46 then
    P.DoDoor(line, 'open')
    changeSwitchTexture(line, true)
  elseif special == 47 then
    doPlat(line, 'raiseToNearestAndChange', 0)
    changeSwitchTexture(line, false)
  end
end

local function lockedDoor(line: any, thing: any): boolean
  return doLockedDoor(line, 'blazeOpen', thing)
end

-- Switches (S1) and buttons (SR).
local UseOnce = {
  [7] = stairs('build8'),
  [9] = doDonut,
  [14] = plat('raiseAndChange', 32),
  [15] = plat('raiseAndChange', 24),
  [18] = floor('raiseFloorToNearest'),
  [20] = plat('raiseToNearestAndChange'),
  [21] = plat('downWaitUpStay'),
  [23] = floor('lowerFloorToLowest'),
  [29] = door('normal'),
  [41] = ceiling('lowerToFloor'),
  [71] = floor('turboLower'),
  [49] = ceiling('crushAndRaise'),
  [50] = door('close'),
  [55] = floor('raiseFloorCrush'),
  [101] = floor('raiseFloor'),
  [102] = floor('lowerFloor'),
  [103] = door('open'),
  [111] = door('blazeRaise'),
  [112] = door('blazeOpen'),
  [113] = door('blazeClose'),
  [122] = plat('blazeDWUS'),
  [127] = stairs('turbo16'),
  [131] = floor('raiseFloorTurbo'),
  [133] = lockedDoor,
  [135] = lockedDoor,
  [137] = lockedDoor,
  [140] = floor('raiseFloor512'),
}

local UseRepeat = {
  [42] = door('close'),
  [43] = ceiling('lowerToFloor'),
  [45] = floor('lowerFloor'),
  [60] = floor('lowerFloorToLowest'),
  [61] = door('open'),
  [62] = plat('downWaitUpStay', 1),
  [63] = door('normal'),
  [64] = floor('raiseFloor'),
  [66] = plat('raiseAndChange', 24),
  [67] = plat('raiseAndChange', 32),
  [65] = floor('raiseFloorCrush'),
  [68] = plat('raiseToNearestAndChange'),
  [69] = floor('raiseFloorToNearest'),
  [70] = floor('turboLower'),
  [114] = door('blazeRaise'),
  [115] = door('blazeOpen'),
  [116] = door('blazeClose'),
  [123] = plat('blazeDWUS'),
  [132] = floor('raiseFloorTurbo'),
  [99] = lockedDoor,
  [134] = lockedDoor,
  [136] = lockedDoor,
  [138] = light(255),
  [139] = light(35),
}

local ManualDoors = { [1] = true, [26] = true, [27] = true, [28] = true, [31] = true, [32] = true, [33] = true, [34] = true, [117] = true, [118] = true }
local MonsterUse = { [1] = true, [32] = true, [33] = true, [34] = true }

function P.UseSpecialLine(thing: any, line: any, side: number): boolean
  local special = line.special
  if side ~= 0 and special ~= 124 then return false end

  if not thing.player then
    if band(line.flags, 32) ~= 0 then return false end
    if not MonsterUse[special] then return false end
  end

  if ManualDoors[special] then
    verticalDoor(line, thing)
  elseif UseOnce[special] then
    if UseOnce[special](line, thing) then changeSwitchTexture(line, false) end
  elseif UseRepeat[special] then
    if UseRepeat[special](line, thing) then changeSwitchTexture(line, true) end
  elseif special == 11 then
    changeSwitchTexture(line, false)
    P.ExitLevel()
  elseif special == 51 then
    changeSwitchTexture(line, false)
    P.SecretExitLevel()
  end

  return true
end

function P.PlayerInSpecialSector(player: any): ()
  local mo = player.mo
  local sector = mo.subsector.sector
  if mo.z ~= sector.floorheight then return end

  local special = sector.special
  local hurtTic = G.leveltime % 32 == 0
  local suit = player.powers[P.pw_ironfeet] ~= 0
  if special == 5 then
    if not suit and hurtTic then P.DamageMobj(mo, nil, nil, 10) end
  elseif special == 7 then
    if not suit and hurtTic then P.DamageMobj(mo, nil, nil, 5) end
  elseif special == 16 or special == 4 then
    if (not suit or P.Random() < 5) and hurtTic then P.DamageMobj(mo, nil, nil, 20) end
  elseif special == 9 then
    player.secretcount += 1
    sector.special = 0
  elseif special == 11 then
    player.cheats = band(player.cheats, bit32.bnot(P.CF_GODMODE))
    if hurtTic then P.DamageMobj(mo, nil, nil, 20) end
    if player.health <= 10 then P.ExitLevel() end
  end
end

function P.UpdateSpecials(): ()
  if G.levelTimer then
    G.levelTimeCount -= 1
    if G.levelTimeCount == 0 then P.ExitLevel() end
  end

  local buttons = G.buttons
  for slot = 1, MAXBUTTONS do
    local button = buttons[slot]
    if not button then continue end

    button.timer -= 1
    if button.timer == 0 then
      G.sides[button.line.sidenum[1] + 1][button.where] = button.texture
      buttons[slot] = nil
    end
  end
end

function P.InitSpecialState(): ()
  G.activeceilings, G.activeplats, G.buttons = {}, {}, {}
end

function P.SpawnSpecials(): ()
  G.levelTimer = false
  if G.timelimit and G.deathmatch ~= 0 then
    G.levelTimer = true
    G.levelTimeCount = G.timelimit * 60 * 35
  end

  for _, sector in G.sectors do
    local special = sector.special
    if special == 1 then
      sector.special = 0
      local maxlight = sector.lightlevel
      P.AddThinker({
        think = 'flash',
        sector = sector,
        maxlight = maxlight,
        minlight = findMinSurroundingLight(sector, maxlight),
        maxtime = 64,
        mintime = 7,
        count = band(P.Random(), 64) + 1,
      })
    elseif special == 2 then
      spawnStrobeFlash(sector, 15, false)
    elseif special == 3 then
      spawnStrobeFlash(sector, 35, false)
    elseif special == 4 then
      spawnStrobeFlash(sector, 15, false)
      sector.special = 4
    elseif special == 8 then
      P.AddThinker({
        think = 'glow',
        sector = sector,
        minlight = findMinSurroundingLight(sector, sector.lightlevel),
        maxlight = sector.lightlevel,
        direction = -1,
      })
      sector.special = 0
    elseif special == 9 then
      G.totalsecret += 1
    elseif special == 10 then
      local closing = newDoor(sector, 'normal')
      sector.special = 0
      closing.direction = 0
      closing.topcountdown = 30 * 35
    elseif special == 12 then
      spawnStrobeFlash(sector, 35, true)
    elseif special == 13 then
      spawnStrobeFlash(sector, 15, true)
    elseif special == 14 then
      local raising = newDoor(sector, 'raiseIn5Mins')
      sector.special = 0
      raising.direction = 2
      raising.topheight = findLowestCeilingSurrounding(sector) - 4 * FRACUNIT
      raising.topcountdown = 5 * 60 * 35
    elseif special == 17 then
      sector.special = 0
      P.AddThinker({
        think = 'flicker',
        sector = sector,
        maxlight = sector.lightlevel,
        minlight = findMinSurroundingLight(sector, sector.lightlevel) + 16,
        count = 4,
      })
    end
  end
end

return P
