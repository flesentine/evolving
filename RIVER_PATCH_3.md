# Evolving — river patch 3

**Date:** 2026-11-10
**Scope:** response to `RIVER_SECOND_PASS_REVIEW.md`. No shader/foam changes; this
pass is river/terrain coupling, graph correctness and confluence geometry.

Screenshots:

- `review/patch3-hero.png` — close river and town, year 2336
- `review/patch3-town.png` — river through the Medieval town, year 3506
- `review/patch3-island.png` — whole island, year 2336
- `review/patch3-debug-sheet.png` — 2×2: normal / banks hidden / river hidden / magenta water

---

## 1. Graph audit — the counter mismatch is resolved

The review correctly spotted that `19 sources / 15 junctions / 9 outlets` cannot
describe one directed forest. The cause was the source counter: it reported the
**pre-prune `isSource` flag**, not the graph's leaves.

After pruning, the reach forest is:

```
69 reaches
24 graph sources (reaches with no upstream)
15 junctions (reaches with >= 2 upstreams)
 9 outlets (reaches with no downstream: 4 coastal mouths + 5 inland tarns)
60 edges (sum of upstream lists)
15 junction excess (sum of indegree - 1)
```

Identity: `24 = 9 + 15`. Edges: `60 = 69 - 9`. Both now pass a hard gate that is
computed from the final reach graph, not from flags.

`civheadless river` prints `graph identity: OK` only when both hold.

---

## 2. River–terrain coupling

### 2.1 Slope-limited valley carve

The old carve cut to `water − 0.45 m` and returned to raw terrain over 4 m. Where
the hillside was far above the water that produced a vertical green wall.

`RiverChannel.carvedHeight` is now:

```swift
d = signed distance from the water edge (negative inside)
if d <= 0:      return water - 0.45 m
if d <= 4 m:    allowed = water - 0.45 m + (d / 4) * 0.44 m   // wet shelf
else:           allowed = water - 0.01 m + (d - 4) * 0.55      // <= 29 deg
return min(originalHeight, allowed)
```

- Inside the channel: 0.45 m of water cover.
- First 4 m outside: stays just below the water, so a terrain triangle crossing the
  waterline cannot poke through.
- Beyond 4 m: ground may rise at 0.55 vertical/horizontal. On a steep hillside this
  cuts a valley; on gentle ground it does nothing.
- Bank-profile terrain heights are sampled from this carved surface, so the apron
  joins the valley instead of the original cliff.

### 2.2 One carved terrain for rendering and placement

`WorldScene` now builds a **carved copy** of the terrain after the river field exists:

```swift
var carved = terrain
for every terrain cell:
    carved.height[idx] = RiverChannel.carvedHeight(
        terrain.height[idx], field, x, z)
self.terrain = carved
```

- The simulation keeps its own canonical `Terrain`; only the scene copy is carved.
- The height texture uploaded to the water shader is the carved height.
- `CityBuilder`, roads, bridges, trees and people read `scene.terrain`, so props sit
  on the valley floor instead of floating above it.
- The terrain mesh is `detail: 2` (≈2.6 m vertices); normals are computed from the
  carved surface.

This fixed the floating props that appeared when the valley was introduced.

### 2.3 Terrain mesh

- `terrainVertices(detail: 2)`, `terrainIndices(detail: 2)`.
- Normals sample the carved surface, not the raw heightfield.
- 4 m wet shelf + 0.55 valley grade replaced the 4 m feather.

---

## 3. Confluences

- `riverGeometry` now builds a **watertight fan** at every junction:
  - collect the two waterline points of the downstream first sample and of every
    upstream last sample;
  - deduplicate, sort by angle around the junction cell;
  - triangulate centre → ring at the shared water level.
- The fan shares the reach end positions and the unified water height, so the wedge
  between ribbons is filled without a raised disc.
- Per-reach water deck lift removed: every reach uses `lift = 0`. The old 4 cm
  `(id % 5) * 0.00004` lift is gone.
- Bank strips are trimmed by `1.0 × max half-width` at junctions (was 2.0), so the
  banks reach closer to the shared cell.

---

## 4. Banks

- Nine-point profile unchanged in structure.
- Crest capped at `water + 2.0 m` on steep cuts; the apron still climbs to the carved
  terrain.
- Waterline vertex is 4 mm below the sheet to avoid coplanar z-fighting.
- Material 8 (same procedural ground shader as the terrain), so banks read as ground.

---

## 5. Gate — seed 1, year 2336

```
reaches: 69  sources: 24  junctions: 15  mouths: 4
width: 8.0–40.8 m
max uphill: 0.001 m
min curvature radius: 16.2 m
max adjacent turn: 13.4°
self-intersections: 0
max junction angle: 26.6°
max sample spacing: 3.00 m
linked reaches: 60  max link gap: 0.00 m
inland terminal ends: 5  junction water step: 0.000 m
max parallel channels in a row: 5
water surface rise: 0.000 m  graph identity: OK

channel cross-sections: 1591
bank lip: 1.09–2.00 m (mean 1.21)
channel depth: 1.69–2.60 m (mean 1.81)
water depth: 0.60 m
wet margin: 1.30–1.80 m
waterline welds: 3182/3182
bed above water: 0 probes (max 0.000 m)
submerged: trees 0  buildings 0  road crossings 0
```

All 11 seeds: `PASS PASS`.

- Determinism OK at years 1200 / 2336 / 4000.
- `./Scripts/verify.sh` OK.
- 6K bench: 11.63 ms/frame (86.0 fps).
- Apps and saver reinstalled.

---

## 6. Debug sheet

`review/patch3-debug-sheet.png` shows the same camera, seed and year:

| Quadrant | Flag | What it shows |
|---|---|---|
| top-left | none | final shaded scene |
| top-right | `EVOLVING_HIDE_BANKS=1` | water and carved terrain without bank strips |
| bottom-left | `EVOLVING_HIDE_RIVER=1` | terrain and valley without water |
| bottom-right | `EVOLVING_RIVER_MAGENTA=1` | water-only surface |

The terrain-only quadrant shows the valley is in the terrain, not a bank-strip
illusion. The water-only quadrant shows the continuous channel and confluence fan.

---

## 7. Still open

- **Bank crest** is still a capped positive lip. It is no longer a wall, but it is
  not terrain-only yet.
- **River classes / cascades**: no steep-creek vs lowland-main-stem distinction, no
  whitewater/rapids class.
- **Tarns**: 5 endorheic ends on seed 1 have rounded caps, not lake polygons.
- **Parallel runs**: 5 maximum on seed 1, 5–9 across seeds.
- **Routing vs render valleys**: the stream-power routing surface and the render
  valley carve are still separate; the visible terrain is not the routed terrain.
- **Fields**: flat agricultural plates can still float or clip on slopes. A
  terrain-conforming field mesh is a separate asset fix (the attempted lowering pass
  was reverted because it turned plates into triangles).
- **Confluence fan** is flat; it has no local slope/rapid treatment.

---

## 8. Reproduction

```sh
./Scripts/build.sh
./build/bin/civheadless river 1 2336

EVOLVING_WEATHER=0 EVOLVING_WIDTH=1800 EVOLVING_HEIGHT=1100 \
EVOLVING_CAMERA="0.1000,0.0900,-0.2450,0.1630,0.0184,-0.1816,45" \
./build/bin/civheadless sim review/patch3-hero.png 2336 12 1 0
```

Debug flags:

- `EVOLVING_HIDE_RIVER=1`
- `EVOLVING_HIDE_BANKS=1`
- `EVOLVING_RIVER_MAGENTA=1`
- `EVOLVING_RIVER_UV=1`
- `EVOLVING_RIVER_FOAM=1`
