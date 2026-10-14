--!nonstrict
--!native
-- g_game.c and p_tick.c: the game loop around the play simulation. New games,
-- level loading, player rebirth and deathmatch spawns, level exits, the
-- intermission, and map progression.
local P: any = require('./core')

local G = P.G
local S, MT = P.S, P.MT
local FRACUNIT, U32 = 65536, 4294967296
local band = bit32.band
local BODYQUESIZE = 32

-- Nightmare and -fast rewrite shared state tables; this remembers whether the
-- tables currently hold the fast values.
local fastTables = false

local function setFastTables(fast: boolean): ()
  if fast == fastTables then return end

  fastTables = fast
  for index = S.S_SARG_RUN1, S.S_SARG_PAIN2 do
    local state = P.states[index]
    state.tics = if fast then state.tics // 2 else state.tics * 2
  end

  P.mobjinfo[MT.MT_BRUISERSHOT].speed = (if fast then 20 else 15) * FRACUNIT
  P.mobjinfo[MT.MT_HEADSHOT].speed = (if fast then 20 else 10) * FRACUNIT
  P.mobjinfo[MT.MT_TROOPSHOT].speed = (if fast then 20 else 10) * FRACUNIT
end

local function blankPlayer(player: any, index: number): ()
  local frags = player.frags or { [0] = 0, 0, 0, 0 }
  local killcount, itemcount, secretcount = player.killcount or 0, player.itemcount or 0, player.secretcount or 0
  table.clear(player)

  player.index = index
  player.playerstate = P.PST_LIVE
  player.cmd = { forwardmove = 0, sidemove = 0, angleturn = 0, buttons = 0 }
  player.viewz, player.viewheight, player.deltaviewheight, player.bob = 0, 0, 0, 0
  player.health, player.armorpoints, player.armortype = 100, 0, 0
  player.powers = { [0] = 0, 0, 0, 0, 0, 0 }
  player.cards = { [0] = false, false, false, false, false, false }
  player.backpack = false
  player.frags = frags
  player.readyweapon, player.pendingweapon = P.wp_pistol, P.wp_pistol
  player.weaponowned = { [0] = true, true, false, false, false, false, false, false, false }
  player.ammo = { [0] = 50, 0, 0, 0 }
  player.maxammo = { [0] = 200, 50, 300, 50 }
  player.attackdown, player.usedown = true, true
  player.cheats, player.refire = 0, 0
  player.killcount, player.itemcount, player.secretcount = killcount, itemcount, secretcount
  player.damagecount, player.bonuscount = 0, 0
  player.extralight, player.fixedcolormap = 0, 0
  player.psprites = { [0] = { tics = 0, sx = 0, sy = 0 }, { tics = 0, sx = 0, sy = 0 } }
  player.didsecret = false
end

P.SetFastTables = setFastTables

function P.PlayerReborn(index: number): ()
  blankPlayer(G.players[index], index)
end

local function checkSpot(playernum: number, mthing: any): boolean
  local x, y = mthing.x * FRACUNIT, mthing.y * FRACUNIT
  local mo = G.players[playernum].mo
  if not mo then
    for index = 0, playernum - 1 do
      local other = G.players[index].mo
      if other and other.x == x and other.y == y then return false end
    end

    return true
  end

  if not P.CheckPosition(mo, x, y) then return false end

  local slot = G.bodyqueslot % BODYQUESIZE
  if G.bodyqueslot >= BODYQUESIZE then P.RemoveMobj(G.bodyque[slot]) end
  G.bodyque[slot] = mo
  G.bodyqueslot += 1

  local fine = ((P.ANG45 * P.idiv(mthing.angle, 45)) % U32) // 524288
  local sector = P.PointInSubsector(x, y).sector
  P.SpawnMobj(x + 20 * P.finesine[fine + 2049], y + 20 * P.finesine[fine + 1], sector.floorheight, MT.MT_TFOG)
  return true
end

function P.DeathMatchSpawnPlayer(playernum: number): ()
  local starts = G.deathmatchstarts
  local selections = #starts
  if selections > 0 then
    for _ = 1, 20 do
      local start = starts[P.Random() % selections + 1]
      if checkSpot(playernum, start) then
        start.type = playernum + 1
        P.SpawnPlayer(start)
        return
      end
    end
  end

  local start = G.playerstarts[playernum]
  if not start then error(`doom: {G.mapname} has no start for player {playernum + 1}`) end
  P.SpawnPlayer(start)
end

local function doReborn(playernum: number): ()
  if not G.netgame then
    G.gameaction = 'loadlevel'
    return
  end

  G.players[playernum].mo.player = nil
  if G.deathmatch ~= 0 then
    P.DeathMatchSpawnPlayer(playernum)
    return
  end

  local starts = G.playerstarts
  if checkSpot(playernum, starts[playernum]) then
    P.SpawnPlayer(starts[playernum])
    return
  end

  for index = 0, 3 do
    local start = starts[index]
    if start and checkSpot(playernum, start) then
      start.type = playernum + 1
      P.SpawnPlayer(start)
      start.type = index + 1
      return
    end
  end

  P.SpawnPlayer(starts[playernum])
end

function P.MapName(episode: number, map: number): string
  if G.commercial then return string.format('MAP%02d', map) end
  return `E{episode}M{map}`
end

local function doLoadLevel(): ()
  G.levelstarttic = G.gametic
  G.gamestate = 'level'
  for index = 0, 3 do
    local player = G.players[index]
    if G.playeringame[index] and player.playerstate == P.PST_DEAD then player.playerstate = P.PST_REBORN end
    player.frags = { [0] = 0, 0, 0, 0 }
  end

  P.SetupLevel(G.mapOverride or P.MapName(G.gameepisode, G.gamemap))
  G.gameaction = nil
end

function P.ExitLevel(): ()
  G.secretexit = false
  G.gameaction = 'completed'
end

function P.SecretExitLevel(): ()
  G.secretexit = not (G.commercial and not G.wad:find('MAP31'))
  G.gameaction = 'completed'
end

local EpisodeSecretReturn = { 3, 5, 6, 2 }

local function doCompleted(): ()
  G.gameaction = nil
  for index = 0, 3 do
    if not G.playeringame[index] then continue end

    local player = G.players[index]
    player.powers = { [0] = 0, 0, 0, 0, 0, 0 }
    player.cards = { [0] = false, false, false, false, false, false }
    player.mo.flags = band(player.mo.flags, bit32.bnot(P.MF_SHADOW))
    player.extralight, player.fixedcolormap, player.damagecount, player.bonuscount = 0, 0, 0, 0
  end

  local map = G.gamemap
  local summary: any = { map = G.mapname, leveltime = G.leveltime, players = {} }
  summary.maxkills, summary.maxitems, summary.maxsecret = G.totalkills, G.totalitems, G.totalsecret
  for index = 0, 3 do
    if not G.playeringame[index] then continue end

    local player = G.players[index]
    summary.players[index] = {
      kills = player.killcount,
      items = player.itemcount,
      secrets = player.secretcount,
      frags = table.clone(player.frags),
    }
  end

  G.lastlevel = summary

  if not G.commercial then
    if map == 8 then
      G.gamestate = 'finale'
      return
    end

    if map == 9 then
      for index = 0, 3 do
        G.players[index].didsecret = true
      end
    end
  end

  local nextMap
  if G.commercial then
    if G.secretexit and map == 15 then
      nextMap = 31
    elseif G.secretexit and map == 31 then
      nextMap = 32
    elseif map == 31 or map == 32 then
      nextMap = 16
    else
      nextMap = map + 1
    end
  elseif G.secretexit then
    nextMap = 9
  elseif map == 9 then
    nextMap = (EpisodeSecretReturn[G.gameepisode] or 3) + 1
  else
    nextMap = map + 1
  end

  G.nextmap = nextMap
  G.gamestate = 'intermission'
  G.intermissiontic = 0
end

-- The intermission has no screen here: it ends when a player presses attack or
-- use, or after intermissionTics.
local function intermissionTicker(): ()
  G.intermissiontic += 1
  local done = G.intermissiontic >= (G.intermissionTics or 105)
  for index = 0, 3 do
    if G.playeringame[index] and band(G.players[index].cmd.buttons, P.BT_ATTACK + P.BT_USE) ~= 0 then done = true end
  end

  if not done then return end

  if G.secretexit then G.players[G.consoleplayer].didsecret = true end

  -- MAP30 and a map with no successor in the WAD end the game.
  local nextName = P.MapName(G.gameepisode, G.nextmap)
  if G.mapOverride or (G.commercial and G.gamemap == 30 and not G.secretexit) or not G.wad:find(nextName) then
    G.gamestate = 'finale'
    return
  end

  G.gameaction = 'worlddone'
end

local function playTicker(): ()
  for index = 0, 3 do
    if G.playeringame[index] then P.PlayerThink(G.players[index]) end
  end

  P.RunThinkers()
  P.UpdateSpecials()
  P.RespawnSpecials()
  G.leveltime += 1
end

-- One 35 Hz tic. `cmds[slot]` is the ticcmd for player `slot` (0 to 3); a
-- missing entry is an idle command.
function P.Ticker(cmds: any?): ()
  for index = 0, 3 do
    if G.playeringame[index] and G.players[index].playerstate == P.PST_REBORN then doReborn(index) end
  end

  while G.gameaction do
    local action = G.gameaction
    if action == 'loadlevel' then
      doLoadLevel()
    elseif action == 'completed' then
      doCompleted()
    elseif action == 'worlddone' then
      G.gamemap = G.nextmap
      doLoadLevel()
    else
      G.gameaction = nil
    end
  end

  for index = 0, 3 do
    if not G.playeringame[index] then continue end

    local cmd, source = G.players[index].cmd, cmds and cmds[index]
    if source then
      cmd.forwardmove, cmd.sidemove = source.forwardmove or 0, source.sidemove or 0
      cmd.angleturn, cmd.buttons = source.angleturn or 0, source.buttons or 0
    else
      cmd.forwardmove, cmd.sidemove, cmd.angleturn, cmd.buttons = 0, 0, 0, 0
    end
  end

  if G.gamestate == 'level' then
    playTicker()
  elseif G.gamestate == 'intermission' then
    intermissionTicker()
  end

  G.gametic += 1
end

export type Options = {
  skill: number?,
  episode: number?,
  map: number?,
  mapName: string?,
  deathmatch: number?,
  netgame: boolean?,
  players: { boolean }?,
  consoleplayer: number?,
  nomonsters: boolean?,
  fast: boolean?,
  respawn: boolean?,
  timelimit: number?,
  intermissionTics: number?,
}

-- G_InitNew. `players` lists which of the four slots are in the game, in slot
-- order starting at slot 0; the default is slot 0 alone.
function P.InitNew(wad: any, options: Options?): ()
  local settings: Options = options or {}
  table.clear(G)
  P.OpenWad(wad)
  G.shareware = not G.commercial and not wad:find('E2M1')

  local skill = math.clamp(settings.skill or 2, 0, 4)
  local episode, map = settings.episode or 1, settings.map or 1
  local mapName = settings.mapName
  if mapName then
    mapName = string.upper(mapName)
    local parsedEpisode, parsedMap = string.match(mapName, '^E(%d)M(%d)$')
    local parsedCommercial = string.match(mapName, '^MAP(%d%d)$')
    if parsedEpisode then
      episode, map = tonumber(parsedEpisode) :: number, tonumber(parsedMap) :: number
    elseif parsedCommercial then
      map = tonumber(parsedCommercial) :: number
    else
      G.mapOverride = mapName
    end
  end

  G.prndindex, G.rndindex = 0, 0
  G.respawnmonsters = skill == 4 or settings.respawn == true
  G.fastparm = settings.fast == true
  setFastTables(G.fastparm or skill == 4)

  G.gameskill, G.gameepisode, G.gamemap = skill, episode, map
  G.deathmatch = settings.deathmatch or 0
  G.netgame = settings.netgame == true or G.deathmatch ~= 0
  G.nomonsters = settings.nomonsters == true
  G.timelimit = settings.timelimit
  G.intermissionTics = settings.intermissionTics
  G.consoleplayer = settings.consoleplayer or 0
  G.gametic, G.leveltime, G.validcount = 0, 0, 1
  G.braineasy = false

  G.players, G.playeringame = {}, {}
  local present = settings.players or { true }
  for index = 0, 3 do
    G.playeringame[index] = present[index + 1] == true
    G.players[index] = {}
    blankPlayer(G.players[index], index)
    G.players[index].playerstate = P.PST_REBORN
  end

  doLoadLevel()
end

return P
