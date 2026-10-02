# doom.jpk

Headless DOOM data/runtime slice for Jess. This package does **not** contain any IWAD data.
Supply a legally obtained DOOM-family WAD at runtime.

This source port is distributed under GPL-2.0; see `LICENSE.TXT`. It is derived from the released id DOOM source and intentionally ships no game data.

The current milestone implements the real WAD directory format, PLAYPAL palettes, the original
DOOM column/post patch representation, classic map lump decoding, a CPU indexed framebuffer,
PPM output, classic texture composition (`PNAMES`/`TEXTURE1`/`TEXTURE2`), BSP-based sector lookup,
a headless first-person preview using WAD textures/flats/COLORMAP, vanilla demo ticcmd decoding, and a
collision-aware scripted player-motion harness. It is a foundation for porting the remaining P_/R_ engine modules; it does not yet claim full
DOOM gameplay or demo-sync compatibility.

Run with Jess:

    jess run --package doom.jpk doom.luau title DOOM.WAD title.ppm
    jess run --package doom.jpk doom.luau map DOOM.WAD E1M1 e1m1.ppm DEMO1
    jess run --package doom.jpk doom.luau view DOOM.WAD E1M1 view.ppm
    jess run --package doom.jpk doom.luau view DOOM.WAD E1M1 view-200.ppm DEMO1 200

`doom.luau` is the launcher distributed beside `doom.jpk`; its source is also stored in the JPK
under `bin/doom.luau`.
