--!strict
-- The source-tree style gate, implemented using Jess's bundled style checker.
local style = require('@jess/style')

local paths: {string} = {}
for index, path in arg do if index ~= 0 then table.insert(paths, path) end end

if #paths == 0 then
    -- Generated lookup tables and the older port modules keep their existing format.
    paths = {
        'lua/src/netgame.luau',
        'lua/bin/doom-client.luau',
        'lua/bin/doom-server.luau',
        'lua/tests/net_test.luau',
        'lua/bin/doom-stylecheck.luau',
    }
end

local errors, warnings = style.run(paths)
print(`Doom Luau style: {errors} errors, {warnings} warnings`)
if errors > 0 then error('doom style check failed') end
