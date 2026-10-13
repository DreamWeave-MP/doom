# Doom benchmarks

`bench/bench.luau` times the package through its public API: the WAD, map, texture and patch
readers, the indexed renderer, demo playback, play saves, observations, the canonical state
encoder, and the wire codec. Each workload is warmed up, sized to a batch of about a tenth of a
second, and reported as the median of seven batches, with a full collection between them. Every
workload's result is checked: frames, textures and encodings by checksum, demos by the state hash
the tests pin, a save by its length (its bytes move with the collector, see below), all against
values pinned for the 2024 re-release's `doom.wad`. Another `doom.wad` is still timed, each
result held to its own first call. Without a `doom.wad` only the state and wire workloads run.

```sh
jess run --package jpk/doom/lua --package-path jpk \
  --capability filesystem.read --capability network.transport \
  jpk/doom/lua/bench/bench.luau <folder holding doom.wad> [filter] [pin]
```

## The move onto l3i 2.0, base against head

- Machine: Intel Core i7-10870H @ 2.20 GHz, 16 threads, shared with other work while this ran.
- Date: 2026-10-12.
- Binary: the verified release build of Jess 0.1.0 on l3i 2.0.2 (Luau 0.742), the same one for
  both sides.
- Base: `b6218e7`, the package before the move, with this bench. Head: `a4cfda0`.
- Protocol: the whole bench run against base, then head, three times over, back to back under one
  lock; each cell is the median of its three runs. A difference under 5 percent is called no
  change.

| Workload | Base, µs | Head, µs | Base / head |
|---|---:|---:|---:|
| state: encode a snapshot | 2762.2 | 2806.5 | no change |
| state: decode a snapshot | 4147.6 | 4110.3 | no change |
| state: fnv1a64 of an encoded snapshot | 1348.9 | 86.6 | 15.58x |
| state: fnv1a32 of an encoded snapshot | 1120.1 | 85.8 | 13.06x |
| save: envelope round trip | 9628.2 | 7149.1 | 1.35x |
| net: pack and unpack 64 tic bundles | 233.7 | 240.8 | no change |
| wad: open | 8400.1 | 5548.5 | 1.51x |
| wad: read 256 lumps | 250.5 | 243.6 | no change |
| map: load E1M1 | 677.4 | 654.0 | no change |
| map: sectorAt, 1024 points of E1M1 | 436.8 | 443.6 | no change |
| demo: parse DEMO1 | 441.4 | 410.6 | 1.07x |
| texture: load every texture | 52870.2 | 18755.2 | 2.82x |
| patch: draw the title | 965.9 | 513.6 | 1.88x |
| palette: frame to PPM | 831.7 | 655.8 | 1.27x |
| palette: nearest, 512 colours | 920.8 | 717.1 | 1.28x |
| render: automap of E1M1 | 225.2 | 212.1 | 1.06x |
| render: view of E1M1 | 69541.5 | 2699.6 | 25.76x |
| play: DEMO1, 1710 tics of E1M5 | 226273.4 | 154565.5 | 1.46x |
| play: DEMO3, 3863 tics of E3M5 | 303212.2 | 212731.5 | 1.43x |
| play: save at tic 800 | 20201.1 | 7636.5 | 2.65x |
| play: load a save | 13550.5 | 13012.5 | no change |
| play: hash | 105.5 | 97.5 | 1.08x |
| play: observe | 387.7 | 222.5 | 1.74x |
| agent: describe | 401.6 | 229.8 | 1.75x |
| render: view with things, E1M5 at tic 800 | 83803.6 | 8779.3 | 9.55x |

`wad: open` reads a 13 MB file into a buffer, and base copies it into a second one: allocations
of that size go to and from the system on every call, which is most of what the row costs and
what makes it wander (the three base runs span 18 percent). The same A/B with
`MALLOC_TRIM_THRESHOLD_=1073741824 MALLOC_MMAP_THRESHOLD_=1073741824` on both sides, which keeps
those pages in the process:

| Workload | Base, µs | Head, µs | Base / head |
|---|---:|---:|---:|
| state: encode a snapshot | 2585.6 | 2575.5 | no change |
| state: decode a snapshot | 3735.8 | 3764.5 | no change |
| state: fnv1a64 of an encoded snapshot | 1281.7 | 79.7 | 16.09x |
| state: fnv1a32 of an encoded snapshot | 1045.8 | 80.2 | 13.04x |
| save: envelope round trip | 8926.2 | 6584.8 | 1.36x |
| net: pack and unpack 64 tic bundles | 220.3 | 224.1 | no change |
| wad: open | 3928.6 | 2916.5 | 1.35x |
| wad: read 256 lumps | 229.3 | 234.0 | no change |
| map: load E1M1 | 614.5 | 617.5 | no change |
| map: sectorAt, 1024 points of E1M1 | 419.5 | 407.5 | no change |
| demo: parse DEMO1 | 383.1 | 381.6 | no change |
| texture: load every texture | 50893.2 | 18446.7 | 2.76x |
| patch: draw the title | 911.8 | 504.3 | 1.81x |
| palette: frame to PPM | 778.8 | 640.4 | 1.22x |
| palette: nearest, 512 colours | 871.1 | 702.9 | 1.24x |
| render: automap of E1M1 | 213.5 | 207.0 | no change |
| render: view of E1M1 | 67605.4 | 2575.5 | 26.25x |
| play: DEMO1, 1710 tics of E1M5 | 223911.7 | 154862.8 | 1.45x |
| play: DEMO3, 3863 tics of E3M5 | 300015.3 | 216499.1 | 1.39x |
| play: save at tic 800 | 19404.2 | 7607.2 | 2.55x |
| play: load a save | 13274.9 | 13006.2 | no change |
| play: hash | 98.5 | 98.3 | no change |
| play: observe | 376.6 | 214.3 | 1.76x |
| agent: describe | 378.3 | 224.3 | 1.69x |
| render: view with things, E1M5 at tic 800 | 80830.9 | 8436.8 | 9.58x |

`demo: parse`, `render: automap` and `play: hash` show 6 to 8 percent in the first table and
nothing in the second, and no change to the package reaches them: that is the machine, not the
code.

## What moved, and what did not

Almost none of this is the dialect. The package now reads its level lumps, builds its summaries
and binds its fields with comprehensions, reducers, sinks and record patterns, and those rows
(`map: load`, `demo: parse`, the setup inside the demos) did not move: a comprehension is the
loop it replaces.

The one row l3i itself moved is the state hash. `state.fnv1a64` and `state.fnv1a32` multiplied
16-bit limbs in Luau, a byte at a time; they are now `@dream/bytes`' digests, 13 to 16 times
faster, and the save envelope, which hashes its payload on the way out and on the way in, came
with them.

The rest is the same Luau doing less. Line of sight was 44 percent of DEMO1: `P_CrossBSPNode`
recursed through node tables and called `P_DivlineSide` some forty times a check. It is now one
loop over a flat copy of the BSP and of each seg's linedef (f64 buffers, filled by buffer sinks
the first time a level's nodes are walked, never saved), with the side tests written into the
walk; point location walks the same copy. That is the 1.4x on both demos and the 1.7x on
observations. The view renderer composed every texture of the WAD for each frame, looked each
floor pixel's flat up by name, and took four trigonometric functions a pixel; it now keeps a
WAD's textures, casts 320 rays once a view, and picks one flat and one light table a row. A
patch post is clipped once instead of tested a pixel. A play save is written into one growing
buffer instead of a string per value; its bytes are what the old writer produces for the same
game, compared 232 times across the thirteen IWAD demos.

The data plane did not earn a place. Its two candidates were measured and lost to the loop:
compositing a post with `data.scatter` and `data.fill` took 21.6 ms over the WAD's textures
against 17.0 ms for the hoisted byte loop (a post is 67 pixels on average, and each call converts
through f64), and expanding a frame through the palette with `data.gather` took 1.48 ms against
0.41 ms, since the frame's bytes have to be widened to u32 indices first.

One thing the bench had to work around: a play save is not reproducible byte for byte. It writes
each table's keys in the order Luau walks them, and that order depends on whether the collector
ran between a field being set to nil and set again, so two runs of one demo can save different
bytes for the same game. Both restore to the same future, and the hashes agree. The bench checks
a save's length for that reason.
