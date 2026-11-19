# Writing mods for DOOM for Jess

A mod is a Jess package. It depends on `org.dreamweave.doom`, exports a module that returns a
definition made with `@doom/mod`, and provides that definition to the game through a managed
module. This guide is the `@doom/mod` API, version 1.

## The contract

- **Simulation changes run inside the tic.** Everything a mod registers that changes the game
  (hooks, actors, states, actions, weapons, pickups, spawn tables, encounters, map order) is
  called synchronously when the tic reaches it, in the order the mods were composed. Every peer
  of a netgame runs the same handlers in the same order on the same state, so a mod must be a
  function of the game state alone: no clocks, no files, no `math.random`, no state outside the
  game. Draw random numbers with `registry.random()` (the game's own), and keep what you must
  remember in `registry.state()`, a table saved with the game.
- **Cosmetic extensions can't reach back.** HUD drawers, sounds and event listeners run after
  the tic, on one machine, and get copies or read-only views. The application also emits the
  game's announcements as `@jess/events` named `doom.kill`, `doom.key`, `doom.levelStart` and
  `doom.levelExit`, delivered at the end of the frame: fine for a kill feed, never for anything
  that changes the game.
- **Capabilities are declared.** A definition lists what it uses; the registry refuses anything
  else, naming the mod and the capability. `rules`, `actors`, `weapons`, `pickups`, `spawns`,
  `maps` and `encounters` change the simulation; `hud`, `audio` and `events` are cosmetic.
- **Content is negotiated.** A netgame compares every peer's IWAD, WADs and simulation mods
  (`id@version#digest`, in order) and refuses a player whose list differs; a save records the
  same list and refuses to load under another. The digest is the mod package's own payload
  (`jess.payload()`), the same from its source folder and from its JPK. Cosmetic-only mods are
  not compared, so players may differ in them.

## A mod package

```text
mymod/
  jess.toml
  src/mymod.jsl      the definition, exported as @mymod
  src/managed.jsl    hands it to the game
  tests/mymod_test.jsl
```

```toml
manifest_version = 1

[package]
id = "org.example.mymod"
version = "1.0.0"
jess_api = "1"
include = ["src", "tests"]
tests = ["tests/mymod_test.jsl"]

[dependencies]
"org.dreamweave.doom" = "^0.1"

[modules]
"@mymod" = "src/mymod.jsl"

[[layer]]
id = "org.example.mymod"
exports = ["@mymod"]

[managed.mod]
module = "src/managed.jsl"
interface = "doom.mods"
```

`src/managed.jsl` is always the same two lines:

```luau
--!strict
local modApi = require('@doom/mod')

return modApi.provide(require('./mymod'))
```

And the definition:

```luau
--!strict
local modApi = require('@doom/mod')

return modApi.define {
  id = 'org.example.mymod',
  version = '1.0.0',
  api = 1,
  title = 'My mod',
  capabilities = { 'actors', 'spawns' },
  payload = jess.payload(),
  register = function(registry: modApi.Registry)
    registry.actor {
      name = 'MT_GIANTIMP',
      base = 'MT_TROOP',
      doomednum = 30200,
      info = { spawnhealth = 240, radius = 30 * 65536, height = 80 * 65536 },
    }
    registry.replace('MT_TROOP', 'MT_GIANTIMP')
  end,
}
```

`define` checks the definition and fails with the field at fault: the id is a reverse-domain
name, the version a semantic version, `api` no newer than the game's `@doom/mod`
(`modApi.ApiVersion`, now 1), the capabilities known and listed once.

## Composition and override order

A game's mods come from the interface `doom.mods`. Each mod's managed module provides it with
`modApi.provide`, which takes the list the packages before it composed and appends itself. The
order is Jess's load order, which is dependency order: a package after everything it depends on,
and packages free to go next by package id. So:

- a mod that must run after another declares a dependency on it;
- two mods that don't know each other run in package id order (the example mod pack runs
  `org.dreamweave.doom.arsenal` before `org.dreamweave.doom.coop-director`);
- the rulesets run before every mod, so a mod's `damage` hook sees the damage the mode allowed.

A game is a package too: a mod pack depends on the game and the mods and gives itself the game's
command line through `@doom/launch` (see `mods/modpack`):

```toml
[dependencies]
"org.dreamweave.doom" = "^0.1"
"org.example.mymod" = "^1"

[targets.doom]
kind = "application"
entry = "src/entry.jsl"
capabilities = ["gpu.device", "gpu.window", "input.actions", "input.configure", "audio.output",
  "network.transport", "filesystem.read", "filesystem.write"]
```

```luau
--!strict
local launch = require('@doom/launch')

launch.apply(launch.parse({ ... }))
```

### Replacing a mode's rules

The modes' rulesets are the interface `doom.rules`, a table of `coop`, `ffa` and `tdm`
definitions. A package that depends on `org.dreamweave.doom` and provides `doom.rules` replaces
it; `interfaceOverride` gets the table it replaces, to keep the modes it doesn't change:

```luau
--!strict
local modApi = require('@doom/mod')

local rules: { [string]: modApi.Definition } = {}

rules.tdm = modApi.define {
  id = 'org.example.capture-rules',
  version = '1.0.0',
  api = 1,
  capabilities = { 'rules' },
  payload = jess.payload(),
  register = function(registry: modApi.Registry)
    -- ... the team rules this mode plays by
  end,
}

return {
  on = {
    host = {
      interfaceOverride = function(previous: { [string]: modApi.Definition })
        rules.coop, rules.ffa = previous.coop, previous.ffa
      end,
    },
  },

  interface = rules,
}
```

with `[managed.rules] module = "src/rules.jsl"` and `interface = "doom.rules"` in its manifest.
Since the rulesets are part of every peer's content manifest, everyone must load the override.

## The registry

`register(registry)` runs before the first tic of every game started or loaded with the mod.

| Member | Capability | Does |
| --- | --- | --- |
| `hook(name, handler)` | `rules` | Joins a simulation hook (below). |
| `actor { name, base?, doomednum?, info?, frames?, states? }` | `actors` | A new thing type, from a built-in one or from `MT_POSSESSED`'s fields; returns its type number. `frames` are new states (`{ label?, sprite, frame, tics, action?, next?, bright? }`, `next` a label, a built-in `S_` name, or the next frame), `states` maps info fields such as `seestate` to labels. |
| `thing(name, fields)` | `actors` | Changes a built-in thing's info: `speed`, `spawnhealth`, `painchance`, `radius`, ... |
| `action(name, handler)` | `actors` or `weapons` | An action states can name, or a replacement for a built-in one (`A_FireShotgun`). Monster actions get `(mobj)`, weapon actions `(player, psprite)`. |
| `weapon(slot, fields)` | `weapons` | Changes a weapon's info: `ammo`, `upstate`, `downstate`, `readystate`, `atkstate`, `flashstate` (state names or numbers). |
| `pickup(sprite, handler)` | `pickups` | What touching a pickup of that sprite does: `handler(player, special)` returns true when it was taken (the thing is then removed). |
| `spawn(doomednum, thing \| false)` | `spawns` | What a map's editor number spawns, or nothing. |
| `replace(thing, replacement)` | `spawns` | Every map spawn of a type spawns another. |
| `encounter { map, tic?, x?, y?, radius?, spawn, message? }` | `encounters` | Monsters that arrive on a map at a level time or when a player comes within `radius` of `x`, `y`, once per level. |
| `nextMap(map, following, secret?)` | `maps` | Which map an exit leads to, within the episode (or `MAPxx`). |
| `state()` | any | The mod's saved table in the game. Plain values only. |
| `random()` | any | The game's random numbers, 0 to 255. |
| `engine` | any | The simulation itself, with Linux Doom 1.10's names (`SpawnMobj`, `DamageMobj`, `G.players`, ...). Its shape can change between versions; prefer the members above. |
| `hud(drawer)` | `hud` | `drawer(frame, game, slot)` draws over the view after the status bar. |
| `sound(event, name)` | `audio` | A sound (`pistol`, without `sfx_`) heard by the local player when an announcement (`kill`, `key`, `levelStart`, `levelExit`) happens. |
| `on(event, listener)` | `events` | A listener for the announcements (`kill`, `key`, `levelStart`, `levelExit`) after each tic. |

### Hooks

| Hook | Called | Handler |
| --- | --- | --- |
| `damage` | before damage lands | `(damage, target, inflictor, source) -> number?`; the new damage, nil to keep it; 0 or less stops it, knockback and pain too. |
| `kill` | after frags and counts are kept | `(source, target)` |
| `reborn` | after a dead player is emptied | `(player, previous)`; `previous` is what they carried. |
| `spawnPlayer` | after a player's body is spawned | `(player)` |
| `deathmatchStarts` | before a deathmatch spawn | `(playernum, starts) -> { start }?`; the order to try them. |
| `pickup` | before a pickup's default | `(player, special) -> boolean?`; true skips the default. |
| `key` | after a player gets a key | `(player, card)` |
| `thingType` | for each map spot | `(type, mapthing) -> number?`; -1 spawns nothing. |
| `tic` | after each level tic's thinkers | `()` |
| `player` | after each player's think | `(player)` |
| `levelStart`, `levelExit` | as a level begins and is left | `()`, `(secret)` |
| `nextMap` | when an exit picks the next map | `(mapname, secret) -> string?` |

Handlers of a hook run in registration order: rulesets first, then mods in composition order.

## Testing a mod

`@doom/testing` writes small synthetic WADs (one room, any things) so a mod's tests need no game
data; `@doom/setup` starts a game with the mod the way the application does:

```luau
--!nonstrict
local mymod = require('@mymod')
local play = require('@doom/play')
local setup = require('@doom/setup')
local testing = require('@doom/testing')
local test = require('@jess/test')

local suite = test.new()

suite.it('turns imps into giant imps', function()
  local wad = testing.roomWad('mymod.wad', { things = { { 256, 64, 90, 1 }, { 256, 400, 270, 3001 } } })
  local game = setup.start(wad, { mode = 'single', mods = { mymod }, players = { true } })
  -- ... look through game.thinkercap for MT_GIANTIMP
  testing.remove('mymod.wad')
end)

return suite
```

Run it with the game beside it: `jess package test mymod --package path/to/doom/lua`, or as a
member of a workspace with the game. The examples' suites (`mods/*/tests`) test what they change
and that a game without them is the game it was.

To check a mod in netgames, the headless peer loads mods by module name:

    jess run --package lua --package mymod --capability network.transport \
      --capability filesystem.read --capability filesystem.write \
      lua/bin/doom-peer.jsl host 127.0.0.1:5029 -players 2 -tokens tokens -mod @mymod

## Versions

`@doom/mod` follows its `ApiVersion`. A new version may add registry members and hooks; one that
removes or changes a member raises `ApiVersion`, and `OldestApiVersion` says which mods still run.
Save files and recordings carry a format version of their own and the content list; a game
refuses a save or recording of another format, or of other content, rather than guess.
