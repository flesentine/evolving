# River query cache — November 21

This pass improves repeated water-triangle queries without changing river geometry. **Release remains blocked on visual acceptance.** PR #15 is draft again. The seed-1 close-up still contains a long, blunt-ended land finger at the join; passing numeric gates and identical screenshots do not establish the intended polished appearance.

[Open the current gallery](index.html). Before/after refers to the coefficient-cache optimization, using baseline commit `9df7083`. The two matched captures are byte-identical, including the remaining seed-1 visual concern.

## Change

`RiverTriangleProbe` caches immutable triangle origins, edges, squared lengths, water deltas and barycentric denominators once. The global nearest-water index and wet/support queries reuse these values. Triangle order, tie accumulation, numerical thresholds, unbounded valley carving and footprint ownership are unchanged. The original `RiverChannel.Field.probe` remains an independent uncached reference. No shader, graph, carve rule, workflow or navigation changes are included.

A conservative per-triangle bounds experiment did not show a reliable benefit and was removed. It is not part of the accepted source.

## Executed checks

- `./Scripts/build.sh` ran; final `./Scripts/verify.sh` rebuilt the retained implementation and passed native bundle presentation and years 500/5000/10000. [Final build/verify output](verify.txt).
- All 18 worlds (seeds 1–17 plus saved 6393821808673518700) pass `river SEED 2336`. Every retained diagnostic line is unchanged from `9df7083`, including exact submitted-mesh clearance, sheet overlap, topology, endpoint and bank checks.
- Six independent `determinism 2336 SEED` runs (seeds 1, 14 and saved, twice each) pass. Geometry, submitted water and terrain hashes match the retained baseline exactly.
- Geometry, routing and terrain fixtures pass. The new fixture performs **22,608 bit-pattern comparisons** against the original uncached distance/height query, including slopes, translations, rotations, both windings, degenerate triangles and vertex/edge ties.
- The existing **416** terrain cutoff pairs still pass: maximum 0.2 mm probe step **0.000121 m**, exhaustive reference error **0.000000 m**.
- [Diagnostic diff](diagnostic-changes.diff): the only intentional output addition is the new cached-query fixture PASS line. All numeric river diagnostics and geometry hashes are unchanged.
- [Matched PNG checksums](render-comparison.json): seed-1 inland junction and seed-14 coastal junction are byte-identical before/after. The captures were inspected.
- `./Scripts/install.sh` passes. [Installed saver](installed-saver.txt): **47 frames/1.5 s**, displayed review export OK. [Installed Player embedded saver](installed-player.txt): **54 frames/1.5 s**, export OK. [Native Timeline input](installed-navigation.txt): orbit, Shift/Move/right drag, trackpad, Option-scroll, wheel and WASD pass. Installed saver, Player and Timeline signatures verify.

The initial temporary test executable was killed after reusing its pathname. A fresh signature-verified copy passed; the failed batch was discarded and the complete checks rerun. The final rebuilt CLI independently reran the query/terrain fixtures ([output](final-build-fixtures.txt)). The parallel test driver used three independent processes; completion order never feeds generation. [Results](results.json), [status](parallel-status.txt), [source fingerprint](source-fingerprint.txt).

## Startup measurements

Apple M3 Pro; fixed seed 1, year 3000, 1600×1000 output, fixed camera `0.65,0.55,0.65,0,0.02,0,52`, weather/snow off, season 0.7. Three serial alternating 120-frame before/after runs, with compilation and validation jobs stopped during timing:

| Pair | Before startup | Cached startup |
|---|---:|---:|
| 1 | 11,547.5 ms | 10,782.8 ms |
| 2 | 11,181.5 ms | 10,507.7 ms |
| 3 | 11,246.0 ms | 10,609.9 ms |
| Median | 11,246.0 ms | 10,609.9 ms |

Observed median improvement: **636.1 ms / 5.7%**. [Raw logs](performance/). This is a modest startup improvement on this Mac, not restoration of the old roughly 4.6-second baseline or a claim about all worlds. Frame timing is separate; no new sustained-frame-rate claim is made. Later timings under changing load were not used to claim a larger gain.

## Visual acceptance concern: seed-1 land finger

Reproduce `riverreview` with `../cases/seed1-junction-10.json` (seed 1, year 2336, hour 10, fixed overhead camera). In its 1600×1200 image, a narrow land finger extends approximately 350 pixels and ends with a visibly blunt edge around x=985–1065, y=940–965. Expected: a convincing confluence boundary without this manufactured-looking tongue. This predates the cache change and is preserved byte for byte.

`Sources/CivRender/RiverJunctionShore.swift:42` emits the shore geometry. [Banks-only isolation](seed1-banks.png) reproduces the sharp outline; [terrain-only](seed1-terrain.png) shows a much smaller underlying ridge. This identifies a bank/footprint investigation rather than a water-colour interpolation fix. The precise ownership/profile cause remains unproven, and the current zero-intrusion test does not reject this shape because the finger lies outside the declared wet footprint. Trace the relevant boundary edges and original approach geometry near junction 8 before changing generation. This is an unresolved **visual release blocker**, not a newly demonstrated overlap/clearance failure.

The prior camera pitch P2 observation and older review threads remain reported. No manual merge or main push was performed. New exact-head CI/review will be required after visual repairs.

## Run the installed version

Quit any old open copy, then:

```sh
open "$HOME/Applications/Evolving Timeline.app"
open "$HOME/Applications/Evolving Player.app"
```

The installed saver is `~/Library/Screen Savers/Evolving.saver`. Timeline Move/M, Shift/right drag and WASD navigation remain available.
