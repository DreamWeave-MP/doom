--!nonstrict
-- One player's side of a doom-arena.luau session: join, look, and act.
local fs = require('@jess/fs')
local agent = require('@doom/agent')

local dir, slot, verb = arg[1], tonumber(arg[2] or ''), arg[3]
if not dir or not slot or not verb then
  print('usage: doom-agent.luau <session-dir> <slot> join|look|act <step> [<step> ...]')
  print('  a step is words like: forward=50 side=-20 turn=45 attack use weapon=shotgun for=20')
  print('  forward/side run -50 to 50; turn is degrees over the whole step, positive left; for is tics')
  return
end

local function look(): ()
  print(fs.read(agent.observationPath(dir, slot)) or 'no observation yet: the arena host has not started')
end

if verb == 'join' then
  fs.replace(agent.readyPath(dir, slot), 'ready\n')
  print(`slot {slot} is ready`)
  look()
elseif verb == 'look' then
  look()
elseif verb == 'act' then
  local texts = {}
  for index = 4, #arg do
    table.insert(texts, arg[index])
  end

  local steps = agent.parseSteps(texts)
  local seqPath = fs.join(dir, `slot{slot}.seq`)
  local seq = (tonumber(fs.read(seqPath) or '') or 0) + 1
  fs.replace(seqPath, `{seq}\n`)
  agent.writePlan(dir, slot, seq, steps)
  print(`plan {seq} queued: {#steps} steps, {agent.planTics(steps)} tics; it replaces any plan still running`)
else
  error(`unknown verb '{verb}'`)
end
