# Doom benchmarks

`bench/bench.jsl` times the package through its public API: the WAD, map, texture and patch
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
  jpk/doom/lua/bench/bench.jsl <folder holding doom.wad> [filter] [pin]
```

## The move onto l3i 2.0, base against head

- Machine: Intel Core i7-10870H @ 2.20 GHz, 16 threads, shared with other work while this ran.
- Date: 2026-10-13.
- Binary: the verified release build of Jess 0.1.0 on l3i 2.0.2 (Luau 0.742), the same one for
  both sides.
- Base: `b6218e7`, the package before the move, under this bench. Head: `6d7e3ff`.
- Protocol: the whole bench run against base, then head, three times over, back to back under one
  lock; each cell is the median of its three runs. A difference under 5 percent is called no
  change.

These are the tables of a later run of the A/B, made when the move was reviewed. The ratios of
the first run, taken the evening before at `a4cfda0`, are within 8 percent of the ones here,
`wad: open` aside (1.51x then), which the paragraph under the table is about.

| Workload | Base, µs | Head, µs | Base / head |
|---|---:|---:|---:|
| state: encode a snapshot | 2570.3 | 2587.9 | no change |
| state: decode a snapshot | 3747.4 | 3781.6 | no change |
| state: fnv1a64 of an encoded snapshot | 1277.0 | 79.7 | 16.02x |
| state: fnv1a32 of an encoded snapshot | 1049.5 | 80.0 | 13.12x |
| save: envelope round trip | 8934.6 | 6549.3 | 1.36x |
| net: pack and unpack 64 tic bundles | 222.6 | 221.0 | no change |
| wad: open | 7255.8 | 5644.5 | 1.29x |
| wad: read 256 lumps | 232.4 | 230.5 | no change |
| map: load E1M1 | 605.7 | 617.1 | no change |
| map: sectorAt, 1024 points of E1M1 | 425.2 | 414.2 | no change |
| demo: parse DEMO1 | 376.0 | 373.5 | no change |
| texture: load every texture | 49558.0 | 18330.7 | 2.70x |
| patch: draw the title | 916.0 | 502.9 | 1.82x |
| palette: frame to PPM | 772.4 | 639.1 | 1.21x |
| palette: nearest, 512 colours | 870.9 | 701.1 | 1.24x |
| render: automap of E1M1 | 213.1 | 207.7 | no change |
| render: view of E1M1 | 66500.8 | 2572.2 | 25.85x |
| play: DEMO1, 1710 tics of E1M5 | 225902.0 | 154735.8 | 1.46x |
| play: DEMO3, 3863 tics of E3M5 | 300184.1 | 213901.5 | 1.40x |
| play: locate 4096 points of E1M5 | 1622.7 | 753.8 | 2.15x |
| play: save at tic 800 | 19352.0 | 7503.2 | 2.58x |
| play: load a save | 12989.8 | 13125.8 | no change |
| play: hash | 98.0 | 98.3 | no change |
| play: observe | 366.2 | 219.0 | 1.67x |
| agent: describe | 377.0 | 227.8 | 1.65x |
| render: view with things, E1M5 at tic 800 | 80523.0 | 8359.6 | 9.63x |

`wad: open` reads a 13 MB file into a buffer, and base copies it into a second one: allocations
of that size go to and from the system on every call, which is most of what the row costs and
what makes it wander from one run of the A/B to the next. The same A/B with
`MALLOC_TRIM_THRESHOLD_=1073741824 MALLOC_MMAP_THRESHOLD_=1073741824` on both sides, which keeps
those pages in the process:

| Workload | Base, µs | Head, µs | Base / head |
|---|---:|---:|---:|
| state: encode a snapshot | 2575.3 | 2585.0 | no change |
| state: decode a snapshot | 3724.1 | 3763.5 | no change |
| state: fnv1a64 of an encoded snapshot | 1281.1 | 79.5 | 16.11x |
| state: fnv1a32 of an encoded snapshot | 1052.0 | 80.0 | 13.15x |
| save: envelope round trip | 9070.9 | 6497.3 | 1.40x |
| net: pack and unpack 64 tic bundles | 218.9 | 218.2 | no change |
| wad: open | 3996.4 | 2825.1 | 1.41x |
| wad: read 256 lumps | 229.6 | 227.1 | no change |
| map: load E1M1 | 611.9 | 613.1 | no change |
| map: sectorAt, 1024 points of E1M1 | 439.8 | 431.1 | no change |
| demo: parse DEMO1 | 373.9 | 382.1 | no change |
| texture: load every texture | 49409.3 | 18001.8 | 2.74x |
| patch: draw the title | 916.3 | 495.2 | 1.85x |
| palette: frame to PPM | 781.6 | 633.5 | 1.23x |
| palette: nearest, 512 colours | 872.5 | 714.0 | 1.22x |
| render: automap of E1M1 | 211.9 | 207.7 | no change |
| render: view of E1M1 | 66542.1 | 2609.0 | 25.50x |
| play: DEMO1, 1710 tics of E1M5 | 222387.4 | 153370.0 | 1.45x |
| play: DEMO3, 3863 tics of E3M5 | 297050.3 | 211151.8 | 1.41x |
| play: locate 4096 points of E1M5 | 1609.4 | 773.3 | 2.08x |
| play: save at tic 800 | 19285.7 | 7497.5 | 2.57x |
| play: load a save | 13168.7 | 12987.9 | no change |
| play: hash | 98.0 | 98.5 | no change |
| play: observe | 370.0 | 218.5 | 1.69x |
| agent: describe | 377.9 | 222.4 | 1.70x |
| render: view with things, E1M5 at tic 800 | 78983.4 | 8337.7 | 9.47x |

## Commit by commit

Most of the changes made for speed have a row to themselves above: the hashes and the save
envelope (`8339a6b`), `texture: load` (`a6668b9`), the palette rows (`241cfbe`), `patch: draw`
(`6d7da40`), `wad: open` (`fcf732f`) and `play: save` (`13d73cd`). The ones that share a row were
each run against their parent, by the same protocol, over the rows they reach:

| Commit | Workload | Parent, µs | Commit, µs | Parent / commit |
|---|---|---:|---:|---:|
| `1d70677`, point location over a flat BSP | play: locate 4096 points of E1M5 | 1635.2 | 767.2 | 2.13x |
| | play: DEMO1, 1710 tics of E1M5 | 221046.5 | 214093.0 | no change |
| | play: DEMO3, 3863 tics of E3M5 | 298289.7 | 291605.7 | no change |
| | play: observe | 364.5 | 366.8 | no change |
| `4f33c9e`, sight in one walk | play: DEMO1, 1710 tics of E1M5 | 215538.2 | 155751.9 | 1.38x |
| | play: DEMO3, 3863 tics of E3M5 | 294924.5 | 212012.5 | 1.39x |
| | play: observe | 366.0 | 219.0 | 1.67x |
| `f632e18`, a WAD's textures kept | render: view of E1M1 | 34261.8 | 16129.5 | 2.12x |
| | render: view with things, E1M5 at tic 800 | 46789.0 | 28501.9 | 1.64x |
| `32b41bd`, rays and light tables | render: view of E1M1 | 16296.9 | 2648.7 | 6.15x |
| | render: view with things, E1M5 at tic 800 | 28100.7 | 9300.1 | 3.02x |
| `a4cfda0`, vertices bounded once | render: view with things, E1M5 at tic 800 | 9963.4 | 9025.4 | 1.10x |

The view was already down from 66 ms to 34 ms before `f632e18`: base composed every texture for
each view, so the compositor's `a6668b9` reached it too. `6d7e3ff`, which put the two walks'
comparisons back in the original's order for the sake of a NaN, moved no `play:` row against its
parent.

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
walk. That is the 1.4x on both demos and the 1.7x on observations. Point location walks the same
copy and is twice as fast for it, which a demo does not show: DEMO1 locates some 27,000 points,
about five of its 155 milliseconds. The view renderer composed every texture of the
WAD for each frame, looked each floor pixel's flat up by name, and took four trigonometric
functions a pixel; it now keeps a WAD's textures, casts 320 rays once a view, and picks one flat
and one light table a row. A patch post is clipped once instead of tested a pixel. A play save is
written into one growing buffer instead of a string per value; its bytes are what the old writer
produces for the same game, compared in one process at 245 points across the thirteen IWAD
demos.

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
