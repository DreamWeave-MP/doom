--!nonstrict
--!native
-- p_maputl.c, p_map.c, and p_sight.c: blockmap iteration, intercept traces,
-- movement clipping, sliding, hitscan, radius damage, sector height changes,
-- and line of sight.
local P: any = require('./core')
local flat = require('./flat')

local G = P.G
local FixedMul, FixedDiv, idiv = P.FixedMul, P.FixedDiv, P.idiv
local finesine = P.finesine
local FRACUNIT = 65536
local MAXRADIUS = P.MAXRADIUS
local BLOCK = 8388608
local MF_SOLID, MF_SPECIAL, MF_SHOOTABLE, MF_MISSILE, MF_SKULLFLY = P.MF_SOLID, P.MF_SPECIAL, P.MF_SHOOTABLE, P.MF_MISSILE, P.MF_SKULLFLY
local MT, S = P.MT, P.S
local band = bit32.band

local function pointOnLineSide(x: number, y: number, line: any): number
  if line.dx == 0 then
    if x <= line.v1.x then return if line.dy > 0 then 1 else 0 end
    return if line.dy < 0 then 1 else 0
  end

  if line.dy == 0 then
    if y <= line.v1.y then return if line.dx < 0 then 1 else 0 end
    return if line.dx > 0 then 1 else 0
  end

  local left = FixedMul(line.dy // 65536, x - line.v1.x)
  local right = FixedMul(y - line.v1.y, line.dx // 65536)
  return if right < left then 0 else 1
end

P.PointOnLineSide = pointOnLineSide

local function boxOnLineSide(box: any, line: any): number
  local p1, p2
  local slopetype = line.slopetype
  if slopetype == 0 then
    p1 = if box[1] > line.v1.y then 1 else 0
    p2 = if box[2] > line.v1.y then 1 else 0
    if line.dx < 0 then
      p1, p2 = 1 - p1, 1 - p2
    end
  elseif slopetype == 1 then
    p1 = if box[4] < line.v1.x then 1 else 0
    p2 = if box[3] < line.v1.x then 1 else 0
    if line.dy < 0 then
      p1, p2 = 1 - p1, 1 - p2
    end
  elseif slopetype == 2 then
    p1 = pointOnLineSide(box[3], box[1], line)
    p2 = pointOnLineSide(box[4], box[2], line)
  else
    p1 = pointOnLineSide(box[4], box[1], line)
    p2 = pointOnLineSide(box[3], box[2], line)
  end

  return if p1 == p2 then p1 else -1
end

local function pointOnDivlineSide(x: number, y: number, line: any): number
  if line.dx == 0 then
    if x <= line.x then return if line.dy > 0 then 1 else 0 end
    return if line.dy < 0 then 1 else 0
  end

  if line.dy == 0 then
    if y <= line.y then return if line.dx < 0 then 1 else 0 end
    return if line.dx > 0 then 1 else 0
  end

  local dx, dy = x - line.x, y - line.y
  if (line.dy < 0) ~= (line.dx < 0) ~= (dx < 0) ~= (dy < 0) then
    return if (line.dy < 0) ~= (dx < 0) then 1 else 0
  end

  local left, right = FixedMul(line.dy // 256, dx // 256), FixedMul(dy // 256, line.dx // 256)
  return if right < left then 0 else 1
end

-- P_InterceptVector(v2, v1), with both divlines passed as scalars.
local function interceptVector(x2: number, y2: number, dx2: number, dy2: number, x1: number, y1: number, dx1: number, dy1: number): number
  local den = FixedMul(dy1 // 256, dx2) - FixedMul(dx1 // 256, dy2)
  if den == 0 then return 0 end

  local num = FixedMul((x1 - x2) // 256, dy1) + FixedMul((y2 - y1) // 256, dx1)
  return FixedDiv(num, den)
end

P.opentop, P.openbottom, P.openrange, P.lowfloor = 0, 0, 0, 0

local function lineOpening(line: any): ()
  if line.sidenum[2] == -1 then
    P.openrange = 0
    return
  end

  local front, back = line.frontsector, line.backsector
  local top = if front.ceilingheight < back.ceilingheight then front.ceilingheight else back.ceilingheight
  local bottom
  if front.floorheight > back.floorheight then
    bottom = front.floorheight
    P.lowfloor = back.floorheight
  else
    bottom = back.floorheight
    P.lowfloor = front.floorheight
  end

  P.opentop, P.openbottom, P.openrange = top, bottom, top - bottom
end

P.LineOpening = lineOpening

function P.UnsetThingPosition(thing: any): ()
  if band(thing.flags, P.MF_NOSECTOR) == 0 then
    if thing.snext then thing.snext.sprev = thing.sprev end
    if thing.sprev then
      thing.sprev.snext = thing.snext
    else
      thing.subsector.sector.thinglist = thing.snext
    end
  end

  if band(thing.flags, P.MF_NOBLOCKMAP) == 0 then
    if thing.bnext then thing.bnext.bprev = thing.bprev end
    if thing.bprev then
      thing.bprev.bnext = thing.bnext
    else
      local blockx, blocky = (thing.x - G.bmaporgx) // BLOCK, (thing.y - G.bmaporgy) // BLOCK
      if blockx >= 0 and blockx < G.bmapwidth and blocky >= 0 and blocky < G.bmapheight then
        G.blocklinks[blocky * G.bmapwidth + blockx] = thing.bnext
      end
    end
  end
end

function P.SetThingPosition(thing: any): ()
  local subsector = P.PointInSubsector(thing.x, thing.y)
  thing.subsector = subsector
  if band(thing.flags, P.MF_NOSECTOR) == 0 then
    local sector = subsector.sector
    thing.sprev = nil
    thing.snext = sector.thinglist
    if sector.thinglist then sector.thinglist.sprev = thing end
    sector.thinglist = thing
  end

  if band(thing.flags, P.MF_NOBLOCKMAP) == 0 then
    local blockx, blocky = (thing.x - G.bmaporgx) // BLOCK, (thing.y - G.bmaporgy) // BLOCK
    if blockx >= 0 and blockx < G.bmapwidth and blocky >= 0 and blocky < G.bmapheight then
      local cell = blocky * G.bmapwidth + blockx
      local head = G.blocklinks[cell]
      thing.bprev = nil
      thing.bnext = head
      if head then head.bprev = thing end
      G.blocklinks[cell] = thing
    else
      thing.bnext, thing.bprev = nil, nil
    end
  end
end

local function blockLinesIterator(x: number, y: number, func: (any) -> boolean): boolean
  if x < 0 or y < 0 or x >= G.bmapwidth or y >= G.bmapheight then return true end

  local validcount = G.validcount
  for _, line in G.blocklines[y * G.bmapwidth + x + 1] do
    if line.validcount == validcount then continue end

    line.validcount = validcount
    if not func(line) then return false end
  end

  return true
end

local function blockThingsIterator(x: number, y: number, func: (any) -> boolean): boolean
  if x < 0 or y < 0 or x >= G.bmapwidth or y >= G.bmapheight then return true end

  local mobj = G.blocklinks[y * G.bmapwidth + x]
  while mobj do
    if not func(mobj) then return false end
    mobj = mobj.bnext
  end

  return true
end

P.BlockLinesIterator, P.BlockThingsIterator = blockLinesIterator, blockThingsIterator

-- Intercepts: parallel arrays, reused across traces.
local interceptFrac, interceptLine, interceptThing = {}, {}, {}
local interceptCount = 0
local traceX, traceY, traceDx, traceDy = 0, 0, 0, 0
local trace = { x = 0, y = 0, dx = 0, dy = 0 }
local earlyout = false

local function addLineIntercepts(line: any): boolean
  local s1, s2
  if traceDx > FRACUNIT * 16 or traceDy > FRACUNIT * 16 or traceDx < -FRACUNIT * 16 or traceDy < -FRACUNIT * 16 then
    s1 = pointOnDivlineSide(line.v1.x, line.v1.y, trace)
    s2 = pointOnDivlineSide(line.v2.x, line.v2.y, trace)
  else
    s1 = pointOnLineSide(traceX, traceY, line)
    s2 = pointOnLineSide(traceX + traceDx, traceY + traceDy, line)
  end

  if s1 == s2 then return true end

  local frac = interceptVector(traceX, traceY, traceDx, traceDy, line.v1.x, line.v1.y, line.dx, line.dy)
  if frac < 0 then return true end
  if earlyout and frac < FRACUNIT and not line.backsector then return false end

  interceptCount += 1
  interceptFrac[interceptCount], interceptLine[interceptCount], interceptThing[interceptCount] = frac, line, false
  return true
end

local function addThingIntercepts(thing: any): boolean
  local x1, y1, x2, y2
  local positive = (traceDx ~= traceDy) and ((traceDx < 0) == (traceDy < 0))
  if positive then
    x1, y1 = thing.x - thing.radius, thing.y + thing.radius
    x2, y2 = thing.x + thing.radius, thing.y - thing.radius
  else
    x1, y1 = thing.x - thing.radius, thing.y - thing.radius
    x2, y2 = thing.x + thing.radius, thing.y + thing.radius
  end

  if pointOnDivlineSide(x1, y1, trace) == pointOnDivlineSide(x2, y2, trace) then return true end

  local frac = interceptVector(traceX, traceY, traceDx, traceDy, x1, y1, x2 - x1, y2 - y1)
  if frac < 0 then return true end

  interceptCount += 1
  interceptFrac[interceptCount], interceptLine[interceptCount], interceptThing[interceptCount] = frac, false, thing
  return true
end

-- The traverser receives (frac, line or false, thing or false).
local function traverseIntercepts(func: (number, any, any) -> boolean, maxfrac: number): boolean
  local count = interceptCount
  local best = 0
  for _ = 1, count do
    local dist = 2147483647
    for scan = 1, count do
      if interceptFrac[scan] < dist then
        dist = interceptFrac[scan]
        best = scan
      end
    end

    if dist > maxfrac then return true end
    if not func(dist, interceptLine[best], interceptThing[best]) then return false end

    interceptFrac[best] = 2147483647
  end

  return true
end

local PT_ADDLINES, PT_ADDTHINGS, PT_EARLYOUT = 1, 2, 4

P.PT_ADDLINES, P.PT_ADDTHINGS, P.PT_EARLYOUT = PT_ADDLINES, PT_ADDTHINGS, PT_EARLYOUT

local function pathTraverse(x1: number, y1: number, x2: number, y2: number, flags: number, trav: (number, any, any) -> boolean): boolean
  earlyout = band(flags, PT_EARLYOUT) ~= 0
  G.validcount += 1
  interceptCount = 0

  local orgx, orgy = G.bmaporgx, G.bmaporgy
  if (x1 - orgx) % BLOCK == 0 then x1 += FRACUNIT end
  if (y1 - orgy) % BLOCK == 0 then y1 += FRACUNIT end

  traceX, traceY, traceDx, traceDy = x1, y1, x2 - x1, y2 - y1
  trace.x, trace.y, trace.dx, trace.dy = x1, y1, traceDx, traceDy

  x1 -= orgx
  y1 -= orgy
  x2 -= orgx
  y2 -= orgy
  local xt1, yt1, xt2, yt2 = x1 // BLOCK, y1 // BLOCK, x2 // BLOCK, y2 // BLOCK
  local mapxstep, mapystep, partial, xstep, ystep

  if xt2 > xt1 then
    mapxstep = 1
    partial = FRACUNIT - (x1 // 128) % 65536
    ystep = FixedDiv(y2 - y1, math.abs(x2 - x1))
  elseif xt2 < xt1 then
    mapxstep = -1
    partial = (x1 // 128) % 65536
    ystep = FixedDiv(y2 - y1, math.abs(x2 - x1))
  else
    mapxstep = 0
    partial = FRACUNIT
    ystep = 256 * FRACUNIT
  end

  local yintercept = y1 // 128 + FixedMul(partial, ystep)

  if yt2 > yt1 then
    mapystep = 1
    partial = FRACUNIT - (y1 // 128) % 65536
    xstep = FixedDiv(x2 - x1, math.abs(y2 - y1))
  elseif yt2 < yt1 then
    mapystep = -1
    partial = (y1 // 128) % 65536
    xstep = FixedDiv(x2 - x1, math.abs(y2 - y1))
  else
    mapystep = 0
    partial = FRACUNIT
    xstep = 256 * FRACUNIT
  end

  local xintercept = x1 // 128 + FixedMul(partial, xstep)
  local mapx, mapy = xt1, yt1
  local addLines, addThings = band(flags, PT_ADDLINES) ~= 0, band(flags, PT_ADDTHINGS) ~= 0

  for _ = 1, 64 do
    if addLines and not blockLinesIterator(mapx, mapy, addLineIntercepts) then return false end
    if addThings and not blockThingsIterator(mapx, mapy, addThingIntercepts) then return false end
    if mapx == xt2 and mapy == yt2 then break end

    if yintercept // 65536 == mapy then
      yintercept += ystep
      mapx += mapxstep
    elseif xintercept // 65536 == mapx then
      xintercept += xstep
      mapy += mapystep
    end
  end

  return traverseIntercepts(trav, FRACUNIT)
end

P.PathTraverse = pathTraverse

-- Movement clipping. tmfloorz and friends are read by other modules, so they
-- live on P the way the originals are extern globals.
local tmbbox = { 0, 0, 0, 0 }
local tmthing: any
local tmflags, tmx, tmy = 0, 0, 0
local spechit = {}

P.floatok, P.tmfloorz, P.tmceilingz, P.tmdropoffz = false, 0, 0, 0
P.ceilingline = nil
P.spechit, P.numspechit = spechit, 0

local function stompThing(thing: any): boolean
  if band(thing.flags, MF_SHOOTABLE) == 0 then return true end

  local blockdist = thing.radius + tmthing.radius
  if math.abs(thing.x - tmx) >= blockdist or math.abs(thing.y - tmy) >= blockdist then return true end
  if thing == tmthing then return true end
  if not tmthing.player and G.gamemap ~= 30 then return false end

  P.DamageMobj(thing, tmthing, tmthing, 10000)
  return true
end

local function beginCheck(thing: any, x: number, y: number): ()
  tmthing, tmflags, tmx, tmy = thing, thing.flags, x, y
  tmbbox[1], tmbbox[2], tmbbox[4], tmbbox[3] = y + thing.radius, y - thing.radius, x + thing.radius, x - thing.radius

  local sector = P.PointInSubsector(x, y).sector
  P.ceilingline = nil
  P.tmfloorz, P.tmdropoffz, P.tmceilingz = sector.floorheight, sector.floorheight, sector.ceilingheight
  G.validcount += 1
  P.numspechit = 0
end

function P.TeleportMove(thing: any, x: number, y: number): boolean
  beginCheck(thing, x, y)

  local xl, xh = (tmbbox[3] - G.bmaporgx - MAXRADIUS) // BLOCK, (tmbbox[4] - G.bmaporgx + MAXRADIUS) // BLOCK
  local yl, yh = (tmbbox[2] - G.bmaporgy - MAXRADIUS) // BLOCK, (tmbbox[1] - G.bmaporgy + MAXRADIUS) // BLOCK
  for bx = xl, xh do
    for by = yl, yh do
      if not blockThingsIterator(bx, by, stompThing) then return false end
    end
  end

  P.UnsetThingPosition(thing)
  thing.floorz, thing.ceilingz = P.tmfloorz, P.tmceilingz
  thing.x, thing.y = x, y
  P.SetThingPosition(thing)
  return true
end

local function checkLine(line: any): boolean
  local box = line.bbox
  if tmbbox[4] <= box[3] or tmbbox[3] >= box[4] or tmbbox[1] <= box[2] or tmbbox[2] >= box[1] then return true end
  if boxOnLineSide(tmbbox, line) ~= -1 then return true end
  if not line.backsector then return false end

  if band(tmthing.flags, MF_MISSILE) == 0 then
    if band(line.flags, 1) ~= 0 then return false end
    if not tmthing.player and band(line.flags, 2) ~= 0 then return false end
  end

  lineOpening(line)
  if P.opentop < P.tmceilingz then
    P.tmceilingz = P.opentop
    P.ceilingline = line
  end

  if P.openbottom > P.tmfloorz then P.tmfloorz = P.openbottom end
  if P.lowfloor < P.tmdropoffz then P.tmdropoffz = P.lowfloor end

  if line.special ~= 0 then
    P.numspechit += 1
    spechit[P.numspechit] = line
  end

  return true
end

local function checkThing(thing: any): boolean
  if band(thing.flags, MF_SOLID + MF_SPECIAL + MF_SHOOTABLE) == 0 then return true end

  local blockdist = thing.radius + tmthing.radius
  if math.abs(thing.x - tmx) >= blockdist or math.abs(thing.y - tmy) >= blockdist then return true end
  if thing == tmthing then return true end

  if band(tmthing.flags, MF_SKULLFLY) ~= 0 then
    local damage = (P.Random() % 8 + 1) * tmthing.info.damage
    P.DamageMobj(thing, tmthing, tmthing, damage)
    tmthing.flags = band(tmthing.flags, bit32.bnot(MF_SKULLFLY))
    tmthing.momx, tmthing.momy, tmthing.momz = 0, 0, 0
    P.SetMobjState(tmthing, tmthing.info.spawnstate)
    return false
  end

  if band(tmthing.flags, MF_MISSILE) ~= 0 then
    if tmthing.z > thing.z + thing.height then return true end
    if tmthing.z + tmthing.height < thing.z then return true end

    local target = tmthing.target
    if
      target
      and (
        target.type == thing.type
        or (target.type == MT.MT_KNIGHT and thing.type == MT.MT_BRUISER)
        or (target.type == MT.MT_BRUISER and thing.type == MT.MT_KNIGHT)
      )
    then
      if thing == target then return true end
      if thing.type ~= MT.MT_PLAYER then return false end
    end

    if band(thing.flags, MF_SHOOTABLE) == 0 then return band(thing.flags, MF_SOLID) == 0 end

    local damage = (P.Random() % 8 + 1) * tmthing.info.damage
    P.DamageMobj(thing, tmthing, tmthing.target, damage)
    return false
  end

  if band(thing.flags, MF_SPECIAL) ~= 0 then
    local solid = band(thing.flags, MF_SOLID) ~= 0
    if band(tmflags, P.MF_PICKUP) ~= 0 then P.TouchSpecialThing(thing, tmthing) end
    return not solid
  end

  return band(thing.flags, MF_SOLID) == 0
end

local function checkPosition(thing: any, x: number, y: number): boolean
  beginCheck(thing, x, y)
  if band(tmflags, P.MF_NOCLIP) ~= 0 then return true end

  local orgx, orgy = G.bmaporgx, G.bmaporgy
  local xl, xh = (tmbbox[3] - orgx - MAXRADIUS) // BLOCK, (tmbbox[4] - orgx + MAXRADIUS) // BLOCK
  local yl, yh = (tmbbox[2] - orgy - MAXRADIUS) // BLOCK, (tmbbox[1] - orgy + MAXRADIUS) // BLOCK
  for bx = xl, xh do
    for by = yl, yh do
      if not blockThingsIterator(bx, by, checkThing) then return false end
    end
  end

  xl, xh = (tmbbox[3] - orgx) // BLOCK, (tmbbox[4] - orgx) // BLOCK
  yl, yh = (tmbbox[2] - orgy) // BLOCK, (tmbbox[1] - orgy) // BLOCK
  for bx = xl, xh do
    for by = yl, yh do
      if not blockLinesIterator(bx, by, checkLine) then return false end
    end
  end

  return true
end

P.CheckPosition = checkPosition

local function tryMove(thing: any, x: number, y: number): boolean
  P.floatok = false
  if not checkPosition(thing, x, y) then return false end

  local flags = thing.flags
  if band(flags, P.MF_NOCLIP) == 0 then
    if P.tmceilingz - P.tmfloorz < thing.height then return false end

    P.floatok = true
    local teleport = band(flags, P.MF_TELEPORT) ~= 0
    if not teleport and P.tmceilingz - thing.z < thing.height then return false end
    if not teleport and P.tmfloorz - thing.z > 24 * FRACUNIT then return false end
    if band(flags, P.MF_DROPOFF + P.MF_FLOAT) == 0 and P.tmfloorz - P.tmdropoffz > 24 * FRACUNIT then return false end
  end

  P.UnsetThingPosition(thing)
  local oldx, oldy = thing.x, thing.y
  thing.floorz, thing.ceilingz = P.tmfloorz, P.tmceilingz
  thing.x, thing.y = x, y
  P.SetThingPosition(thing)

  if band(thing.flags, P.MF_TELEPORT + P.MF_NOCLIP) == 0 then
    while P.numspechit > 0 do
      local line = spechit[P.numspechit]
      P.numspechit -= 1
      local side, oldside = pointOnLineSide(thing.x, thing.y, line), pointOnLineSide(oldx, oldy, line)
      if side ~= oldside and line.special ~= 0 then P.CrossSpecialLine(line, oldside, thing) end
    end
  end

  return true
end

P.TryMove = tryMove

local function thingHeightClip(thing: any): boolean
  local onfloor = thing.z == thing.floorz
  checkPosition(thing, thing.x, thing.y)
  thing.floorz, thing.ceilingz = P.tmfloorz, P.tmceilingz

  if onfloor then
    thing.z = thing.floorz
  elseif thing.z + thing.height > thing.ceilingz then
    thing.z = thing.ceilingz - thing.height
  end

  return thing.ceilingz - thing.floorz >= thing.height
end

-- Sliding along walls.
local bestslidefrac, bestslideline = 0, nil :: any
local slidemo: any
local tmxmove, tmymove = 0, 0

local function hitSlideLine(line: any): ()
  if line.slopetype == 0 then
    tmymove = 0
    return
  end

  if line.slopetype == 1 then
    tmxmove = 0
    return
  end

  local side = pointOnLineSide(slidemo.x, slidemo.y, line)
  local lineangle = P.PointToAngle2(0, 0, line.dx, line.dy)
  if side == 1 then lineangle = (lineangle + 0x80000000) % 4294967296 end

  local moveangle = P.PointToAngle2(0, 0, tmxmove, tmymove)
  local deltaangle = (moveangle - lineangle) % 4294967296
  if deltaangle > 0x80000000 then deltaangle = (deltaangle + 0x80000000) % 4294967296 end

  local lineFine, deltaFine = lineangle // 524288, deltaangle // 524288
  local movelen = P.AproxDistance(tmxmove, tmymove)
  local newlen = FixedMul(movelen, finesine[deltaFine + 2049])
  tmxmove = FixedMul(newlen, finesine[lineFine + 2049])
  tmymove = FixedMul(newlen, finesine[lineFine + 1])
end

local function slideTraverse(frac: number, line: any, _thing: any): boolean
  local blocking = false
  if band(line.flags, 4) == 0 then
    if pointOnLineSide(slidemo.x, slidemo.y, line) ~= 0 then return true end
    blocking = true
  else
    lineOpening(line)
    blocking = P.openrange < slidemo.height
      or P.opentop - slidemo.z < slidemo.height
      or P.openbottom - slidemo.z > 24 * FRACUNIT
  end

  if not blocking then return true end

  if frac < bestslidefrac then
    bestslidefrac = frac
    bestslideline = line
  end

  return false
end

local function stairstep(mo: any): ()
  if not tryMove(mo, mo.x, mo.y + mo.momy) then tryMove(mo, mo.x + mo.momx, mo.y) end
end

function P.SlideMove(mo: any): ()
  slidemo = mo
  local hitcount = 0
  while true do
    hitcount += 1
    if hitcount == 3 then return stairstep(mo) end

    local leadx, trailx, leady, traily
    if mo.momx > 0 then
      leadx, trailx = mo.x + mo.radius, mo.x - mo.radius
    else
      leadx, trailx = mo.x - mo.radius, mo.x + mo.radius
    end

    if mo.momy > 0 then
      leady, traily = mo.y + mo.radius, mo.y - mo.radius
    else
      leady, traily = mo.y - mo.radius, mo.y + mo.radius
    end

    bestslidefrac = FRACUNIT + 1
    pathTraverse(leadx, leady, leadx + mo.momx, leady + mo.momy, PT_ADDLINES, slideTraverse)
    pathTraverse(trailx, leady, trailx + mo.momx, leady + mo.momy, PT_ADDLINES, slideTraverse)
    pathTraverse(leadx, traily, leadx + mo.momx, traily + mo.momy, PT_ADDLINES, slideTraverse)

    if bestslidefrac == FRACUNIT + 1 then return stairstep(mo) end

    bestslidefrac -= 0x800
    if bestslidefrac > 0 then
      local newx, newy = FixedMul(mo.momx, bestslidefrac), FixedMul(mo.momy, bestslidefrac)
      if not tryMove(mo, mo.x + newx, mo.y + newy) then return stairstep(mo) end
    end

    bestslidefrac = FRACUNIT - (bestslidefrac + 0x800)
    if bestslidefrac > FRACUNIT then bestslidefrac = FRACUNIT end
    if bestslidefrac <= 0 then return end

    tmxmove, tmymove = FixedMul(mo.momx, bestslidefrac), FixedMul(mo.momy, bestslidefrac)
    hitSlideLine(bestslideline)
    mo.momx, mo.momy = tmxmove, tmymove
    if tryMove(mo, mo.x + tmxmove, mo.y + tmymove) then return end
  end
end

-- Hitscan.
local shootthing: any
local shootz, la_damage, aimslope = 0, 0, 0
local topslope, bottomslope = 0, 0

P.linetarget = nil
P.attackrange = 0

local function aimTraverse(frac: number, line: any, thing: any): boolean
  if line then
    if band(line.flags, 4) == 0 then return false end

    lineOpening(line)
    if P.openbottom >= P.opentop then return false end

    local dist = FixedMul(P.attackrange, frac)
    if line.frontsector.floorheight ~= line.backsector.floorheight then
      local slope = FixedDiv(P.openbottom - shootz, dist)
      if slope > bottomslope then bottomslope = slope end
    end

    if line.frontsector.ceilingheight ~= line.backsector.ceilingheight then
      local slope = FixedDiv(P.opentop - shootz, dist)
      if slope < topslope then topslope = slope end
    end

    return topslope > bottomslope
  end

  if thing == shootthing then return true end
  if band(thing.flags, MF_SHOOTABLE) == 0 then return true end

  local dist = FixedMul(P.attackrange, frac)
  local thingtopslope = FixedDiv(thing.z + thing.height - shootz, dist)
  if thingtopslope < bottomslope then return true end

  local thingbottomslope = FixedDiv(thing.z - shootz, dist)
  if thingbottomslope > topslope then return true end

  if thingtopslope > topslope then thingtopslope = topslope end
  if thingbottomslope < bottomslope then thingbottomslope = bottomslope end
  aimslope = idiv(thingtopslope + thingbottomslope, 2)
  P.linetarget = thing
  return false
end

local function shootTraverse(frac: number, line: any, thing: any): boolean
  local attackrange = P.attackrange
  if line then
    if line.special ~= 0 then P.ShootSpecialLine(shootthing, line) end

    local hit = band(line.flags, 4) == 0
    if not hit then
      lineOpening(line)
      local dist = FixedMul(attackrange, frac)
      if line.frontsector.floorheight ~= line.backsector.floorheight then
        if FixedDiv(P.openbottom - shootz, dist) > aimslope then hit = true end
      end

      if not hit and line.frontsector.ceilingheight ~= line.backsector.ceilingheight then
        if FixedDiv(P.opentop - shootz, dist) < aimslope then hit = true end
      end

      if not hit then return true end
    end

    frac -= FixedDiv(4 * FRACUNIT, attackrange)
    local x, y = traceX + FixedMul(traceDx, frac), traceY + FixedMul(traceDy, frac)
    local z = shootz + FixedMul(aimslope, FixedMul(frac, attackrange))
    if line.frontsector.ceilingpic == 'F_SKY1' then
      if z > line.frontsector.ceilingheight then return false end
      if line.backsector and line.backsector.ceilingpic == 'F_SKY1' then return false end
    end

    P.SpawnPuff(x, y, z)
    return false
  end

  if thing == shootthing then return true end
  if band(thing.flags, MF_SHOOTABLE) == 0 then return true end

  local dist = FixedMul(attackrange, frac)
  if FixedDiv(thing.z + thing.height - shootz, dist) < aimslope then return true end
  if FixedDiv(thing.z - shootz, dist) > aimslope then return true end

  frac -= FixedDiv(10 * FRACUNIT, attackrange)
  local x, y = traceX + FixedMul(traceDx, frac), traceY + FixedMul(traceDy, frac)
  local z = shootz + FixedMul(aimslope, FixedMul(frac, attackrange))
  if band(thing.flags, P.MF_NOBLOOD) ~= 0 then
    P.SpawnPuff(x, y, z)
  else
    P.SpawnBlood(x, y, z, la_damage)
  end

  if la_damage ~= 0 then P.DamageMobj(thing, shootthing, shootthing, la_damage) end
  return false
end

function P.AimLineAttack(t1: any, angle: number, distance: number): number
  local fine = angle // 524288
  shootthing = t1
  local x2 = t1.x + (distance // 65536) * finesine[fine + 2049]
  local y2 = t1.y + (distance // 65536) * finesine[fine + 1]
  shootz = t1.z + t1.height // 2 + 8 * FRACUNIT
  topslope, bottomslope = 40960, -40960
  P.attackrange = distance
  P.linetarget = nil
  pathTraverse(t1.x, t1.y, x2, y2, PT_ADDLINES + PT_ADDTHINGS, aimTraverse)
  return if P.linetarget then aimslope else 0
end

function P.LineAttack(t1: any, angle: number, distance: number, slope: number, damage: number): ()
  local fine = angle // 524288
  shootthing = t1
  la_damage = damage
  local x2 = t1.x + (distance // 65536) * finesine[fine + 2049]
  local y2 = t1.y + (distance // 65536) * finesine[fine + 1]
  shootz = t1.z + t1.height // 2 + 8 * FRACUNIT
  P.attackrange = distance
  aimslope = slope
  pathTraverse(t1.x, t1.y, x2, y2, PT_ADDLINES + PT_ADDTHINGS, shootTraverse)
end

local usething: any

local function useTraverse(_frac: number, line: any, _thing: any): boolean
  if line.special == 0 then
    lineOpening(line)
    return P.openrange > 0
  end

  local side = if pointOnLineSide(usething.x, usething.y, line) == 1 then 1 else 0
  P.UseSpecialLine(usething, line, side)
  return false
end

function P.UseLines(player: any): ()
  usething = player.mo
  local fine = player.mo.angle // 524288
  local x1, y1 = player.mo.x, player.mo.y
  local x2, y2 = x1 + 64 * finesine[fine + 2049], y1 + 64 * finesine[fine + 1]
  pathTraverse(x1, y1, x2, y2, PT_ADDLINES, useTraverse)
end

local bombsource: any, bombspot: any
local bombdamage = 0

local function radiusAttack(thing: any): boolean
  if band(thing.flags, MF_SHOOTABLE) == 0 then return true end
  if thing.type == MT.MT_CYBORG or thing.type == MT.MT_SPIDER then return true end

  local dx, dy = math.abs(thing.x - bombspot.x), math.abs(thing.y - bombspot.y)
  local dist = ((if dx > dy then dx else dy) - thing.radius) // 65536
  if dist < 0 then dist = 0 end
  if dist >= bombdamage then return true end

  if P.CheckSight(thing, bombspot) then P.DamageMobj(thing, bombspot, bombsource, bombdamage - dist) end
  return true
end

function P.RadiusAttack(spot: any, source: any, damage: number): ()
  local dist = (damage + 32) * FRACUNIT
  local yh, yl = (spot.y + dist - G.bmaporgy) // BLOCK, (spot.y - dist - G.bmaporgy) // BLOCK
  local xh, xl = (spot.x + dist - G.bmaporgx) // BLOCK, (spot.x - dist - G.bmaporgx) // BLOCK
  bombspot, bombsource, bombdamage = spot, source, damage
  for y = yl, yh do
    for x = xl, xh do
      blockThingsIterator(x, y, radiusAttack)
    end
  end
end

local crushchange, nofit = false, false

local function changeSector(thing: any): boolean
  if thingHeightClip(thing) then return true end

  if thing.health <= 0 then
    P.SetMobjState(thing, S.S_GIBS)
    thing.flags = band(thing.flags, bit32.bnot(MF_SOLID))
    thing.height, thing.radius = 0, 0
    return true
  end

  if band(thing.flags, P.MF_DROPPED) ~= 0 then
    P.RemoveMobj(thing)
    return true
  end

  if band(thing.flags, MF_SHOOTABLE) == 0 then return true end

  nofit = true
  if crushchange and G.leveltime % 4 == 0 then
    P.DamageMobj(thing, nil, nil, 10)
    local mo = P.SpawnMobj(thing.x, thing.y, thing.z + idiv(thing.height, 2), MT.MT_BLOOD)
    mo.momx = P.SubRandom() * 4096
    mo.momy = P.SubRandom() * 4096
  end

  return true
end

function P.ChangeSector(sector: any, crunch: boolean): boolean
  nofit, crushchange = false, crunch
  local box = sector.blockbox
  for x = box[3], box[4] do
    for y = box[2], box[1] do
      blockThingsIterator(x, y, changeSector)
    end
  end

  return nofit
end

-- Line of sight (p_sight.c). P_CrossBSPNode's walk runs over the flat BSP (see ./flat): the
-- near side of each partition first, the far side only when the target lies across it, and the
-- far sides still owed wait on a stack instead of the call stack.
local farSides: { number } = table.create(64, 0)

-- P_DivlineSide for a line passed as scalars: 0 in front, 1 behind, 2 on it.
local function divlineSide(
  pointX: number,
  pointY: number,
  lineX: number,
  lineY: number,
  lineDx: number,
  lineDy: number
): number
  if lineDx == 0 then
    if pointX == lineX then return 2 end
    if pointX <= lineX then return if lineDy > 0 then 1 else 0 end
    return if lineDy < 0 then 1 else 0
  end

  if lineDy == 0 then
    -- The original compares x against the line's y here.
    if pointX == lineY then return 2 end
    if pointY <= lineY then return if lineDx < 0 then 1 else 0 end
    return if lineDx > 0 then 1 else 0
  end

  local left = (lineDy // 65536) * ((pointX - lineX) // 65536)
  local right = ((pointY - lineY) // 65536) * (lineDx // 65536)
  if right < left then return 0 end
  if left == right then return 2 end
  return 1
end

function P.CheckSight(t1: any, t2: any): boolean
  local pnum = t1.subsector.sector.index * #G.sectors + t2.subsector.sector.index
  local bytenum = pnum // 8
  if bytenum < buffer.len(G.reject) and band(buffer.readu8(G.reject, bytenum), bit32.lshift(1, pnum % 8)) ~= 0 then
    return false
  end

  G.validcount += 1

  local validcount = G.validcount
  local eye = t1.z + t1.height - t1.height // 4
  topslope = t2.z + t2.height - eye
  bottomslope = t2.z - eye

  local fromX, fromY, toX, toY = t1.x, t1.y, t2.x, t2.y
  local deltaX, deltaY = toX - fromX, toY - fromY
  local wholeDeltaX, wholeDeltaY = deltaX // 65536, deltaY // 65536
  local slanted = deltaX ~= 0 and deltaY ~= 0
  local {subsectors, segs} = G
  local count = #G.nodes
  local nodes = flat.nodes(G.nodes)
  local lineEnds, segLines = flat.segs(segs)
  local owed = 0
  local child = if count == 0 then 0x8000 else count - 1
  while true do
    -- P_CrossBSPNode: P_DivlineSide of the viewer and of the target against each partition, the
    -- viewer's 2 (on the line) already taken for the front.
    while child < 0x8000 do
      local at = child * 64
      local lineX, lineY = buffer.readf64(nodes, at), buffer.readf64(nodes, at + 8)
      local lineDx, lineDy = buffer.readf64(nodes, at + 16), buffer.readf64(nodes, at + 24)
      local side, across = 0, 2
      if lineDx == 0 then
        if fromX < lineX then
          side = if lineDy > 0 then 1 else 0
        elseif fromX > lineX then
          side = if lineDy < 0 then 1 else 0
        end

        if toX < lineX then
          across = if lineDy > 0 then 1 else 0
        elseif toX > lineX then
          across = if lineDy < 0 then 1 else 0
        end
      elseif lineDy == 0 then
        if fromX ~= lineY then
          if fromY <= lineY then side = if lineDx < 0 then 1 else 0 else side = if lineDx > 0 then 1 else 0 end
        end

        if toX ~= lineY then
          if toY <= lineY then across = if lineDx < 0 then 1 else 0 else across = if lineDx > 0 then 1 else 0 end
        end
      else
        local wholeDx, wholeDy = buffer.readf64(nodes, at + 32), buffer.readf64(nodes, at + 40)
        local left = wholeDy * ((fromX - lineX) // 65536)
        local right = ((fromY - lineY) // 65536) * wholeDx
        if right > left then side = 1 end

        left = wholeDy * ((toX - lineX) // 65536)
        right = ((toY - lineY) // 65536) * wholeDx
        if right < left then
          across = 0
        elseif right > left then
          across = 1
        end
      end

      if across ~= side then
        owed += 1
        farSides[owed] = buffer.readf64(nodes, at + 56 - side * 8)
      end

      child = buffer.readf64(nodes, at + 48 + side * 8)
    end

    -- P_CrossSubsector.
    local sub = subsectors[child - 0x8000 + 1]
    local first = sub.firstline
    for index = first + 1, first + sub.numlines do
      local line = segLines[index]
      if line.validcount == validcount then continue end

      line.validcount = validcount

      local at = (index - 1) * 32
      local startX, startY = buffer.readf64(lineEnds, at), buffer.readf64(lineEnds, at + 8)
      local endX, endY = buffer.readf64(lineEnds, at + 16), buffer.readf64(lineEnds, at + 24)
      local startSide, endSide = 2, 2
      if slanted then
        local left = wholeDeltaY * ((startX - fromX) // 65536)
        local right = ((startY - fromY) // 65536) * wholeDeltaX
        if right < left then
          startSide = 0
        elseif right > left then
          startSide = 1
        end

        left = wholeDeltaY * ((endX - fromX) // 65536)
        right = ((endY - fromY) // 65536) * wholeDeltaX
        if right < left then
          endSide = 0
        elseif right > left then
          endSide = 1
        end
      else
        startSide = divlineSide(startX, startY, fromX, fromY, deltaX, deltaY)
        endSide = divlineSide(endX, endY, fromX, fromY, deltaX, deltaY)
      end

      if startSide == endSide then continue end

      local lineDx, lineDy = endX - startX, endY - startY
      local viewerSide = divlineSide(fromX, fromY, startX, startY, lineDx, lineDy)
      if viewerSide == divlineSide(toX, toY, startX, startY, lineDx, lineDy) then continue end
      if band(line.flags, 4) == 0 then return false end

      local seg = segs[index]
      local front, back = seg.frontsector, seg.backsector
      if front.floorheight == back.floorheight and front.ceilingheight == back.ceilingheight then continue end

      local opentop = if front.ceilingheight < back.ceilingheight then front.ceilingheight else back.ceilingheight
      local openbottom = if front.floorheight > back.floorheight then front.floorheight else back.floorheight
      if openbottom >= opentop then return false end

      local frac = interceptVector(fromX, fromY, deltaX, deltaY, startX, startY, lineDx, lineDy)
      if front.floorheight ~= back.floorheight then
        local slope = FixedDiv(openbottom - eye, frac)
        if slope > bottomslope then bottomslope = slope end
      end

      if front.ceilingheight ~= back.ceilingheight then
        local slope = FixedDiv(opentop - eye, frac)
        if slope < topslope then topslope = slope end
      end

      if topslope <= bottomslope then return false end
    end

    if owed == 0 then return true end

    child = farSides[owed]
    owed -= 1
  end
end

return P
