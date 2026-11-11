# Evolving — river patch 4

**Date:** 2026-11-10
**Scope:** response to `RIVER_PATCH_3_REVIEW.md`. This pass removes the square
confluence plug, narrows headwaters, lowers the bank crest, preserves more valley
detail, and turns closed-basin ends into ponds.

Screenshots:

- `review/patch4-hero.png` — close river, year 2336
- `review/patch4-town.png` — Medieval town and confluence, year 3506
- `review/patch4-island.png` — whole island, year 2336
- `review/patch4-debug-sheet.png` — normal / banks hidden / river hidden / magenta water

---

## 1. Square confluence removed

The square blue plug in `patch3-town.png` was the four-point junction fan: the two
waterline points of each incident reach were angle-sorted and triangulated as one
quadrilateral around the junction cell.

Replaced with a **round confluence pool**:

- centre at the shared junction cell;
- radius `1.05 × max incident half-width`;
- one shared water level, 2 mm above the ribbons to win the coplanar depth test;
- 24 segments, depth-shaded centre and zero-depth rim.

The town view now shows a rounded join behind the red-roofed houses instead of a
rectangular plug. The pool is still a pool, not a full polygon boolean union; a true
union remains future work.

## 2. Headwaters narrowed

`widthForFlow` changed from `4 + 0.22√flow` clamped 8–45 m to:

```swift
metres = 1.5 + 0.12 * sqrt(max(flow, 1))
width  = clamp(metres, 3, 45) / metresPerUnit
```

Seed 1 width is now **3.0–21.6 m** (was 8.0–40.8 m). The width gate is 3–45 m.
This creates a readable hierarchy: 3–6 m headwaters, ~8–12 m tributaries, ~15–22 m
trunks. It also removes the full-width stub look at sources.

## 3. Bank crest lowered

- `bankHeight` 1.15 m → **0.35 m**.
- Gate changed from `min ≥ 0.9, mean 1.0–2.0` to `min ≥ 0.15, mean 0.15–1.2`.
- On gentle ground the visible lip is now ~0.33–0.4 m; on steep cuts the 2 m cap still
  applies, but most of the bank height now comes from the carved terrain.

Seed 1 bank lip: **0.33–2.00 m (mean 0.38)**, channel depth 0.93–2.60 m (mean 0.98).

## 4. Less destructive smoothing

The centreline Laplacian pass count dropped from **200 to 80**. Corner-cutting
(Chaikin ×4) is unchanged, so self-intersections remain zero; the smaller number keeps
more of the valley-scale path instead of flattening it into a smooth canal.

Seed 1: curvature 20.9 m, adjacent turn 11.3°, self-intersections 0.

## 5. Closed-basin tarns are ponds

Reach endpoints that are not coastal mouths now get a **2.5 × half-width water disc**
at the terminal water level. The field adds a matching 2.5 R circle, so the terrain is
carved under the pond. This replaces the rounded ribbon cap that read as a blunt blue
stub.

Seed 1 still reports 5 endorheic ends; they now render as tarns rather than cut ribbons.
A proper bank ring around the tarn is not built yet.

## 6. Retained from patch 3

- Slope-limited valley carve (0.45 m bed, 4 m wet shelf, 0.55 grade).
- One carved terrain copy used for the terrain mesh and all placement.
- Capsule-based river field.
- 2× render terrain (≈2.6 m) with carved normals.
- Deck lift 0; bank trim 1R.
- Graph forest identity: 24 sources = 9 outlets + 15 junction excess; 60 edges =
  69 reaches − 9 outlets.
- Junction water step and downstream water rise both 0.000 m.

---

## 7. Gate — seed 1, year 2336

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

All 11 seeds: `PASS PASS`.

- Determinism OK at 1200 / 2336 / 4000.
- `./Scripts/verify.sh` OK.
- 6K bench: 17.92 ms/frame (55.8 fps) on this run; it varies with machine load.
- Apps and saver reinstalled.

---

## 8. Still open

- **Scale** remains the unresolved 2 km vs 20 km question. This pass keeps the code's
  2 km world and recalibrates widths to 3–21.6 m; a 20 km world would require a
  different width formula and render resolution.
- **True confluence union**: the pool is round, not a polygon boolean union. It can
  still look like a pool at a sharp Y.
- **River classes / cascades**: width now varies, but there is no explicit steep-creek,
  foothill or lowland class, and no rapid/waterfall rendering.
- **Routing vs visible valleys**: the stream-power routing surface and the render
  valley carve are still separate.
- **Tarn shoreline**: the tarn has a water disc but no bank ring.
- **Parallel runs**: max 5 on seed 1, 5–9 across seeds.
- **Farm fields**: still flat plates that float/clip on slopes; separate asset fix.
- **Debug IDs/wireframe**: no junction-ID or wireframe overlay yet; the four debug
  toggles remain.

---

## 9. Reproduction

```sh
./Scripts/build.sh
./build/bin/civheadless river 1 2336

EVOLVING_WEATHER=0 EVOLVING_WIDTH=1800 EVOLVING_HEIGHT=1100 \
EVOLVING_CAMERA="0.2100,0.0600,-0.1000,0.1650,0.0180,-0.1800,45" \
./build/bin/civheadless sim review/patch4-town.png 3506 12 1 0
```

Debug flags: `EVOLVING_HIDE_RIVER=1`, `EVOLVING_HIDE_BANKS=1`,
`EVOLVING_RIVER_MAGENTA=1`, `EVOLVING_RIVER_UV=1`, `EVOLVING_RIVER_FOAM=1`.
