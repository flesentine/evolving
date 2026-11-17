# Patch 6A visual comparisons

All paired captures use seed 1, year 2336, hour 10, weather 0 and the same
explicit camera. Before images come from unchanged `main` at `e72eb50`.

| View | Before | After |
|---|---|---|
| Junction 28 overhead | [before](before-junction-28.png) | [after](after-junction-28.png) |
| Junction 35 overhead | [before](before-junction-35.png) | [after](after-junction-35.png) |

Additional town overhead/oblique pairs (`before/after-aerial.png` and
`before/after-town.png`), all isolated GPU views, and the other junction sheets
remain local, following the repository's generated-capture convention. The two
paired defect closeups and `debug/junction-28.png` / `debug/junction-35.png` are
committed for PR review.

`debug/junction-*.png` separates water triangles, banks over neutral ground, and
the queried wet field. IDs and world coordinates appear on every sheet. The
adjacent input JSON is the exact swept geometry used to construct each union.
GPU isolated water/wire/bank/terrain views are also included for the closeups.

`seed-1.txt` through `seed-11.txt` contain final diagnostics.
`baseline-seed-*.txt` contain the corresponding pre-patch diagnostics.
`fixtures.txt`, `determinism.txt`, `build.txt`, `verify.txt` and
`performance.txt` record the remaining checks. `build.txt` is the final build
section of `verify.txt`, since verification invokes the build script again. See `RIVER_PATCH_6A.md` in the
repository root for the implementation brief, numerical tolerances and results.

To regenerate diagnostics and the labeled sheets after building:

```sh
build/bin/civheadless riverfixtures
build/bin/civheadless determinism 2336 1
for seed in 1 2 3 4 5 6 7 8 9 10 11; do
  build/bin/civheadless river "$seed" 2336
done
build/bin/civheadless riverdebug review/patch6a/debug 1
```

For the GPU closeups, set `EVOLVING_WEATHER=0` and either camera from the brief,
then run `build/bin/civheadless sim output.png 2336 10 1`.
`EVOLVING_RIVER_VIEW=water|wire|banks|terrain` selects isolated passes;
`EVOLVING_RIVER_MAGENTA=1` gives the water a diagnostic color.
