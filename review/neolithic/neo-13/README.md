# NEO-13 Neolithic acceptance

The baseline is the pre-Neolithic release at `16f0956e9e9546ce4ccae453bee2ae675fb5a026`.
Each pair shows the baseline on the left and the Neolithic candidate on the
right. Both renders use the same seed, year, camera, viewport, solar hour,
season, precipitation, and animation time.

| Place and time | Close | Overhead |
|---|---|---|
| Inland hamlet, seed 1, year 450, daylight | [Comparison](inland-close-daylight.jpg) | [Comparison](inland-overhead-daylight.jpg) |
| Inland hamlet, dusk or rain | [Dusk](inland-close-dusk.jpg) | [Rain](inland-overhead-rain.jpg) |
| Exposed settlement, seed 8, year 790, daylight | [Comparison](coastal-close-daylight.jpg) | [Comparison](coastal-overhead-daylight.jpg) |
| Exposed settlement, dusk or rain | [Dusk](coastal-close-dusk.jpg) | [Rain](coastal-overhead-rain.jpg) |

The [island comparison](island-daylight.jpg) uses seed 1 at year 450.

## Open the installed Timeline

From the repository root, launch the inland daylight view.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/neolithic/neo-13/views/inland-close-daylight.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

The camera records live in [views](views/). Replace the JSON filename with
`coastal-close-daylight.json` to open the exposed settlement. Shift-drag
pans, scroll zooms, and drag orbits. Open `~/Applications/Evolving Player.app`
for normal interactive exploration. The saver is in System Settings under
Screen Saver → Evolving.

To replay a still with the production Metal renderer:

```sh
build/bin/civheadless riverreview \
  review/neolithic/neo-13/views/inland-close-daylight.json build/neo-13-inland --no-ids
```

## Seed and release checks

The [seed results](seed-results.tsv) report year-790 settlement and building
counts, nearest object clearances in metres, and the unchanged river and
submitted terrain hashes. The [check matrix](check-matrix.tsv) records all
33 before-and-after checks. Determinism passed in every run. River checks
passed at years 790 and 2336 across seeds 1–11. The year-2336 diagnostics
matched byte for byte. At year 790, nearest object clearance changed in nine
seeds as the new home footprints changed. All river mesh, terrain clearance,
endpoint, and static footprint checks passed.

For each revision, build in its own checkout and run:

```sh
for seed in 1 2 3 4 5 6 7 8 9 10 11; do
  build/bin/civheadless determinism 790 "$seed"
  build/bin/civheadless river "$seed" 790
  build/bin/civheadless river "$seed" 2336
done
```

The stone-roof finish was corrected during the visual review. Coastal homes
now use the terrain's ground shading and the local ground tint on the turf
section of each roof. The stone walls and entrances still use their authored
atlas. The scene check verifies the submitted material and tint alongside the
house transforms.

The final build also passed the 11 Neolithic feature fixtures, the standard
verification scripts, and the native Timeline navigation check. The
performance comparison uses the baseline saver and installed candidate on
the same Mac, with separate 60-second runs at seed 1, year 450, in daylight.
Time to the first displayed frame is reported separately from the sustained
presentation rate. Exact results are recorded on the release pull request.
