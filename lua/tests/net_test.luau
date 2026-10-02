--!strict
local doomNet = require('@doom/net')
local test = require('@jess/test')
local suite = test.new()
local expect = test.expect

suite.describe('dream.net Doom protocol', function()
    suite.it('round-trips tic commands, bundles, and state hashes', function()
        local protocol = doomNet.protocol()
        expect(protocol.schema.eventCount).toBe(3)
        expect(protocol.schema:eventName(protocol.events.TICCMD)).toBe('TICCMD')

        local command = doomNet.botCommand(42, { forward = 60, side = 12, turn = -7, attackEvery = 3 })
        expect(doomNet.unpackTicCmd(doomNet.packTicCmd(command))).toEqual(command)

        local bundle = doomNet.botBundle(2, 100, 4, { attackEvery = 2 })
        expect(doomNet.unpackTicBundle(doomNet.packTicBundle(bundle))).toEqual(bundle)

        local state = buffer.fromstring('deterministic Doom state')
        local hash = doomNet.unpackStateHash(doomNet.packStateHash(123, state))
        expect(hash.tic).toBe(123)
        expect(buffer.tostring(hash.digest)).toBe(buffer.tostring(doomNet.hashState(state)))
    end)

    suite.it('rejects malformed wire values and truncated packets', function()
        expect(function() doomNet.packTicCmd({ forward = 200, side = 0, angleTurn = 0, consistency = 0, chat = 0, buttons = 0 }) end)
            .toThrow('forward must be an integer')
        expect(function() doomNet.unpackTicBundle(buffer.create(4)) end).toThrow('TIC_BUNDLE header is truncated')
    end)
end)

return suite
