--!strict
-- Vanilla DOOM 1.10 sector specials.  This module is deliberately independent
-- of tick.luau: a host can install it beside any Game-shaped container and drive
-- one deterministic 35 Hz tic at a time.
local mapModule = require './map'
local mobj = require './mobj'
local random = require './random'

local module = {}

export type Runtime = {
    game: any,
    map: any,
    thinkers: {any},
    buttons: {any},
    rngState: number,
    nextId: number,
    leveltime: number,
    exited: boolean,
    secretExit: boolean,
    textureHeights: {[string]: number},
}

local FRACUNIT = mobj.FRACUNIT
local TICRATE = 35
local FLOOR_SPEED = math.floor(FRACUNIT / 8)
local CEILING_SPEED = math.floor(FRACUNIT / 8)
local PLAT_SPEED = math.floor(FRACUNIT / 4)
local VDOOR_WAIT = 150
local PLAT_WAIT = 105
local BUTTON_TIME = 35
local FAST_DARK = 15
local SLOW_DARK = 35
local STROBE_BRIGHT = 5
local GLOW_SPEED = 8

local function fixedHeight(value: number): number
    return math.floor(value * FRACUNIT + 0.5)
end

local function worldHeight(value: number): number
    return value / FRACUNIT
end

local function clamp(value: number, low: number, high: number): number
    if value < low then return low end
    if value > high then return high end
    return value
end

local function playerFor(runtime: Runtime, value: any): any
    if type(value) ~= 'table' then return nil end
    if value.moId then return runtime.game.players[value.index or value.playerId] end
    if value.playerId then return runtime.game.players[value.playerId] end
    for index, player in runtime.game.players do
        if player.moId == value.id then return player end
        if player == value then return player end
        if index == value.index then return player end
    end
    return nil
end

local function objectFor(runtime: Runtime, value: any): any
    if type(value) == 'number' then return runtime.game.mobjs[value] end
    if type(value) ~= 'table' then return nil end
    if value.moId then return runtime.game.mobjs[value.moId] end
    if value.id and value.x ~= nil then return value end
    if value.playerId then return runtime.game.mobjs[value.playerId] end
    return nil
end

local function isPlayer(runtime: Runtime, value: any): boolean
    local object = objectFor(runtime, value)
    return object ~= nil and object.playerId ~= nil or playerFor(runtime, value) ~= nil
end

local function lineFor(runtime: Runtime, value: any): (any, number)
    if type(value) == 'number' then
        local line = runtime.map.lines[value]
        if not line then error(`specials: invalid line {value}`, 3) end
        return line, value
    end
    if type(value) == 'table' then
        for index, line in runtime.map.lines do
            if line == value then return line, index end
        end
    end
    error('specials: line is not in the map', 3)
end

local function sideSector(runtime: Runtime, sideIndex: number): number?
    if sideIndex == 0xffff then return nil end
    local side = runtime.map.sides[sideIndex + 1]
    return if side then side.sector else nil
end

local function lineSectors(runtime: Runtime, line: any): (number?, number?)
    return sideSector(runtime, line.right), sideSector(runtime, line.left)
end

local function neighbors(runtime: Runtime, sectorIndex: number): {number}
    local result: {number} = {}
    local seen: {[number]: boolean} = {}
    for _, line in runtime.map.lines do
        local right, left = lineSectors(runtime, line)
        local other: number? = nil
        if right == sectorIndex then other = left elseif left == sectorIndex then other = right end
        if other and not seen[other] then
            seen[other] = true
            table.insert(result, other)
        end
    end
    return result
end

local function taggedSectors(runtime: Runtime, tag: number): {number}
    local result: {number} = {}
    for index, sector in runtime.map.sectors do
        if sector.tag == tag then table.insert(result, index) end
    end
    return result
end

local function surroundingFloor(runtime: Runtime, sectorIndex: number, high: boolean): number
    local sector = runtime.map.sectors[sectorIndex]
    local value = if high then -math.huge else math.huge
    for _, otherIndex in neighbors(runtime, sectorIndex) do
        local other = runtime.map.sectors[otherIndex]
        if high then value = math.max(value, other.floor) else value = math.min(value, other.floor) end
    end
    if value == math.huge or value == -math.huge then return sector.floor end
    return value
end

local function lowestCeiling(runtime: Runtime, sectorIndex: number): number
    local sector = runtime.map.sectors[sectorIndex]
    local value = math.huge
    for _, otherIndex in neighbors(runtime, sectorIndex) do
        value = math.min(value, runtime.map.sectors[otherIndex].ceiling)
    end
    return if value == math.huge then sector.ceiling else value
end

local function highestCeiling(runtime: Runtime, sectorIndex: number): number
    local sector = runtime.map.sectors[sectorIndex]
    local value = 0
    for _, otherIndex in neighbors(runtime, sectorIndex) do
        value = math.max(value, runtime.map.sectors[otherIndex].ceiling)
    end
    return if value == 0 then sector.ceiling else value
end

local function nextHighestFloor(runtime: Runtime, sectorIndex: number): number
    local sector = runtime.map.sectors[sectorIndex]
    local value = math.huge
    for _, otherIndex in neighbors(runtime, sectorIndex) do
        local floor = runtime.map.sectors[otherIndex].floor
        if floor > sector.floor then value = math.min(value, floor) end
    end
    return if value == math.huge then sector.floor else value
end

local function minLight(runtime: Runtime, sectorIndex: number, maximum: number): number
    local value = maximum
    for _, otherIndex in neighbors(runtime, sectorIndex) do
        value = math.min(value, runtime.map.sectors[otherIndex].light)
    end
    return value
end

local function randomByte(runtime: Runtime): number
    local stream = {mIndex = 0, pIndex = runtime.rngState % 256}
    local result = random.mRandom(stream)
    runtime.rngState = stream.mIndex
    return result
end

local function thinker(runtime: Runtime, kind: string, fields: any?): any
    local result: any = fields or {}
    result.id = runtime.nextId
    runtime.nextId += 1
    result.kind = kind
    result.removed = false
    table.insert(runtime.thinkers, result)
    return result
end

local function clearSectorData(runtime: Runtime, mover: any): ()
    local sector = runtime.map.sectors[mover.sector]
    if sector and sector.specialdata == mover.id then sector.specialdata = nil end
end

local function removeThinker(runtime: Runtime, mover: any): ()
    if mover.removed then return end
    mover.removed = true
    if mover.sector then clearSectorData(runtime, mover) end
end

local function sectorAtObject(runtime: Runtime, object: any): number?
    if not object then return nil end
    local sector = mapModule.sectorAt(runtime.map, math.floor(object.x / FRACUNIT), math.floor(object.y / FRACUNIT))
    for index, candidate in runtime.map.sectors do
        if candidate == sector then return index end
    end
    return nil
end

local function hasIronfeet(player: any): boolean
    return player.ironfeet == true or (player.powers and (player.powers[4] or 0) > 0) == true
end

local function damage(runtime: Runtime, object: any, amount: number): number
    if not object or object.removed or object.health <= 0 then return 0 end
    local player = playerFor(runtime, object)
    local applied = amount
    if player then
        if player.powers and (player.powers[1] or 0) > 0 then return 0 end
        if runtime.game.skill == 0 then applied = math.floor(applied / 2) end
        if player.armor and player.armor > 0 then
            local fraction = if player.armorType == 1 then 3 else 2
            local absorbed = math.min(player.armor, math.floor(applied / fraction))
            player.armor -= absorbed
            applied -= absorbed
        end
        if applied < 1 then applied = 1 end
        player.damagecount = math.min(100, (player.damagecount or 0) + applied)
        player.health = math.max(0, player.health - applied)
        object.health = player.health
        if player.health == 0 then
            player.state = mobj.PST_DEAD
            player.deathSourceId = 0
            player.deaths = (player.deaths or 0) + 1
            object.state = 'dead'
            object.flags = bit32.band(object.flags, bit32.bnot(mobj.MF_SHOOTABLE))
        end
    else
        object.health = math.max(0, object.health - applied)
    end
    return applied
end

local function syncSector(runtime: Runtime, sectorIndex: number, oldFloor: number, oldCeiling: number, crush: boolean): boolean
    local sector = runtime.map.sectors[sectorIndex]
    local blocked = false
    sector.floor = worldHeight(fixedHeight(sector.floor))
    sector.ceiling = worldHeight(fixedHeight(sector.ceiling))
    for _, object in runtime.game.mobjs do
        if not object.removed and sectorAtObject(runtime, object) == sectorIndex then
            local floorz = fixedHeight(sector.floor)
            local ceilingz = fixedHeight(sector.ceiling)
            if object.z == fixedHeight(oldFloor) then object.z = floorz end
            object.floorz, object.ceilingz = floorz, ceilingz
            if object.z + object.height > ceilingz then
                blocked = true
                if crush then damage(runtime, object, 10) end
            end
            local player = playerFor(runtime, object)
            if player then player.viewz = object.z + player.viewheight end
        end
    end
    return blocked
end

local function movePlane(runtime: Runtime, mover: any, plane: string, speed: number, dest: number, crush: boolean, direction: number): string
    local sector = runtime.map.sectors[mover.sector]
    local oldFloor, oldCeiling = sector.floor, sector.ceiling
    local current = fixedHeight(if plane == 'floor' then oldFloor else oldCeiling)
    local target = fixedHeight(dest)
    local nextValue = current + speed * direction
    local past = if direction > 0 then nextValue >= target else nextValue <= target
    local value = if past then target else nextValue
    if plane == 'floor' then sector.floor = worldHeight(value) else sector.ceiling = worldHeight(value) end
    local blocked = syncSector(runtime, mover.sector, oldFloor, oldCeiling, crush)
    if blocked and not crush then
        if plane == 'floor' then sector.floor = oldFloor else sector.ceiling = oldCeiling end
        syncSector(runtime, mover.sector, oldFloor, oldCeiling, false)
        return 'crushed'
    end
    if past then return 'pastdest' end
    if blocked then return 'crushed' end
    return 'ok'
end

local function spawnFloor(runtime: Runtime, sectorIndex: number, destination: number, speed: number, direction: number, kind: string, crush: boolean?, line: any?): boolean
    local sector = runtime.map.sectors[sectorIndex]
    if sector.specialdata ~= nil then return false end
    local mover = thinker(runtime, 'floor', {
        sector = sectorIndex, dest = destination, speed = speed, direction = direction,
        crush = crush == true, type = kind, texture = nil, newspecial = nil,
    })
    sector.specialdata = mover.id
    if kind == 'raise24AndChange' and line then
        local front = sideSector(runtime, line.right)
        if front then
            sector.floorTex = runtime.map.sectors[front].floorTex
            sector.special = runtime.map.sectors[front].special
        end
    end
    return true
end

local function spawnCeiling(runtime: Runtime, sectorIndex: number, kind: string): boolean
    local sector = runtime.map.sectors[sectorIndex]
    if sector.specialdata ~= nil then return false end
    local mover: any = {sector = sectorIndex, tag = runtime.map.sectors[sectorIndex].tag, type = kind, direction = -1, speed = CEILING_SPEED, crush = false}
    if kind == 'fastCrushAndRaise' then
        mover.crush, mover.top, mover.bottom, mover.speed = true, sector.ceiling, sector.floor + 8, CEILING_SPEED * 2
    elseif kind == 'silentCrushAndRaise' or kind == 'crushAndRaise' then
        mover.crush, mover.top, mover.bottom = true, sector.ceiling, sector.floor + 8
    elseif kind == 'lowerAndCrush' then
        mover.crush, mover.bottom = true, sector.floor + 8
    elseif kind == 'lowerToFloor' then
        mover.bottom = sector.floor
    elseif kind == 'raiseToHighest' then
        mover.direction, mover.top = 1, highestCeiling(runtime, sectorIndex)
    else
        return false
    end
    local result = thinker(runtime, 'ceiling', mover)
    sector.specialdata = result.id
    return true
end

local function spawnDoor(runtime: Runtime, sectorIndex: number, kind: string): boolean
    local sector = runtime.map.sectors[sectorIndex]
    if sector.specialdata ~= nil then return false end
    local mover: any = {
        sector = sectorIndex, type = kind, direction = 1, speed = FLOOR_SPEED,
        topWait = VDOOR_WAIT, count = 0, top = lowestCeiling(runtime, sectorIndex) - 4,
    }
    if kind == 'close' or kind == 'blazeClose' then
        mover.direction, mover.top = -1, lowestCeiling(runtime, sectorIndex) - 4
    elseif kind == 'close30ThenOpen' then
        mover.direction, mover.top = -1, sector.ceiling
    elseif kind == 'blazeRaise' or kind == 'blazeOpen' then
        mover.speed = FLOOR_SPEED * 4
    elseif kind == 'normal' or kind == 'open' then
        -- Defaults above are the vanilla raise/open destinations.
    else
        return false
    end
    local result = thinker(runtime, 'door', mover)
    sector.specialdata = result.id
    return true
end

local function taggedAction(runtime: Runtime, line: any, action: (number) -> boolean): boolean
    local started = false
    for _, sectorIndex in taggedSectors(runtime, line.tag) do
        if action(sectorIndex) then started = true end
    end
    return started
end

local function doFloor(runtime: Runtime, line: any, kind: string): boolean
    return taggedAction(runtime, line, function(sectorIndex: number): boolean
        local sector = runtime.map.sectors[sectorIndex]
        local destination, speed, direction, crush = sector.floor, FLOOR_SPEED, 1, false
        if kind == 'lowerFloor' then destination, direction = surroundingFloor(runtime, sectorIndex, true), -1
        elseif kind == 'lowerFloorToLowest' then destination, direction = surroundingFloor(runtime, sectorIndex, false), -1
        elseif kind == 'turboLower' then
            destination, direction, speed = surroundingFloor(runtime, sectorIndex, true), -1, FLOOR_SPEED * 4
            if destination ~= sector.floor then destination += 8 end
        elseif kind == 'raiseFloor' then
            destination = math.min(lowestCeiling(runtime, sectorIndex), sector.ceiling)
        elseif kind == 'raiseFloorCrush' then
            destination, crush = math.min(lowestCeiling(runtime, sectorIndex), sector.ceiling) - 8, true
        elseif kind == 'raiseFloorTurbo' then destination, speed = nextHighestFloor(runtime, sectorIndex), FLOOR_SPEED * 4
        elseif kind == 'raiseFloorToNearest' then destination = nextHighestFloor(runtime, sectorIndex)
        elseif kind == 'raiseFloor24' then destination = sector.floor + 24
        elseif kind == 'raiseFloor512' then destination = sector.floor + 512
        elseif kind == 'raiseFloor24AndChange' then destination = sector.floor + 24
        elseif kind == 'lowerAndChange' then
            destination, direction = surroundingFloor(runtime, sectorIndex, false), -1
            for _, otherIndex in neighbors(runtime, sectorIndex) do
                if runtime.map.sectors[otherIndex].floor == destination then
                    sector.floorTex = runtime.map.sectors[otherIndex].floorTex
                    sector.special = runtime.map.sectors[otherIndex].special
                    break
                end
            end
        elseif kind == 'raiseToTexture' then
            local minimum = math.huge
            for _, otherIndex in neighbors(runtime, sectorIndex) do
                minimum = math.min(minimum, (runtime.textureHeights and runtime.textureHeights[runtime.map.sectors[otherIndex].floorTex]) or 0)
            end
            destination = if minimum == math.huge then sector.floor else sector.floor + minimum
        else return false end
        return spawnFloor(runtime, sectorIndex, destination, speed, direction, kind, crush, line)
    end)
end

local function doCeiling(runtime: Runtime, line: any, kind: string): boolean
    local started = false
    if kind == 'crushAndRaise' or kind == 'fastCrushAndRaise' or kind == 'silentCrushAndRaise' then
        for _, mover in runtime.thinkers do
            if mover.kind == 'ceiling' and mover.tag == line.tag and mover.direction == 0 and not mover.removed then
                mover.direction = mover.oldDirection or -1
                started = true
            end
        end
    end
    local spawned = taggedAction(runtime, line, function(sectorIndex: number): boolean
        return spawnCeiling(runtime, sectorIndex, kind)
    end)
    return started or spawned
end

local function doDoor(runtime: Runtime, line: any, kind: string): boolean
    return taggedAction(runtime, line, function(sectorIndex: number): boolean
        return spawnDoor(runtime, sectorIndex, kind)
    end)
end

local function stairs(runtime: Runtime, line: any, turbo: boolean): boolean
    local started = false
    local size, speed = if turbo then 16 else 8, if turbo then FLOOR_SPEED * 4 else math.floor(FLOOR_SPEED / 4)
    for _, initial in taggedSectors(runtime, line.tag) do
        local current = initial
        local height = runtime.map.sectors[current].floor + size
        local texture = runtime.map.sectors[current].floorTex
        local visited: {[number]: boolean} = {}
        while not visited[current] do
            visited[current] = true
            if spawnFloor(runtime, current, height, speed, 1, 'stair', false, line) then started = true end
            local nextSector: number? = nil
            for _, candidate in neighbors(runtime, current) do
                local other = runtime.map.sectors[candidate]
                if not visited[candidate] and other.floorTex == texture and other.specialdata == nil then
                    nextSector = candidate
                    break
                end
            end
            if not nextSector then break end
            current = nextSector
            height += size
        end
    end
    return started
end

local function donut(runtime: Runtime, line: any): boolean
    local started = false
    for _, hole in taggedSectors(runtime, line.tag) do
        local ring: number? = nil
        local outer: number? = nil
        for _, candidate in neighbors(runtime, hole) do
            if not ring then ring = candidate else outer = candidate break end
        end
        if ring and outer then
            local ringSector, outerSector = runtime.map.sectors[ring], runtime.map.sectors[outer]
            if ringSector.specialdata == nil and runtime.map.sectors[hole].specialdata == nil then
                ringSector.special = 0
                local ringStarted = spawnFloor(runtime, ring, outerSector.floor, math.floor(FLOOR_SPEED / 2), 1, 'donutRaise', false, line)
                if ringStarted then
                    for _, mover in runtime.thinkers do
                        if mover.kind == 'floor' and mover.sector == ring and not mover.removed then mover.texture = outerSector.floorTex break end
                    end
                end
                started = ringStarted or started
                started = spawnFloor(runtime, hole, outerSector.floor, math.floor(FLOOR_SPEED / 2), -1, 'lowerFloor', false, line) or started
            end
        end
    end
    return started
end

local function platform(runtime: Runtime, line: any, kind: string, amount: number?): boolean
    return taggedAction(runtime, line, function(sectorIndex: number): boolean
        local sector = runtime.map.sectors[sectorIndex]
        if sector.specialdata ~= nil then
            if kind == 'perpetualRaise' then
                for _, mover in runtime.thinkers do
                    if mover.kind == 'plat' and mover.sector == sectorIndex and mover.status == 'stasis' and not mover.removed then
                        mover.status = mover.oldstatus or 'up'
                        return true
                    end
                end
            end
            return false
        end
        local low = math.min(surroundingFloor(runtime, sectorIndex, false), sector.floor)
        local high = sector.floor
        local speed, wait, status = PLAT_SPEED, 0, 'down'
        if kind == 'downWaitUpStay' or kind == 'blazeDWUS' then
            speed = if kind == 'blazeDWUS' then PLAT_SPEED * 8 else PLAT_SPEED * 4
            wait, high = PLAT_WAIT, sector.floor
        elseif kind == 'perpetualRaise' then
            low, high, wait = math.min(low, sector.floor), math.max(surroundingFloor(runtime, sectorIndex, true), sector.floor), PLAT_WAIT
            status = if randomByte(runtime) % 2 == 0 then 'up' else 'down'
        elseif kind == 'raiseToNearestAndChange' then
            speed, high = math.floor(PLAT_SPEED / 2), nextHighestFloor(runtime, sectorIndex)
            sector.floorTex = if line.right ~= 0xffff then runtime.map.sectors[sideSector(runtime, line.right) or sectorIndex].floorTex else sector.floorTex
            sector.special = 0
            status = 'up'
        elseif kind == 'raiseAndChange' then
            speed, high = math.floor(PLAT_SPEED / 2), sector.floor + (amount or 0)
            sector.floorTex = if line.right ~= 0xffff then runtime.map.sectors[sideSector(runtime, line.right) or sectorIndex].floorTex else sector.floorTex
            status = 'up'
        else return false end
        local mover = thinker(runtime, 'plat', {
            sector = sectorIndex, low = low, high = high, speed = speed, wait = wait,
            count = 0, status = status, oldstatus = status, type = kind,
            tag = line.tag, crush = false,
        })
        sector.specialdata = mover.id
        return true
    end)
end

local function lightOn(runtime: Runtime, line: any, value: number): boolean
    for _, sectorIndex in taggedSectors(runtime, line.tag) do
        local sector = runtime.map.sectors[sectorIndex]
        if value == 0 then
            local brightest = value
            for _, other in neighbors(runtime, sectorIndex) do brightest = math.max(brightest, runtime.map.sectors[other].light) end
            sector.light = brightest
        else sector.light = value end
    end
    return true
end

local function lightsOff(runtime: Runtime, line: any): boolean
    for _, sectorIndex in taggedSectors(runtime, line.tag) do
        local value = runtime.map.sectors[sectorIndex].light
        for _, other in neighbors(runtime, sectorIndex) do value = math.min(value, runtime.map.sectors[other].light) end
        runtime.map.sectors[sectorIndex].light = value
    end
    return true
end

local function startStrobe(runtime: Runtime, line: any): boolean
    local started = false
    for _, sectorIndex in taggedSectors(runtime, line.tag) do
        local sector = runtime.map.sectors[sectorIndex]
        if sector.specialdata == nil then
            thinker(runtime, 'strobe', {sector = sectorIndex, max = sector.light, min = minLight(runtime, sectorIndex, sector.light), dark = SLOW_DARK, bright = STROBE_BRIGHT, count = (randomByte(runtime) % 8) + 1})
            started = true
        end
    end
    return started
end

local switchPairs: {[string]: string} = {
    SW1BRCOM='SW2BRCOM', SW1BRN1='SW2BRN1', SW1BRN2='SW2BRN2', SW1BRNGN='SW2BRNGN', SW1BROWN='SW2BROWN', SW1COMM='SW2COMM', SW1COMP='SW2COMP', SW1DIRT='SW2DIRT', SW1EXIT='SW2EXIT', SW1GRAY='SW2GRAY', SW1GRAY1='SW2GRAY1', SW1METAL='SW2METAL', SW1PIPE='SW2PIPE', SW1SLAD='SW2SLAD', SW1STARG='SW2STARG', SW1STON1='SW2STON1', SW1STON2='SW2STON2', SW1STONE='SW2STONE', SW1STRTN='SW2STRTN',
    SW1BLUE='SW2BLUE', SW1CMT='SW2CMT', SW1GARG='SW2GARG', SW1GSTON='SW2GSTON', SW1HOT='SW2HOT', SW1LION='SW2LION', SW1SATYR='SW2SATYR', SW1SKIN='SW2SKIN', SW1VINE='SW2VINE', SW1WOOD='SW2WOOD',
    SW1PANEL='SW2PANEL', SW1ROCK='SW2ROCK', SW1MET2='SW2MET2', SW1WDMET='SW2WDMET', SW1BRIK='SW2BRIK', SW1MOD1='SW2MOD1', SW1ZIM='SW2ZIM', SW1STON6='SW2STON6', SW1TEK='SW2TEK', SW1MARB='SW2MARB', SW1SKULL='SW2SKULL',
}

local function oppositeTexture(texture: string): string?
    local upper = string.upper(texture)
    local pair = switchPairs[upper]
    if pair then return pair end
    if string.sub(upper, 1, 3) == 'SW1' then return 'SW2' .. string.sub(upper, 4) end
    if string.sub(upper, 1, 3) == 'SW2' then return 'SW1' .. string.sub(upper, 4) end
    return nil
end

local function changeSwitch(runtime: Runtime, line: any, useAgain: boolean): boolean
    if line.right == 0xffff then return false end
    local side = runtime.map.sides[line.right + 1]
    if not side then return false end
    local places = {{name = 'upper', texture = side.upper}, {name = 'middle', texture = side.middle}, {name = 'lower', texture = side.lower}}
    for _, place in places do
        local replacement = oppositeTexture(place.texture)
        if replacement then
            local original = place.texture
            side[place.name] = replacement
            if useAgain then
                local button = {line = line, lineIndex = 0, where = place.name, texture = original, count = BUTTON_TIME}
                for index, candidate in runtime.map.lines do if candidate == line then button.lineIndex = index break end end
                local occupied = false
                for _, existing in runtime.buttons do if existing.count > 0 and existing.line == line then occupied = true break end end
                if not occupied then table.insert(runtime.buttons, button) end
            end
            return true
        end
    end
    return false
end

local function hasKey(runtime: Runtime, value: any, colour: string): boolean
    local player = playerFor(runtime, value)
    local cards = if player then player.cards else nil
    if not cards and type(value) == 'table' then cards = value.cards end
    if not cards then return false end
    local lower = string.lower(colour)
    return cards[lower] == true or cards[colour .. 'card'] == true or cards[colour .. 'skull'] == true
        or cards[lower .. 'card'] == true or cards[lower .. 'skull'] == true
        or cards[lower] == 1 or cards[lower .. 'card'] == 1 or cards[lower .. 'skull'] == 1
end

local function locked(runtime: Runtime, line: any, value: any): boolean
    local special = line.special
    local colour: string? = nil
    if special == 26 or special == 32 or special == 99 or special == 133 then colour = 'blue'
    elseif special == 27 or special == 34 or special == 136 or special == 137 then colour = 'yellow'
    elseif special == 28 or special == 33 or special == 134 or special == 135 then colour = 'red' end
    if colour and not hasKey(runtime, value, colour) then
        local player = playerFor(runtime, value)
        if player then player.message = `PD_{string.upper(colour)}O` end
        return true
    end
    return false
end

local function manualDoor(runtime: Runtime, line: any, value: any): boolean
    local _, back = lineSectors(runtime, line)
    local sectorIndex = back or sideSector(runtime, line.right)
    if not sectorIndex then return false end
    local sector = runtime.map.sectors[sectorIndex]
    if sector.specialdata then
        for _, mover in runtime.thinkers do
            if mover.id == sector.specialdata and mover.kind == 'door' then
                if mover.direction == -1 then mover.direction = 1 elseif isPlayer(runtime, value) then mover.direction = -1 else return false end
                return true
            end
        end
    end
    local kind = if line.special == 117 then 'blazeRaise' elseif line.special == 118 then 'blazeOpen' elseif line.special == 31 or line.special == 32 or line.special == 33 or line.special == 34 then 'open' else 'normal'
    local started = spawnDoor(runtime, sectorIndex, kind)
    if started and (kind == 'open' or kind == 'blazeOpen') then line.special = 0 end
    return started
end

local function teleport(runtime: Runtime, line: any, side: number, value: any): boolean
    if side == 1 then return false end
    local object = objectFor(runtime, value)
    if not object or bit32.band(object.flags, 0x100) ~= 0 then return false end
    local target: any = nil
    local targetIsMapThing = false
    for _, thing in runtime.map.things do
        if thing.kind == 14 then
            local sectorIndex = sectorAtObject(runtime, {x = thing.x * FRACUNIT, y = thing.y * FRACUNIT})
            if sectorIndex and runtime.map.sectors[sectorIndex].tag == line.tag then target, targetIsMapThing = thing, true break end
        end
    end
    if not target then
        for _, candidate in runtime.game.mobjs do
            if candidate.kind == 14 then
                local sectorIndex = sectorAtObject(runtime, candidate)
                if sectorIndex and runtime.map.sectors[sectorIndex].tag == line.tag then target, targetIsMapThing = candidate, false break end
            end
        end
    end
    if not target then return false end
    if targetIsMapThing then
        object.x, object.y = target.x * FRACUNIT, target.y * FRACUNIT
    else
        object.x, object.y = target.x, target.y
    end
    local floorz, ceilingz = 0, 128 * FRACUNIT
    local targetSector = sectorAtObject(runtime, object)
    if targetSector then
        floorz, ceilingz = fixedHeight(runtime.map.sectors[targetSector].floor), fixedHeight(runtime.map.sectors[targetSector].ceiling)
    end
    object.floorz, object.ceilingz, object.z = floorz, ceilingz, floorz
    object.angle = mobj.angleFromDegrees(target.angle)
    object.momx, object.momy, object.momz = 0, 0, 0
    object.reactiontime = if object.playerId then 18 else object.reactiontime
    local player = playerFor(runtime, object)
    if player then player.angle, player.viewz = object.angle, object.z + player.viewheight end
    return true
end

local function exitLevel(runtime: Runtime, secret: boolean): boolean
    runtime.exited = true
    runtime.secretExit = secret
    return true
end

local function activate(runtime: Runtime, line: any, value: any, side: number, fromUse: boolean): boolean
    local special = line.special
    if fromUse then
        if side ~= 0 then return false end
        if line.flags and bit32.band(line.flags, 0x20) ~= 0 and not isPlayer(runtime, value) then return false end
        if locked(runtime, line, value) then return false end
        if not isPlayer(runtime, value) and not (special == 1 or special == 32 or special == 33 or special == 34) then return false end
    end
    local started = false
    if special == 1 or special == 26 or special == 27 or special == 28 or special == 31 or special == 32 or special == 33 or special == 34 or special == 117 or special == 118 then
        started = manualDoor(runtime, line, value)
    elseif special == 2 or special == 86 then started = doDoor(runtime, line, 'open')
    elseif special == 3 or special == 75 then started = doDoor(runtime, line, 'close')
    elseif special == 4 or special == 90 then started = doDoor(runtime, line, 'normal')
    elseif special == 5 or special == 64 or special == 91 or special == 101 then started = doFloor(runtime, line, 'raiseFloor')
    elseif special == 6 or special == 77 then started = doCeiling(runtime, line, 'fastCrushAndRaise')
    elseif special == 7 or special == 127 then started = stairs(runtime, line, special == 127)
    elseif special == 8 or special == 100 then started = stairs(runtime, line, special == 100)
    elseif special == 9 then started = donut(runtime, line)
    elseif special == 10 or special == 88 or special == 21 or special == 62 then started = platform(runtime, line, 'downWaitUpStay', if special == 62 then 1 else 0)
    elseif special == 11 then return exitLevel(runtime, false)
    elseif special == 12 or special == 80 then started = lightOn(runtime, line, 0)
    elseif special == 13 or special == 81 or special == 138 then started = lightOn(runtime, line, 255)
    elseif special == 14 then started = platform(runtime, line, 'raiseAndChange', 32)
    elseif special == 15 or special == 66 then started = platform(runtime, line, 'raiseAndChange', 24)
    elseif special == 16 or special == 76 then started = doDoor(runtime, line, 'close30ThenOpen')
    elseif special == 17 then started = startStrobe(runtime, line)
    elseif special == 18 or special == 69 then started = doFloor(runtime, line, 'raiseFloorToNearest')
    elseif special == 19 or special == 83 or special == 102 then started = doFloor(runtime, line, 'lowerFloor')
    elseif special == 20 or special == 68 or special == 95 then started = platform(runtime, line, 'raiseToNearestAndChange')
    elseif special == 22 or special == 93 then started = platform(runtime, line, 'raiseToNearestAndChange')
    elseif special == 23 or special == 60 or special == 82 then started = doFloor(runtime, line, 'lowerFloorToLowest')
    elseif special == 24 then started = doFloor(runtime, line, 'raiseFloor')
    elseif special == 25 or special == 49 or special == 73 then started = doCeiling(runtime, line, 'crushAndRaise')
    elseif special == 29 or special == 63 then started = doDoor(runtime, line, 'normal')
    elseif special == 67 then started = platform(runtime, line, 'raiseAndChange', 32)
    elseif special == 30 or special == 96 then started = doFloor(runtime, line, 'raiseToTexture')
    elseif special == 35 or special == 79 or special == 139 then started = lightOn(runtime, line, 35)
    elseif special == 36 or special == 70 or special == 98 then started = doFloor(runtime, line, 'turboLower')
    elseif special == 37 or special == 84 then started = doFloor(runtime, line, 'lowerAndChange')
    elseif special == 38 or special == 60 or special == 82 then started = doFloor(runtime, line, 'lowerFloorToLowest')
    elseif special == 39 or special == 97 or special == 125 or special == 126 then started = teleport(runtime, line, side, value)
    elseif special == 40 then
        local ceilingStarted = doCeiling(runtime, line, 'raiseToHighest')
        local floorStarted = doFloor(runtime, line, 'lowerFloorToLowest')
        started = ceilingStarted or floorStarted
    elseif special == 41 or special == 43 then started = doCeiling(runtime, line, 'lowerToFloor')
    elseif special == 42 or special == 50 then started = doDoor(runtime, line, 'close')
    elseif special == 44 or special == 72 then started = doCeiling(runtime, line, 'lowerAndCrush')
    elseif special == 45 then started = doFloor(runtime, line, 'lowerFloor')
    elseif special == 46 or special == 61 or special == 103 then started = doDoor(runtime, line, 'open')
    elseif special == 47 then started = platform(runtime, line, 'raiseToNearestAndChange')
    elseif special == 48 then return true
    elseif special == 51 then return exitLevel(runtime, true)
    elseif special == 52 then return exitLevel(runtime, false)
    elseif special == 53 or special == 87 then started = platform(runtime, line, 'perpetualRaise')
    elseif special == 54 or special == 89 then
        for _, mover in runtime.thinkers do if mover.kind == 'plat' and mover.tag == line.tag and not mover.removed then mover.oldstatus, mover.status = mover.status, 'stasis' end end
        started = true
    elseif special == 55 or special == 65 then started = doFloor(runtime, line, 'raiseFloorCrush')
    elseif special == 56 or special == 58 or special == 59 or special == 92 or special == 94 or special == 130 or special == 129 or special == 131 or special == 132 then
        local kind = 'raiseFloor'
        if special == 56 or special == 94 or special == 65 then kind = 'raiseFloorCrush'
        elseif special == 58 or special == 92 then kind = 'raiseFloor24'
        elseif special == 59 or special == 93 then kind = 'raiseFloor24AndChange'
        elseif special == 130 or special == 129 or special == 131 or special == 132 then kind = 'raiseFloorTurbo' end
        started = doFloor(runtime, line, kind)
    elseif special == 57 or special == 74 then
        for _, mover in runtime.thinkers do if mover.kind == 'ceiling' and mover.tag == line.tag and not mover.removed then mover.oldDirection, mover.direction = mover.direction, 0 end end
        started = true
    elseif special == 71 then started = doFloor(runtime, line, 'turboLower')
    elseif special == 104 then started = lightsOff(runtime, line)
    elseif special == 108 or special == 105 or special == 114 then started = doDoor(runtime, line, 'blazeRaise')
    elseif special == 109 or special == 106 or special == 111 or special == 112 or special == 115 or special == 99 or special == 133 or special == 134 or special == 135 or special == 136 or special == 137 then started = doDoor(runtime, line, 'blazeOpen')
    elseif special == 110 or special == 107 or special == 113 or special == 116 then started = doDoor(runtime, line, 'blazeClose')
    elseif special == 119 or special == 128 then started = doFloor(runtime, line, 'raiseFloorToNearest')
    elseif special == 120 or special == 121 or special == 122 or special == 123 then started = platform(runtime, line, 'blazeDWUS')
    elseif special == 124 then
        if fromUse then return true else return exitLevel(runtime, true) end
    elseif special == 140 then started = doFloor(runtime, line, 'raiseFloor512')
    elseif special == 141 then started = doCeiling(runtime, line, 'silentCrushAndRaise')
    end
    return started
end

local oneShotCross: {[number]: boolean} = {[2]=true,[3]=true,[4]=true,[5]=true,[6]=true,[8]=true,[10]=true,[12]=true,[13]=true,[16]=true,[17]=true,[19]=true,[22]=true,[25]=true,[30]=true,[35]=true,[36]=true,[37]=true,[38]=true,[39]=true,[40]=true,[44]=true,[51]=true,[52]=true,[53]=true,[54]=true,[56]=true,[57]=true,[58]=true,[59]=true,[100]=true,[104]=true,[108]=true,[109]=true,[110]=true,[119]=true,[121]=true,[124]=true,[125]=true,[130]=true,[141]=true}
local retriggerCross: {[number]: boolean} = {[72]=true,[73]=true,[74]=true,[75]=true,[76]=true,[77]=true,[79]=true,[80]=true,[81]=true,[82]=true,[83]=true,[84]=true,[86]=true,[87]=true,[88]=true,[89]=true,[90]=true,[91]=true,[92]=true,[93]=true,[94]=true,[95]=true,[96]=true,[97]=true,[98]=true,[105]=true,[106]=true,[107]=true,[120]=true,[126]=true,[128]=true,[129]=true}

local function tickMover(runtime: Runtime, mover: any): ()
    local sector = runtime.map.sectors[mover.sector]
    if mover.kind == 'door' then
        if mover.direction == 0 then
            mover.count -= 1
            if mover.count <= 0 then
                if mover.type == 'close30ThenOpen' then mover.direction = 1 else mover.direction = -1 end
            end
        elseif mover.direction == 2 then
            mover.count -= 1
            if mover.count <= 0 then mover.direction, mover.type = 1, 'normal' end
        elseif mover.direction == 1 then
            local result = movePlane(runtime, mover, 'ceiling', mover.speed, mover.top, false, 1)
            if result == 'pastdest' then
                if mover.type == 'normal' or mover.type == 'blazeRaise' then mover.direction, mover.count = 0, mover.topWait else removeThinker(runtime, mover) end
            end
        elseif mover.direction == -1 then
            local result = movePlane(runtime, mover, 'ceiling', mover.speed, sector.floor, false, -1)
            if result == 'pastdest' then
                if mover.type == 'close30ThenOpen' then mover.direction, mover.count = 0, 30 * TICRATE else removeThinker(runtime, mover) end
            elseif result == 'crushed' and mover.type ~= 'close' and mover.type ~= 'blazeClose' then mover.direction = 1 end
        end
    elseif mover.kind == 'floor' then
        local result = movePlane(runtime, mover, 'floor', mover.speed, mover.dest, mover.crush, mover.direction)
        if result == 'pastdest' then
            if mover.type == 'donutRaise' and mover.texture then sector.floorTex, sector.special = mover.texture, mover.newspecial or 0 end
            if mover.type == 'lowerAndChange' and mover.texture then sector.floorTex, sector.special = mover.texture, mover.newspecial or 0 end
            removeThinker(runtime, mover)
        end
    elseif mover.kind == 'ceiling' then
        if mover.direction == 0 then return end
        local destination = mover.bottom
        if mover.direction == 1 then destination = mover.top end
        local result = movePlane(runtime, mover, 'ceiling', mover.speed, destination, mover.crush, mover.direction)
        if result == 'pastdest' then
            if mover.direction == 1 and (mover.type == 'crushAndRaise' or mover.type == 'fastCrushAndRaise' or mover.type == 'silentCrushAndRaise') then
                mover.direction = -1
            elseif mover.direction == -1 and (mover.type == 'crushAndRaise' or mover.type == 'fastCrushAndRaise' or mover.type == 'silentCrushAndRaise') then
                mover.direction = 1
                if mover.type == 'crushAndRaise' then mover.speed = CEILING_SPEED end
            else
                removeThinker(runtime, mover)
            end
        elseif result == 'crushed' and (mover.type == 'crushAndRaise' or mover.type == 'silentCrushAndRaise' or mover.type == 'lowerAndCrush') then
            mover.speed = math.max(1, math.floor(CEILING_SPEED / 8))
        end
    elseif mover.kind == 'plat' then
        if mover.status == 'stasis' then return end
        if mover.status == 'up' then
            local result = movePlane(runtime, mover, 'floor', mover.speed, mover.high, false, 1)
            if result == 'pastdest' then
                mover.count, mover.status = mover.wait, 'waiting'
                if mover.type == 'downWaitUpStay' or mover.type == 'blazeDWUS' or mover.type == 'raiseAndChange' or mover.type == 'raiseToNearestAndChange' then removeThinker(runtime, mover) end
            elseif result == 'crushed' and not mover.crush then mover.count, mover.status = mover.wait, 'down' end
        elseif mover.status == 'down' then
            local result = movePlane(runtime, mover, 'floor', mover.speed, mover.low, false, -1)
            if result == 'pastdest' then mover.count, mover.status = mover.wait, 'waiting' end
        elseif mover.status == 'waiting' then
            mover.count -= 1
            if mover.count <= 0 then mover.status = if sector.floor == mover.low then 'up' else 'down' end
        end
    end
end

local function tickLight(runtime: Runtime, light: any): ()
    local sector = runtime.map.sectors[light.sector]
    if light.kind == 'flicker' then
        light.count -= 1
        if light.count <= 0 then
            local amount = (randomByte(runtime) % 4) * 16
            sector.light = math.max(light.min, light.max - amount)
            light.count = 4
        end
    elseif light.kind == 'flash' or light.kind == 'strobe' then
        light.count -= 1
        if light.count <= 0 then
            if sector.light == light.max then sector.light, light.count = light.min, (randomByte(runtime) % (light.dark or light.minTime or 1)) + 1
            else sector.light, light.count = light.max, (randomByte(runtime) % (light.bright or light.maxTime or 1)) + 1 end
        end
    elseif light.kind == 'glow' then
        sector.light += light.direction * GLOW_SPEED
        if sector.light <= light.min then sector.light, light.direction = light.min, 1 elseif sector.light >= light.max then sector.light, light.direction = light.max, -1 end
    end
end

local function finishButtons(runtime: Runtime): ()
    for _, button in runtime.buttons do
        if button.count > 0 then
            button.count -= 1
            if button.count == 0 then
                local side = runtime.map.sides[button.line.right + 1]
                if side then side[button.where] = button.texture end
            end
        end
    end
end

local function playerSpecial(runtime: Runtime): ()
    for _, player in runtime.game.players do
        local object = runtime.game.mobjs[player.moId]
        local sectorIndex = sectorAtObject(runtime, object)
        local sector = if sectorIndex then runtime.map.sectors[sectorIndex] else nil
        if object and sector and object.z == fixedHeight(sector.floor) then
            local special = sector.special
            local hurt = 0
            if special == 5 then hurt = 10 elseif special == 7 then hurt = 5 elseif special == 16 or special == 4 then
                if not hasIronfeet(player) or (runtime.leveltime % 32 == 0 and randomByte(runtime) < 5) then hurt = 20 end
            elseif special == 9 then
                player.secretcount = (player.secretcount or 0) + 1
                sector.special = 0
            elseif special == 11 then
                hurt = 20
            end
            if hurt > 0 and runtime.leveltime % 32 == 0 then damage(runtime, object, hurt) end
            if special == 11 and player.health <= 10 then exitLevel(runtime, false) end
        end
    end
end

function module.init(game: any, options: any?): Runtime
    local settings = options or {}
    local runtime: Runtime = {
        game = game, map = game.map, thinkers = {}, buttons = {},
        rngState = settings.seed or game.rngState or 0x13579bdf, nextId = 1,
        leveltime = game.leveltime or 0, exited = false, secretExit = false,
        textureHeights = settings.textureHeights or game.textureHeights or {},
    }
    game.specials = runtime
    game.leveltime = runtime.leveltime
    for _, sector in runtime.map.sectors do sector.specialdata = nil end
    for index, sector in runtime.map.sectors do
        local special = sector.special
        if special == 1 then thinker(runtime, 'flicker', {sector=index, max=sector.light, min=minLight(runtime,index,sector.light)+16, count=4}); sector.special = 0
        elseif special == 2 then thinker(runtime, 'strobe', {sector=index,max=sector.light,min=minLight(runtime,index,sector.light),dark=FAST_DARK,bright=STROBE_BRIGHT,count=(randomByte(runtime)%64)+1}); sector.special=0
        elseif special == 3 then thinker(runtime, 'strobe', {sector=index,max=sector.light,min=minLight(runtime,index,sector.light),dark=SLOW_DARK,bright=STROBE_BRIGHT,count=(randomByte(runtime)%64)+1}); sector.special=0
        elseif special == 4 then thinker(runtime, 'strobe', {sector=index,max=sector.light,min=minLight(runtime,index,sector.light),dark=FAST_DARK,bright=STROBE_BRIGHT,count=(randomByte(runtime)%64)+1})
        elseif special == 8 then thinker(runtime, 'glow', {sector=index,max=sector.light,min=minLight(runtime,index,sector.light),direction=-1}); sector.special=0
        elseif special == 9 then game.totalSecret = (game.totalSecret or 0) + 1
        elseif special == 10 then spawnDoor(runtime,index,'normal'); runtime.map.sectors[index].special=0; for _, mover in runtime.thinkers do if mover.sector==index and mover.kind=='door' then mover.direction,mover.count=0,30*TICRATE end end
        elseif special == 12 then thinker(runtime,'strobe',{sector=index,max=sector.light,min=minLight(runtime,index,sector.light),dark=SLOW_DARK,bright=STROBE_BRIGHT,count=1}); sector.special=0
        elseif special == 13 then thinker(runtime,'strobe',{sector=index,max=sector.light,min=minLight(runtime,index,sector.light),dark=FAST_DARK,bright=STROBE_BRIGHT,count=1}); sector.special=0
        elseif special == 14 then spawnDoor(runtime,index,'normal'); sector.special=0; for _, mover in runtime.thinkers do if mover.sector==index and mover.kind=='door' then mover.direction,mover.count=2,5*60*TICRATE end end
        elseif special == 17 then thinker(runtime,'flicker',{sector=index,max=sector.light,min=minLight(runtime,index,sector.light)+16,count=4}); sector.special=0 end
    end
    return runtime
end

local function runtimeOf(value: any): Runtime
    local runtime = if value and value.thinkers and value.map and value.buttons and value.nextId then value else if value then value.specials else nil
    if not runtime then error('specials: operation requires init(game) runtime', 3) end
    return runtime
end

function module.tick(value: any): Runtime
    local runtime = runtimeOf(value)
    local count = #runtime.thinkers
    for index = 1, count do
        local mover = runtime.thinkers[index]
        if mover and not mover.removed then
            if mover.kind == 'door' or mover.kind == 'floor' or mover.kind == 'ceiling' or mover.kind == 'plat' then tickMover(runtime, mover)
            elseif mover.kind == 'flicker' or mover.kind == 'flash' or mover.kind == 'strobe' or mover.kind == 'glow' then tickLight(runtime, mover) end
        end
    end
    finishButtons(runtime)
    for _, line in runtime.map.lines do if line.special == 48 and line.right ~= 0xffff then runtime.map.sides[line.right + 1].xOffset += 1 end end
    playerSpecial(runtime)
    local live: {any} = {}
    for _, mover in runtime.thinkers do if not mover.removed then table.insert(live, mover) end end
    runtime.thinkers = live
    runtime.leveltime += 1
    runtime.game.leveltime = runtime.leveltime
    return runtime
end

local useSpecials: {[number]: boolean} = {
    [1]=true,[7]=true,[9]=true,[11]=true,[14]=true,[15]=true,[18]=true,[20]=true,[21]=true,[23]=true,[26]=true,[27]=true,[28]=true,[29]=true,[31]=true,[32]=true,[33]=true,[34]=true,[41]=true,[42]=true,[43]=true,[45]=true,[49]=true,[50]=true,[51]=true,[55]=true,[60]=true,[61]=true,[62]=true,[63]=true,[64]=true,[65]=true,[66]=true,[67]=true,[68]=true,[69]=true,[70]=true,[71]=true,[99]=true,[101]=true,[102]=true,[103]=true,[111]=true,[112]=true,[113]=true,[114]=true,[115]=true,[116]=true,[117]=true,[118]=true,[122]=true,[123]=true,[127]=true,[131]=true,[132]=true,[133]=true,[134]=true,[135]=true,[136]=true,[137]=true,[138]=true,[139]=true,[140]=true,
}
local switchUseSpecials: {[number]: boolean} = {
    [7]=true,[9]=true,[11]=true,[14]=true,[15]=true,[18]=true,[20]=true,[21]=true,[23]=true,[29]=true,[41]=true,[49]=true,[50]=true,[51]=true,[55]=true,[101]=true,[102]=true,[103]=true,[111]=true,[112]=true,[113]=true,[122]=true,[127]=true,[131]=true,[133]=true,[135]=true,[137]=true,[140]=true,[42]=true,[43]=true,[45]=true,[60]=true,[61]=true,[62]=true,[63]=true,[64]=true,[65]=true,[66]=true,[67]=true,[68]=true,[69]=true,[70]=true,[114]=true,[115]=true,[116]=true,[123]=true,[132]=true,[99]=true,[134]=true,[136]=true,[138]=true,[139]=true,
}

function module.useLine(value: any, lineValue: any, thing: any, side: number?): boolean
    local runtime = runtimeOf(value)
    local line = lineFor(runtime, lineValue)
    local actualSide = side or 0
    local special = line.special
    if not useSpecials[special] then return false end
    local result = activate(runtime, line, thing, actualSide, true)
    local button = special == 42 or special == 43 or special == 45 or special == 60 or special == 61 or special == 62 or special == 63 or special == 64 or special == 65 or special == 66 or special == 67 or special == 68 or special == 69 or special == 70 or special == 114 or special == 115 or special == 116 or special == 123 or special == 132 or special == 134 or special == 136 or special == 138 or special == 139
    if result and switchUseSpecials[special] then changeSwitch(runtime, line, button) end
    return result
end

function module.crossLine(value: any, lineValue: any, side: number, thing: any): boolean
    local runtime = runtimeOf(value)
    local line = lineFor(runtime, lineValue)
    local special = line.special
    if not oneShotCross[special] and not retriggerCross[special] then return false end
    if (special == 125 or special == 126) and isPlayer(runtime, thing) then return false end
    if not isPlayer(runtime, thing) then
        if not (special == 39 or special == 97 or special == 125 or special == 126 or special == 4 or special == 10 or special == 88) then return false end
        if special == 125 or special == 126 then if isPlayer(runtime, thing) then return false end end
    end
    local result = activate(runtime, line, thing, side, false)
    if oneShotCross[special] and special ~= 52 and special ~= 124 then line.special = 0 end
    return result
end

function module.shootLine(value: any, lineValue: any, thing: any): boolean
    local runtime = runtimeOf(value)
    local line = lineFor(runtime, lineValue)
    local special = line.special
    if special ~= 24 and special ~= 46 and special ~= 47 then return false end
    local result = false
    if special == 24 then result = doFloor(runtime, line, 'raiseFloor')
    elseif special == 46 then result = doDoor(runtime, line, 'open')
    else result = platform(runtime, line, 'raiseToNearestAndChange') end
    if result then changeSwitch(runtime, line, special == 46) end
    return result
end

function module.snapshot(value: any): any
    local runtime = runtimeOf(value)
    local sectors, lines, sides = {}, {}, {}
    for _, sector in runtime.map.sectors do table.insert(sectors, {floor=sector.floor,ceiling=sector.ceiling,floorTex=sector.floorTex,ceilingTex=sector.ceilingTex,light=sector.light,special=sector.special,tag=sector.tag}) end
    for _, line in runtime.map.lines do table.insert(lines, {special=line.special,tag=line.tag,flags=line.flags}) end
    for _, side in runtime.map.sides do table.insert(sides, {xOffset=side.xOffset,yOffset=side.yOffset,upper=side.upper,lower=side.lower,middle=side.middle}) end
    local thinkers, buttons = {}, {}
    for _, mover in runtime.thinkers do
        if not mover.removed then
            local copy: any = {}
            for key, item in mover do if key ~= 'removed' then copy[key] = item end end
            table.insert(thinkers, copy)
        end
    end
    for _, button in runtime.buttons do table.insert(buttons, {lineIndex=button.lineIndex,where=button.where,texture=button.texture,count=button.count}) end
    return {version=1,leveltime=runtime.leveltime,rngState=runtime.rngState,nextId=runtime.nextId,exited=runtime.exited,secretExit=runtime.secretExit,sectors=sectors,lines=lines,sides=sides,thinkers=thinkers,buttons=buttons}
end

function module.restore(value: any, snapshot: any): Runtime
    local runtime = runtimeOf(value)
    if type(snapshot) ~= 'table' or snapshot.version ~= 1 then error('specials: unsupported snapshot', 2) end
    runtime.leveltime, runtime.rngState, runtime.nextId = snapshot.leveltime, snapshot.rngState, snapshot.nextId
    runtime.exited, runtime.secretExit = snapshot.exited == true, snapshot.secretExit == true
    for _, sector in runtime.map.sectors do sector.specialdata = nil end
    for index, saved in snapshot.sectors do
        local sector = runtime.map.sectors[index]
        if sector then for key, item in saved do sector[key] = item end end
    end
    for index, saved in snapshot.lines do
        local line = runtime.map.lines[index]
        if line then line.special, line.tag, line.flags = saved.special, saved.tag, saved.flags end
    end
    for index, saved in snapshot.sides do
        local side = runtime.map.sides[index]
        if side then for key, item in saved do side[key] = item end end
    end
    runtime.thinkers, runtime.buttons = {}, {}
    for _, saved in snapshot.thinkers do
        local mover: any = {}
        for key, item in saved do mover[key] = item end
        mover.removed = false
        table.insert(runtime.thinkers, mover)
        if mover.sector and runtime.map.sectors[mover.sector] and (mover.kind == 'door' or mover.kind == 'floor' or mover.kind == 'ceiling' or mover.kind == 'plat') then runtime.map.sectors[mover.sector].specialdata = mover.id end
    end
    for _, saved in snapshot.buttons do
        local line = runtime.map.lines[saved.lineIndex]
        if line then table.insert(runtime.buttons, {line=line,lineIndex=saved.lineIndex,where=saved.where,texture=saved.texture,count=saved.count}) end
    end
    runtime.game.leveltime = runtime.leveltime
    runtime.game.specials = runtime
    return runtime
end

module.stateSnapshot = module.snapshot
module.save = module.snapshot
module.load = module.restore
module.restoreState = module.restore
module.tic = module.tick

return module
