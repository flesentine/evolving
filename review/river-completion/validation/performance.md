# Mac performance acceptance

Apple M3 Pro, 6016×3384 output, renderer scene scale 0.52. Seed 1, year
3000/hour 12, fixed camera `0.65,0.55,0.65,0,0.02,0,52`, season 0.7,
weather/snow off. Compilation and other rendering jobs finished before these
three alternating 240-frame runs. Baseline executable: exact PR head 954f2b6.

| Measurement | Baseline | Final |
|---|---:|---:|
| Median of three mean frame times | 12.72 ms | 13.80 ms |
| Relative frame-time change | — | +8.49% |
| Non-frame process wall time, median estimate | 4.58 s | 10.99 s |

The non-frame estimate subtracts the timed frames from process wall time and
includes launch, initialization, warm-up and teardown. The final CLI separately
measures generation/simulation/scene startup: 10.902 s in the sustained run.

The **1,800-frame** sustained run averaged **13.84 ms / 72.2 fps**, median
13.87 ms, p95 14.05 ms, maximum 19.08 ms. These are serial offscreen production
frames at a fixed animation time, not an assertion about every possible world
or view. A longer native installed-bundle run is recorded separately.

Startup is a real regression. A seven-second native sampling profile placed
most startup work in WorldScene terrain construction and exact nearest-water
queries. Seed 1 now submits 11,227 water triangles versus 7,799 at the baseline,
with 2 m channel sampling, complete trims and welded boundary geometry. The
full-distance carve remains necessary to avoid the old finite-halo cutoffs.
An ordered-membership experiment preserved all geometry hashes but did not
produce a repeatable idle startup improvement and was removed. The accepted
source fingerprint is identical to the complete seed/matrix/replay test set.

This satisfies the sustained rendering target and investigates the >10%
startup regression; it does **not** claim that startup has been restored to
baseline speed. The 8.49% frame-time change stays below the 10% investigation
threshold. Different regenerated scene content also affects the comparison.

Raw alternating/sustained timings: [performance/](performance/).

The installed native saver presented **1,963 frames in 60 s (32.7 fps)**
at a recorded 2560×1600 physical viewport. The displayed seed/year/camera
review export also validated. See [native-sustained.txt](native-sustained.txt).
