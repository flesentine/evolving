# Coastal junction repair — November 20

Local acceptance passes for this source version. Fresh exact-head review and required CI remain release gates. No manual merge, workflow edit, main push or force push was performed. This report supersedes the November 19 seed-14 release blocker; the older reports remain historical evidence.

[Open the comparison gallery](index.html). The tested Sources SHA-256 is recorded in [source-fingerprint.txt](source-fingerprint.txt). Build, verify, native checks, diagnostics and captures all use this source fingerprint. Documentation and evidence packaging happened afterward.

## Demonstrated cause and repair

The previous junction union applied inverse-distance height interpolation across a receiving sheet already at exact sea level. Positive inland cut controls lifted part of that domain. The expanded seed-14 regression reproduced 9.53434229433725 m² elevated river water over original ocean (expected <=0.000001 m²), plus four shore-closure failures. The first reported boundary-to-bank distance was 1.066935 m (expected <=0.001 m). See [unchanged failing log](../nov19-audit/river-14.txt) and [before capture](../nov19-audit/seed14-coastal-junction.png).

- `Sources/CivRender/RiverJunctionSurface.swift:69`: preserve the actual incoming flat receiving-water footprint geometrically, subtract it from the graded domain, then reunite both as one indexed surface. Elevation above the sea overlap is now zero m² in the submitted-mesh check.
- `Sources/CivRender/RiverJunctionSurface.swift:122` and `Sources/CivRender/RiverSurfaceWeld.swift:12`: conform subdivision edges in XZ before assigning heights; carry explicit internal grade seams through the final weld. An intermediate candidate conformed after height assignment and grew false banks at internal T-junctions; it was rejected. Final topology failures and duplicate interior-sheet area are zero.
- `Sources/CivCore/RiverCoastalControls.swift:9`: inspect linked reaches as well as terminal mouths; carry a real coastal intersection's zero-level constraint downstream. A separate linked-coastal-reach fixture proves the inland source stays at 1 m while the coastal interval and receiver are zero.
- `Sources/CivRender/RiverJunctionShore.swift:144`: an original-sea boundary may join actual submitted ocean water within 1 mm XY/Y. It must demonstrate that ocean coverage; simply omitting the bank check is insufficient. All land boundaries retain their existing bank-closure check. Seed 14 has four demonstrated marine connections and zero closure failures.

The original concave-safe footprint union, shared trims, canonical wet footprint, exact terrain clearance, bank exclusion, deep-pool preservation and navigation remain in place. No shader offsets, decorative discs or foam were added.

## Executed validation

| Check | Result |
|---|---|
| `./Scripts/build.sh` | PASS; [full log](build.txt) |
| `./Scripts/verify.sh` | PASS; native load/frames and years 500/5000/10000; [log](verify.txt) |
| `river` seeds 1–17 plus saved 6393821808673518700, year 2336 | 18/18 PASS; individual `river-SEED.txt` logs |
| Saved seed at year 4594 | PASS; [log](river-saved-4594.txt) |
| `determinism 2336 SEED`, seeds 1, 14 and saved, twice in separate processes | 6/6 PASS; geometry, river and submitted terrain hashes agree |
| Geometry, routing and continuous terrain fixtures | PASS; [union](riverfixtures.txt), [routing](riverroutingfixtures.txt), [terrain](riverterrainfixtures.txt) |
| New rotated/translated coastal-grade fixture | 199.999281 m² vs expected 200 m² (0.01 m² tolerance), elevated sea region 0 m², topology failures 0; upstream 1 m control preserved within 1 mm |
| GPU triangulation invariance, day/night | PASS; exact material max RGB difference 1/255 day, 0/255 night; legacy failure reproduced at 41/255 and 48/255; [log](material.txt) |
| Terrain-bounded lake fixture | PASS; [log](lake.txt) |
| Camera rendering and native Timeline input | PASS; [camera](camera.txt), [installed checks](installed-checks.txt) |
| `./Scripts/install.sh` | PASS; [log](install.txt) |
| Installed saver sustained native presentation | 1,961 frames / 60 s, about 32.7 fps at 2560×1600; [log](native-sustained.txt) |
| Installed Player and Timeline embedded saver | Both loaded and presented frames; signatures and installed bytes match build; [log](installed-checks.txt) |

Seed 14 final mesh: 0 topology, winding, terrain clearance, bank intrusion, dry toe, spring closure and cut-seam failures; 0 duplicate interior water area; minimum exact terrain clearance 0.449996 m; maximum cut-height error 0.000024 m (<1 mm). [Complete log](river-14.txt).

## Intentional diagnostic changes

[The complete line-by-line comparison](diagnostic-changes.diff) includes every changed diagnostic against the previous retained twelve-world results and the failing seed-14 audit. For the original twelve worlds, numeric river diagnostics are unchanged; only the new marine-connection count is added (zero in those worlds).

For seed 14, junction triangles change 246→306 and whole-river triangles 13,062→13,122 because the flat/graded domains now have a conforming interface. Terrain probes change 52,248→52,488 and exact triangle intersections 59,512→59,649. Numerical outside-union area within the existing 0.1 mm boundary band changes 0.001307→0.001291 m²; area beyond that band remains zero. Raw river/original-ocean overlap changes 9.5468154173→0 m²; elevated overlap 9.5343422943→0 m²; closure failures 4→0 and endpoint failures 1→0. Four verified marine connections replace the four old failed shore probes. Source/reach/junction/outlet counts, maximum edge grade and minimum exact clearance are unchanged. Seeds 12–13 and 15–17 extend coverage without a retained old baseline.

The printed numerical-collapse counter describes final global packing; it does not aggregate removals in the new local planar conforming pass. Final submitted topology, union coverage, overlaps and exact terrain intersections are independently checked.

## Visual review and performance

Generated 21 fixed close-up cases in all seven production passes, including new seed-14 day/night coastal cases. The gallery includes current normal captures and all seven seed-14 passes. The full local pass outputs remain in `../work/nov20-acceptance/views/`. Generated and inspected 12 nine-image contact sheets: seeds 1–11 plus saved world, whole-island/town/overhead × day/night/rain, 108 frames. Full-size frames and portable view records remain in `../work/nov20-acceptance/matrix/`. Required normal and hidden-river paint stills are in [required/](required/). Supplied screenshot cameras were not recorded; saved-world views are explicitly reconstructions.

No unresolved P0/P1 river findings were observed in this review set. This is a bounded visual assessment, not proof for every procedural world. General coastal grid steps, building/farmland appearance and bird appearance remain outside this river repair. Existing P2 unused-soil/compiler observations and the prior camera pitch observation were not automatically changed.

82/108 matrix PNGs match the previous set byte for byte. The other 26 have localized pixel differences; they are retained and were visually inspected rather than described as identical. [Pixel report](matrix-pixels.txt). Within-version geometry determinism is independently verified above.

Apple M3 Pro, fixed seed-1/year-3000 camera, 6016×3384 output at scene scale 0.52: the final 1,800-frame idle run averaged **15.44 ms / 64.8 fps**, median 14.54 ms, p95 19.39 ms, max 93.93 ms. Startup measured separately at **15.673 s**. [Log](performance-idle.txt).

An initial run with the older installed saver host still active averaged 27.45 ms / 36.4 fps ([retained log](performance.txt)). After installing and restarting that confirmed old Evolving host, alternating 240-frame before/after runs measured 20.83/20.77 ms, then 15.85/14.30 ms. These show no observed slowdown in the paired runs, but host load was settling and the baseline build configuration differs; they do not establish an algorithmic speedup. Startup remains variable at roughly 11–16 s and is a known regression versus the older baseline documented in [the prior performance report](../validation/performance.md). Sustained native/offscreen timing and startup are distinct measurements.

## Test the installed software

Quit any already-open old copy, then run:

```sh
open "$HOME/Applications/Evolving Timeline.app"
open "$HOME/Applications/Evolving Player.app"
```

In Timeline use Move mode (`M`), Shift-drag, right/middle drag, trackpad pan or WASD to move; drag to orbit, scroll to zoom, Auto to reset. Save Review View captures a reproducible camera/world record. The saver is installed at `~/Library/Screen Savers/Evolving.saver`; select Evolving in macOS Screen Saver settings to preview it.
