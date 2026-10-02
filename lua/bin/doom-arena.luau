--!nonstrict
-- A live deathmatch for players that plan instead of pressing keys. The host
-- runs the game at a chosen tic rate; each slot's player (see doom-agent.luau)
-- reads its observation file and writes plans, whenever it likes. A slot with
-- no plan left stands still, so a slow thinker never stalls the others.
local fs = require('@jess/fs')
local play = require('@doom/play')
local agent = require('@doom/agent')

local wadPath, mapName, dir = arg[1], arg[2], arg[3]
local playerCount = tonumber(arg[4] or '4') or 4
local rate = tonumber(arg[5] or '10') or 10
local ticLimit = tonumber(arg[6] or '21000') or 21000
local fragLimit = tonumber(arg[7] or '20') or 20
local waitSeconds = tonumber(arg[8] or '600') or 600
if not wadPath or not mapName or not dir then
  error('usage: doom-arena.luau <IWAD> <MAP> <session-dir> [players=4] [tics-per-second=10] [tic-limit=21000] [frag-limit=20] [ready-wait-seconds=600]')
end

if playerCount < 1 or playerCount > 4 or rate <= 0 or rate > 35 then error('players must be 1 to 4 and the rate 1 to 35 tics per second') end

fs.createDir(dir)
for _, name in fs.list(dir) do
  if string.match(name, '^slot%d%.') or name == 'stop' or name == 'status.txt' or name == 'events.log' then fs.remove(fs.join(dir, name)) end
end

local present = {}
for slot = 0, playerCount - 1 do
  present[slot + 1] = true
end

local game = play.new(wadPath, { mapName = mapName, deathmatch = 1, netgame = true, players = present, skill = 3, nomonsters = true, intermissionTics = 1 })
local events: { string } = {}
local plans: { [number]: agent.Plan? } = {}
local lastSeq: { [number]: number } = {}
local recent: { [number]: { string } } = {}
local deaths: { [number]: number } = {}
local wasAlive: { [number]: boolean } = {}
local lastFrags: { [number]: { number } } = {}
for slot = 0, playerCount - 1 do
  recent[slot], deaths[slot], wasAlive[slot], lastFrags[slot] = {}, 0, true, { 0, 0, 0, 0 }
end

local everyone = {}
for slot = 0, playerCount - 1 do
  table.insert(everyone, slot)
end

local function note(slots: { number }, text: string): ()
  local line = `tic {game.gametic}: {text}`
  table.insert(events, line)
  print(line)
  for _, slot in slots do
    local list = recent[slot]
    table.insert(list, `event {line}`)
    if #list > 6 then table.remove(list, 1) end
  end
end

local function fragTotal(slot: number): number
  local frags = game.players[slot].frags
  local total = 0
  for other = 0, 3 do
    total += if other == slot then -frags[other] else frags[other]
  end

  return total
end

local function writeStatus(phase: string): ()
  local lines = { `{phase}: {game.mapname} tic {game.gametic} of {ticLimit}, {rate} tics per second, frag limit {fragLimit}` }
  for slot = 0, playerCount - 1 do
    local player = game.players[slot]
    table.insert(
      lines,
      `slot {slot}: frags {fragTotal(slot)} deaths {deaths[slot]} health {player.health} weapon {play.WeaponNames[player.readyweapon]}`
        .. ` plan-tics-left {agent.remaining(plans[slot])}`
    )
  end

  fs.replace(fs.join(dir, 'status.txt'), table.concat(lines, '\n') .. '\n')
  fs.replace(fs.join(dir, 'events.log'), table.concat(events, '\n') .. '\n')
end

local function writeObservations(): ()
  for slot = 0, playerCount - 1 do
    local extra = table.clone(recent[slot])
    table.insert(extra, `plan tics left {agent.remaining(plans[slot])}; game runs {rate} tics per second`)
    fs.replace(agent.observationPath(dir, slot), agent.describe(slot, extra))
  end
end

-- Every command is kept in the vanilla demo format, so the match replays here
-- (`doom.luau demo`) and in any port that plays version 1.9 demos.
local skill = 3
local demo = { string.char(109, skill, game.gameepisode, game.gamemap, 1, 0, 0, 1, 0) }
for slot = 0, 3 do
  table.insert(demo, string.char(if slot < playerCount then 1 else 0))
end

local function writeDemo(): ()
  fs.replace(fs.join(dir, 'match.lmp'), table.concat(demo) .. '\128')
end

-- The start barrier: every slot's player says it is ready, or the wait ends.
writeObservations()
writeStatus('waiting for players')
print(`DOOM arena {game.mapname} in {dir}: waiting for {playerCount} players to join`)
local deadline = os.clock() + waitSeconds
while os.clock() < deadline do
  local ready = 0
  for slot = 0, playerCount - 1 do
    if fs.exists(agent.readyPath(dir, slot)) then ready += 1 end
  end

  if ready == playerCount then break end

  local pause = os.clock() + 0.25
  while os.clock() < pause do
  end
end

note(everyone, 'the match starts')

local step = 1 / rate
local nextTic = os.clock()
local cmds = {}
local winner: number? = nil
while game.gametic < ticLimit and not winner and not fs.exists(fs.join(dir, 'stop')) do
  if os.clock() < nextTic then continue end

  nextTic += step
  for slot = 0, playerCount - 1 do
    local plan = agent.readPlan(dir, slot, lastSeq[slot])
    if plan then
      plans[slot], lastSeq[slot] = plan, plan.seq
    end

    cmds[slot] = agent.nextCommand(plans[slot])
  end

  for slot = 0, playerCount - 1 do
    local cmd = cmds[slot]
    table.insert(
      demo,
      if cmd then string.char(cmd.forwardmove % 256, cmd.sidemove % 256, (cmd.angleturn // 256) % 256, cmd.buttons) else '\0\0\0\0'
    )
  end

  play.tick(cmds)

  if game.gamestate ~= 'level' then
    note(everyone, 'the level was exited')
    break
  end

  for slot = 0, playerCount - 1 do
    local player = game.players[slot]
    local alive = player.playerstate == 0
    if wasAlive[slot] and not alive then
      deaths[slot] += 1
      local killer = 'the level'
      for other = 0, playerCount - 1 do
        local count = game.players[other].frags[slot]
        if count ~= lastFrags[other][slot + 1] then
          lastFrags[other][slot + 1] = count
          killer = if other == slot then 'themselves' else `slot {other}`
        end
      end

      note(everyone, `slot {slot} was killed by {killer}`)
    elseif alive and not wasAlive[slot] then
      note({ slot }, `slot {slot} respawned`)
    end

    wasAlive[slot] = alive
    if fragTotal(slot) >= fragLimit then winner = slot end
  end

  writeObservations()
  if game.gametic % rate == 0 then writeStatus('playing') end
  if game.gametic % 350 == 0 then writeDemo() end
end

if winner then note(everyone, `slot {winner} reached the frag limit`) end
note(everyone, 'the match is over')
writeObservations()
writeStatus('finished')
writeDemo()
print(`final state hash {play.hash()}; the whole match is in {fs.join(dir, 'match.lmp')}`)
print(fs.read(fs.join(dir, 'status.txt')))
