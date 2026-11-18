# River completion acceptance

The river repair is implemented on `codex/river-patch6a-confluence-footprint`,
[PR #15](https://github.com/flesentine/evolving/pull/15), based on main `e72eb50`.
Local correctness and visual acceptance pass for the reviewed set. A merge
recommendation still requires clean review and required CI for the exact PR head.
No workflow edits, direct main pushes, force pushes or manual merges are included.

Open [the local comparison gallery](index.html). It contains 19 fixed review
cases, matched before/after images and links to seven production-renderer passes.
The twelve [contact sheets](contact-sheets/) cover 108 whole-island, town and
overhead views in daylight, night and rain. Full-size matrix frames remain locally
in `review/river-completion/matrix/`; their 108 portable records and full reach/junction inputs are preserved in
[review-inputs.zip](review-inputs.zip). Unzip it inside this review directory
to restore the matrix-records, ID inputs and provenance folders. Individual images are unretouched native Metal
captures; contact sheets only arrange and label those captures.

## What changed

A shared Core `RiverGraph` now supplies simulation ecology, rendering and
placement. Complete retained drainage paths and deterministic catchment ties are
preserved. Covered/short headwater starts and obsolete degree-two nodes are
removed. Smoothing remains inside the drainage corridor.

Confluences use a concave-safe union with holes, complete overlap trims and
canonical indexed seams. Swept-row winding and tributary-section containment
prevent projecting corners. Connected water grades avoid concentrating the
entire descent at a stamped junction endpoint. Springs taper to real 0.30 m tips;
true terminal basins use terrain-bounded lake polygons, including dry islands.

The submitted wet surface drives carve support, bank clipping and continuous
placement checks. Original deep terrain is never raised. Coastal controls use
exact swept-water / original-terrain triangle intersections; banks cannot extend
past the original coast. Sea-level faces meet the ocean without duplicate sheets
or a separate dark cap.

The shader reconstructs the submitted terrain's triangle interpolation per pixel.
River and ocean depth share that representation, ripples use world coordinates,
and the materials meet at sea level. The 1 m optical estuary transition changes
colour only. No water-height offsets, decorative discs or extra foam coverups
were added. See [the implementation brief](../../RIVER_PATCH_6A.md).

## Reproduce a review view

Timeline's **Save Review View…** records the displayed seed, year, hour, season,
weather/snow, animation time, camera/FOV and physical viewport before opening the
save panel. Replay without repositioning the camera:

```sh
build/bin/civheadless riverreview view.json output-directory all
```

The passes are normal, flat water, wireframe, water height, depth, terrain-only
and banks-only. `--no-ids` skips repeated global ID diagrams; [ids](ids/) retains
labelled junction maps and reach data for the reported cases.

Saved-world views reconstruct the regions in the user screenshot. Its exact
camera was not recorded, so these are explicitly **reconstructions**, not a
recovered camera. Seed and year are recorded in every case JSON.

## Validation actually run

```text
./Scripts/build.sh: saver, CLI, Companion, Player and Timeline built/signed
./Scripts/verify.sh: native saver loaded/presented frames; years 500/5000/10000 rendered
civheadless river 1..11 2336: 11/11 PASS
saved seed 6393821808673518700, years 2336 and 4594: PASS
independent determinism, seed 1 + saved world/year 2336: PASS
saved-world/year 4594 determinism: PASS
riverfixtures: adversarial unions/holes, 100 transformed joins, 48 narrow/subcell cases: PASS
riverroutingfixtures: conservation/cycles/ties/complete paths/source tips/grades: PASS
riverterrainfixtures: 416 cutoff pairs, exhaustive reference: PASS
rivermaterialcheck: exact max RGB delta 1/255 day, 0/255 night: PASS
  legacy fixture fails as intended: 41/255 day, 48/255 night
riverlakefixture: bounded shore, dry island, source entry: PASS
cameracheck: real Metal images; four bearings × five pitches, pan/zoom/reset: PASS
independent native replay: 14 byte-identical PNGs across all seven passes: PASS
```

All twelve worlds have zero final winding, topology, interior-sheet overlap,
exact terrain-clearance, bank-interior intrusion, coastal intrusion, endpoint,
placement and seam failures. Minimum exact clearance is **0.449993 m**; maximum
cut height error is **0.000013 m** (under the 1 mm gate).
Raw numerical boundary residues are printed separately from the declared 0.1 mm
interior band. The normal 0.10 m/m approach-profile bound is not misrepresented
as a universal triangle-slope bound on naturally steep headwaters.

[Full seed table](seed-table.md), [every diagnostic delta against 954f2b6](diagnostic-changes.diff),
[commands/output](validation/), [resolved findings and visual assessment](validation/visual-review.md),
[exact source fingerprint](validation/source-fingerprint.txt).

The final source matches the complete rendered/tested set byte for byte.
Seed 1/year 2336 hashes:

```text
geometry          c53b67cbfc19f1d6
river mesh        d76c7e3367c7c8d0
submitted terrain 12b82ec8054ce26d
```

Intentional changes against the old PR head include source/reach selection,
channel widths, corrected coastal datum and profiles, water/terrain/bank geometry,
placements and shared-graph simulation ecology/history. Repeated identical inputs
within this version remain deterministic. The saved graph now has 12 reaches / 7
catchment-backed sources. All changes to reported diagnostics are preserved in
the full diff above, rather than claiming old and new layouts are identical.

## Performance and limits

Three alternating 240-frame comparisons at 6016×3384, scene scale 0.52, measured
**12.72 → 13.80 ms/frame (+8.49%)**. The 1,800-frame run averaged **72.2 fps**,
p95 **14.05 ms**. Startup is separate and slower: approximately **11 s**, versus
**4.6 s** baseline non-frame wall time. It was profiled and investigated;
startup restoration is not claimed. [Full method and logs](validation/performance.md).

The stylized generator retains straight or near-parallel corridors where the
underlying catchments run that way; provenance for the close seed-9 tributaries
is documented in the visual review. Bird sizing and general farm/building
styling remain separate work. Natural original island cliffs remain.

## Run the updated software

Quit an old host with **Cmd-Q** before reopening it, so it loads the updated saver.

```sh
open "$HOME/Applications/Evolving Timeline.app"
open "$HOME/Applications/Evolving Player.app"
```

Timeline provides interactive exploration: **Move** or **M** makes ordinary drag
pan; Shift/right/middle-drag, two-finger scroll and WASD also move. Shift moves
faster. Pinch, Option-scroll or a mouse wheel zoom; double-click restores Auto.
Use **Save Review View…** to reproduce a view later. Player is the full-screen
live saver host; **Esc** exits. System Settings → Screen Saver → Evolving selects
the installed saver.

Installation and installed-bundle/native-input checks are recorded in
`validation/install.txt` and `validation/installed-checks.txt`. The installed
saver presented **1,963 frames in 60 s (32.7 fps)** at 2560×1600; its displayed
review record validated. [Native run](validation/native-sustained.txt).
