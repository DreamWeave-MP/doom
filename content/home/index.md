+++
title = "DOOM for Jess"
description = "DOOM's game simulation in Luau, for Jess: WAD reading, the renderer, demos, saves and netgames. Ships no IWAD; bring a legally obtained WAD."
date = 2026-10-21

[taxonomies]
tags = ["Jess", "Luau", "DOOM"]

[extra]
sections = ["overview", "releases", "credits"]
+++

DOOM's game simulation in Luau, for Jess: WAD reading, the renderer, demos, saves and netgames. Ships no IWAD; bring a legally obtained WAD.

<!-- more -->

A [Jess](https://github.com/DreamWeave-MP/jess) package, `org.dreamweave.doom`. Add it to a `jess.toml` and
`jess workspace sync` pins it from this site:

```toml
[dependencies]
"org.dreamweave.doom" = "0.1"
```

Every release below is the package's own archive, with its content digest beside the archive's
SHA-256; `jess.lock` pins the first and checks both.
