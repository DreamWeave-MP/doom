--!nonstrict
--!native
-- @doom/play: the Linux Doom 1.10 play simulation. One game per runtime, held
-- in `play.game`; the functions here are the host-facing surface over it.
local P: any = require('./core')
require('./pmap')
require('./pmobj')
require('./penemy')
require('./pspec')
require('./game')
require('./save')

local wadModule = require('../wad')
local demoModule = require('../demo')

local G = P.G
local FRACUNIT, U32 = 65536, 4294967296
local band = bit32.band

local module = {}

module.game = G
module.engine = P
module.BT_ATTACK, module.BT_USE, module.BT_CHANGE = 1, 2, 4

-- Starts a game on an opened WAD (or a path) and returns the game state.
function module.new(wad: any, options: any?): any
  if type(wad) == 'string' then wad = wadModule.open(wad) end
  P.InitNew(wad, options)
  return G
end

-- Runs one tic. `cmds` is indexed by slot, 0 to 3.
function module.tick(cmds: any?): ()
  P.Ticker(cmds)
end

export type Action = {
  forward: number?,
  side: number?,
  turn: number?,
  attack: boolean?,
  use: boolean?,
  weapon: number?,
}

-- Builds a ticcmd from plain values: forward and side in [-50, 50] (the run
-- speeds), turn in degrees for this tic (positive is left), and weapon as the
-- slot to switch to (0 fist to 8 super shotgun).
function module.command(action: Action): any
  local buttons = 0
  if action.attack then buttons += 1 end
  if action.use then buttons += 2 end
  if action.weapon then buttons += 4 + band(action.weapon, 7) * 8 end

  local turn = math.clamp(math.floor((action.turn or 0) * 65536 / 360 + 0.5), -32768, 32767)
  return {
    forwardmove = math.clamp(math.floor(action.forward or 0), -50, 50),
    sidemove = math.clamp(math.floor(action.side or 0), -50, 50),
    angleturn = turn,
    buttons = buttons,
  }
end

-- The whole game as bytes, and back. A restored game continues on the same WAD.
function module.save(): buffer
  return P.Save()
end

function module.load(wad: any, data: buffer): any
  if type(wad) == 'string' then wad = wadModule.open(wad) end
  P.Restore(wad, data)
  return G
end

local function mix(hash: number, value: number): number
  hash = bit32.bxor(hash, value % U32)
  return ((hash % 65536) * 16777619 + ((hash // 65536) * 16777619 % 65536) * 65536) % U32
end

-- A 32-bit digest of everything that steers the simulation: the random index,
-- every thinker in ring order, every player, and every sector's heights.
function module.hash(): string
  local hash = mix(2166136261, G.prndindex)
  hash = mix(hash, G.leveltime)

  local cap = G.thinkercap
  local thinker = cap.next
  while thinker ~= cap do
    if thinker.think == 'mobj' then
      hash = mix(hash, thinker.x)
      hash = mix(hash, thinker.y)
      hash = mix(hash, thinker.z)
      hash = mix(hash, thinker.angle)
      hash = mix(hash, thinker.momx)
      hash = mix(hash, thinker.momy)
      hash = mix(hash, thinker.momz)
      hash = mix(hash, thinker.health)
      hash = mix(hash, thinker.state)
      hash = mix(hash, thinker.tics)
      hash = mix(hash, thinker.flags)
      hash = mix(hash, thinker.type)
    end

    thinker = thinker.next
  end

  for index = 0, 3 do
    if not G.playeringame[index] then continue end

    local player = G.players[index]
    hash = mix(hash, player.health)
    hash = mix(hash, player.armorpoints)
    hash = mix(hash, player.readyweapon)
    hash = mix(hash, player.killcount)
    for ammo = 0, 3 do
      hash = mix(hash, player.ammo[ammo])
      hash = mix(hash, player.frags[ammo])
    end
  end

  for _, sector in G.sectors do
    hash = mix(hash, sector.floorheight)
    hash = mix(hash, sector.ceilingheight)
    hash = mix(hash, sector.lightlevel)
    hash = mix(hash, sector.special)
  end

  return string.format('%08x', hash)
end

-- Plays a demo lump (by name, or its bytes) from the start. Stops at the end
-- of the demo, when the level is left, or after `maxTics`.
function module.playDemo(wad: any, demo: string | buffer, maxTics: number?): any
  if type(wad) == 'string' then wad = wadModule.open(wad) end

  local data = if type(demo) == 'string' then wad:read(demo) else demo
  local header, frames = demoModule.parseFull(data)
  P.InitNew(wad, {
    skill = header.skill,
    episode = header.episode,
    map = header.map,
    deathmatch = header.deathmatch,
    respawn = header.respawn ~= 0,
    fast = header.fast ~= 0,
    nomonsters = header.nomonsters ~= 0,
    consoleplayer = header.consolePlayer,
    players = header.players,
    netgame = header.players[2],
  })

  local played = 0
  local cmds = {}
  for index = 1, math.min(#frames, maxTics or #frames) do
    local frame = frames[index]
    for slot = 0, 3 do
      cmds[slot] = frame[slot + 1]
    end

    P.Ticker(cmds)
    played = index
    if G.gamestate ~= 'level' then break end
  end

  return { header = header, tics = played, length = #frames, summary = module.summary() }
end

local WeaponNames = { [0] = 'fist', 'pistol', 'shotgun', 'chaingun', 'rocket launcher', 'plasma rifle', 'bfg', 'chainsaw', 'super shotgun' }
local AmmoNames = { [0] = 'bullets', 'shells', 'cells', 'rockets' }

module.WeaponNames, module.AmmoNames = WeaponNames, AmmoNames

local function degrees(angle: number): number
  return math.floor(angle * 3600 / U32 + 0.5) / 10
end

local function playerSummary(player: any): any
  local mo = player.mo
  local ammo = {}
  for index = 0, 3 do
    ammo[AmmoNames[index]] = player.ammo[index]
  end

  local weapons = [for index in range(0, 8) if player.weaponowned[index] => WeaponNames[index]]

  return {
    slot = player.index,
    alive = player.playerstate == P.PST_LIVE,
    health = player.health,
    armor = player.armorpoints,
    weapon = WeaponNames[player.readyweapon],
    weapons = weapons,
    ammo = ammo,
    x = mo and mo.x // FRACUNIT,
    y = mo and mo.y // FRACUNIT,
    z = mo and mo.z // FRACUNIT,
    angle = mo and degrees(mo.angle),
    kills = player.killcount,
    items = player.itemcount,
    secrets = player.secretcount,
    frags = { player.frags[0], player.frags[1], player.frags[2], player.frags[3] },
  }
end

function module.summary(): any
  local players = [for index in range(0, 3) if G.playeringame[index] => playerSummary(G.players[index])]

  return {
    map = G.mapname,
    gamestate = G.gamestate,
    gametic = G.gametic,
    leveltime = G.leveltime,
    totalkills = G.totalkills,
    totalitems = G.totalitems,
    totalsecret = G.totalsecret,
    hash = module.hash(),
    players = players,
  }
end

local ItemNames = {
  ARM1 = 'green armor',
  ARM2 = 'blue armor',
  BON1 = 'health bonus',
  BON2 = 'armor bonus',
  SOUL = 'soulsphere',
  MEGA = 'megasphere',
  STIM = 'stimpack',
  MEDI = 'medikit',
  PINV = 'invulnerability',
  PSTR = 'berserk',
  PINS = 'invisibility',
  SUIT = 'radiation suit',
  PMAP = 'computer map',
  PVIS = 'light goggles',
  CLIP = 'clip',
  AMMO = 'box of bullets',
  ROCK = 'rocket',
  BROK = 'box of rockets',
  CELL = 'cell',
  CELP = 'cell pack',
  SHEL = 'shells',
  SBOX = 'box of shells',
  BPAK = 'backpack',
  BFUG = 'bfg',
  MGUN = 'chaingun',
  CSAW = 'chainsaw',
  LAUN = 'rocket launcher',
  PLAS = 'plasma rifle',
  SHOT = 'shotgun',
  SGN2 = 'super shotgun',
  BKEY = 'blue key',
  YKEY = 'yellow key',
  RKEY = 'red key',
  BSKU = 'blue skull key',
  YSKU = 'yellow skull key',
  RSKU = 'red skull key',
}

local function category(mo: any): string
  if mo.player then return 'player' end

  local flags = mo.flags
  if band(flags, P.MF_MISSILE) ~= 0 then return 'missile' end
  if band(flags, P.MF_COUNTKILL) ~= 0 or mo.type == P.MT.MT_SKULL then return if mo.health > 0 then 'monster' else 'corpse' end
  if band(flags, P.MF_SPECIAL) ~= 0 then return 'item' end
  if band(flags, P.MF_CORPSE) ~= 0 then return 'corpse' end
  if band(flags, P.MF_SHOOTABLE) ~= 0 then return 'barrel' end
  return 'scenery'
end

-- How far a player-sized walk goes along `angle` before a wall, a closed door,
-- or a ledge too high to step stops it, capped at `range` map units.
local function clearance(mo: any, angle: number, range: number): (number, number)
  local fine = angle // 524288
  local x2 = mo.x + range * P.finesine[fine + 2049]
  local y2 = mo.y + range * P.finesine[fine + 1]
  local stopped, special = FRACUNIT, 0

  P.PathTraverse(mo.x, mo.y, x2, y2, P.PT_ADDLINES, function(frac: number, line: any, _thing: any): boolean
    local blocking = band(line.flags, 4) == 0 or band(line.flags, 1) ~= 0
    if not blocking then
      P.LineOpening(line)
      blocking = P.openrange < mo.height or P.opentop - mo.z < mo.height or P.openbottom - mo.z > 24 * FRACUNIT
    end

    if blocking and band(line.flags, 4) == 0 and P.PointOnLineSide(mo.x, mo.y, line) ~= 0 then return true end
    if line.special ~= 0 and special == 0 then special = line.special end
    if not blocking then return true end

    stopped = frac
    return false
  end)

  return math.floor(range * stopped / FRACUNIT), special
end

local Feelers = { 0, 20, -20, 45, -45, 90, -90, 135, -135, 180 }

-- What the player in `slot` can know: their own state, everything alive or
-- collectable in line of sight within `range` map units (bearing is degrees
-- left of where they face), and how far they can walk in each feeler direction.
function module.observe(slot: number, range: number?): any
  local player = G.players[slot]
  local mo = player.mo
  local view: any = playerSummary(player)
  view.map, view.gamestate, view.gametic, view.leveltime = G.mapname, G.gamestate, G.gametic, G.leveltime
  view.attacker = nil
  view.damaged = player.damagecount > 0
  if not mo or G.gamestate ~= 'level' then return view end

  local limit = (range or 1536) * FRACUNIT
  local things = {}
  local cap = G.thinkercap
  local other = cap.next
  while other ~= cap do
    if other.think == 'mobj' and other ~= mo then
      local kind = category(other)
      if kind ~= 'scenery' and kind ~= 'corpse' then
        local dist = P.AproxDistance(other.x - mo.x, other.y - mo.y)
        if dist <= limit and P.CheckSight(mo, other) then
          local bearing = degrees((P.PointToAngle2(mo.x, mo.y, other.x, other.y) - mo.angle) % U32)
          if bearing > 180 then bearing = math.floor((bearing - 360) * 10 + 0.5) / 10 end

          table.insert(things, {
            kind = kind,
            type = if kind == 'item' then ItemNames[other.sprite] or other.sprite else string.lower(string.sub(other.info.name, 4)),
            slot = if other.player then other.player.index else nil,
            distance = dist // FRACUNIT,
            bearing = bearing,
            height = (other.z - mo.z) // FRACUNIT,
            health = if kind == 'player' or kind == 'monster' then other.health else nil,
          })
        end
      end
    end

    other = other.next
  end

  table.sort(things, function(a: any, b: any): boolean
    return a.distance < b.distance
  end)

  local walls = {}
  for _, offset in Feelers do
    local angle = (mo.angle + offset * (U32 / 360)) % U32
    local distance, special = clearance(mo, math.floor(angle), 512)
    table.insert(walls, { bearing = offset, clear = distance, special = if special ~= 0 then special else nil })
  end

  view.things, view.walls = things, walls
  view.sectorSpecial = mo.subsector.sector.special
  return view
end

return module
