# Visual and geometry review

Status: the final native matrix and focused captures were inspected. No unresolved
P0/P1 river correctness findings were found in this review set. Merge eligibility
still requires a clean review and required CI for the exact published head.

The original user screenshot did not record its camera. Saved-world cases
reconstruct its upper/central junctions and hooked source; they are labelled
reconstructions. All other cases are explicitly fixed regression cameras.
The 954f2b6 executable supplies before views with matching inputs.

## Causes established and corrected

- Incomplete shared trims left overlapping approach sheets after channels
  separated and met again. Full swept-interval overlap collection, connected
  patch union and exact canonical cuts remove those sheets. Seed 1 exposed
  26.5 m² of duplicate water and a 54.7 mm incompatible-height intersection
  during development. The final submitted-sheet gate measures the mesh.
- Degenerate width transitions and a tributary section projecting beyond its
  receiver produced rectangular spurs. Analytic row-winding constraints and
  section containment remove the projecting geometry (seeds 10/11).
- Endpoint-only stamps concentrated a 0.9425 m drop in a 0.408 m final segment
  in the saved world. Connected grade propagation spreads the approach while
  preserving source/lake controls and never raising a river level. The
  submitted-mesh fixture reduces maximum edge grade from 0.74113 to 0.11117 m/m.
- Vertex-interpolated depth and local UV resets produced coloured diagonals.
  Exact submitted-terrain interpolation and world-space procedural coordinates
  remove the triangulation dependency. The GPU fixture must fail with legacy
  shading and pass with production shading, in daylight and at night.
- Banks restored original soil beyond the original coastline. Exact clipping
  against its submitted triangles removes offshore strips, while retaining
  landward banks. The controlled coast fixture preserves 100 m² of landward soil
  and removes the former 99.995 m² of above-ocean intrusion.
- A sea-level river cap used an unrelated material. Sea-level faces are submitted
  once through the ocean material. River and ocean depth now share the actual
  terrain interpolation, with matching colour at the sea-level boundary.
- A new coastal gate exposed an elevated corner missed by section samples:
  seed 6 had 0.0017307 m² of water over original ocean at up to 0.39104 m height,
  expected no interior area above the 1 mm level tolerance. Exact swept-water /
  original-terrain triangle intersections now establish the coastal level
  control. The failing submitted-mesh output is preserved in
  ../regressions/coastal-elevated-before.txt. This was fixed geometrically;
  changing the material alone did not pass the test.

## Scope and known observations

Natural steep island cliffs and their shadows remain. Bank/carve reference
checks distinguish those original features from a newly truncated excavation.
The simulation now consumes the canonical drainage graph, so regeneration may
intentionally change settlement history and layouts. Repeatability within this
version is required; equality with the old generation is not claimed.

Bird scale and general farm/building styling remain separate work, as requested.
P2 compiler observations include the existing unused soil colour in RiverNetwork
and unused bank-generation network parameter. They are not silently auto-fixed.

## Final visual inspection

Inspected all twelve final nine-panel sheets: island, town and overhead views
in daylight, night and rain (108 frames). Also inspected full-size saved-world
upper/central junctions and spring, day/night material behavior, seed 6's coast,
and the isolated normal/flat/wire/height/depth/terrain/bank review passes.
The reported land blades, projecting water corners, colored diagonals and bank
cutoff seams are absent in the reproduced cases. No decorative water discs or
water-height offsets were introduced.

Seed 9's near-parallel R7/R8 are distinct tributaries, not duplicate sheets:
upstream catchments immediately before joining are 1,929 and 6,694 cells;
sections are approximately 17–19 m apart with 1.1–1.3 m distinct water levels,
and both terminate at receiving R5. Each retained source is catchment-backed;
that world's minimum source area is 1,314 cells. Full reach data is retained in
[provenance](../provenance/seed9-reaches.json). Straight/near-parallel drainage
corridors remain an intentional stylized-generation characteristic. Removing
valid catchments solely to disguise that appearance was not part of this fix.

## Resolved findings and concrete checks

| Severity / location | Unit; observed → expected | Concrete check |
|---|---|---|
| P0 `Sources/CivRender/RiverSurface.swift:34` | m² / m; duplicate approaches and 0.054765 m incompatible levels → zero interior overlap | seed 1; ../regressions/overlap-before.txt; final river-1.txt |
| P0 `Sources/CivCore/RiverJunctionWidths.swift:130` | signed projected triangle area; inverted row → all upward valid faces | seed 11; ../regressions/winding-before.txt; final river-11.txt |
| P0 `Sources/CivCore/RiverCoastalControls.swift:9` | m / m²; 0.39104 m above original ocean over 0.0017307 m² → no area above 0.001 m | seed 6; ../regressions/coastal-elevated-before.txt; final river-6.txt |
| P1 `Sources/CivRender/RiverCoastalBanks.swift:59` | m²; 99.995 above-ocean bank intrusion → zero, retain 100 m² landward half | riverfixtures coast fixture |
| P1 `Sources/CivCore/RiverWaterGrades.swift:8` | m/m; submitted fixture edge 0.74113 → 0.11117, fixed controls retained | riverroutingfixtures |
| P1 `Sources/CivRender/Shaders.metal:759` | RGB/255; diagonal changes 41 day / 48 night → <=2 | rivermaterialcheck; final 1 day / 0 night |

P2 observations: unused `soil` in `Sources/CivRender/RiverNetwork.swift:237`
and an unused `network` argument in WorldScene bank generation. These compiler
observations do not affect the submitted surface and were not auto-fixed.

See [the acceptance report](../README.md), [seed table](../seed-table.md),
[performance](performance.md) and the source fingerprint for exact evidence.
