# Evolving — current river implementation, for external review

**Date:** 2026-11-10
**Basis:** the actual Swift sources in this repository after river patches 1–4. This is
not a summary of a summary; the constants and formulas below are copied from the code.
**Screenshots to review:**

- `review/patch4-town.png` — medieval town, year 3506 (junction close-up)
- `review/patch4-hero.png` — river and town, year 2336
- `review/patch4-island.png` — whole island, year 2336
- `review/patch4-debug-sheet.png` — 2×2: normal / banks hidden / river hidden / magenta water

---

## 1. Scale and grid — unresolved decision

- World X/Z span `[-1, +1]`.
- `RiverNetwork.metresPerUnit = 1_000`, so the code's physical world is **2 km across**.
- A stale comment says “20 km across in 2 units”; it contradicts the constant.
- Terrain grid: `384 × 384` (`WorldGen.generate(seed:size: 384)`), cell = **5.22 m**
  under the 2 km reading.
- Render terrain: `detail: 2`, **2.6 m** vertices, carved normals.
- **Decision taken this pass:** keep the 2 km world and recalibrate widths. This is
  documented, not hidden; a 20 km refactor would change every width/depth/bank constant.

Please review this decision explicitly. The current width model is calibrated for a
2 km island.

---

## 2. Current pipeline (exact order)

Files:

- `Sources/CivCore/WorldGen.swift` — canonical terrain, seed, settlement simulation
- `Sources/CivRender/RiverNetwork.swift` — routing graph, reaches, bed/water, diagnostics
- `Sources/CivRender/WorldScene.swift` — carved terrain, water/bank meshes, carving
- `Sources/CivRender/Shaders.metal` — water material
- `Sources/CivRender/CityBuilder.swift` — placement and clipping
- `Sources/Headless/main.swift` — `river`, `sim`, `determinism`, `bench`

Order:

1. **Routing surface** (render-only, `RiverNetwork.build`):
   - `route = terrain.height`; 3 stream-power passes.
   - Each pass: true-gradient D8 on `route` (diagonal distance `√2`); topological
     accumulation with a donor queue; cells with `routeArea > 250` lower by 0.12 m and
     their 8 neighbours by 0.03 m.
   - After the passes: `routeArea` is recomputed on the final receiver graph; the
     channel mask is `routeArea > 1200`; `flow = routeArea`.
2. **Priority flood** on `route`: seeds are sea cells (`≤ 0.004`) and the four grid
   edges; `filled`, `parent`, `popOrder`, binary min-heap.
3. **Final D8 receiver**: true steepest positive slope on `route`.
4. **Sink handling**: cells whose steepest path already reaches the sea are marked
   `settled` in increasing-height order; each true sink walks the flood-parent tree
   until it reaches a settled cell, overriding `down` along that one spill path.
5. **Final area**: topological accumulation on the authoritative `down`; the channel
   mask is derived from this area (not from the pre-spill pass).
6. **Reach segmentation**: start cells are channel cells with `indegree ≠ 1`; a reach
   stops at the next junction/mouth. One source per 180 m is kept (source thinning);
   all junction starts are kept.
7. **Linking**: downstream reach is the one whose `firstCell == lastCell`; fallback is
   nearest start within 5 m.
8. **Bed/water**: local centreline terrain is the bed. Water is one connected
   downstream-non-increasing profile: start at `bed + 0.60 m`, running minimum along
   the reach, then lower all junction endpoints to the lowest incident end (64 passes).
9. **Centreline**: Chaikin ×4 → 16 Laplacian → resample 3 m → 80 Laplacian →
   meander overlay → resample 3 m → 30 Laplacian.
10. **Widths**: `clamp(1.5 + 0.12√flow, 3, 45) m`; relief narrowing; bend cap
    `1.20 × radius`; six narrowing-only smoothing passes; 55 m source taper.
11. **Terrain carve** (`RiverChannel.carvedHeight`):
    ```
    d <= 0:      water − 0.45 m
    0 < d <= 4:  water − 0.45 m + (d/4) × 0.44 m       // wet shelf
    d > 4:       water − 0.01 m + (d − 4) × 0.55        // ≤29° valley wall
    return min(originalHeight, allowed)
    ```
12. **One carved terrain**: `WorldScene` stores `carvedTerrain` with the formula
    applied at every 384² cell; the terrain mesh, buildings, roads, bridges, trees and
    people all use it. The simulation keeps the canonical terrain.
13. **Meshes**:
    - water: 5 vertices across, depth in vertex alpha (`(water − carvedBed)/1.25 m`);
    - caps only at unlinked ends (half-ellipse, outward 0.62×half);
    - junction **round pool** radius `1.05 × max half`, 24 segments, shared level +2 mm;
    - tarns: `2.5 × half` water disc + matching field circle;
    - banks: 9-point profile, natural crest `water + 0.35 m`, capped `water + 2.0 m`,
      trimmed `1.0 × max half` at junctions, waterline −4 mm;
    - **no per-reach deck lift** (lift = 0).
14. **Field**: capsule per sample pair (segment, interpolated half-width and water
    level) + junction circle 1.3 R + tarn circle 2.5 R, 20 m buckets.
15. **Clipping**: buildings/streets/plots/fields/plaza/bridges/people against the same
    field; bridges keyed to the rendered water.

---

## 3. What the last review asked for, and what was done

| Review item | Status |
|---|---|
| Square confluence plug | **Fixed**: four-point angle fan replaced by a round pool |
| Blunt headwater stubs | **Improved**: minimum width 3 m, source taper; caps remain |
| Isolated inland terminal | **Improved**: tarns are now 2.5 R discs with carved field circles |
| Bank crest everywhere | **Reduced**: 1.15 m → 0.35 m natural crest (2 m cap on steep cuts) |
| Ruler-straight channels | **Partially**: Laplacian 200 → 80; widths narrowed; meander still an overlay |
| Scale ambiguity | **Decided** for this pass: 2 km world, recalculated widths; documented |
| Surface valleys not routed | **Not fixed**: routing surface and render carve still separate |
| River classes/cascades | **Not implemented** |
| True confluence union | **Not implemented**: round pool, not polygon boolean |
| Debug IDs/wireframe | **Not implemented**; four existing debug toggles only |
| Farm fields floating | **Not fixed**; separate asset task (lowering attempt reverted) |

---

## 4. Gate — seed 1, year 2336

```
reaches: 69  sources: 24  junctions: 15  mouths: 4
width: 3.0–21.6 m          (reported raw width; rendered min 4 m)
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

All 11 seeds pass. Determinism OK at 1200/2336/4000. `verify.sh` OK. 6K bench 17.92 ms
(55.8 fps) on the last run.

Graph identity: `24 sources = 9 outlets + 15 junction excess`; `60 edges =
69 reaches − 9 outlets`.

---

## 5. What still looks wrong — honest list

1. **Confluences are round pools, not unions.** A sharp Y can read as a circular basin.
   The pool is at one level and watertight, but its boundary is not the union of the
   swept footprints.
2. **Mountain channels can still be straight.** The meander is an overlay; it is
   tapered to zero at reach ends and clamped by local bend radius, so steep, narrow
   reaches stay almost straight. There is no slope/stream-order class.
3. **No cascades/rapids.** Every reach uses the same flat water ribbon. A steep
   mountain drop is not represented as stepped flow/whitewater.
4. **Routing vs visible valleys are separate surfaces.** The stream-power routing
   surface (invisible) picks the path; the render valley carve is applied afterwards.
   A path can therefore require implausible excavation to exist.
5. **Tarns have water discs but no bank ring.** Their edge can end against rising
   ground without a beach/shore mesh.
6. **Farm fields are flat plates.** They float or clip on slopes; this is a separate
   asset problem and was not hidden by changing the river.
7. **5–9 parallel runs** can still share a 250 m row on some seeds.
8. **The natural bank crest is still positive (0.35 m).** It is no longer a levee, but
   it is not terrain-only.
9. **No wireframe/junction-ID debug overlay.** The debug sheet distinguishes water,
   banks and terrain but not individual reaches/junctions.
10. **The 2 km vs 20 km scale is a decision, not a refactor.** Every metre value still
    depends on `metresPerUnit = 1_000`.

---

## 6. Specific questions for the reviewer

1. **Confluence footprint:** what is the most robust way to produce a true union of
   swept water ribbons at a Y, on a 384² logic grid with 2.6 m render vertices and a
   Metal mesh pipeline? Options considered: polygon boolean (no dependency yet),
   local SDF + marching squares + triangulation, stencil/depth tricks, or overlapping
   ribbons with a shared level. Which would you implement first and why?
2. **Scale:** should the project commit to 2 km or 20 km? If 20 km, what width law and
   render resolution are needed so a 3–20 m channel is visible without turning every
   source into a sub-pixel thread?
3. **River classes:** what is the smallest useful class system (steep creek, foothill,
   lowland main stem) that changes geometry, bank profile and water treatment without
   destabilising the reach graph?
4. **Route–incise–reroute:** can we run a small erosion loop on a working terrain and
   then use the *same* surface for routing, visible valleys and placement, while
   keeping the simulation deterministic? What is the cheapest stable formulation at
   384²?
5. **Bank crest:** is a 0.35 m natural lip acceptable, or should natural reaches have
   no positive crest at all? If none, how do you keep the opaque water from visually
   spilling over the carved shelf?
6. **Tarns:** is a 2.5 R water disc with a field circle enough, or should closed basins
   get a shoreline mesh and a fill/spill elevation solve?
7. **Acceptance tests:** beyond the current numerical gates, which image/geometry
   checks would you automate first (coastal continuity, source taper, junction union,
   width hierarchy, slope class, valley cut budget, bank profile, deterministic panel)?

---

## 7. Reproduction and debug

```sh
./Scripts/build.sh
./build/bin/civheadless river 1 2336

EVOLVING_WEATHER=0 EVOLVING_WIDTH=1800 EVOLVING_HEIGHT=1100 \
EVOLVING_CAMERA="0.2100,0.0600,-0.1000,0.1650,0.0180,-0.1800,45" \
./build/bin/civheadless sim review/patch4-town.png 3506 12 1 0
```

Debug flags:

- `EVOLVING_HIDE_RIVER=1`
- `EVOLVING_HIDE_BANKS=1`
- `EVOLVING_RIVER_MAGENTA=1`
- `EVOLVING_RIVER_UV=1`
- `EVOLVING_RIVER_FOAM=1`

The debug sheet is the same camera/seed/year in four modes; the terrain-only panel
proves the valley exists without the bank strips, and the water-only panel shows the
continuous channel and confluence pool.
