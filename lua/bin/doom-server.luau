--!strict
-- Luau-owned headless DOOM deathmatch server. Each slot's token is an opaque credential;
-- the native dream.net userdata retains the signing key, while all simulation remains here.
local doom = require '@doom'
local wadModule = require '@doom/wad'
local mapModule = require '@doom/map'
local net = require '@doom/net'
local netgame = require '@doom/netgame'

local wadPath = arg[1]
local mapName = arg[2] or 'MAP01'
local address = arg[3] or '127.0.0.1:0'
local tokenPath = arg[4]
local playerCount = tonumber(arg[5] or '4') or 4
local ticCount = tonumber(arg[6] or '700') or 700
if not wadPath then
    error('usage: doom-server.luau <IWAD> <MAP> <address> <tokens.txt> [players] [tics]')
end

if not tokenPath then
    error('doom-server.luau requires a token output path')
end

if playerCount < 1 or playerCount > 4 or playerCount ~= math.floor(playerCount) then
    error('players must be in [1, 4]')
end

if ticCount < 1 or ticCount ~= math.floor(ticCount) then
    error('tics must be a positive integer')
end

local wad = wadModule.open(wadPath)
local map = mapModule.load(wad, mapName)
local slots = {}
for slot = 1, playerCount do
    slots[slot] = slot
end

local game = doom.flow.newGame(map, {
    playerCount = playerCount,
    activeSlots = slots,
    consolePlayer = 1,
    deathmatch = true,
    netgame = true,
    mode = if string.sub(map.name, 1, 3) == 'MAP' then 'doom2' else 'doom',
})
game.wad, game.wadPath, game.mapName = wad, wadPath, map.name

local host = netgame.newHost(game, address, net.PROTOCOL_ID)
local tokens = {}
for slot = 1, playerCount do
    tokens[slot] = netgame.connectToken(host, slot)
end
jess.fs.write(tokenPath, table.concat(tokens, '\n') .. '\n')
print(`DOOM host {map.name} at {host.server.handle.address}; {playerCount} tokens written to {tokenPath}`)

local connectDeadline = os.clock() + 30
while host.server.handle.numConnected < playerCount and os.clock() < connectDeadline do
    netgame.serverPump(host)
    if host.rejection then
        error(host.rejection)
    end
end

if host.server.handle.numConnected < playerCount then
    error(`timed out waiting for {playerCount} deathmatch clients`)
end

-- The CLI has no frame scheduler. Pace this explicit headless harness at Doom's 35 Hz; the
-- game loop and every peer decision still execute in Luau.
local nextTic = os.clock()
local step = 1 / netgame.TICRATE
while game.gametic < ticCount do
    netgame.serverPump(host)
    local now = os.clock()
    if now >= nextTic then
        netgame.serverTic(host)
        nextTic += step
    end
end
print(`DOOM host stopped at tic {game.gametic}; world hash {netgame.stateHash(game)}`)
