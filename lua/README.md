# doom.jpk

DOOM's game simulation in Luau, for Jess. The package holds **no** IWAD data: supply a legally
obtained DOOM-family WAD at runtime.

The source is distributed under GPL-2.0 (see `LICENSE.TXT`); it is derived from the released id
DOOM source.

## What is in it

- `@doom/play` is a port of Linux Doom 1.10's play simulation (`p_*.c`, `g_game.c`): map setup,
  thinkers, movement and collision, sliding, hitscan and projectiles, every monster and its state
  actions, weapons, pickups, doors, floors, ceilings, lifts, stairs, crushers, lights, teleporters,
  switches, all line and sector specials, deathmatch spawns and frags, item respawn, nightmare
  respawn, level exits, and map progression. State and thing tables are generated from `info.c`
  by `tools/geninfo.jsl`.
- It plays vanilla demos. All thirteen built-in demos of `doom.wad`, `doom2.wad`, `plutonia.wad`,
  and `tnt.wad` run to the recorded player's death, tic for tic (`tests/play_test.jsl`).
- Save games (`play.save`, `play.load`) store the whole game graph and restore to the same future.
- `@doom/agent` and `bin/doom-arena.jsl` run a live deathmatch for players that plan rather than
  press keys: each slot reads a text observation and writes short timed plans.
- `@doom/net` and `@doom/netgame` are the tic-command protocol over dream.udp: an authoritative
  host, clients that replay the same tics, and a world hash to compare.
- WAD, map, palette, patch, and texture readers, and a headless indexed renderer for the title,
  the automap, and a first-person view.

What it is not: there is no sound, no status bar, menu, intermission or finale screen (the
intermission is a timed pause that any player can skip), and the first-person renderer draws
the map's starting geometry, so opened doors and moved lifts are not shown. The original's
overflow emulation (intercepts, spechits, the body queue) is not reproduced, so a demo that
relies on one of those can drift.

## Running

Every command is `jess run --package doom.jpk --capability network.transport doom.jsl ...` (or
`--package lua lua/bin/doom.jsl` from this repository):

    doom.jsl info      DOOM.WAD
    doom.jsl demo      DOOM.WAD DEMO1          # play a demo lump or a .lmp file, print the outcome
    doom.jsl run       DOOM.WAD E1M1 350       # idle for 350 tics
    doom.jsl statehash DOOM.WAD E1M1 350 DEMO1
    doom.jsl save      DOOM.WAD E1M5 save.bin 800 DEMO1
    doom.jsl load      DOOM.WAD save.bin 100 view.ppm
    doom.jsl title     DOOM.WAD title.ppm
    doom.jsl map       DOOM.WAD E1M5 map.ppm DEMO1
    doom.jsl view      DOOM.WAD E1M1 view.ppm

From Luau:

```luau
local play = require('@doom/play')

local game = play.new('doom2.wad', { mapName = 'MAP01', skill = 3 })
for _ = 1, 35 do
  play.tick { [0] = play.command { forward = 50, turn = 2, attack = true } }
end

print(play.summary().players[1].x, play.hash())
```

`play.tick` takes one ticcmd per slot (0 to 3). `play.observe(slot)` returns what that player
can know: its own state, everything in line of sight with distance and bearing, and how far it
can walk in ten directions. One game runs per Jess runtime.

## Live deathmatch for agents

The host runs the match at a chosen speed and never waits for anyone: a slot with no plan
stands still.

    jess run --package lua --capability network.transport lua/bin/doom-arena.jsl \
      doom2.wad MAP01 session 4 10 6000 10

That is four players, ten tics per second, a 6000-tic limit, and a frag limit of ten. Each
player then drives one slot:

    doom-agent.jsl session 2 join
    doom-agent.jsl session 2 look
    doom-agent.jsl session 2 act "turn=35 for=4" "attack for=20" "forward=50 side=20 for=30"

A plan is up to sixteen steps; each step holds `forward=`, `back=`, `side=` (-50 to 50),
`turn=` (degrees over the step, positive left), `attack`, `use`, `weapon=`, and `for=` (tics).
A new plan replaces the one running. The session folder also holds `status.txt` (the
scoreboard), `events.log` (kills and respawns), and `match.lmp`: the whole match as a version
1.9 demo, which `doom.jsl demo doom2.wad session/match.lmp` replays to the same state hash.

## Network deathmatch

The server writes one connect token per slot and waits for every client before ticking:

    doom-server.jsl doom2.wad MAP01 127.0.0.1:0 tokens.txt 4 700
    doom-client.jsl doom2.wad MAP01 tokens.txt 1 700 4 [session-dir]

With a session folder a client takes its commands from `doom-agent.jsl` plans and writes its
observations there; without one it runs a canned patrol. Every client should report the host's
final world hash and zero mismatches. Token files are credentials: share each only with its
player and remove them afterwards.

## Checks

    jess package test lua
    jess run lua/bin/doom-stylecheck.jsl
    jess run --package lua --capability filesystem.read --capability network.transport \
      lua/bench/bench.jsl

The demo tests run only when the IWADs sit in the working folder. The benchmark needs
`doom.wad` there and a release build of Jess; `BENCHMARKS.md` holds what it last measured.
