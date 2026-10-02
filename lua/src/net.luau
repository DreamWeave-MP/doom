--!strict
-- Doom's dream-net wire protocol.
--
-- The transport owns no Doom state and retains no Luau buffers: sendEvent copies its
-- payload and pollInto fills a caller-owned scratch buffer. A Server is deliberately
-- injected because the Jess host owns the private key and is the only side allowed to
-- acquire a dream.net.Server handle.

local bytes = require("@dream/bytes")

type NetModule = {
    schema: (options: { version: number, maxMessagesPerPacket: number?, channels: { { [string]: any } }, events: { { [string]: any } } }) -> dream_net_Schema,
    client: (options: { schema: dream_net_Schema, bind: string? }) -> dream_net_Client,
}

-- Jess 0.1.0/l3i 1.3 exposes this bridge as @dream/net. A missing transport
-- is an environment error and must remain visible to the caller.
local net = require("@dream/net") :: NetModule
local module = {}

export type EventName = "TICCMD" | "TIC_BUNDLE" | "STATE_HASH"
export type TicCmd = {
    forward: number,
    side: number,
    angleTurn: number,
    consistency: number,
    chat: number,
    buttons: number,
}
export type TicBundle = {
    firstTic: number,
    player: number,
    commands: { TicCmd },
}
export type StateHash = {
    tic: number,
    digest: buffer,
}
export type EventIds = {
    TICCMD: integer,
    TIC_BUNDLE: integer,
    STATE_HASH: integer,
}
export type Protocol = {
    schema: dream_net_Schema,
    events: EventIds,
}
export type ClientOptions = {
    bind: string?,
}
export type Client = {
    handle: dream_net_Client,
    protocol: Protocol,
}
export type Server = {
    handle: dream_net_Server,
    protocol: Protocol,
}
export type ClientEvent =
    { kind: "message", peer: integer, event: EventName, eventId: integer, channel: integer, payload: buffer }
    | { kind: "connected", peer: integer, clientId: integer }
    | { kind: "disconnected", peer: integer, reason: string }
    | { kind: "connectFailed", peer: integer, reason: string }
export type ServerEvent =
    { kind: "message", peer: integer, event: EventName, eventId: integer, channel: integer, payload: buffer }
    | { kind: "connected", peer: integer, clientId: integer }
    | { kind: "disconnected", peer: integer, reason: string }
    | { kind: "rejected", peer: integer, clientId: integer, reason: string }
export type BotOptions = {
    forward: number?,
    side: number?,
    turn: number?,
    period: number?,
    attackEvery: number?,
    chat: number?,
    consistency: number?,
    buttons: number?,
}

module.SCHEMA_VERSION = 1
module.CODEC_VERSION = 1
module.TICCMD_SIZE = 8
module.BUNDLE_HEADER_SIZE = 8
module.MAX_BUNDLE_TICS = 12
module.STATE_HASH_SIZE = 37
module.STATE_DIGEST_SIZE = 32
module.MAX_EVENT_PAYLOAD = 104
module.TIC_BUNDLE_MAX_PAYLOAD = 104
module.POLL_BUFFER_SIZE = 104

local function fail(message: string): never
    error("doom.net: " .. message, 2)
end

local function lengthOf(source: buffer | string): number
    return if type(source) == "buffer" then buffer.len(source :: buffer) else #source :: string
end

local function requireInteger(value: number, name: string, minimum: number, maximum: number): number
    if value ~= math.floor(value) or value < minimum or value > maximum then
        fail(name .. " must be an integer in [" .. tostring(minimum) .. ", " .. tostring(maximum) .. "]")
    end
    return value
end

local function readRange(source: buffer | string, offset: number, size: number, label: string): number
    requireInteger(offset, "offset", 0, math.max(0, lengthOf(source)))
    local finish = offset + size
    if finish > lengthOf(source) then
        fail(label .. " is truncated")
    end
    return finish
end

local function validateCmd(cmd: TicCmd): TicCmd
    requireInteger(cmd.forward, "forward", -128, 127)
    requireInteger(cmd.side, "side", -128, 127)
    requireInteger(cmd.angleTurn, "angleTurn", -32768, 32767)
    requireInteger(cmd.consistency, "consistency", -32768, 32767)
    requireInteger(cmd.chat, "chat", 0, 255)
    requireInteger(cmd.buttons, "buttons", 0, 255)
    return cmd
end

local function writeCmd(target: buffer, offset: number, cmd: TicCmd): number
    validateCmd(cmd)
    local nextOffset = offset + module.TICCMD_SIZE
    if offset < 0 or offset ~= math.floor(offset) or nextOffset > buffer.len(target) then
        fail("TICCMD target is too small")
    end
    buffer.writei8(target, offset, cmd.forward)
    buffer.writei8(target, offset + 1, cmd.side)
    buffer.writei16(target, offset + 2, cmd.angleTurn)
    buffer.writei16(target, offset + 4, cmd.consistency)
    buffer.writeu8(target, offset + 6, cmd.chat)
    buffer.writeu8(target, offset + 7, cmd.buttons)
    return nextOffset
end

local function readCmd(source: buffer | string, offset: number): (TicCmd, number)
    local nextOffset = readRange(source, offset, module.TICCMD_SIZE, "TICCMD")
    local cmd: TicCmd = {
        forward = buffer.readi8(source, offset),
        side = buffer.readi8(source, offset + 1),
        angleTurn = buffer.readi16(source, offset + 2),
        consistency = buffer.readi16(source, offset + 4),
        chat = buffer.readu8(source, offset + 6),
        buttons = buffer.readu8(source, offset + 7),
    }
    return cmd, nextOffset
end

-- TICCMD is the little-endian wire image of Doom's ticcmd_t:
-- i8 forward, i8 side, i16 angleturn, i16 consistancy, u8 chatchar, u8 buttons.
function module.writeTicCmd(target: buffer, offset: number, cmd: TicCmd): number
    return writeCmd(target, offset, cmd)
end

function module.readTicCmd(source: buffer | string, offset: number?): (TicCmd, number)
    return readCmd(source, offset or 0)
end

function module.packTicCmd(cmd: TicCmd): buffer
    local target = buffer.create(module.TICCMD_SIZE)
    writeCmd(target, 0, cmd)
    return target
end

function module.unpackTicCmd(source: buffer | string): TicCmd
    local cmd, nextOffset = readCmd(source, 0)
    if nextOffset ~= lengthOf(source) then fail("TICCMD has trailing bytes") end
    return cmd
end

local function validateBundle(bundle: TicBundle): number
    requireInteger(bundle.firstTic, "firstTic", 0, 4294967295)
    requireInteger(bundle.player, "player", 0, 255)
    local count = #bundle.commands
    if count < 1 or count > module.MAX_BUNDLE_TICS then
        fail("TIC_BUNDLE command count must be in [1, " .. tostring(module.MAX_BUNDLE_TICS) .. "]")
    end
    return count
end

-- TIC_BUNDLE header: u8 codec, u8 player, u8 count, u8 reserved, u32 firstTic;
-- followed by count TICCMD records. The reserved byte makes the header extensible
-- without changing command alignment. All integer fields are little-endian.
function module.writeTicBundle(target: buffer, offset: number, bundle: TicBundle): number
    local count = validateBundle(bundle)
    local needed = module.BUNDLE_HEADER_SIZE + count * module.TICCMD_SIZE
    if offset < 0 or offset ~= math.floor(offset) or offset + needed > buffer.len(target) then
        fail("TIC_BUNDLE target is too small")
    end
    buffer.writeu8(target, offset, module.CODEC_VERSION)
    buffer.writeu8(target, offset + 1, bundle.player)
    buffer.writeu8(target, offset + 2, count)
    buffer.writeu8(target, offset + 3, 0)
    buffer.writeu32(target, offset + 4, bundle.firstTic)
    local at = offset + module.BUNDLE_HEADER_SIZE
    for _, cmd in bundle.commands do
        at = writeCmd(target, at, cmd)
    end
    return at
end

function module.readTicBundle(source: buffer | string, offset: number?, length: number?): (TicBundle, number)
    local start = offset or 0
    local finish = if length then start + length else lengthOf(source)
    if finish < start or finish > lengthOf(source) then fail("TIC_BUNDLE range is invalid") end
    readRange(source, start, module.BUNDLE_HEADER_SIZE, "TIC_BUNDLE header")
    if buffer.readu8(source, start) ~= module.CODEC_VERSION then fail("unsupported TIC_BUNDLE codec") end
    local count = buffer.readu8(source, start + 2)
    if count < 1 or count > module.MAX_BUNDLE_TICS then fail("invalid TIC_BUNDLE command count") end
    local needed = module.BUNDLE_HEADER_SIZE + count * module.TICCMD_SIZE
    if start + needed > finish then fail("TIC_BUNDLE is truncated") end
    local commands: { TicCmd } = {}
    local at = start + module.BUNDLE_HEADER_SIZE
    for i = 1, count do
        local cmd
        cmd, at = readCmd(source, at)
        commands[i] = cmd
    end
    return { firstTic = buffer.readu32(source, start + 4), player = buffer.readu8(source, start + 1), commands = commands }, at
end

function module.packTicBundle(bundle: TicBundle): buffer
    local count = validateBundle(bundle)
    local target = buffer.create(module.BUNDLE_HEADER_SIZE + count * module.TICCMD_SIZE)
    module.writeTicBundle(target, 0, bundle)
    return target
end

function module.unpackTicBundle(source: buffer | string): TicBundle
    local bundle, nextOffset = module.readTicBundle(source)
    if nextOffset ~= lengthOf(source) then fail("TIC_BUNDLE has trailing bytes") end
    return bundle
end

function module.hashState(state: buffer | string): buffer
    return bytes.digest(state, "blake3")
end

-- STATE_HASH: u8 codec, u32 tic, 32 raw BLAKE3 digest bytes.
function module.writeStateHash(target: buffer, offset: number, tic: number, digest: buffer): number
    requireInteger(tic, "tic", 0, 4294967295)
    if offset < 0 or offset ~= math.floor(offset) or offset + module.STATE_HASH_SIZE > buffer.len(target) then
        fail("STATE_HASH target is too small")
    end
    if buffer.len(digest) ~= module.STATE_DIGEST_SIZE then fail("STATE_HASH digest must be 32 bytes") end
    buffer.writeu8(target, offset, module.CODEC_VERSION)
    buffer.writeu32(target, offset + 1, tic)
    buffer.copy(target, offset + 5, digest, 0, module.STATE_DIGEST_SIZE)
    return offset + module.STATE_HASH_SIZE
end

function module.readStateHash(source: buffer | string, offset: number?): (StateHash, number)
    local at = offset or 0
    local nextOffset = readRange(source, at, module.STATE_HASH_SIZE, "STATE_HASH")
    if buffer.readu8(source, at) ~= module.CODEC_VERSION then fail("unsupported STATE_HASH codec") end
    local digest = buffer.create(module.STATE_DIGEST_SIZE)
    if type(source) == "buffer" then
        buffer.copy(digest, 0, source :: buffer, at + 5, module.STATE_DIGEST_SIZE)
    else
        buffer.writestring(digest, 0, (source :: string):sub(at + 6, at + 5 + module.STATE_DIGEST_SIZE))
    end
    return { tic = buffer.readu32(source, at + 1), digest = digest }, nextOffset
end

function module.packStateHash(tic: number, state: buffer | string): buffer
    local target = buffer.create(module.STATE_HASH_SIZE)
    module.writeStateHash(target, 0, tic, module.hashState(state))
    return target
end

function module.unpackStateHash(source: buffer | string): StateHash
    local hash, nextOffset = module.readStateHash(source)
    if nextOffset ~= lengthOf(source) then fail("STATE_HASH has trailing bytes") end
    return hash
end

local function eventIds(schema: dream_net_Schema): EventIds
    local tic = schema:eventId("TICCMD")
    local bundle = schema:eventId("TIC_BUNDLE")
    local state = schema:eventId("STATE_HASH")
    if tic == nil or bundle == nil or state == nil then fail("protocol schema is missing a Doom event") end
    return { TICCMD = tic, TIC_BUNDLE = bundle, STATE_HASH = state }
end

function module.protocol(): Protocol
    local schema = net.schema({
        version = module.SCHEMA_VERSION,
        maxMessagesPerPacket = 64,
        channels = {
            { name = "reliable", delivery = "reliableOrdered", capacity = 256 },
            { name = "state", delivery = "unreliableUnordered", capacity = 64, overflow = "dropOldest" },
        },
        events = {
            { name = "TICCMD", channel = "reliable", maxPayload = module.TICCMD_SIZE, codecVersion = module.CODEC_VERSION },
            { name = "TIC_BUNDLE", channel = "reliable", maxPayload = module.MAX_EVENT_PAYLOAD, codecVersion = module.CODEC_VERSION },
            { name = "STATE_HASH", channel = "state", maxPayload = module.STATE_HASH_SIZE, codecVersion = module.CODEC_VERSION },
        },
    })
    return { schema = schema, events = eventIds(schema) }
end

function module.newClient(protocol: Protocol, options: ClientOptions?): Client
    local settings = options or {}
    return {
        handle = net.client({ schema = protocol.schema, bind = settings.bind }),
        protocol = protocol,
    }
end

-- Server creation is intentionally absent. The host must create and inject a
-- dream.net.Server userdata; this wrapper never accepts an address or private key.
function module.wrapServer(handle: dream_net_Server, protocol: Protocol): Server
    return { handle = handle, protocol = protocol }
end

local function eventName(protocol: Protocol, id: integer): EventName
    local name = protocol.schema:eventName(id)
    if name == "TICCMD" or name == "TIC_BUNDLE" or name == "STATE_HASH" then return name end
    fail("transport returned an unknown Doom event id " .. tostring(id))
end

local function clientSend(handle: dream_net_Client, id: integer, payload: buffer): ()
    handle:sendEvent(id, payload)
end

local function serverSend(handle: dream_net_Server, peer: integer, id: integer, payload: buffer): ()
    handle:sendEvent(peer, id, payload)
end

function module.clientConnect(client: Client, token: buffer | string): ()
    client.handle:connect(token)
end

function module.clientDisconnect(client: Client): ()
    client.handle:disconnect()
end

function module.clientUpdate(client: Client): ()
    client.handle:update()
end

function module.clientFlush(client: Client): ()
    client.handle:flush()
end

function module.clientPoll(client: Client, scratch: buffer): ClientEvent?
    local kind, peer, a, b, c = client.handle:pollInto(scratch)
    if kind == nil then return nil end
    if kind == "message" then
        local eventId = a :: integer
        local channel = b :: integer
        local size = c :: number
        local payload = buffer.create(size)
        buffer.copy(payload, 0, scratch, 0, size)
        return { kind = "message", peer = peer :: integer, event = eventName(client.protocol, eventId), eventId = eventId, channel = channel, payload = payload }
    elseif kind == "connected" then
        return { kind = "connected", peer = peer :: integer, clientId = a :: integer }
    elseif kind == "disconnected" then
        return { kind = "disconnected", peer = peer :: integer, reason = a :: string }
    elseif kind == "connectFailed" then
        return { kind = "connectFailed", peer = peer :: integer, reason = a :: string }
    end
    fail("transport returned unknown client poll kind " .. tostring(kind))
end

function module.serverUpdate(server: Server): ()
    server.handle:update()
end

function module.serverFlush(server: Server): ()
    server.handle:flush()
end

function module.serverPoll(server: Server, scratch: buffer): ServerEvent?
    local kind, peer, a, b, c = server.handle:pollInto(scratch)
    if kind == nil then return nil end
    if kind == "message" then
        local eventId = a :: integer
        local channel = b :: integer
        local size = c :: number
        local payload = buffer.create(size)
        buffer.copy(payload, 0, scratch, 0, size)
        return { kind = "message", peer = peer :: integer, event = eventName(server.protocol, eventId), eventId = eventId, channel = channel, payload = payload }
    elseif kind == "connected" then
        return { kind = "connected", peer = peer :: integer, clientId = a :: integer }
    elseif kind == "disconnected" then
        return { kind = "disconnected", peer = peer :: integer, reason = a :: string }
    elseif kind == "rejected" then
        return { kind = "rejected", peer = peer :: integer, clientId = a :: integer, reason = b :: string }
    end
    fail("transport returned unknown server poll kind " .. tostring(kind))
end

function module.clientSendTicCmd(client: Client, cmd: TicCmd): ()
    clientSend(client.handle, client.protocol.events.TICCMD, module.packTicCmd(cmd))
end

function module.clientSendTicBundle(client: Client, bundle: TicBundle): ()
    clientSend(client.handle, client.protocol.events.TIC_BUNDLE, module.packTicBundle(bundle))
end

function module.clientSendStateHash(client: Client, tic: number, state: buffer | string): ()
    clientSend(client.handle, client.protocol.events.STATE_HASH, module.packStateHash(tic, state))
end

function module.serverSendTicCmd(server: Server, peer: integer, cmd: TicCmd): ()
    serverSend(server.handle, peer, server.protocol.events.TICCMD, module.packTicCmd(cmd))
end

function module.serverSendTicBundle(server: Server, peer: integer, bundle: TicBundle): ()
    serverSend(server.handle, peer, server.protocol.events.TIC_BUNDLE, module.packTicBundle(bundle))
end

function module.serverSendStateHash(server: Server, peer: integer, tic: number, state: buffer | string): ()
    serverSend(server.handle, peer, server.protocol.events.STATE_HASH, module.packStateHash(tic, state))
end

function module.serverBroadcastTicBundle(server: Server, bundle: TicBundle): integer
    return server.handle:broadcast(server.protocol.events.TIC_BUNDLE, module.packTicBundle(bundle))
end

function module.serverBroadcastStateHash(server: Server, tic: number, state: buffer | string): integer
    return server.handle:broadcast(server.protocol.events.STATE_HASH, module.packStateHash(tic, state))
end

-- A stateless deterministic square-patrol bot. No shared bot state is kept: the
-- caller supplies the tic, so replay and tests produce the same command sequence.
function module.botCommand(tic: number, options: BotOptions?): TicCmd
    requireInteger(tic, "tic", 0, 4294967295)
    local settings = options or {}
    local period = settings.period or 35
    requireInteger(period, "period", 1, 4294967295)
    local phase = math.floor(tic / period) % 4
    local forward = if settings.forward == nil then 50 else settings.forward
    local side = if settings.side == nil then 50 else settings.side
    local attackEvery = settings.attackEvery or 0
    if attackEvery < 0 or attackEvery ~= math.floor(attackEvery) then fail("attackEvery must be a non-negative integer") end
    local buttons = settings.buttons or 0
    if attackEvery > 0 and tic % attackEvery == 0 then buttons = bit32.bor(buttons, 1) end
    local signedForward = if phase == 0 then forward elseif phase == 2 then -forward else 0
    local signedSide = if phase == 1 then side elseif phase == 3 then -side else 0
    return validateCmd({
        forward = signedForward,
        side = signedSide,
        angleTurn = settings.turn or 0,
        consistency = settings.consistency or 0,
        chat = settings.chat or 0,
        buttons = buttons,
    })
end

function module.botBundle(player: number, firstTic: number, count: number, options: BotOptions?): TicBundle
    requireInteger(player, "player", 0, 255)
    requireInteger(firstTic, "firstTic", 0, 4294967295)
    requireInteger(count, "count", 1, module.MAX_BUNDLE_TICS)
    if firstTic + count - 1 > 4294967295 then fail("bot bundle tic range exceeds u32") end
    local commands: { TicCmd } = {}
    for i = 1, count do commands[i] = module.botCommand(firstTic + i - 1, options) end
    return { firstTic = firstTic, player = player, commands = commands }
end

return module
