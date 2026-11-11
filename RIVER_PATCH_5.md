# Evolving — river patch 5

**Date:** 2026-11-10
**Scope:** response to `RIVER_PATCH_4_REVIEW.md`, Phase A: replace the decorative
junction pool with one joined water polygon. Widths, bank height, valley carve and
graph identities from Patch 4 are retained.

Screenshots:

- `review/patch5-town.png` — medieval town and former tributary plug, year 3506
- `review/patch5-hero.png` — close river, year 2336
- `review/patch5-island.png` — whole island, year 2336
- `review/patch5-debug-sheet.png` — normal / banks hidden / river hidden / magenta water

---

## 1. Junction geometry — round pool removed

The round 24-segment disc is gone. The new junction is one **Y-shaped water polygon**:

1. Every reach is trimmed back from a junction by `1.05 × max incident half-width`
   (in sample-space, using `along`). The ribbon and its indices simply stop at the
   last kept row; no overlapping ends.
2. Each incident reach contributes its **five cut vertices** (the full cross-section:
   left edge, three interior, right edge) at the trimmed end.
3. The cut vertices are deduplicated, sorted by angle around the junction cell, and
   triangulated as one centre fan. A Y union is star-shaped around the junction, so
   this is a valid single polygon rather than a convex-hull patch.
4. The fan carries each cut vertex's own water height and depth, so the tributary
   slope into the junction is preserved.
5. No 2 mm overlay, no separate material ring, no circular footprint.

This is the reviewer's **cheaper fallback** (trim + ordered cut-bank vertices), not the
preferred full polygon boolean union. A true union of the swept footprints remains
future work.

Known minor issue: bank strips are trimmed at `1.0 × half` while the water cuts at
`1.05 × half`, leaving a possible half-metre seam at very large widths. It is not
visible in the town shot but should be aligned in the next pass.

---

## 2. Endpoints and narrow streams

- Widths remain `clamp(1.5 + 0.12√flow, 3, 45) m`; seed 1 reports 3.0–21.6 m. The
  rendered minimum is 4 m (`minChannel`), slightly above the 3 m reported width.
- Source taper remains 55 m.
- Closed basins get a **2.5 R tarn disc** and a matching field circle. They are still
  fixed-radius ponds, not flooded-basin polygons; no bank ring yet.
- Coastal mouths are still classified by graph/terrain (`isMouth`), not by an explicit
  water-to-ocean mesh contact test.

### Carve sampling

`terrainVertices(detail: 2)` evaluates `RiverChannel.carvedHeight` at **every 2.6 m
render vertex** using the continuous capsule field, so the draw mesh does sample the
3 m incision. The scene also stores a carved copy at the 384² / 5.22 m grid for
placement; that copy can miss a 3 m channel, but the field clipping keeps buildings,
trees and streets out of the water. A subcell cross-section probe test is still needed
to prove the 3 m case at different grid alignments.

---

## 3. What is retained from Patch 4

- Ground profile: 0.45 m bed cut, 4 m wet shelf, 0.55 valley grade, one carved terrain
  for rendering and placement.
- Capsule field, 2× render terrain, carved normals.
- Natural bank crest 0.35 m (2 m cap on steep cuts), 1R bank trim, waterline −4 mm.
- Deck lift 0.
- Laplacian smoothing 80 passes.
- Graph identity: 24 sources = 9 outlets + 15 junction excess; 60 edges =
  69 reaches − 9 outlets.

---

## 4. Gate — seed 1, year 2336

```
reaches: 69  sources: 24  junctions: 15  mouths: 4
width: 3.0–21.6 m
max uphill: 0.001 m
min curvature radius: 20.9 m
max adjacent turn: 11.3°
self-intersections: 0
max junction angle: 26.6°
max sample spacing: 3.00 m
linked reaches: 60  max link gap: 0.00 m
inland terminal ends: 5  junction water step: 0.000 m
max parallel channels in a row: 5
water surface rise: 0.000 m  graph identity: OK

channel cross-sections: 1579
bank lip: 0.33–2.00 m (mean 0.38)
channel depth: 0.93–2.60 m (mean 0.98)
water depth: 0.60 m
wet margin: 1.30–1.80 m
waterline welds: 3158/3158
bed above water: 0 probes (max 0.000 m)
submerged: trees 0  buildings 0  road crossings 0
```

All 11 seeds pass. Determinism OK at 1200/2336/4000. `verify.sh` OK. 6K bench
12.38 ms/frame (80.8 fps) on this run. Apps and saver reinstalled.

---

## 5. What the screenshots show

- `patch5-town.png`: the former square/circular plug behind the red-roofed houses is
  now a single flared Y join. No pale lens patches remain on the main river surface.
- `patch5-hero.png`: same carved valley, narrower channels, lower banks.
- `patch5-island.png`: hierarchy retained; the lower-left reach is still the weakest
  endpoint case.
- `patch5-debug-sheet.png`: normal / banks hidden / river hidden / magenta water.
  Terrain-only shows the valley; water-only shows the joined footprints.

---

## 6. Still open (Patch 5 Phase B–D)

1. **True polygon union** of swept footprints, rather than trim + angular fan.
2. **Coastal contact test**: river water footprint vs ocean mesh/mask; no beach gap.
3. **Headwater semantics**: intermittent/dry streams below a catchment threshold;
   hide tube caps in springs/hollows.
4. **Flooded-basin tarns**: contour the terrain to a spill level and build a lake
   polygon; a 2.5 R disc is still a stopgap.
5. **3–6 m cross-section probes** at multiple subcell offsets and orientations.
6. **River classes/cascades**: steep creek, foothill, lowland; no sine meander in
   mountains.
7. **Routing and visible valleys** are still separate surfaces.
8. **Wireframe / junction-ID debug modes** are not implemented; only the four existing
   toggles.
9. **Scale**: 2 km is the active decision; every metre constant still derives from
   `metresPerUnit = 1_000`.
10. **Scene defects**: flat farm plates, bridge supports, paving edges — separate task.
11. Max parallel runs 5 on seed 1, 5–9 across seeds.

---

## 7. Reproduction

```sh
./Scripts/build.sh
./build/bin/civheadless river 1 2336

EVOLVING_WEATHER=0 EVOLVING_WIDTH=1800 EVOLVING_HEIGHT=1100 \
EVOLVING_CAMERA="0.2100,0.0600,-0.1000,0.1650,0.0180,-0.1800,45" \
./build/bin/civheadless sim review/patch5-town.png 3506 12 1 0
```

Debug flags: `EVOLVING_HIDE_RIVER=1`, `EVOLVING_HIDE_BANKS=1`,
`EVOLVING_RIVER_MAGENTA=1`, `EVOLVING_RIVER_UV=1`, `EVOLVING_RIVER_FOAM=1`.
