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

    jess run --package doom.jpk doom.luau title DOOM.WAD title.ppm
    jess run --package doom.jpk doom.luau map DOOM.WAD E1M1 e1m1.ppm DEMO1
    jess run --package doom.jpk doom.luau view DOOM.WAD E1M1 view.ppm
    jess run --package doom.jpk doom.luau view DOOM.WAD E1M1 view-200.ppm DEMO1 200
    jess run --package doom.jpk doom.luau run DOOM.WAD E1M1 350 DEMO1
    jess run --package doom.jpk doom.luau statehash DOOM.WAD E1M1 350
    jess run --package doom.jpk doom.luau save DOOM.WAD E1M1 save.bin 350 DEMO1
    jess run --package doom.jpk doom.luau load DOOM.WAD E1M1 save.bin restored.ppm

`doom.luau` is the launcher distributed beside `doom.jpk`; its source is also stored in the JPK
under `bin/doom.luau`.

The `@doom/net` module defines the real dream-net ticcmd protocol and uses native transport
handles. The supplied plain `jess run` host does not grant `network.transport` and does not expose
a server constructor; a host integration must grant that capability and inject the authoritative
`dream_net_Server` handle before a separate-process deathmatch can run.
