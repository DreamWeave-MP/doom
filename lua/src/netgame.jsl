--!strict
-- Luau-owned Doom deathmatch orchestration over dream.udp's opaque transport handles.
local wire = require './net'
local play = require './play/api'

local module = {}
local MaxPlayers = 4
local IntegerSlots: {integer} = { 1i, 2i, 3i, 4i }

type Host = {
    game: any,
    server: wire.Server,
    scratch: buffer,
    peers: {[integer]: number},
    commands: {[number]: wire.TicCmd},
    slots: {number},
    rejection: string?,
}

type Client = {
    game: any,
    client: wire.Client,
    player: number,
    scratch: buffer,
    bundles: {[number]: {[number]: wire.TicCmd}},
    hashes: {[number]: buffer},
    slots: {number},
    failure: string?,
}

local function neutral(): wire.TicCmd
    return { forward = 0, side = 0, angleTurn = 0, consistency = 0, chat = 0, buttons = 0 }
end

local function localCommand(command: wire.TicCmd): any
    return {
        forwardmove = command.forward,
        sidemove = command.side,
        angleturn = command.angleTurn,
        buttons = command.buttons,
    }
end

-- The digest covers only what steers the simulation, so every peer computes
-- the same one whichever slot is its console player.
function module.stateHash(_game: any): string
    return play.hash()
end

-- Wire slots are 1 to 4; the simulation's are 0 to 3.
local function copySlots(game: any): {number}
    local result = [for slot in range(1, MaxPlayers) if game.playeringame[slot - 1] => slot]

    if #result == 0 or #result > MaxPlayers then
        error('doom.netgame: game must have one to four active players', 2)
    end
    return result
end

function module.newHost(game: any, address: string, protocolId: integer?): Host
    local protocol = wire.protocol()
    local server = wire.newServer(protocol, {
        address = address,
        protocolId = protocolId or wire.PROTOCOL_ID,
        maxClients = MaxPlayers,
    })
    local commands: {[number]: wire.TicCmd} = {}
    for slot = 1, MaxPlayers do
        commands[slot] = neutral()
    end

    return {
        game = game,
        server = server,
        scratch = buffer.create(wire.POLL_BUFFER_SIZE),
        peers = {},
        commands = commands,
        slots = copySlots(game),
        rejection = nil,
    }
end

function module.connectToken(host: Host, player: number): string
    if player < 1 or player > MaxPlayers or player ~= math.floor(player) then
        error('doom.netgame: player slot must be in [1, 4]', 2)
    end
    return wire.serverConnectTokenBase64(host.server, IntegerSlots[player])
end

function module.serverPump(host: Host): number
    wire.serverUpdate(host.server)
    local count = 0
    while true do
        local event = wire.serverPoll(host.server, host.scratch)
        if not event then break end
        count += 1
        if event.kind == 'connected' then
            local slotAllowed = false
            for _, slot in IntegerSlots do
                if event.clientId == slot then
                    slotAllowed = true
                    break
                end
            end

            if not slotAllowed then
                host.server.handle:disconnect(event.peer)
            else
                host.peers[event.peer] = event.clientId
            end
        elseif event.kind == 'disconnected' then
            local player = host.peers[event.peer]
            if player then
                host.peers[event.peer] = nil
                host.commands[player] = neutral()
            end
        elseif event.kind == 'rejected' then
            host.rejection = `client {event.clientId} rejected: {event.reason}`
        elseif event.kind == 'message' then
            local player = host.peers[event.peer]
            if player and event.event == 'TICCMD' then
                host.commands[player] = wire.unpackTicCmd(event.payload)
            elseif player and event.event == 'TIC_BUNDLE' then
                local bundle = wire.unpackTicBundle(event.payload)
                if bundle.player == player and #bundle.commands > 0 then
                    host.commands[player] = bundle.commands[#bundle.commands]
                end
            end
        end
    end
    -- Handshake packets and acks must be flushed while the host is still waiting for the
    -- configured player slots; simulation does not begin until everyone has connected.
    wire.serverFlush(host.server)
    return count
end

function module.serverTic(host: Host): any
    local tic = host.game.gametic
    local inputs = {}
    for _, slot in host.slots do
        inputs[slot - 1] = localCommand(host.commands[slot] or neutral())
    end
    play.tick(inputs)

    for _, slot in host.slots do
        local bundle: wire.TicBundle = {
            firstTic = tic,
            player = slot,
            commands = { host.commands[slot] or neutral() },
        }
        wire.serverBroadcastTicBundle(host.server, bundle)
    end

    if host.game.gametic % 35 == 0 then
        wire.serverBroadcastStateHash(host.server, host.game.gametic, module.stateHash(host.game))
    end
    wire.serverFlush(host.server)
    return host.game
end

function module.newClient(game: any, token: string, player: number, bind: string?): Client
    if player < 1 or player > MaxPlayers or player ~= math.floor(player) then
        error('doom.netgame: player slot must be in [1, 4]', 2)
    end
    local protocol = wire.protocol()
    local client = wire.newClient(protocol, { bind = bind })
    wire.clientConnect(client, token)
    return {
        game = game,
        client = client,
        player = player,
        scratch = buffer.create(wire.POLL_BUFFER_SIZE),
        bundles = {},
        hashes = {},
        slots = copySlots(game),
        failure = nil,
    }
end

function module.clientPump(client: Client): number
    wire.clientUpdate(client.client)
    local count = 0
    while true do
        local event = wire.clientPoll(client.client, client.scratch)
        if not event then break end
        count += 1
        if event.kind == 'message' and event.event == 'TIC_BUNDLE' then
            local bundle = wire.unpackTicBundle(event.payload)
            local row = client.bundles[bundle.firstTic]
            if not row then
                row = {}
                client.bundles[bundle.firstTic] = row
            end

            if bundle.commands[1] then row[bundle.player] = bundle.commands[1] end
        elseif event.kind == 'message' and event.event == 'STATE_HASH' then
            local hash = wire.unpackStateHash(event.payload)
            client.hashes[hash.tic] = hash.digest
        elseif event.kind == 'connectFailed' then
            client.failure = event.reason
        end
    end
    -- The client must emit its hello/ack while it waits for the server to finish
    -- authenticating the other deathmatch slots.
    wire.clientFlush(client.client)
    return count
end

function module.clientTic(client: Client, command: wire.TicCmd): (any, boolean?)
    if client.client.handle.connected then
        wire.clientSendTicCmd(client.client, command)
        wire.clientFlush(client.client)
    end
    local tic = client.game.gametic
    local row = client.bundles[tic]
    if not row then return client.game, nil end

    for _, slot in client.slots do
        if row[slot] == nil then return client.game, nil end
    end

    local inputs = {}
    for _, slot in client.slots do inputs[slot - 1] = localCommand(row[slot]) end
    play.tick(inputs)
    client.bundles[tic] = nil

    local expected = client.hashes[client.game.gametic]
    if expected then
        client.hashes[client.game.gametic] = nil
        return client.game, buffer.tostring(expected) == buffer.tostring(wire.hashState(module.stateHash(client.game)))
    end
    return client.game, nil
end

function module.clientDisconnect(client: Client): ()
    wire.clientDisconnect(client.client)
end

module.TICRATE = 35
module.MAX_PLAYERS = MaxPlayers

return module
