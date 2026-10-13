--!nonstrict
--!native
-- Shared state, arithmetic, and level setup for the Linux Doom 1.10 play
-- simulation (m_fixed.c, m_random.c, tables.c, r_main.c, p_setup.c, p_tick.c).
-- Every other play module adds its functions to the table returned here, the
-- way the C sources share one set of globals.
local flat = require('./flat')
local info = require('./info')
local tables = require('../tables')
local randomModule = require('../random')

local P: any = {}

-- G is the mutable game: everything a save holds. It is one table for the life
-- of the process; a new game clears it rather than replacing it.
local G: any = {}

P.G = G
P.S, P.MT, P.states, P.mobjinfo = info.S, info.MT, info.states, info.mobjinfo

local U32 = 4294967296
local FRACUNIT = 65536

P.FRACUNIT = FRACUNIT
P.MAXINT, P.MININT = 2147483647, -2147483648
P.ANG45, P.ANG90, P.ANG180, P.ANG270 = 0x20000000, 0x40000000, 0x80000000, 0xC0000000
P.MAXRADIUS = 32 * FRACUNIT
P.MAPBLOCKSHIFT = 23
P.ONFLOORZ, P.ONCEILINGZ = -2147483648, 2147483647
P.VIEWHEIGHT = 41 * FRACUNIT
P.MELEERANGE, P.MISSILERANGE, P.USERANGE = 64 * FRACUNIT, 32 * 64 * FRACUNIT, 64 * FRACUNIT
P.GRAVITY, P.MAXMOVE, P.FLOATSPEED = FRACUNIT, 30 * FRACUNIT, 4 * FRACUNIT
P.TICRATE = 35

P.ML_BLOCKING, P.ML_BLOCKMONSTERS, P.ML_TWOSIDED, P.ML_SECRET, P.ML_SOUNDBLOCK = 1, 2, 4, 32, 64
P.ST_HORIZONTAL, P.ST_VERTICAL, P.ST_POSITIVE, P.ST_NEGATIVE = 0, 1, 2, 3
P.BOXTOP, P.BOXBOTTOM, P.BOXLEFT, P.BOXRIGHT = 1, 2, 3, 4

P.MF_SPECIAL, P.MF_SOLID, P.MF_SHOOTABLE, P.MF_NOSECTOR, P.MF_NOBLOCKMAP = 1, 2, 4, 8, 16
P.MF_AMBUSH, P.MF_JUSTHIT, P.MF_JUSTATTACKED, P.MF_SPAWNCEILING, P.MF_NOGRAVITY = 32, 64, 128, 256, 512
P.MF_DROPOFF, P.MF_PICKUP, P.MF_NOCLIP, P.MF_SLIDE, P.MF_FLOAT = 0x400, 0x800, 0x1000, 0x2000, 0x4000
P.MF_TELEPORT, P.MF_MISSILE, P.MF_DROPPED, P.MF_SHADOW, P.MF_NOBLOOD = 0x8000, 0x10000, 0x20000, 0x40000, 0x80000
P.MF_CORPSE, P.MF_INFLOAT, P.MF_COUNTKILL, P.MF_COUNTITEM = 0x100000, 0x200000, 0x400000, 0x800000
P.MF_SKULLFLY, P.MF_NOTDMATCH, P.MF_TRANSSHIFT = 0x1000000, 0x2000000, 26

P.PST_LIVE, P.PST_DEAD, P.PST_REBORN = 0, 1, 2
P.CF_NOCLIP, P.CF_GODMODE, P.CF_NOMOMENTUM = 1, 2, 4
P.BT_ATTACK, P.BT_USE, P.BT_CHANGE, P.BT_WEAPONMASK, P.BT_WEAPONSHIFT, P.BT_SPECIAL = 1, 2, 4, 56, 3, 128

P.pw_invulnerability, P.pw_strength, P.pw_invisibility, P.pw_ironfeet, P.pw_allmap, P.pw_infrared = 0, 1, 2, 3, 4, 5
P.INVULNTICS, P.INVISTICS, P.INFRATICS, P.IRONTICS = 30 * 35, 60 * 35, 120 * 35, 60 * 35

P.wp_fist, P.wp_pistol, P.wp_shotgun, P.wp_chaingun, P.wp_missile = 0, 1, 2, 3, 4
P.wp_plasma, P.wp_bfg, P.wp_chainsaw, P.wp_supershotgun, P.wp_nochange = 5, 6, 7, 8, 10
P.am_clip, P.am_shell, P.am_cell, P.am_misl, P.am_noammo = 0, 1, 2, 3, 5
P.clipammo = { [0] = 10, 4, 20, 1 }
P.maxammo = { [0] = 200, 50, 300, 50 }
P.sk_baby, P.sk_easy, P.sk_medium, P.sk_hard, P.sk_nightmare = 0, 1, 2, 3, 4

local S = info.S

local function weapon(ammo: number, up: number, down: number, ready: number, atk: number, flash: number): any
  return { ammo = ammo, upstate = up, downstate = down, readystate = ready, atkstate = atk, flashstate = flash }
end

P.weaponinfo = {
  [0] = weapon(5, S.S_PUNCHUP, S.S_PUNCHDOWN, S.S_PUNCH, S.S_PUNCH1, S.S_NULL),
  weapon(0, S.S_PISTOLUP, S.S_PISTOLDOWN, S.S_PISTOL, S.S_PISTOL1, S.S_PISTOLFLASH),
  weapon(1, S.S_SGUNUP, S.S_SGUNDOWN, S.S_SGUN, S.S_SGUN1, S.S_SGUNFLASH1),
  weapon(0, S.S_CHAINUP, S.S_CHAINDOWN, S.S_CHAIN, S.S_CHAIN1, S.S_CHAINFLASH1),
  weapon(3, S.S_MISSILEUP, S.S_MISSILEDOWN, S.S_MISSILE, S.S_MISSILE1, S.S_MISSILEFLASH1),
  weapon(2, S.S_PLASMAUP, S.S_PLASMADOWN, S.S_PLASMA, S.S_PLASMA1, S.S_PLASMAFLASH1),
  weapon(2, S.S_BFGUP, S.S_BFGDOWN, S.S_BFG, S.S_BFG1, S.S_BFGFLASH1),
  weapon(5, S.S_SAWUP, S.S_SAWDOWN, S.S_SAW, S.S_SAW1, S.S_NULL),
  weapon(1, S.S_DSGUNUP, S.S_DSGUNDOWN, S.S_DSGUN, S.S_DSGUN1, S.S_DSGUNFLASH1),
}

local finesine, finetangent, tantoangle = tables.finesine, tables.finetangent, tables.tantoangle

P.finesine, P.finetangent, P.tantoangle = finesine, finetangent, tantoangle

local function i32(value: number): number
  value %= U32
  return if value >= 2147483648 then value - U32 else value
end

-- ((int64)a * b) >> 16, exact in doubles by splitting b into 16-bit limbs.
local function FixedMul(a: number, b: number): number
  local high = b // 65536
  local result = a * high + (a * (b - high * 65536)) // 65536
  if result >= 2147483648 or result < -2147483648 then return i32(result) end
  return result
end

local function FixedDiv(a: number, b: number): number
  if math.abs(a) // 16384 >= math.abs(b) then return if (a < 0) ~= (b < 0) then -2147483648 else 2147483647 end

  local c = a / b * 65536
  return if c < 0 then math.ceil(c) else math.floor(c)
end

-- C integer division: truncates toward zero.
local function idiv(a: number, b: number): number
  local c = a / b
  return if c < 0 then math.ceil(c) else math.floor(c)
end

local function sine(angle: number): number
  return finesine[angle // 524288 + 1]
end

local function cosine(angle: number): number
  return finesine[angle // 524288 + 2049]
end

P.i32, P.FixedMul, P.FixedDiv, P.idiv, P.sine, P.cosine = i32, FixedMul, FixedDiv, idiv, sine, cosine

local rndtable = randomModule.rndTable

function P.Random(): number
  local index = (G.prndindex + 1) % 256
  G.prndindex = index
  return rndtable[index + 1]
end

-- M_Random only feeds presentation in the original; here it backs the few
-- gameplay callers (light flicker, switch timing never uses it).
function P.MRandom(): number
  local index = (G.rndindex + 1) % 256
  G.rndindex = index
  return rndtable[index + 1]
end

function P.SubRandom(): number
  local first = P.Random()
  return first - P.Random()
end

function P.AproxDistance(dx: number, dy: number): number
  dx, dy = math.abs(dx), math.abs(dy)
  if dx < dy then return dx + dy - dx // 2 end
  return dx + dy - dy // 2
end

local function slopeDiv(num: number, den: number): number
  if den < 512 then return 2048 end

  local ans = (num * 8) // (den // 256)
  return if ans <= 2048 then ans else 2048
end

function P.PointToAngle2(x1: number, y1: number, x2: number, y2: number): number
  local x, y = x2 - x1, y2 - y1
  if x == 0 and y == 0 then return 0 end

  if x >= 0 then
    if y >= 0 then
      if x > y then return tantoangle[slopeDiv(y, x) + 1] end
      return 0x40000000 - 1 - tantoangle[slopeDiv(x, y) + 1]
    end

    y = -y
    if x > y then return (-tantoangle[slopeDiv(y, x) + 1]) % U32 end
    return 0xC0000000 + tantoangle[slopeDiv(x, y) + 1]
  end

  x = -x
  if y >= 0 then
    if x > y then return 0x80000000 - 1 - tantoangle[slopeDiv(y, x) + 1] end
    return 0x40000000 + tantoangle[slopeDiv(x, y) + 1]
  end

  y = -y
  if x > y then return 0x80000000 + tantoangle[slopeDiv(y, x) + 1] end
  return 0xC0000000 - 1 - tantoangle[slopeDiv(x, y) + 1]
end

-- R_PointInSubsector over the flat BSP (see ./flat for a node's layout), with R_PointOnSide
-- written into the walk: `back` is its answer of 1.
function P.PointInSubsector(x: number, y: number): any
  local count = #G.nodes
  if count == 0 then return G.subsectors[1] end

  local nodes = flat.nodes(G.nodes)
  local child = count - 1
  while child < 0x8000 do
    local at = child * 64
    local lineDx, lineDy = buffer.readf64(nodes, at + 16), buffer.readf64(nodes, at + 24)
    local back
    if lineDx == 0 then
      if x <= buffer.readf64(nodes, at) then back = lineDy > 0 else back = lineDy < 0 end
    elseif lineDy == 0 then
      if y <= buffer.readf64(nodes, at + 8) then back = lineDx < 0 else back = lineDx > 0 end
    else
      local dx, dy = x - buffer.readf64(nodes, at), y - buffer.readf64(nodes, at + 8)
      if (lineDy < 0) ~= (lineDx < 0) ~= (dx < 0) ~= (dy < 0) then
        back = (lineDy < 0) ~= (dx < 0)
      else
        local right = FixedMul(dy, buffer.readf64(nodes, at + 32))
        back = right >= FixedMul(buffer.readf64(nodes, at + 40), dx)
      end
    end

    child = buffer.readf64(nodes, if back then at + 56 else at + 48)
  end

  return G.subsectors[child - 0x8000 + 1]
end

-- Thinkers form the original doubly linked ring around a sentinel. A removed
-- thinker has think == false and is unlinked the next time the ring runs.
P.think = {}

function P.InitThinkers(): ()
  local cap: any = {}
  cap.prev, cap.next = cap, cap
  G.thinkercap = cap
end

function P.AddThinker(thinker: any): ()
  local cap = G.thinkercap
  cap.prev.next = thinker
  thinker.next = cap
  thinker.prev = cap.prev
  cap.prev = thinker
end

function P.RemoveThinker(thinker: any): ()
  thinker.think = false
end

function P.RunThinkers(): ()
  local cap, think = G.thinkercap, P.think
  local current = cap.next
  while current ~= cap do
    local kind = current.think
    if kind == false then
      current.next.prev = current.prev
      current.prev.next = current.next
    elseif kind then
      think[kind](current)
    end

    current = current.next
  end
end

local function name8(data: buffer, at: number): string
  local text = buffer.readstring(data, at, 8)
  local zero = string.find(text, '\0', 1, true)
  if zero then text = string.sub(text, 1, zero - 1) end
  return string.upper(text)
end

-- Texture numbers and heights in TEXTURE1 then TEXTURE2 order, as R_InitTextures
-- numbers them; '-' is 0.
local function loadTextures(wad: any): any
  local numbers, heights, names = {}, {}, {}
  local count = 0
  for _, lumpName in { 'TEXTURE1', 'TEXTURE2' } do
    if not wad:find(lumpName) then continue end

    local data = wad:read(lumpName)
    for index = 0, buffer.readi32(data, 0) - 1 do
      local at = buffer.readi32(data, 4 + index * 4)
      local name = name8(data, at)
      if numbers[name] == nil then numbers[name] = count end
      names[count] = name
      heights[count] = buffer.readi16(data, at + 14) * FRACUNIT
      count += 1
    end
  end

  return { numbers = numbers, heights = heights, names = names, count = count }
end

function P.TextureNum(name: string): number
  if string.sub(name, 1, 1) == '-' then return 0 end
  return G.textures.numbers[name] or 0
end

function P.OpenWad(wad: any): ()
  if G.wad == wad then return end

  G.wad = wad
  G.textures = loadTextures(wad)
  G.commercial = wad:find('MAP01') ~= nil
end

local function loadGeometry(wad: any, marker: string): ()
  local function lump(name: string): buffer
    return wad:read(wad:mapLump(marker, name))
  end

  local data = lump('BLOCKMAP')
  local words = buffer.len(data) // 2
  G.bmaporgx, G.bmaporgy = buffer.readi16(data, 0) * FRACUNIT, buffer.readi16(data, 2) * FRACUNIT
  G.bmapwidth, G.bmapheight = buffer.readi16(data, 4), buffer.readi16(data, 6)
  local blockmap = data

  data = lump('VERTEXES')
  local vertexes = [for at in range(0, buffer.len(data) - 4, 4) => {
    x = buffer.readi16(data, at) * FRACUNIT,
    y = buffer.readi16(data, at + 2) * FRACUNIT,
  }]

  data = lump('SECTORS')
  local sectors = [for at in range(0, buffer.len(data) - 26, 26) => {
    index = at // 26,
    floorheight = buffer.readi16(data, at) * FRACUNIT,
    ceilingheight = buffer.readi16(data, at + 2) * FRACUNIT,
    floorpic = name8(data, at + 4),
    ceilingpic = name8(data, at + 12),
    lightlevel = buffer.readi16(data, at + 20),
    special = buffer.readi16(data, at + 22),
    tag = buffer.readi16(data, at + 24),
    soundtraversed = 0,
    validcount = 0,
    lines = {},
    blockbox = { 0, 0, 0, 0 },
  }]

  data = lump('SIDEDEFS')
  local sides = [for at in range(0, buffer.len(data) - 30, 30) => {
    textureoffset = buffer.readi16(data, at) * FRACUNIT,
    rowoffset = buffer.readi16(data, at + 2) * FRACUNIT,
    toptexture = P.TextureNum(name8(data, at + 4)),
    bottomtexture = P.TextureNum(name8(data, at + 12)),
    midtexture = P.TextureNum(name8(data, at + 20)),
    sector = sectors[buffer.readi16(data, at + 28) + 1],
  }]

  data = lump('LINEDEFS')
  local lines = table.create(buffer.len(data) // 14)
  for at = 0, buffer.len(data) - 14, 14 do
    local v1, v2 = vertexes[buffer.readu16(data, at) + 1], vertexes[buffer.readu16(data, at + 2) + 1]
    local dx, dy = v2.x - v1.x, v2.y - v1.y
    local right, left = buffer.readi16(data, at + 10), buffer.readi16(data, at + 12)
    local slopetype
    if dx == 0 then
      slopetype = 1
    elseif dy == 0 then
      slopetype = 0
    elseif FixedDiv(dy, dx) > 0 then
      slopetype = 2
    else
      slopetype = 3
    end

    table.insert(lines, {
      index = #lines,
      v1 = v1,
      v2 = v2,
      dx = dx,
      dy = dy,
      flags = buffer.readi16(data, at + 4),
      special = buffer.readi16(data, at + 6),
      tag = buffer.readi16(data, at + 8),
      sidenum = { right, left },
      slopetype = slopetype,
      bbox = { math.max(v1.y, v2.y), math.min(v1.y, v2.y), math.min(v1.x, v2.x), math.max(v1.x, v2.x) },
      frontsector = if right ~= -1 then sides[right + 1].sector else nil,
      backsector = if left ~= -1 then sides[left + 1].sector else nil,
      validcount = 0,
    })
  end

  data = lump('SSECTORS')
  local subsectors = [for at in range(0, buffer.len(data) - 4, 4) => {
    numlines = buffer.readu16(data, at),
    firstline = buffer.readu16(data, at + 2),
  }]

  data = lump('NODES')
  local nodes = [for at in range(0, buffer.len(data) - 28, 28) => {
    x = buffer.readi16(data, at) * FRACUNIT,
    y = buffer.readi16(data, at + 2) * FRACUNIT,
    dx = buffer.readi16(data, at + 4) * FRACUNIT,
    dy = buffer.readi16(data, at + 6) * FRACUNIT,
    children = { buffer.readu16(data, at + 24), buffer.readu16(data, at + 26) },
  }]

  data = lump('SEGS')
  local segs = table.create(buffer.len(data) // 12)
  for at = 0, buffer.len(data) - 12, 12 do
    local line = lines[buffer.readu16(data, at + 6) + 1]
    local side = buffer.readi16(data, at + 8)
    local sidedef = sides[line.sidenum[side + 1] + 1]
    table.insert(segs, {
      v1 = vertexes[buffer.readu16(data, at) + 1],
      v2 = vertexes[buffer.readu16(data, at + 2) + 1],
      linedef = line,
      sidedef = sidedef,
      frontsector = sidedef.sector,
      backsector = if bit32.band(line.flags, 4) ~= 0 then sides[line.sidenum[2 - side] + 1].sector else nil,
    })
  end

  G.reject = lump('REJECT')
  G.vertexes, G.sectors, G.sides, G.lines = vertexes, sectors, sides, lines
  G.subsectors, G.nodes, G.segs = subsectors, nodes, segs

  -- P_GroupLines
  for _, subsector in subsectors do
    subsector.sector = segs[subsector.firstline + 1].sidedef.sector
  end

  local width, height = G.bmapwidth, G.bmapheight
  local boxes = {}
  for _, line in lines do
    for pass = 1, 2 do
      local sector = if pass == 1 then line.frontsector else line.backsector
      if not sector or (pass == 2 and sector == line.frontsector) then continue end

      table.insert(sector.lines, line)
      local box = boxes[sector]
      if not box then
        box = { -2147483648, 2147483647, 2147483647, -2147483648 }
        boxes[sector] = box
      end

      for _, vertex in { line.v1, line.v2 } do
        if vertex.x < box[3] then
          box[3] = vertex.x
        elseif vertex.x > box[4] then
          box[4] = vertex.x
        end

        if vertex.y < box[2] then
          box[2] = vertex.y
        elseif vertex.y > box[1] then
          box[1] = vertex.y
        end
      end
    end
  end

  for _, sector in sectors do
    local box = boxes[sector] or { 0, 0, 0, 0 }
    sector.soundorg = { x = idiv(box[4] + box[3], 2), y = idiv(box[1] + box[2], 2) }
    sector.blockbox[1] = math.min((box[1] - G.bmaporgy + P.MAXRADIUS) // 8388608, height - 1)
    sector.blockbox[2] = math.max((box[2] - G.bmaporgy - P.MAXRADIUS) // 8388608, 0)
    sector.blockbox[4] = math.min((box[4] - G.bmaporgx + P.MAXRADIUS) // 8388608, width - 1)
    sector.blockbox[3] = math.max((box[3] - G.bmaporgx - P.MAXRADIUS) // 8388608, 0)
  end

  -- Each block's line list, including the leading 0 entry the original
  -- iterator never skips (so linedef 0 is tested in every block).
  local blocklines = table.create(width * height)
  for cell = 0, width * height - 1 do
    local list = {}
    local at = buffer.readu16(blockmap, (4 + cell) * 2)
    while at < words do
      local number = buffer.readi16(blockmap, at * 2)
      if number == -1 then break end

      table.insert(list, lines[number + 1])
      at += 1
    end

    blocklines[cell + 1] = list
  end

  G.blocklines = blocklines
  G.blocklinks = {}
end

local NewMonsters = { [68] = true, [64] = true, [88] = true, [89] = true, [69] = true, [67] = true, [71] = true, [65] = true, [66] = true, [84] = true }

function P.SetupLevel(marker: string): ()
  local wad = G.wad
  G.totalkills, G.totalitems, G.totalsecret = 0, 0, 0
  for index = 0, 3 do
    local player = G.players[index]
    player.killcount, player.secretcount, player.itemcount = 0, 0, 0
  end

  G.players[G.consoleplayer].viewz = 1
  P.InitThinkers()
  G.leveltime = 0
  G.validcount = G.validcount or 1
  G.mapname = marker
  loadGeometry(wad, marker)

  G.bodyque, G.bodyqueslot = {}, 0
  G.deathmatchstarts, G.playerstarts = {}, {}
  G.itemrespawnque, G.itemrespawntime, G.iquehead, G.iquetail = {}, {}, 0, 0
  P.InitSpecialState()

  local data = wad:read(wad:mapLump(marker, 'THINGS'))
  for at = 0, buffer.len(data) - 10, 10 do
    local mthing = {
      x = buffer.readi16(data, at),
      y = buffer.readi16(data, at + 2),
      angle = buffer.readi16(data, at + 4),
      type = buffer.readi16(data, at + 6),
      options = buffer.readi16(data, at + 8),
    }
    if not G.commercial and NewMonsters[mthing.type] then break end
    P.SpawnMapThing(mthing)
  end

  if G.deathmatch ~= 0 then
    for index = 0, 3 do
      if G.playeringame[index] then
        G.players[index].mo = nil
        P.DeathMatchSpawnPlayer(index)
      end
    end
  end

  P.SpawnSpecials()
end

return P
