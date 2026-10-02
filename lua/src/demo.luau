--!strict
local module = {}

export type Header = {
    version: number, skill: number, episode: number, map: number,
    deathmatch: number, respawn: number, fast: number, nomonsters: number,
    consolePlayer: number, players: {boolean},
}
export type Tic = { forward: number, side: number, turn: number, buttons: number }

local function signedByte(v: number): number
    return if v >= 128 then v - 256 else v
end

function module.parse(data: buffer): (Header, {Tic})
    if buffer.len(data) < 13 then error("demo: truncated header", 2) end
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
        players = {
            buffer.readu8(data, 9) ~= 0,
            buffer.readu8(data, 10) ~= 0,
            buffer.readu8(data, 11) ~= 0,
            buffer.readu8(data, 12) ~= 0,
        },
    }
    local active = 0
    for _, yes in header.players do if yes then active += 1 end end
    if active == 0 then error("demo: no players", 2) end

    local tics: {Tic} = {}
    local at = 13
    -- Expose console-player commands. Skip the other players' four-byte commands per tic.
    while at < buffer.len(data) do
        if buffer.readu8(data, at) == 128 then break end
        local chosen: Tic? = nil
        for player = 0, 3 do
            if header.players[player + 1] then
                if at + 4 > buffer.len(data) then error("demo: truncated ticcmd", 2) end
                local tic = {
                    forward = signedByte(buffer.readu8(data, at)),
                    side = signedByte(buffer.readu8(data, at + 1)),
                    turn = buffer.readu8(data, at + 2),
                    buttons = buffer.readu8(data, at + 3),
                }
                if player == header.consolePlayer then chosen = tic end
                at += 4
            end
        end
        if chosen then table.insert(tics, chosen) end
    end
    return header, tics
end

return module
