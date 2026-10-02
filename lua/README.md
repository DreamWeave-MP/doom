# doom.jpk

Headless DOOM data/runtime slice for Jess. This package does **not** contain any IWAD data.
Supply a legally obtained DOOM-family WAD at runtime.

This source port is distributed under GPL-2.0; see `LICENSE.TXT`. It is derived from the released id DOOM source and intentionally ships no game data.

The package implements the WAD directory and override rules, PLAYPAL/COLORMAP palettes, patch
posts, classic map structures including BLOCKMAP/REJECT, texture composition, a deterministic
fixed-point gameplay slice, vanilla demo command validation, canonical state hashing, save/load
envelopes, and a headless indexed software-rendering path. The gameplay and renderer are useful
vertical slices, not a claim of byte-for-byte Linux Doom 1.10 synchronization: monster AI,
sector movement, collision edge cases, visplanes, weapon/status-bar presentation, and several UI
systems remain incomplete or simplified.

Run with Jess:

    jess run --package doom.jpk --capability network.transport doom.luau title DOOM.WAD title.ppm
    jess run --package doom.jpk --capability network.transport doom.luau map DOOM.WAD E1M1 e1m1.ppm DEMO1
    jess run --package doom.jpk --capability network.transport doom.luau view DOOM.WAD E1M1 view.ppm
    jess run --package doom.jpk --capability network.transport doom.luau view DOOM.WAD E1M1 view-200.ppm DEMO1 200
    jess run --package doom.jpk --capability network.transport doom.luau run DOOM.WAD E1M1 350 DEMO1
    jess run --package doom.jpk --capability network.transport doom.luau statehash DOOM.WAD E1M1 350
    jess run --package doom.jpk --capability network.transport doom.luau save DOOM.WAD E1M1 save.bin 350 DEMO1
    jess run --package doom.jpk --capability network.transport doom.luau load DOOM.WAD E1M1 save.bin restored.ppm

`doom.luau` is the launcher distributed beside `doom.jpk`; its source is also stored in the JPK
under `bin/doom.luau`.

The `@doom/net` module defines the real dream-net ticcmd protocol and uses native transport
handles. `jess run` accepts explicit `--capability network.transport` grants; without that flag,
`@dream/net` client and server creation are denied by design. With it, Luau can create its own
server and mint client tokens while the native transport keeps its private key opaque. The Doom
simulation, authoritative game loop, and tic-command routing remain in Luau.

Run a four-player headless deathmatch as separate Jess processes (server in one terminal; then
start four clients from another). The server writes one base64 token per slot and waits for all four
clients before ticking:

    jess run --package doom.jpk --capability network.transport lua/bin/doom-server.luau doom2.wad MAP01 127.0.0.1:0 /tmp/doom-tokens.txt 4 700
    jess run --package doom.jpk --capability network.transport lua/bin/doom-client.luau doom2.wad MAP01 /tmp/doom-tokens.txt 1 700 4
    jess run --package doom.jpk --capability network.transport lua/bin/doom-client.luau doom2.wad MAP01 /tmp/doom-tokens.txt 2 700 4
    jess run --package doom.jpk --capability network.transport lua/bin/doom-client.luau doom2.wad MAP01 /tmp/doom-tokens.txt 3 700 4
    jess run --package doom.jpk --capability network.transport lua/bin/doom-client.luau doom2.wad MAP01 /tmp/doom-tokens.txt 4 700 4

The CLI harness paces the Luau host loop at Doom's 35 Hz. Every client should report the same
final state hash and zero received-state hash mismatches. Token files are credentials: share them
only with the intended clients and remove them after the session.

For local development, inspect performance and emitted code with `jess run --package doom.jpk
--capability network.transport --profile doom.luau run DOOM.WAD E1M1 350`, or dump a script with
`jess run --package doom.jpk --capability network.transport --disassemble listing.txt lua/bin/doom-server.luau`
and `--emit-asm listing.asm`.
