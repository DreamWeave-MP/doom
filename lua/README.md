# DOOM for Jess

DOOM, played: Linux Doom 1.10's simulation and renderer in Luau, as a Jess application with a
window, sound and music, a menu, saves, and netgames of one to four players in cooperative,
deathmatch and team deathmatch. Mods are Jess packages.

The package holds **no** game data. Bring a legally obtained IWAD: DOOM or The Ultimate DOOM
(`doom.wad`), DOOM II (`doom2.wad`), Final DOOM (`plutonia.wad`, `tnt.wad`), all sold on the
usual stores, the shareware `doom1.wad`, or Freedoom (`freedoom1.wad`, `freedoom2.wad`), which is
free. Never put an IWAD in a package or a commit.

The source is GPL-2.0 (`LICENSE.TXT`), derived from the source id Software released. Jess itself
is MIT or Apache-2.0 and is not relicensed by running this.

## Playing

You need Jess 0.3.0 or later, built with windows and audio (the released builds are). From this
repository, with an IWAD in the folder you run from:

    jess package run lua --trusted
    jess package run lua --trusted -- -iwad doom2.wad -warp 7 -skill 4
    jess package run lua --trusted -- -iwad doom.wad -file mymaps.wad -warp 2 3

`--trusted` grants what the `doom` target declares: the GPU window, input, audio output, files
(for saves and WADs) and UDP (for netgames). Name them one by one with `--capability` instead if
you prefer. Without `-iwad` the game looks for `doom2.wad`, `plutonia.wad`, `tnt.wad`,
`doom.wad`, `doom1.wad`, `freedoom2.wad`, then `freedoom1.wad`, in that order.

| Switch | Does |
| --- | --- |
| `-iwad FILE` | The IWAD. |
| `-file PWAD...` | WADs laid over it in order; a later file's lumps win by name (maps, textures, sounds, music). |
| `-warp E M` or `-warp MAP` | Start on that map instead of at the title. `-warp 7` is MAP07. |
| `-skill 1-5` | 1 is I'm Too Young To Die, 5 Nightmare. Default 3. |
| `-host ADDRESS`, `-players N`, `-mode coop\|ffa\|tdm` | Host a netgame (see below). |
| `-fraglimit N`, `-timelimit MINUTES`, `-teamdamage`, `-keepinventory` | Its rules. |
| `-join TOKEN` | Join a netgame; TOKEN is the token file or its text. |
| `-name TEXT` | Your name in the lobby. |
| `-scale N`, `-fullscreen` | Window size (N × 320 wide, default 3) or borderless fullscreen. |
| `-nosound`, `-nomusic` | Silence. |
| `-frames N` | Stop after N frames (for scripted runs). |

The frame is DOOM's 320×200 in its 256-color palette, colored on the GPU and shown at the 4:3
shape a monitor gave it, letterboxed in any window size. The game runs at exactly 35 tics a
second whatever the display does; the window draws at the host's 60 frames a second.

### Controls

| Action | Keyboard and mouse | Gamepad |
| --- | --- | --- |
| Move | W/S or ↑/↓ | Left stick, D-pad |
| Turn | ←/→, mouse (click the window to capture it) | Right stick |
| Strafe | A/D or `,`/`.`; hold Alt to strafe with ←/→ | Bumpers |
| Run | Shift | Left stick click |
| Fire | Ctrl, left mouse button | Right trigger |
| Use (doors, switches) | Space, E, middle mouse button | A / Cross |
| Weapons | 1–7, mouse wheel | Y / Triangle (next), X / Square (previous) |
| Automap | Tab; `=`/`-` zoom, F follow, G grid | View / Select |
| Screen size | `=` and `-` outside the automap | |
| Menu | Escape | Start / Options |
| Pause | P, Pause | |
| Quicksave / quickload | F6 / F9 (slot 1) | |
| Scoreboard (deathmatch) | Hold F1 or `` ` `` | |

The bindings are a Jess input document (`src/app/controls.jsl`). Under `jess package run` Jess
gives an application its windows' keyboard and pointer; a gamepad reaches it only through a host
that launches it with a device backend (see Limitations).

Saves live in `saves/` beside where you run the game, six slots, each a versioned header (mode,
rules, skill, map, and the simulation content in order) and the simulation's whole state. A save
made with other mods is refused rather than loaded wrong.

## Multiplayer

One player hosts; up to three join. The host runs the authoritative tic stream: every tic it
takes one command from each player (a player whose command is late repeats their last movement
rather than stalling everyone), runs the tic, and sends it to every client, who run exactly
that. State hashes go both ways every 35 tics and are checked however late either arrives; a
client that finds itself out of step asks for, and loads, a snapshot of the host's game.
Players may join a game in progress (they load a snapshot) and leave or drop (their body goes,
the game goes on); a client the host hasn't heard from for ten seconds is dropped.

The transport is dream.udp: connections are authenticated with connect tokens the host mints,
and only a holder of a token can take its slot. **A token is a credential**: send each one only
to its player, privately, and delete them when the game is over.

To host, bind an address the other players can reach (the token carries it, so `0.0.0.0` won't
do; use your LAN or public address, and forward the UDP port if you're behind NAT):

    jess package run lua --trusted -- -iwad doom2.wad -host 192.168.1.20:5029 -players 4 -mode coop -warp 1

The game writes one token per slot to `tokens/slot2.token` … `tokens/slot4.token` and waits in a
lobby. It starts when every slot is filled and ready, or when the host presses Enter. Each
player joins with their token file:

    jess package run lua --trusted -- -iwad doom2.wad -join slot2.token -name rowan

Everyone must load the same IWAD, the same `-file` WADs in the same order, and the same
simulation mods in the same order; the host compares a manifest of their digests on joining
and refuses a player whose content differs, saying which entry. The Multiplayer menu hosts and joins
too; it hosts on the `-host` address, or on 127.0.0.1:5029 for a game on one machine.

### Modes

- **Cooperative** (`coop`): everyone against the map, from their own starts. Keys are shared by
  default (one player's key opens the door for all); friendly fire is off unless `-teamdamage`;
  the dead respawn at their start with a pistol (with `-keepinventory`, with the weapons and
  ammo they carried). Weapons stay for every player, as vanilla netgames leave them. Any player's exit
  takes everyone to the intermission and the next map, keeping what they carry.
- **Deathmatch** (`ffa`): every player against every other, at deathmatch starts. Frags are
  credited exactly: hitscan and missiles to their shooter, a barrel to whoever set it off, a
  death with no killer against the dead player. `-fraglimit` ends the level when a player
  reaches it; `-timelimit` after that many minutes.
- **Team deathmatch** (`tdm`): two teams, red and blue, two against two with four players (the
  lobby honors who asked for which team while there is room). Players wear their team's color,
  respawn at the deathmatch start farthest from the enemy, can't hurt teammates unless
  `-teamdamage`, and score their kills of the other team less suicides and team kills. The
  score limit (`-fraglimit`, 20 by default) wins it for the team.

### Dedicated hosts, bots and replays

`bin/doom-peer.jsl` runs the same sessions without a window, a simple bot at each seat:

    jess run --package lua --capability network.transport --capability filesystem.read \
      --capability filesystem.write lua/bin/doom-peer.jsl host 192.168.1.20:5029 -players 4 \
      -mode tdm -tokens tokens -tics 35000 -record match.rec
    jess run --package lua --capability network.transport --capability filesystem.read \
      --capability filesystem.write lua/bin/doom-peer.jsl join tokens/slot2.token
    jess run --package lua --capability filesystem.read lua/bin/doom-peer.jsl replay match.rec

`-record` writes the whole tic stream (joins and leaves included); `replay` plays it again to the
same final state hash. `-latency`, `-jitter` and `-loss` put a link conditioner in front of a
peer, for testing over a bad network on a good one.

## Mods

There are two kinds, and they combine.

- **WADs** (`-file`): maps, textures, sprites, sounds and music laid over the IWAD, as vanilla
  did. They change content, not rules.
- **Jess packages** written against `@doom/mod`: actors and their AI, weapons, pickups, spawn
  tables, map order, encounters, rules for a mode, and HUD drawers, sounds and event listeners.
  Everything that changes the simulation runs synchronously inside the tic, in the order the
  mods were composed, on every peer.

`MODDING.md` is the authoring guide. The repository has two examples under `mods/`, each a
package with tests: `coop-director` paces waves of returning monsters to a cooperative party's
size and health, and `arsenal` gives the shotgun nine pellets and swaps demons for faster,
tougher stalkers. `mods/modpack` is a game with both, run as a workspace target:

    jess workspace run --trusted org.dreamweave.doom.modpack:doom -- -iwad doom2.wad

## From Luau

```luau
local play = require('@doom/play')

local game = play.new('doom2.wad', { mapName = 'MAP01', skill = 3 })
for _ = 1, 35 do
  play.tick { [0] = play.command { forward = 50, turn = 2, attack = true } }
end

print(play.summary().players[1].x, play.hash())
```

`play.tick` takes one ticcmd per slot (0 to 3). One game runs per Jess runtime. `@doom/setup`
starts and loads games with a ruleset and mods; `@doom/view` draws a player's view
(`view.render(renderer, game, slot, frame, { size = 10 })`), `@doom/hud` the status bar, messages
and automap, `@doom/screens` the menu, intermission and finale, and `@doom/sound` plays the
sounds the simulation queues (`play.drainSounds()`) through a Jess audio context. `@doom/session`
is the netgame host and client, `@doom/net` their wire protocol, and `@doom/content` the content
manifests they compare. `play.drainAnnouncements()` lists the kills, keys, level starts and exits
of the last tics, which the application also emits as `@jess/events` named `doom.kill`,
`doom.key`, `doom.levelStart` and `doom.levelExit`: cosmetic news, never a way back into the game.

### Live deathmatch for agents

`bin/doom-arena.jsl` runs a match for players that plan rather than press keys (each slot reads
a text observation and writes short timed plans with `bin/doom-agent.jsl`), and records it as a
vanilla demo:

    jess run --package lua --capability network.transport --capability filesystem.read \
      --capability filesystem.write lua/bin/doom-arena.jsl doom2.wad MAP01 session 4 10 6000 10
    doom-agent.jsl session 2 act "turn=35 for=4" "attack for=20" "forward=50 side=20 for=30"

The headless tools in `bin/doom.jsl` (`info`, `demo`, `statehash`, `save`, `load`, `title`, `map`,
`view`, `watch`) take the IWAD and a map or demo; run it with no arguments for the list.

## Checks

    jess package test lua                 # 122 tests, run from the package source and its JPK
    jess workspace test                   # the package and both example mods
    jess package check lua                # strict types, every file
    jess run --trusted lua/bin/doom-stylecheck.jsl
    jess run --trusted lua/bin/doom-netcheck.jsl doom2.wad
    jess run --package lua --capability filesystem.read lua/bin/doom-profile.jsl

The IWAD tests (all thirteen built-in demos in sync, rendering, the status bar, the intermission
and finale, sound through a whole demo) run when the IWADs are in the folder you test from, and
pass without them. `doom-netcheck` is the multiplayer acceptance run: real sessions between
separate jess processes on loopback, 2 and 4 players in every mode, a bad link, a late join, a
leave, a timeout, a forced desync, a replay, modded sessions, and content and mod mismatches. It
takes about five minutes. `doom-profile` times each tic's simulation, rendering, HUD and sound
over the demos; `BENCHMARKS.md` holds what it and `bench/bench.jsl` measured.

## Limitations

- **Gamepads** are bound but reach the game only through a Jess host that attaches a device
  backend; `jess package run` gives an application its windows' keyboard and pointer only.
- **Music** is not an OPL2. Its voices are two-operator FM with the chip's multiples, waveforms,
  feedback and envelope rates, pitched as DMX's driver pitches them, but with no tremolo,
  vibrato, or key scaling, 16 voices rather than 9, and a volume curve that only approximates
  Doom's. It sounds like the songs, not like the card.
- **Vanilla limits** are gone: no visplane, drawseg or sprite overflow, so maps that crash vanilla
  draw here, and demos that depend on the original's overflows (intercepts, spechits) can drift.
  There is no low-detail mode, and no Medusa or tutti-frutti.
- **Netgames** are for up to four players, saved games are single player only, and there is no
  chat window (the protocol carries chat; the screen doesn't show it yet). A host on a NAT needs
  a forwarded UDP port; there is no relay or discovery.
- **Cheats**, the "Read This!" order screens of the shareware, and the original's random pitch
  variation (gone from DOS Doom since 1.666) are not there.
