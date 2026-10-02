--!nonstrict
-- @doom/agent: the input and observation boundary for a player that is not at
-- a keyboard. A plan is a short list of timed steps ("turn 40 degrees left
-- while running forward for 20 tics, then fire for 10"); the host turns it
-- into one ticcmd per tic and falls back to standing still when it runs out.
-- Plans and observations cross between processes as small files in a session
-- folder, one pair per slot.
local fs = require('@jess/fs')
local play = require('./play/api')

local module = {}

export type Step = { tics: number, forward: number, side: number, turn: number, buttons: number }
export type Plan = { seq: number, steps: { Step }, at: number, left: number, turnLeft: number }

local Weapons = {
  fist = 0,
  chainsaw = 0,
  pistol = 1,
  shotgun = 2,
  ssg = 2,
  chaingun = 3,
  rocket = 4,
  plasma = 5,
  bfg = 6,
}

local MaxStepTics, MaxSteps = 350, 16

-- Parses steps written as `key=value` words. Keys: forward and side (-50 to
-- 50), turn (degrees over the whole step, positive is left), attack, use,
-- weapon (a name or 0 to 7), and for (tics, default 10).
function module.parseSteps(texts: { string }): { Step }
  local steps: { Step } = {}
  for _, text in texts do
    local step: Step = { tics = 10, forward = 0, side = 0, turn = 0, buttons = 0 }
    for word in string.gmatch(text, '%S+') do
      local key, value = string.match(word, '^(%a+)=?(.*)$')
      local number = tonumber(value)
      if key == 'forward' or key == 'side' then
        step[key] = math.clamp(math.floor(number or 50), -50, 50)
      elseif key == 'back' then
        step.forward = -math.clamp(math.floor(number or 50), 0, 50)
      elseif key == 'turn' then
        step.turn = math.floor(math.clamp(number or 0, -360, 360) * 65536 / 360 + 0.5)
      elseif key == 'for' then
        step.tics = math.clamp(math.floor(number or 10), 1, MaxStepTics)
      elseif key == 'attack' or key == 'fire' then
        step.buttons = bit32.bor(step.buttons, 1)
      elseif key == 'use' then
        step.buttons = bit32.bor(step.buttons, 2)
      elseif key == 'weapon' then
        local weapon = Weapons[string.lower(value)] or number
        if not weapon then error(`unknown weapon '{value}'`, 2) end
        step.buttons = bit32.bor(step.buttons, 4 + bit32.band(weapon, 7) * 8)
      else
        error(`unknown plan word '{word}': use forward= back= side= turn= for= attack use weapon=`, 2)
      end
    end

    table.insert(steps, step)
    if #steps > MaxSteps then error(`a plan holds at most {MaxSteps} steps`, 2) end
  end

  return steps
end

function module.planTics(steps: { Step }): number
  local total = 0
  for _, step in steps do
    total += step.tics
  end

  return total
end

local function planPath(dir: string, slot: number): string
  return fs.join(dir, `slot{slot}.plan`)
end

function module.observationPath(dir: string, slot: number): string
  return fs.join(dir, `slot{slot}.obs`)
end

function module.readyPath(dir: string, slot: number): string
  return fs.join(dir, `slot{slot}.ready`)
end

-- Replaces the slot's plan. `seq` only has to differ from the last one sent.
function module.writePlan(dir: string, slot: number, seq: number, steps: { Step }): ()
  local lines = { `seq {seq}` }
  for _, step in steps do
    table.insert(lines, `{step.tics} {step.forward} {step.side} {step.turn} {step.buttons}`)
  end

  fs.replace(planPath(dir, slot), table.concat(lines, '\n') .. '\n')
end

-- Returns the slot's plan when it is newer than `lastSeq`.
function module.readPlan(dir: string, slot: number, lastSeq: number?): Plan?
  local text = fs.read(planPath(dir, slot))
  if not text then return nil end

  local seq = tonumber(string.match(text, '^seq (%d+)'))
  if not seq or seq == lastSeq then return nil end

  local steps: { Step } = {}
  for tics, forward, side, turn, buttons in string.gmatch(text, '\n(%d+) (%-?%d+) (%-?%d+) (%-?%d+) (%d+)') do
    table.insert(steps, {
      tics = math.clamp(tonumber(tics) :: number, 1, MaxStepTics),
      forward = math.clamp(tonumber(forward) :: number, -50, 50),
      side = math.clamp(tonumber(side) :: number, -50, 50),
      turn = math.clamp(tonumber(turn) :: number, -65536, 65536),
      buttons = bit32.band(tonumber(buttons) :: number, 63),
    })

    if #steps == MaxSteps then break end
  end

  return { seq = seq, steps = steps, at = 1, left = if steps[1] then steps[1].tics else 0, turnLeft = if steps[1] then steps[1].turn else 0 }
end

-- The plan's ticcmd for this tic, or nil once it has run out. The turn is
-- spread evenly over the step, and a weapon change is sent on its first tic.
function module.nextCommand(plan: Plan?): any
  if not plan then return nil end

  local step = plan.steps[plan.at]
  while step and plan.left <= 0 do
    plan.at += 1
    step = plan.steps[plan.at]
    if step then
      plan.left, plan.turnLeft = step.tics, step.turn
    end
  end

  if not step then return nil end

  local turn = math.clamp(math.floor(plan.turnLeft / plan.left + 0.5), -32768, 32767)
  local buttons = step.buttons
  if plan.left ~= step.tics then buttons = bit32.band(buttons, 3) end

  plan.turnLeft -= turn
  plan.left -= 1
  return { forwardmove = step.forward, sidemove = step.side, angleturn = turn, buttons = buttons }
end

function module.remaining(plan: Plan?): number
  if not plan then return 0 end

  local total = math.max(plan.left, 0)
  for index = plan.at + 1, #plan.steps do
    total += plan.steps[index].tics
  end

  return total
end

local SpecialNames = { [11] = 'exit switch', [51] = 'secret exit switch', [52] = 'exit line', [124] = 'secret exit line' }

-- One slot's observation as text: what an agent reads before it plans.
function module.describe(slot: number, extra: { string }?): string
  local view = play.observe(slot)
  local lines = {
    `tic {view.gametic} map {view.map} state {view.gamestate} you-are slot {slot}`,
    `{if view.alive then 'ALIVE' else 'DEAD (send a plan with use to respawn)'} health {view.health} armor {view.armor}`
      .. `{if view.damaged then ' TAKING-DAMAGE' else ''}`,
    `weapon {view.weapon}; owned {table.concat(view.weapons, ', ')}`,
    `ammo bullets {view.ammo.bullets} shells {view.ammo.shells} rockets {view.ammo.rockets} cells {view.ammo.cells}`,
    `position x {view.x} y {view.y} z {view.z} facing {view.angle} degrees`,
    `frags vs slots 0-3: {table.concat(view.frags, ' ')}`,
  }

  if view.walls then
    local parts = {}
    for _, wall in view.walls do
      local note = ''
      if wall.special then note = ` ({SpecialNames[wall.special] or `usable/trigger line {wall.special}`})` end
      table.insert(parts, `{if wall.bearing > 0 then '+' else ''}{wall.bearing}:{wall.clear}{note}`)
    end

    table.insert(lines, `walkable distance by bearing (degrees left of facing, max 512): {table.concat(parts, '  ')}`)
  end

  if view.things then
    if #view.things == 0 then table.insert(lines, 'in sight: nothing') end

    for index, thing in view.things do
      if index > 24 then break end

      local who = if thing.slot then ` slot {thing.slot}` else ''
      local health = if thing.health then ` health {thing.health}` else ''
      table.insert(
        lines,
        `in sight: {thing.kind} {thing.type}{who} distance {thing.distance} bearing {if thing.bearing > 0 then '+' else ''}{thing.bearing}`
          .. ` height {thing.height}{health}`
      )
    end
  end

  if extra then
    for _, line in extra do
      table.insert(lines, line)
    end
  end

  return table.concat(lines, '\n') .. '\n'
end

return module
