--!strict
-- Separate-process Luau deathmatch client for the headless Doom harness.
local play = require '@doom/play'
local agent = require '@doom/agent'
local net = require '@doom/net'
local netgame = require '@doom/netgame'

local wadPath = arg[1]
local mapName = arg[2] or 'MAP01'
local tokenPath = arg[3]
local player = tonumber(arg[4] or '1') or 1
local ticCount = tonumber(arg[5] or '700') or 700
local playerCount = tonumber(arg[6] or '4') or 4
local sessionDir = arg[7]
if not wadPath or not tokenPath then
    error('usage: doom-client.luau <IWAD> <MAP> <tokens.txt> <slot> [tics] [players] [agent-session-dir]')
end

if playerCount < 1 or playerCount > 4 or playerCount ~= math.floor(playerCount) then
    error('players must be in [1, 4]')
end

if player < 1 or player > playerCount or player ~= math.floor(player) then
    error('slot must be in [1, players]')
end

local tokenLines = {}
local tokenText = jess.fs.read(tokenPath)
if not tokenText then
    error(`cannot read connect-token file {tokenPath}`)
end

for line in string.gmatch(tokenText, '([^\r\n]+)') do
    table.insert(tokenLines, line)
end
local token = tokenLines[player]
if not token then
    error(`no connect token for player slot {player}`)
end

local present = {}
for slot = 1, playerCount do
    present[slot] = true
end

local game = play.new(wadPath, {
    mapName = mapName,
    players = present,
    consoleplayer = player - 1,
    deathmatch = 1,
    netgame = true,
    nomonsters = true,
    skill = 3,
})
local client = netgame.newClient(game, token, player)

local nextTic = os.clock()
local step = 1 / netgame.TICRATE
local mismatches = 0
local plan: agent.Plan? = nil
local lastSeq: number? = nil
while game.gametic < ticCount do
    netgame.clientPump(client)
    if client.failure then
        error(`dream.net client failed: {client.failure}`)
    end
    local now = os.clock()
    if now >= nextTic then
        -- With a session folder the slot is driven by plans from doom-agent.luau and
        -- reports what it sees there; without one it runs the canned patrol.
        local command
        if sessionDir then
            local fresh = agent.readPlan(sessionDir, player - 1, lastSeq)
            if fresh then
                plan, lastSeq = fresh, fresh.seq
            end

            local cmd = agent.nextCommand(plan)
            command = {
                forward = if cmd then cmd.forwardmove else 0,
                side = if cmd then cmd.sidemove else 0,
                angleTurn = if cmd then cmd.angleturn else 0,
                consistency = 0,
                chat = 0,
                buttons = if cmd then cmd.buttons else 0,
            }
            jess.fs.replace(agent.observationPath(sessionDir, player - 1), agent.describe(player - 1))
        else
            command = net.botCommand(game.gametic, { period = 35, attackEvery = 7 })
        end

        local _, synchronized = netgame.clientTic(client, command)
        if synchronized == false then
            mismatches += 1
        end
        nextTic += step
    end
end
netgame.clientDisconnect(client)
print(`DOOM client {player} reached tic {game.gametic}; world hash {netgame.stateHash(game)}; mismatches {mismatches}`)
