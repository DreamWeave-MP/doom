--!strict
-- Vanilla DOOM demo command decoding. The four-byte demo command is not the
-- in-memory ticcmd_t: it omits consistency/chatchar and stores only the high
-- byte of angleturn (g_game.c:G_ReadDemoTiccmd).
local module = {}

export type Header = {
    version: number, skill: number, episode: number, map: number,
    deathmatch: number, respawn: number, fast: number, nomonsters: number,
    consolePlayer: number, players: {boolean},
}

-- This is the historical parse() surface. `turn` is deliberately the raw
-- unsigned demo byte; callers already use that value.
export type Tic = { forward: number, side: number, turn: number, buttons: number }

-- Full commands retain the exact signed C fields as well as compatibility
-- aliases. angleturn is the signed 16-bit value represented by the demo byte.
export type Command = {
    forward: number, side: number, turn: number, buttons: number,
    forwardmove: number, sidemove: number, angleturn: number, turnByte: number,
}
export type FullTic = {[number]: Command}

local HeaderSize = 13
local DemoMarker = 0x80

local function fail(message: string): never
    error(message, 2)
end

local function signedByte(value: number): number
    return if value >= 128 then value - 256 else value
end

local function signedShort(value: number): number
    return if value >= 0x8000 then value - 0x10000 else value
end

local function readHeader(data: buffer): Header
    if buffer.len(data) < HeaderSize then
        fail('demo: truncated header')
    end

    local players: {boolean} = {}
    for index = 0, 3 do
        local value = buffer.readu8(data, 9 + index)
        if value > 1 then
            fail(`demo: invalid player flag {index}: {value}`)
        end
        players[index + 1] = value ~= 0
    end

    local header: Header = {
        version = buffer.readu8(data, 0),
        skill = buffer.readu8(data, 1),
        episode = buffer.readu8(data, 2),
        map = buffer.readu8(data, 3),
        deathmatch = buffer.readu8(data, 4),
        respawn = buffer.readu8(data, 5),
        fast = buffer.readu8(data, 6),
        nomonsters = buffer.readu8(data, 7),
        consolePlayer = buffer.readu8(data, 8),
        players = players,
    }

    local active = 0
    for _, yes in players do
        if yes then
            active += 1
        end
    end

    if active == 0 then
        fail('demo: no players')
    end

    if header.consolePlayer > 3 or not players[header.consolePlayer + 1] then
        fail(`demo: console player {header.consolePlayer} is not active`)
    end

    return header
end

local function readCommand(data: buffer, at: number): Command
    local forward = signedByte(buffer.readu8(data, at))
    local side = signedByte(buffer.readu8(data, at + 1))
    local turnByte = buffer.readu8(data, at + 2)
    local angleturn = signedShort(turnByte * 0x100)

    return {
        forward = forward,
        side = side,
        turn = turnByte,
        buttons = buffer.readu8(data, at + 3),
        forwardmove = forward,
        sidemove = side,
        angleturn = angleturn,
        turnByte = turnByte,
    }
end

local function legacy(command: Command): Tic
    return {
        forward = command.forward,
        side = command.side,
        turn = command.turn,
        buttons = command.buttons,
    }
end

-- Parse every active player's command in each tic. Numeric keys are one-based
-- Lua player slots (so key 1 is the C player 0); inactive slots are absent.
function module.parseFull(data: buffer): (Header, {FullTic})
    local header = readHeader(data)
    local frames: {FullTic} = {}
    local at = HeaderSize
    local length = buffer.len(data)
    local ended = false

    while at < length do
        if buffer.readu8(data, at) == DemoMarker then
            at += 1
            ended = true
            break
        end

        local frame: FullTic = {}
        for player = 0, 3 do
            if not header.players[player + 1] then
                continue
            end

            if at + 4 > length then
                fail('demo: truncated ticcmd')
            end
            frame[player + 1] = readCommand(data, at)
            at += 4
        end
        table.insert(frames, frame)
    end

    if not ended then
        fail('demo: missing end marker')
    end

    if at ~= length then
        fail('demo: trailing bytes after end marker')
    end

    return header, frames
end

-- Keep the original `(Header, {Tic})` return shape and field names. Only the
-- console player's command is projected into this legacy view.
function module.parse(data: buffer): (Header, {Tic})
    local header, frames = module.parseFull(data)
    local tics: {Tic} = {}
    local slot = header.consolePlayer + 1

    for _, frame in frames do
        local command = frame[slot]
        if command == nil then
            fail('demo: console command missing')
        end
        table.insert(tics, legacy(command))
    end

    return header, tics
end

-- Descriptive aliases for callers that do not use the shorter parseFull name.
module.parsePlayers = module.parseFull
module.parseAll = module.parseFull
module.parseCommands = module.parseFull

return module
