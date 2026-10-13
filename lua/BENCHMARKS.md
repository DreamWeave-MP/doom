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
- Date: 2026-10-13.
- Binary: the verified release build of Jess 0.1.0 on l3i 2.0.2 (Luau 0.742), the same one for
  both sides.
- Base: `b6218e7`, the package before the move, under this bench. Head: `68f257f`.
- Protocol: the whole bench run against base, then head, three times over, back to back under one
  lock; each cell is the median of its three runs. A difference under 5 percent is called no
  change.

These are the tables of a second run of the A/B, made when the move was reviewed. The ratios of
the first run, taken the evening before at `a4cfda0`, are within 8 percent of the ones here,
`wad: open` aside (1.51x then), which the paragraph under the table is about.

| Workload | Base, µs | Head, µs | Base / head |
|---|---:|---:|---:|
| state: encode a snapshot | 2585.9 | 2638.0 | no change |
| state: decode a snapshot | 3722.0 | 3842.9 | no change |
| state: fnv1a64 of an encoded snapshot | 1282.5 | 80.7 | 15.89x |
| state: fnv1a32 of an encoded snapshot | 1062.5 | 79.9 | 13.30x |
| save: envelope round trip | 8963.4 | 6680.9 | 1.34x |
| net: pack and unpack 64 tic bundles | 217.2 | 221.2 | no change |
| wad: open | 7236.9 | 5393.8 | 1.34x |
| wad: read 256 lumps | 227.0 | 227.6 | no change |
| map: load E1M1 | 600.4 | 619.5 | no change |
| map: sectorAt, 1024 points of E1M1 | 424.2 | 442.5 | no change |
| demo: parse DEMO1 | 373.8 | 374.6 | no change |
| texture: load every texture | 49944.6 | 18265.1 | 2.73x |
| patch: draw the title | 905.3 | 504.1 | 1.80x |
| palette: frame to PPM | 774.6 | 637.7 | 1.21x |
| palette: nearest, 512 colours | 871.1 | 720.9 | 1.21x |
| render: automap of E1M1 | 211.4 | 216.9 | no change |
| render: view of E1M1 | 65649.5 | 2600.5 | 25.24x |
| play: DEMO1, 1710 tics of E1M5 | 217798.6 | 154729.4 | 1.41x |
| play: DEMO3, 3863 tics of E3M5 | 299073.1 | 211816.6 | 1.41x |
| play: locate 4096 points of E1M5 | 1629.4 | 772.1 | 2.11x |
| play: save at tic 800 | 19372.8 | 7739.0 | 2.50x |
| play: load a save | 13165.5 | 13104.5 | no change |
| play: hash | 97.7 | 97.5 | no change |
| play: observe | 362.3 | 216.3 | 1.68x |
| agent: describe | 369.3 | 226.1 | 1.63x |
| render: view with things, E1M5 at tic 800 | 79320.0 | 8552.2 | 9.27x |

`wad: open` reads a 13 MB file into a buffer, and base copies it into a second one: allocations
of that size go to and from the system on every call, which is most of what the row costs and
what makes it wander (its three head runs span 13 percent). The same A/B with
`MALLOC_TRIM_THRESHOLD_=1073741824 MALLOC_MMAP_THRESHOLD_=1073741824` on both sides, which keeps
those pages in the process:

| Workload | Base, µs | Head, µs | Base / head |
|---|---:|---:|---:|
| state: encode a snapshot | 2575.5 | 2588.1 | no change |
| state: decode a snapshot | 3771.1 | 3796.5 | no change |
| state: fnv1a64 of an encoded snapshot | 1255.9 | 80.1 | 15.68x |
| state: fnv1a32 of an encoded snapshot | 1038.7 | 80.4 | 12.91x |
| save: envelope round trip | 8992.4 | 6555.7 | 1.37x |
| net: pack and unpack 64 tic bundles | 217.9 | 223.7 | no change |
| wad: open | 4015.3 | 2818.3 | 1.42x |
| wad: read 256 lumps | 229.6 | 230.9 | no change |
| map: load E1M1 | 619.8 | 623.2 | no change |
| map: sectorAt, 1024 points of E1M1 | 428.6 | 432.6 | no change |
| demo: parse DEMO1 | 374.9 | 379.2 | no change |
| texture: load every texture | 50378.2 | 18350.7 | 2.75x |
| patch: draw the title | 918.9 | 511.1 | 1.80x |
| palette: frame to PPM | 781.2 | 640.0 | 1.22x |
| palette: nearest, 512 colours | 872.6 | 721.1 | 1.21x |
| render: automap of E1M1 | 209.1 | 212.4 | no change |
| render: view of E1M1 | 65476.0 | 2627.6 | 24.92x |
| play: DEMO1, 1710 tics of E1M5 | 220636.6 | 153597.1 | 1.44x |
| play: DEMO3, 3863 tics of E3M5 | 293021.5 | 212795.6 | 1.38x |
| play: locate 4096 points of E1M5 | 1600.3 | 775.2 | 2.06x |
| play: save at tic 800 | 19250.7 | 7778.8 | 2.47x |
| play: load a save | 13154.2 | 13093.9 | no change |
| play: hash | 96.7 | 97.9 | no change |
| play: observe | 360.2 | 216.3 | 1.67x |
| agent: describe | 372.3 | 229.8 | 1.62x |
| render: view with things, E1M5 at tic 800 | 80166.0 | 8537.2 | 9.39x |

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
each view, so the compositor's `a6668b9` reached it too.

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
