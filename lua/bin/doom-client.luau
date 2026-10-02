--!strict
-- Separate-process Luau deathmatch client for the headless Doom harness.
local doom = require("@doom")
local wadModule = require("@doom/wad")
local mapModule = require("@doom/map")
local net = require("@doom/net")
local netgame = require("@doom/netgame")

local wadPath = arg[1]
local mapName = arg[2] or "MAP01"
local tokenPath = arg[3]
local player = tonumber(arg[4] or "1") or 1
local ticCount = tonumber(arg[5] or "700") or 700
local playerCount = tonumber(arg[6] or "4") or 4
if not wadPath or not tokenPath then error("usage: doom-client.luau <IWAD> <MAP> <tokens.txt> <slot> [tics] [players]") end
if playerCount < 1 or playerCount > 4 or playerCount ~= math.floor(playerCount) then error("players must be in [1, 4]") end
if player < 1 or player > playerCount or player ~= math.floor(player) then error("slot must be in [1, players]") end

local tokenLines = {}
local tokenText = jess.fs.read(tokenPath)
if not tokenText then error(`cannot read connect-token file {tokenPath}`) end
for line in string.gmatch(tokenText, "([^\r\n]+)") do table.insert(tokenLines, line) end
local token = tokenLines[player]
if not token then error(`no connect token for player slot {player}`) end

local wad = wadModule.open(wadPath)
local map = mapModule.load(wad, mapName)
local slots = {}
for slot = 1, playerCount do slots[slot] = slot end
local game = doom.flow.newGame(map, {
    playerCount = playerCount,
    activeSlots = slots,
    consolePlayer = player,
    deathmatch = true,
    netgame = true,
    mode = if string.sub(map.name, 1, 3) == "MAP" then "doom2" else "doom",
})
game.wad, game.wadPath, game.mapName = wad, wadPath, map.name
local client = netgame.newClient(game, token, player)

local nextTic = os.clock()
local step = 1 / netgame.TICRATE
local mismatches = 0
while game.gametic < ticCount do
    netgame.clientPump(client)
    if client.failure then error(`dream.net client failed: {client.failure}`) end
    local now = os.clock()
    if now >= nextTic then
        local command = net.botCommand(game.gametic, { period = 35, attackEvery = 7 })
        local _, synchronized = netgame.clientTic(client, command)
        if synchronized == false then mismatches += 1 end
        nextTic += step
    end
end
netgame.clientDisconnect(client)
print(`DOOM client {player} reached tic {game.gametic}; world hash {netgame.stateHash(game)}; mismatches {mismatches}`)
