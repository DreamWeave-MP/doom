--!strict
-- Deterministic game-flow glue for the small gameplay container.  This module
-- keeps the simulation in game.luau authoritative and adds the state which
-- vanilla g_game.c keeps outside the level's mobjs.
local gameModule = require './game'
local mobj = require './mobj'
local physics = require './physics'
local tick = require './tick'

local module = {}

local FLOW_VERSION = 1
local MAX_PLAYERS = 4
local TICRATE = 35

export type MapDescriptor = {
    mode: string,
    episode: number,
    map: number,
    name: string,
}

export type Intermission = {
    version: number,
    mode: string,
    episode: number,
    last: number,
    next: number?,
    nextName: string?,
    didSecret: boolean,
    maxKills: number,
    maxItems: number,
    maxSecret: number,
    maxFrags: number,
    partime: number,
    leveltime: number,
    players: {any},
}

export type FlowState = {
    version: number,
    state: string,
    mode: string,
    episode: number,
    mapNumber: number,
    mapName: string,
    deathmatch: boolean,
    netgame: boolean,
    spawnMonsters: boolean,
    skill: number,
    consolePlayer: number,
    activeSlots: {number},
    didSecret: boolean,
    secretExit: boolean,
    pending: MapDescriptor?,
    intermission: Intermission?,
    frags: {{number}},
    totalKills: number,
    totalItems: number,
    totalSecret: number,
    demoTics: number,
    timedemo: boolean,
    timedemoTics: number,
    timedemoStartTic: number,
    mapLoader: ((string) -> any)?,
    maps: {[string]: any}?,
}

export type FlowGame = gameModule.Game & {
    flow: FlowState,
    frags: {{number}},
    gamestate: string,
    gameState: string,
    demoTics: number,
    timedemoTics: number,
    timedemo: boolean,
    mapName: string?,
}

local doomPar: {[number]: {[number]: number}} = {
    [1] = {[1] = 30, [2] = 75, [3] = 120, [4] = 90, [5] = 165, [6] = 180, [7] = 180, [8] = 30, [9] = 165},
    [2] = {[1] = 90, [2] = 90, [3] = 90, [4] = 120, [5] = 90, [6] = 360, [7] = 240, [8] = 30, [9] = 170},
    [3] = {[1] = 90, [2] = 45, [3] = 90, [4] = 150, [5] = 90, [6] = 90, [7] = 165, [8] = 30, [9] = 135},
    [4] = {[1] = 90, [2] = 45, [3] = 90, [4] = 150, [5] = 90, [6] = 90, [7] = 165, [8] = 30, [9] = 135},
}

local doom2Par: {[number]: number} = {
    [1] = 30, [2] = 90, [3] = 120, [4] = 120, [5] = 90, [6] = 150, [7] = 120, [8] = 120,
    [9] = 270, [10] = 90, [11] = 210, [12] = 150, [13] = 150, [14] = 150, [15] = 210, [16] = 150,
    [17] = 420, [18] = 150, [19] = 210, [20] = 150, [21] = 240, [22] = 150, [23] = 180, [24] = 150,
    [25] = 150, [26] = 300, [27] = 330, [28] = 420, [29] = 300, [30] = 180, [31] = 120, [32] = 30,
}

local function fail(message: string): never
    error('doom.flow: ' .. message, 2)
end

local function clone(value: any): any
    if type(value) ~= 'table' then return value end
    local result: {[any]: any} = {}
    for key, item in value do result[key] = clone(item) end
    return result
end

local function integer(value: any, name: string, minimum: number, maximum: number): number
    if type(value) ~= 'number' or value ~= math.floor(value) or value < minimum or value > maximum then
        fail(`{name} must be an integer in [{minimum}, {maximum}]`)
    end
    return value
end

local function newFrags(): {{number}}
    local result: {{number}} = {}
    for player = 1, MAX_PLAYERS do
        result[player] = {0, 0, 0, 0}
    end
    return result
end

local function normalizeMode(value: any, mapName: string): string
    if type(value) == 'string' then
        local mode = string.lower(value)
        if mode == 'doom2' or mode == 'commercial' or mode == 'doomii' then return 'doom2' end
        if mode == 'doom' or mode == 'episode' or mode == 'retail' or mode == 'registered' then return 'doom' end
        fail(`unsupported game mode '{value}'`)
    end
    if string.sub(mapName, 1, 3) == 'MAP' then return 'doom2' end
    return 'doom'
end

local function parsedMap(map: any, settings: any): MapDescriptor
    local mapName = string.upper(if type(map.name) == 'string' then map.name else '')
    local mode = normalizeMode(settings.mode or settings.gameMode, mapName)
    local episode = if type(settings.episode) == 'number' then settings.episode else nil
    local mapNumber = if type(settings.mapNumber) == 'number' then settings.mapNumber else nil
    if mapNumber == nil and type(settings.map) == 'number' then mapNumber = settings.map end

    if mode == 'doom2' then
        if mapNumber == nil and string.sub(mapName, 1, 3) == 'MAP' then
            mapNumber = tonumber(string.sub(mapName, 4, 5))
        end
        episode = 1
    else
        if episode == nil and string.sub(mapName, 1, 1) == 'E' and string.sub(mapName, 3, 3) == 'M' then
            episode = tonumber(string.sub(mapName, 2, 2))
        end
        if mapNumber == nil and string.sub(mapName, 1, 1) == 'E' and string.sub(mapName, 3, 3) == 'M' then
            mapNumber = tonumber(string.sub(mapName, 4, 4))
        end
    end

    if episode == nil then episode = 1 end
    if mapNumber == nil then mapNumber = 1 end
    episode = integer(episode, 'episode', 1, if mode == 'doom' then 4 else 1)
    mapNumber = integer(mapNumber, 'map', 1, if mode == 'doom' then 9 else 32)
    if mapName == '' then mapName = if mode == 'doom2' then `MAP{string.format('%02d', mapNumber)}` else `E{episode}M{mapNumber}` end
    return {mode = mode, episode = episode, map = mapNumber, name = mapName}
end

local function mapName(mode: string, episode: number, mapNumber: number): string
    if mode == 'doom2' then return `MAP{string.format('%02d', mapNumber)}` end
    return `E{episode}M{mapNumber}`
end

local function parTime(descriptor: MapDescriptor): number
    local seconds = if descriptor.mode == 'doom2'
        then (doom2Par[descriptor.map] or 0)
        else ((doomPar[descriptor.episode] or {})[descriptor.map] or 0)
    return seconds * TICRATE
end

local function attachFrags(game: any, state: FlowState): ()
    game.flow = state
    game.frags = state.frags
    game.gamestate = state.state
    game.gameState = state.state
    game.demoTics = state.demoTics
    game.timedemoTics = state.timedemoTics
    game.timedemo = state.timedemo
    for index, player in game.players do
        player.frags = state.frags[index]
    end
end

local function makeState(game: any, descriptor: MapDescriptor, settings: any): FlowState
    local count = #game.players
    local slots: {number} = {}
    local configuredSlots = settings.activeSlots or settings.playerSlots
    for index = 1, count do
        local slot = if type(configuredSlots) == 'table' and type(configuredSlots[index]) == 'number'
            then configuredSlots[index]
            else index
        slots[index] = integer(slot, `activeSlots[{index}]`, 1, MAX_PLAYERS)
    end
    local consolePlayer = settings.consolePlayer or settings.consoleplayer or 1
    if consolePlayer == 0 then consolePlayer = 1 end
    consolePlayer = integer(consolePlayer, 'consolePlayer', 1, MAX_PLAYERS)
    local skill = integer(settings.skill or 2, 'skill', 0, 4)
    return {
        version = FLOW_VERSION,
        state = 'level',
        mode = descriptor.mode,
        episode = descriptor.episode,
        mapNumber = descriptor.map,
        mapName = descriptor.name,
        deathmatch = settings.deathmatch == true,
        netgame = settings.netgame == true,
        spawnMonsters = settings.spawnMonsters ~= false and settings.nomonsters ~= true and settings.nomons ~= true,
        skill = skill,
        consolePlayer = consolePlayer,
        activeSlots = slots,
        didSecret = settings.didSecret == true,
        secretExit = false,
        pending = nil,
        intermission = nil,
        frags = newFrags(),
        totalKills = if type(settings.totalKills) == 'number' then settings.totalKills else (game.totalKills or 0),
        totalItems = if type(settings.totalItems) == 'number' then settings.totalItems else (game.totalItems or 0),
        totalSecret = if type(settings.totalSecret) == 'number' then settings.totalSecret else (game.totalSecret or 0),
        demoTics = 0,
        timedemo = settings.timedemo == true or settings.timeDemo == true,
        timedemoTics = 0,
        timedemoStartTic = game.gametic,
        mapLoader = if type(settings.mapLoader) == 'function' then settings.mapLoader else nil,
        maps = if type(settings.maps) == 'table' then settings.maps else nil,
    }
end

local function stateFor(game: any): FlowState
    if type(game) ~= 'table' then fail('expected a game object') end
    if type(game.flow) == 'table' then return game.flow :: FlowState end
    local descriptor = parsedMap(game.map, {})
    local state = makeState(game, descriptor, {})
    attachFrags(game, state)
    return state
end

local function copyPersistent(oldPlayer: any, newPlayer: any): ()
    newPlayer.health = oldPlayer.health
    newPlayer.armor = oldPlayer.armor
    newPlayer.armorType = oldPlayer.armorType
    newPlayer.deaths = oldPlayer.deaths
    newPlayer.kills = oldPlayer.kills
    newPlayer.killcount = 0
    newPlayer.itemcount = 0
    newPlayer.secretcount = 0
    newPlayer.powers = clone(oldPlayer.powers or {})
    newPlayer.cards = clone(oldPlayer.cards or {})
    newPlayer.backpack = oldPlayer.backpack == true
    newPlayer.maxammo = clone(oldPlayer.maxammo or { [1] = 200, [2] = 50, [3] = 300, [4] = 50 })
    newPlayer.readyweapon = oldPlayer.readyweapon
    newPlayer.pendingweapon = oldPlayer.pendingweapon
    newPlayer.ammo = clone(oldPlayer.ammo)
    newPlayer.weaponowned = clone(oldPlayer.weaponowned)
end

local function replaceLevel(game: any, map: any, state: FlowState, resetFrags: boolean): ()
    local oldPlayers = game.players
    local oldGametic = game.gametic
    local oldRng = game.rngState
    local replacement = gameModule.new(map, {
        playerCount = math.max(1, #oldPlayers),
        spawnMonsters = state.spawnMonsters,
        seed = oldRng,
        skill = state.skill,
        deathmatch = state.deathmatch,
        netgame = state.netgame,
    })
    for index, oldPlayer in oldPlayers do
        local newPlayer = replacement.players[index]
        if newPlayer then copyPersistent(oldPlayer, newPlayer) end
    end

    game.map = replacement.map
    game.leveltime = 0
    game.gametic = oldGametic
    game.rngState = oldRng
    game.players = replacement.players
    game.mobjs = replacement.mobjs
    game.thinkers = replacement.thinkers
    if type(game.mapName) == 'string' then game.mapName = map.name end
    if resetFrags then state.frags = newFrags() end
    state.state = 'level'
    state.mapName = string.upper(map.name)
    state.pending = nil
    state.intermission = nil
    attachFrags(game, state)
end

local function setPlayerSpawn(game: any, playerIndex: number, thing: any): boolean
    local player = gameModule.resetPlayerForReborn(game, playerIndex)
    if not player then return false end
    local object = game.mobjs[player.moId]
    if not object then return false end
    local angle = mobj.angleFromDegrees(thing.angle)
    local x, y = thing.x * mobj.FRACUNIT, thing.y * mobj.FRACUNIT
    object.x, object.y, object.angle = x, y, angle
    object.floorz, object.ceilingz = physics.floorAndCeiling(game.map, x, y)
    object.z = object.floorz
    object.momx, object.momy, object.momz = 0, 0, 0
    object.health = 100
    object.flags = bit32.bor(bit32.band(object.flags, bit32.bnot(mobj.MF_CORPSE)), mobj.MF_SOLID, mobj.MF_SHOOTABLE)
    object.state, object.tics, object.removed = 'spawn', 0, false
    player.spawnX, player.spawnY, player.spawnAngle = x, y, angle
    player.angle = angle
    player.state, player.health = mobj.PST_LIVE, 100
    player.viewheight = 41 * mobj.FRACUNIT
    player.viewz = object.z + player.viewheight
    player.usedown, player.attackdown, player.attackCooldown, player.deathTics = true, true, 0, 0
    player.damagecount, player.bonuscount = 0, 0
    return true
end

local function deathmatchStart(map: any, game: any): any?
    local starts: {any} = {}
    for _, thing in map.things do
        if thing.kind >= 11 and thing.kind <= 14 then table.insert(starts, thing) end
    end
    if #starts == 0 then return nil end
    -- Keep the choice integer-safe on Luau numbers and independent of table order
    -- outside the map's serialized THINGS order.
    local random = (game.rngState * 1103515 + 12345) % 2147483647
    game.rngState = random
    return starts[(random % #starts) + 1]
end

local function spawnDeathmatchPlayers(game: any): ()
    for index = 1, #game.players do
        local start = deathmatchStart(game.map, game)
        if start then setPlayerSpawn(game, index, start) end
    end
end

local function nextDescriptor(state: FlowState): MapDescriptor?
    local mapNumber = state.mapNumber
    if state.mode == 'doom2' then
        if state.secretExit then
            if mapNumber == 15 then mapNumber = 31 elseif mapNumber == 31 then mapNumber = 32 else return nil end
        elseif mapNumber == 31 or mapNumber == 32 then
            mapNumber = 16
        else
            mapNumber += 1
        end
        if mapNumber > 32 then return nil end
        return {mode = 'doom2', episode = 1, map = mapNumber, name = mapName('doom2', 1, mapNumber)}
    end

    if state.secretExit then
        mapNumber = 9
    elseif mapNumber == 9 then
        local returnMap = {[1] = 3, [2] = 5, [3] = 6, [4] = 2}
        mapNumber = returnMap[state.episode] or 1
    else
        mapNumber += 1
    end
    if mapNumber > 9 then return nil end
    return {mode = 'doom', episode = state.episode, map = mapNumber, name = mapName('doom', state.episode, mapNumber)}
end

local function playerSummary(game: any, state: FlowState): {any}
    local result: {any} = {}
    for index, player in game.players do
        result[index] = {
            inGame = true,
            kills = player.killcount or 0,
            items = player.itemcount or 0,
            secret = player.secretcount or 0,
            time = game.leveltime,
            frags = clone(state.frags[index]),
        }
    end
    return result
end

local function setFlowState(game: any, state: FlowState, value: string): ()
    state.state = value
    attachFrags(game, state)
end

function module.newGame(map: any, options: any?): FlowGame
    if type(map) ~= 'table' then fail('newGame requires a loaded map') end
    local settings = options or {}
    local descriptor = parsedMap(map, settings)
    local gameOptions: {[string]: any} = {
        playerCount = settings.playerCount or 1,
        spawnMonsters = settings.spawnMonsters ~= false and settings.nomonsters ~= true and settings.nomons ~= true,
        seed = settings.seed,
        skill = settings.skill or 2,
        deathmatch = settings.deathmatch == true,
        netgame = settings.netgame == true,
    }
    local game: any = gameModule.new(map, gameOptions)
    local state = makeState(game, descriptor, settings)
    attachFrags(game, state)
    if state.deathmatch then spawnDeathmatchPlayers(game) end
    game.mapName = descriptor.name
    return game :: FlowGame
end

function module.applyDemoFrame(game: FlowGame, frame: any?): FlowGame
    local state = stateFor(game)
    if state.state ~= 'level' then fail('cannot apply a demo frame outside a level') end
    local source = if type(frame) == 'table' and type(frame.commands) == 'table' then frame.commands else frame
    local direct = type(source) == 'table' and source.forwardmove == nil and source.forward == nil and source.sidemove == nil and source.side == nil and source.buttons == nil
    local commands: {any} = {}
    local beforeDead: {[number]: boolean} = {}
    for index, player in game.players do
        beforeDead[index] = player.state == mobj.PST_DEAD
        local command = nil
        if not direct and index == state.consolePlayer then
            command = source
        elseif type(source) == 'table' then
            local slot = state.activeSlots[index] or index
            command = source[slot] or source[index] or (if slot > 1 then source[slot - 1] else nil)
        end
        commands[index] = command or {forwardmove = 0, sidemove = 0, angleturn = 0, buttons = 0}
    end

    tick.step(game, commands)

    local newDeaths: {number} = {}
    for index, player in game.players do
        if not beforeDead[index] and player.state == mobj.PST_DEAD then table.insert(newDeaths, index) end
    end
    if state.deathmatch and #newDeaths > 0 then
        for _, victim in newDeaths do
            local deathSourceId = game.players[victim].deathSourceId or 0
            if deathSourceId == 0 then
                module.recordFrag(game, victim, victim)
            else
                local source = game.mobjs[deathSourceId]
                if source and source.playerId then module.recordFrag(game, source.playerId, victim) end
            end
        end
    end

    local runtime = game.specials
    if runtime and runtime.exited then
        module.completeLevel(game, { secretExit = runtime.secretExit })
    end

    state.demoTics += 1
    if state.timedemo then state.timedemoTics += 1 end
    game.demoTics = state.demoTics
    game.timedemoTics = state.timedemoTics
    return game
end

function module.recordFrag(game: FlowGame, killer: number, victim: number, amount: number?): FlowGame
    local state = stateFor(game)
    killer = integer(killer, 'killer', 1, MAX_PLAYERS)
    victim = integer(victim, 'victim', 1, MAX_PLAYERS)
    local change = amount or 1
    change = integer(change, 'frag amount', -2147483648, 2147483647)
    if not state.frags[killer] then state.frags[killer] = {0, 0, 0, 0} end
    state.frags[killer][victim] = (state.frags[killer][victim] or 0) + change
    attachFrags(game, state)
    return game
end

function module.completeLevel(game: FlowGame, exit: any?): FlowGame
    local state = stateFor(game)
    if state.state ~= 'level' then return game end
    local settings = if type(exit) == 'table' then exit else {}
    local secret = if type(exit) == 'boolean' then exit else settings.secretExit == true
    state.secretExit = secret
    if state.mapNumber == 9 then state.didSecret = true end

    if state.mode == 'doom' and state.mapNumber == 8 then
        state.pending = nil
        state.intermission = nil
        setFlowState(game, state, 'victory')
        return game
    end

    local descriptor = nextDescriptor(state)
    state.pending = descriptor
    local info: Intermission = {
        version = FLOW_VERSION,
        mode = state.mode,
        episode = state.episode,
        last = state.mapNumber,
        next = if descriptor then descriptor.map else nil,
        nextName = if descriptor then descriptor.name else nil,
        didSecret = state.didSecret,
        maxKills = if type(settings.totalKills) == 'number' then settings.totalKills else state.totalKills,
        maxItems = if type(settings.totalItems) == 'number' then settings.totalItems else state.totalItems,
        maxSecret = if type(settings.totalSecret) == 'number' then settings.totalSecret else state.totalSecret,
        maxFrags = 0,
        partime = parTime({mode = state.mode, episode = state.episode, map = state.mapNumber, name = state.mapName}),
        leveltime = game.leveltime,
        players = playerSummary(game, state),
    }
    state.intermission = info
    setFlowState(game, state, 'intermission')
    return game
end

function module.nextMap(game: FlowGame, suppliedMap: any?): FlowGame
    local state = stateFor(game)
    if state.state == 'victory' then return game end
    if state.state == 'level' then module.completeLevel(game, false) end
    if state.state == 'victory' then return game end

    local descriptor = state.pending
    local map = suppliedMap
    if map == nil and descriptor == nil then
        setFlowState(game, state, 'victory')
        return game
    end
    if type(map) == 'string' then
        local name = string.upper(map)
        if state.mapLoader then map = state.mapLoader(name)
        elseif state.maps then map = state.maps[name] or state.maps[map]
        else fail(`map '{name}' is not available; provide suppliedMap, maps, or mapLoader`) end
        if map == nil then fail(`map loader returned no map for '{name}'`) end
    elseif map == nil and descriptor then
        if state.mapLoader then map = state.mapLoader(descriptor.name)
        elseif state.maps then map = state.maps[descriptor.name]
        else fail(`map '{descriptor.name}' is not available; provide suppliedMap, maps, or mapLoader`) end
        if map == nil then fail(`map loader returned no map for '{descriptor.name}'`) end
    end
    if type(map) ~= 'table' then fail('nextMap requires a loaded map') end

    local loaded = parsedMap(map, {
        mode = state.mode,
        episode = state.episode,
        mapNumber = if descriptor then descriptor.map else nil,
    })
    state.episode, state.mapNumber, state.mode, state.mapName = loaded.episode, loaded.map, loaded.mode, loaded.name
    replaceLevel(game, map, state, true)
    if state.deathmatch then spawnDeathmatchPlayers(game) end
    state.secretExit = false
    return game
end

function module.reborn(game: FlowGame, playerIndex: number?, killerIndex: number?): FlowGame
    local state = stateFor(game)
    local index = playerIndex or state.consolePlayer
    index = integer(index, 'player', 1, #game.players)
    local player = game.players[index]
    if not player then fail(`player {index} is not active`) end
    if killerIndex then module.recordFrag(game, killerIndex, index) end
    if player.state ~= mobj.PST_DEAD then return game end

    if state.deathmatch then
        local start = deathmatchStart(game.map, game)
        if start and setPlayerSpawn(game, index, start) then return game end
        if gameModule.respawn(game, index) then
            player.usedown, player.attackdown = true, true
            return game
        end
        fail(`cannot respawn player {index}`)
    end

    if state.netgame then
        if gameModule.respawn(game, index) then
            player.usedown, player.attackdown = true, true
            return game
        end
        fail(`cannot respawn player {index}`)
    end

    -- Vanilla single-player G_DoReborn reloads the whole level.  The current
    -- map is supplied directly, so this remains deterministic and has no IO.
    gameModule.resetPlayerForReborn(game, index)
    replaceLevel(game, game.map, state, true)
    return game
end

function module.snapshot(game: FlowGame): any
    local state = stateFor(game)
    return {
        version = FLOW_VERSION,
        game = gameModule.snapshot(game),
        flow = {
            version = state.version,
            state = state.state,
            mode = state.mode,
            episode = state.episode,
            mapNumber = state.mapNumber,
            mapName = state.mapName,
            deathmatch = state.deathmatch,
            netgame = state.netgame,
            spawnMonsters = state.spawnMonsters,
            skill = state.skill,
            consolePlayer = state.consolePlayer,
            activeSlots = clone(state.activeSlots),
            didSecret = state.didSecret,
            secretExit = state.secretExit,
            pending = clone(state.pending),
            intermission = clone(state.intermission),
            frags = clone(state.frags),
            totalKills = state.totalKills,
            totalItems = state.totalItems,
            totalSecret = state.totalSecret,
            demoTics = state.demoTics,
            timedemo = state.timedemo,
            timedemoTics = state.timedemoTics,
            timedemoStartTic = state.timedemoStartTic,
        },
    }
end

local function restoreGame(game: any, record: any): ()
    if type(record) ~= 'table' then fail('restore requires a snapshot table') end
    if record.version ~= nil and record.version ~= FLOW_VERSION then fail(`unsupported flow snapshot version {record.version}`) end
    local raw = if type(record.game) == 'table' then record.game else record
    if raw.version ~= 1 then fail('unsupported game snapshot version') end
    local mapName = string.upper(raw.map or '')
    if mapName ~= string.upper(game.map.name or '') then fail(`snapshot map '{mapName}' does not match '{game.map.name}'`) end
    game.gametic = raw.gametic
    game.leveltime = raw.leveltime
    game.rngState = raw.rngState
    local rawGame = game :: any
    rawGame.skill = raw.skill or 2
    game.players = clone(raw.players)
    game.mobjs = clone(raw.mobjs)
    game.thinkers = clone(raw.thinkers)
    for _, object in game.mobjs do
        if object.playerId == 0 then object.playerId = nil end
        if object.targetId == 0 then object.targetId = nil end
    end
    gameModule.normalizePlayers(game)
end

function module.restore(game: FlowGame, record: any): FlowGame
    restoreGame(game, record)
    local old = stateFor(game)
    local saved = if type(record.flow) == 'table' then record.flow else nil
    if saved then
        if saved.version ~= FLOW_VERSION then fail(`unsupported flow state version {saved.version}`) end
        old.version = saved.version
        old.state = saved.state
        old.mode = saved.mode
        old.episode = saved.episode
        old.mapNumber = saved.mapNumber
        old.mapName = saved.mapName
        old.deathmatch = saved.deathmatch
        old.netgame = saved.netgame
        old.spawnMonsters = saved.spawnMonsters
        old.skill = saved.skill or 2
        old.consolePlayer = saved.consolePlayer
        old.activeSlots = clone(saved.activeSlots)
        old.didSecret = saved.didSecret
        old.secretExit = saved.secretExit
        old.pending = clone(saved.pending)
        old.intermission = clone(saved.intermission)
        old.frags = clone(saved.frags)
        old.totalKills = saved.totalKills
        old.totalItems = saved.totalItems
        old.totalSecret = saved.totalSecret
        old.demoTics = saved.demoTics
        old.timedemo = saved.timedemo
        old.timedemoTics = saved.timedemoTics
        old.timedemoStartTic = saved.timedemoStartTic
    end
    attachFrags(game, old)
    return game
end

module.VERSION = FLOW_VERSION
module.TICRATE = TICRATE
module.new = module.newGame
module.applyFrame = module.applyDemoFrame
module.complete = module.completeLevel
module.stateSnapshot = module.snapshot

return module
