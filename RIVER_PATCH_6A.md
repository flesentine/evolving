# River Patch 6A — confluence footprints

**Latest validation:** [PR 15 source-backed side-channel fix](review/side-rivers/README.md).
[Earlier mountain/estuary follow-up](review/patch6a-followup/README.md) remains historical evidence.
The results below describe the initial confluence implementation; the follow-up
supersedes its terrain, graph, performance and installed-build results.

Base: `e72eb508c096c2b45bfcb8d2d9991977e60c2687`. Source changes remain on
`codex/river-patch6a-confluence-footprint`; GitHub Actions are unchanged.

## Geometry

`RiverSurface` is the canonical indexed water mesh. It retains the five-across
reach ribbons and unions the actual swept strip triangles removed by the shared
trims. The macOS 13 CoreGraphics Boolean engine resolves exterior loops in local
metres. Zero-area out-and-back spurs in its weakly-simple output are removed;
collinear cut-row stops are restored and simple loops are ear-clipped. Explicit
holes use disjoint vertical wet intervals from the normalized perimeter. There
is no assumption that a junction is star-shaped around its graph cell, no
angular sorting of arbitrary cut-row vertices, and no decorative junction disc.

The merged `RiverChannel.junctionTrimFactor = 1.05` remains the minimum. Actual
cut rows extend beyond incident strip overlap. Entirely consumed short reaches
connect their junctions into one patch; cuts are checked against that complete
component. Water and banks use the same row-range function. External cut rows
constrain junction elevation exactly, while junction cells anchor the grade.
All geometry traversal, grouping, clipping, and tie breaking is ordered.

`RiverChannel.Field` indexes every triangle AABB from this mesh, with a 20 m
query margin. It no longer invents capsules or enlarged confluence discs.
Wet classification and interpolated water height therefore follow submitted
water triangles. Outside distance is to the triangle union; inside distance is
conservative at internal edges (only its sign is used for bed/exclusion queries).
Outside water levels blend across nearest-boundary ties with support shrinking
to zero at the shoreline. Placement uses this same field.

Bank triangles are geometrically subtracted against the wet union. The 0.5 mm
horizontal clipping tolerance covers Float interpolation error; there is no
additional junction water disc or shader-height offset. Convex clip results are
cleaned as convex polygons before subsequent cuts, preventing rounding-induced
backtracking slivers. The complete junction is never convex-hulled.

Carving only lowers terrain, including original deep pools. Render vertices also
respect a conservative water-height bound over the terrain triangle support
radius (one grid diagonal), using the existing 0.45 m bed clearance. This makes
interpolated terrain triangles stay below wet triangles between grid vertices.
The simulation river mask no longer supplies river tint/wetness; paint follows
the canonical drawn field.

## Validation and inspection

`civheadless river` retains the legacy graph/profile gates and adds gates against
final submitted water/bank arrays and the actual detail-2 terrain triangles:

- Junction triangle winding and nonzero area; simple boundary graph incidence.
- Exact triangle subtraction against the intended swept union, reporting raw
  numerical outside area and separately gating residual area beyond an explicit
  0.1 mm boundary tolerance band (maximum 1 mm² residual).
- Independent 0.5 m wet/dry probes, including points outside the footprint.
- Fifteen barycentric terrain-clearance probes per junction triangle, requiring
  at least 1 cm clearance, and 17 samples per cut seam within 1 mm in height.
- No bank/water overlap above the 1 mm² numerical intersection tolerance.
- Actual emitted ribbon widths, rather than only nominal network widths.

`civheadless riverfixtures` exercises acute Y, near-parallel, unequal-width,
four-arm and S-shaped approaches, 100 translated/rotated triangulations, and
48 narrow-channel cases: 3/4/5/6/10/20 m widths, axial/diagonal orientations and
quarter-cell offsets. Narrow cases check drawn wetness, exclusion, carving and
preservation of original deep terrain. These are field-level placement checks;
full bridge/road asset and coast/lake semantics remain Patch 6B work.

`civheadless determinism 2336 1` also rebuilds the river mesh independently and
hashes explicit vertex scalar bits and indices (not struct padding).

`civheadless riverdebug review/patch6a/debug 1` writes orthographic junction IDs,
water triangles, isolated banks over neutral ground, and quarter-metre field
outlines. GPU debug views use `EVOLVING_RIVER_VIEW=water|wire|banks|terrain`;
existing hide-bank/hide-river and magenta flags remain available.

Matching seed/year/hour/camera before/after GPU captures are under
`review/patch6a/`. The two closeups use seed 1, year 2336, hour 10, weather 0:

```sh
EVOLVING_CAMERA='0.190,0.10,-0.2727,0.190,0.018,-0.2737,45'
EVOLVING_CAMERA='0.263,0.10,-0.1112,0.263,0.018,-0.1122,45'
```

Before captures use an independently compiled, unchanged `main` at the base SHA.
The original review's aerial camera was not recorded, so these are explicit,
reproducible overhead views of the actual defective joins, plus the town view.

## Scope and remaining observations

Routing, graph identity, nominal widths, source selection, and valley slope are
unchanged. The previously intended 55 m source-width ramp now uses metres
correctly. Intentional diagnostic changes include field/object clearance,
outer bank freeboard and any bank profile values affected by the canonical
footprint; per-seed differences are recorded alongside the results below.
Legacy profile water-depth/weld metrics are not proof of final mesh validity;
the new rendered-mesh gates are required independently.

P2 observations retained: old endpoint caps/tarns outside consumed patches still submit both windings;
the unused `RiverChannel.junctions` disc helper and stale comments remain.
Existing steep bank apron interpolation and post-thinning source taper deserve
a separate pass. No P2-only cleanup or endpoint redesign is claimed here.


The native macOS 13 CoreGraphics path Boolean engine performs the final union
in local metre coordinates. Normalized outer loops are triangulated directly;
only contours with explicit holes use vertical interval decomposition. This
avoids internal triangle arrangements and produces far fewer triangles than
triangulating each intermediate Boolean fragment. Collinear cut-row stops are
restored before triangulation.

Two additional geometry corrections are intentional: straight-through links
share one endpoint width/tangent row, and caps of wholly consumed short sources
belong to the junction union rather than providing nonexistent ribbon seams.
The source-taper units bug was also corrected: `sample.along` is metres, so the
55 m ramp must divide by 55, not `55 / metresPerUnit` (which previously made the
ramp complete after only 0.055 m). Nominal network widths and graph routing are
unchanged; source ribbon widths now follow the already-documented 55 m ramp.

## Final results

Both `./Scripts/build.sh` and `./Scripts/verify.sh` ran successfully. The final
verification rebuilt all products, loaded `com.mccullough.evolving`, presented
48 frames in 1.5 seconds, and rendered years 500, 5000 and 10000. Verification
including that rebuild took 132.74 seconds.

All 11 seeds passed the legacy graph/profile and final rendered-mesh gates.
Topology/winding errors, wet/dry mismatches, terrain-clearance failures, bank
intrusions and cut-seam failures are zero throughout. Raw outside-area figures
are retained below; none extends beyond the 0.1 mm numerical boundary band.

| Seed | Patches | Triangles | Wet/dry probes | Min clearance m | Max seam error m | Raw outside m² | Beyond band m² | Result |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | 34 | 743 | 42457 | 0.450 | 0.000007 | 0.000647 | 0.000000000 | PASS |
| 2 | 35 | 810 | 32948 | 0.450 | 0.000056 | 0.000561 | 0.000000000 | PASS |
| 3 | 28 | 732 | 71630 | 0.450 | 0.000026 | 0.000873 | 0.000000000 | PASS |
| 4 | 27 | 806 | 35430 | 0.450 | 0.000030 | 0.000541 | 0.000000000 | PASS |
| 5 | 20 | 648 | 60239 | 0.450 | 0.000007 | 0.001522 | 0.000000000 | PASS |
| 6 | 27 | 571 | 32685 | 0.450 | 0.000007 | 0.000832 | 0.000000000 | PASS |
| 7 | 34 | 894 | 87867 | 0.450 | 0.000024 | 0.000687 | 0.000000000 | PASS |
| 8 | 28 | 722 | 57708 | 0.450 | 0.000034 | 0.001109 | 0.000000000 | PASS |
| 9 | 28 | 957 | 39557 | 0.450 | 0.000104 | 0.000299 | 0.000000000 | PASS |
| 10 | 39 | 870 | 49298 | 0.450 | 0.000017 | 0.000549 | 0.000000000 | PASS |
| 11 | 31 | 881 | 112055 | 0.450 | 0.000015 | 0.001202 | 0.000000000 | PASS |

The five adversarial unions, one hole fixture, 100 translated/rotated cases and
48 narrow/subcell cases all pass (154 cases total). The hole fixture preserves
299.999 m² of wet area against an expected 300 m²; its 100 m² dry hole remains
dry. Two separate determinism processes produced identical output:

```text
geometry hash ec2a356a8a94f289 / ec2a356a8a94f289
river mesh hash b77dde9d9b7809d8 / b77dde9d9b7809d8
deterministic: OK
```

Graph diagnostic output is byte-identical before/after for all seeds. Every
changed legacy profile or sample value is recorded in
`review/patch6a/diagnostic-changes.txt`: altered bank/freeboard measurements and
object clearance follow the canonical field and non-raising carve; headwater
sample widths reflect the corrected metre-valued 55 m ramp. New actual ribbon
widths include the pre-existing 2.8 m minimum taper, rather than reporting only
the nominal 3 m minimum. Water depth shading now uses the actual submitted
terrain triangle height, avoiding triangulation-dependent pale water patches.

`./Scripts/install.sh` installed the saver and all three apps under the user's
Library/Applications directories. Signatures verify; installed saver and Player
files match the build exactly. The installed saver presented 47 frames in
1.5 seconds. The prior saver was backed up under
`/tmp/evolving-prepatch-install/` before replacement.

Normalized numerical holes are removed only when subtracting a 0.1 mm boundary
band leaves no interior. This operation uses local millimetres for precision,
and changes the actual submitted footprint and field together. Larger holes
are retained (the explicit ring fixture verifies this).

## Performance and retained P2 observations

Three sequential, alternating baseline/patched runs used seed 1, year 2336,
weather 0, 24 measured frames per run and 6016×3384 output at the same 0.52
scene scale. Baseline: 11.90 / 11.35 / 11.20 ms per frame. Patch 6A:
13.73 / 11.97 / 11.97 ms per frame. Median changes from 11.35 to 11.97 ms
(about +5.5%); the first patched run is retained rather than discarded. These
are short local measurements, not a guarantee for every scene or machine.
Scene construction/update is separate: about 3.5 seconds in an isolated closeup
run, and 4.1–5.5 seconds while concurrent validation was active. The standalone
build checkpoint took 96.85 seconds; final verification including rebuilding
all products took 132.74 seconds.

The following are P2 observations, reported without additional cleanup:

| Location | Unit / observed vs expected | Concrete check |
|---|---|---|
| `Sources/CivRender/RiverSurface.swift:278` | Triangle count: unlinked caps retain two windings, whereas back-face culling needs one. | Inspect the paired forward/reverse index appends; junction unions submit one upward winding. |
| `Sources/CivRender/RiverNetwork.swift:402` | No distance comparison: the unused disc helper remains although canonical junctions use polygon unions. | Search for calls to `RiverChannel.junctions`; none construct the new submitted mesh. |
| `Sources/CivRender/RiverNetwork.swift:1399` | No physical unit: the existing `previousBed` variable is unused. | Swift compiler warning in the build log. |
| `Sources/CivRender/RiverSurface.swift:189` | No physical comparison: legacy position/height arguments in the provisional depth helper are unused; submitted depth now comes from actual terrain triangles. | Inspect helper usage versus `WorldScene.riverGeometry`. |

No remaining P0/P1 failures are reported by the confluence gates for the tested
11 seeds. This is not a complete audit/redesign of coast/lake semantics, the
simulation routing algorithm, or bridge assets; those remain outside Patch 6A.

## Screenshot-driven PR 15 follow-up

The user's saved-world screenshot exposed finite-bucket valley cutoffs that
junction-only checks missed. The follow-up adds a deterministic global
nearest-water hierarchy, continuous outside-water profile/support constraints,
submitted-grid terrain normals, all-water clearance/bank checks and exhaustive
unbucketed terrain reconstruction. A second raw-terrain visual check found
recursive estuary excavation in WorldGen; sea classification is now snapshotted
before the pass so only the original coastal halo is excavated.

That generator correction intentionally changes some terrain, river graphs,
water meshes and settlement replays relative to the initial version, while
remaining deterministic. The graph-unchanged claim in the initial section
above does not apply to this follow-up. Every diagnostic delta is retained in
[the current before/after log](review/patch6a-followup/diagnostic-changes.txt).

[Current validation, fixed findings, visual verdict and limitations](review/patch6a-followup/README.md)
and [twelve-seed table](review/patch6a-followup/seed-table.md) accompany native
saved-world before/after, whole-island and overhead screenshots. Screenshots
must be captured and inspected by the agent before future merge recommendations;
passing geometry diagnostics alone is insufficient.

## Source-backed side-channel follow-up

The user's second installed-world screenshot showed that geometrically valid
water could still represent invalid selected drainage. Spill-only paths below
the established catchment threshold were being drawn, and source thinning left
orphan downstream fragments. Routing now uses the correct surface order,
accumulation rejects cycles, and selection rebuilds complete retained-source
paths before reach splitting. Spring taper survives the channel-width floor;
true bend radii prevent inside ribbon inversion. Actual submitted triangle
intervals replace the routing-row statistic as the channel-run gate.

[Current before/after captures, twelve-seed results, regression fixtures,
installation and merge assessment](review/side-rivers/README.md) supersede the
previous graph, width, source-count, geometry-hash and performance results.
The user's seed changes from 77 reaches / 22 starts to 11 reaches / six retained
catchments. This is not a cosmetic hide flag. No workflow changes are included.
