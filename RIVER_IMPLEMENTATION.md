# River implementation — technical brief for review

This document describes the river system exactly as implemented in
`Sources/CivRender/RiverNetwork.swift`, `Sources/CivRender/WorldScene.swift`,
`Sources/CivRender/Shaders.metal` and the clipping code in
`Sources/CivRender/CityBuilder.swift`.

It is written so an external reviewer can point at a specific stage and propose a
replacement without having to reverse-engineer the code.

---

## 1. Coordinate system and data sources

- World X/Z span `[-1, +1]`; **1 world unit = 1,000 m** (`RiverNetwork.metresPerUnit`).
  Read literally, the island is about **2 km across**. Note: a comment in
  `RiverNetwork` says “about 20 km across in 2 units”, which contradicts
  `metresPerUnit = 1_000`. This scale ambiguity matters: every metre value below
  (widths 8–21 m, depth 0.6 m, bank 1.15 m, meander wavelengths) scales by 10 if the
  intended world is 20 km. Resolve this before tuning realism.
- Terrain grid: `384 × 384` (`WorldGen.generate(seed:size: 384)`), so one cell is
  `2 / 383 × 1,000 ≈ 5.22 m` under the 2 km reading (52 m under the 20 km reading).
  The **render** terrain is built at `detail: 2` (≈2.6 m) and samples the carved
  surface; the simulation grid stays 384².
- Terrain height is stored in world units (0.02 = 20 m). The sea is height ≤ 0.004.
- `Terrain` is generated deterministically from the seed. The simulation owns
  `height`, `river` (a thresholded D8 mask) and `flow` (flow accumulation); the river
  renderer may read but **never mutates** the simulation grid.
- Everything below is derived per frame/scene build from `(seed, terrain)`; nothing is
  saved.

The river renderer is a **render-only graph and mesh**. It does not feed back into
`Simulation`. Object placement and road geometry are subsequently filtered against the
rendered water field.

---

## 2. Pipeline overview

```
terrain.height (384²)
  │
  ├─ A. routing surface: 3 stream-power passes on a copy (route, routeFlow)
  │      → routeFlow, isRiver = routeFlow > 1200
  │
  ├─ B. priority flood on `route` (sea + grid edge seeds)
  │      → filled, parent, popOrder
  │
  ├─ C. D8 `down` on `route` (strictly lower neighbour)
  │      + one parent-tree spill per true sink → connected drainage tree
  │
  ├─ D. channel mask / indegree / channelFlow / major junctions
  │
  ├─ E. source thinning (180 m) → start cells → traced reaches
  │
  ├─ F. link reaches (shared cell) → bed normalisation
  │      → junction bed unification → water-surface ramps
  │
  ├─ G. per reach: Chaikin + Laplacian + resample + meander
  │      → samples (3 m spacing, monotonic bed, width, bend limits)
  │
  ├─ H. meshes: 5-vertex water ribbon, 9-point bank strips
  │
  ├─ I. field: bucketed circle union for carving and object clipping
  │
  └─ J. shader: depth ramp, ripples, Fresnel, foam
```

Everything is deterministic: no `random()`; hashes are `sin`-based or golden-angle
phases derived from reach ids/positions.

---

## 3. Stage A — routing surface (stream-power passes)

File: `RiverNetwork.build`, lines ~717–766.

```swift
let land = indices where terrain.height > 0.004
var route = terrain.height
var routeDown = [Int](0), routeArea = [Float](0)

func steepestDown(on surface) {
    for each land cell:
        best = argmax( (surface[idx] - surface[n]) / distance ),  distance = 1 or sqrt(2)
        receivers[idx] = best   // strictly positive slope only
}

func topologicalArea(receivers) {
    pending[receiver] += 1 for every cell
    queue = cells with pending == 0
    area = 1 per land cell
    while queue not empty:
        i = queue.popFront()
        if down[i] >= 0:
            area[down[i]] += area[i]
            pending[down[i]] -= 1
            if pending[down[i]] == 0 { queue.pushBack(down[i]) }
}

for _ in 0..<3 {
    steepestDown(on: route)
    routeArea = topologicalArea(routeDown)
    for idx where routeArea[idx] > 250 {
        route[idx] -= 0.12 m
        for each 8-neighbour { route[n] -= 0.03 m }
    }
}
```

Notes:

- Base flow is **1 per land cell**, not area/moisture weighted.
- The carve is deliberately weak (0.36 m total) and **routing-only**. The rendered
  terrain is not modified; this pass only biases later D8 paths into shallow swales.
- `isRiver` is a high threshold: 1,200 cells of contributing channel length.
- This is the current response to “parallel irrigation canals”: the passes deepen the
  strongest lines and their shoulders so adjacent lines can be captured. There is **no
  real erosion, sediment transport, or valley carving in the heightfield**.

---

## 4. Stage B — priority flood (spill levels)

File: `RiverNetwork.build`, lines ~768–818.

- `filled = route`.
- Seeds: every cell with `route <= 0.004`, plus the four grid edges.
- A binary min-heap (`FloodHeap`, ordered by `(level, insertionOrder)`) pops cells in
  increasing filled height.
- When a neighbour is first reached:
  - `parent[neighbour] = poppedCell`
  - `filled[neighbour] = max(route[neighbour], poppedLevel + 1e-6)`
  - push `(filled[neighbour], insertionOrder, neighbour)`
- `popOrder[cell]` = pop sequence.

`parent` is the spill tree: following it from any cell leads to a sea/edge seed.

---

## 5. Stage C — D8 routing and spills

File: `RiverNetwork.build`, lines ~820–874.

### 5.1 Steepest descent

For every land cell:

```swift
best = argmax( (route[idx] - route[n]) / distance )
distance = 1 for axial, sqrt(2) for diagonal
down[idx] = best   // only if slope > 0
```

- This is true gradient descent, not raw lowest-neighbour, so diagonals are not
  penalised.
- Strictly positive slope only; flats/sinks use the flood parent below.
- Ties keep the first direction, which is deterministic.

### 5.2 One spill per sink

```swift
settled = false
byHeight = all cells sorted by terrain.height ascending
for idx in byHeight {
    settled[idx] = route[idx] <= 0.004
        ? true
        : down[idx] >= 0 ? settled[down[idx]] : false
}

for idx where down[idx] < 0 && route[idx] > 0.004 {   // true sink
    var cursor = idx
    while cursor >= 0 && !settled[cursor] && parent[cursor] >= 0 {
        down[cursor] = parent[cursor]
        channel[cursor] = true
        settled[cursor] = true
        cursor = parent[cursor]
    }
}
```

- `channel = isRiver` initially; spill cells are added.
- This guarantees most cells eventually reach the sea without the earlier fan of a
  spillway from every river cell.
- Roughly 10–20 true sinks remain endorheic per seed (`inlandTerminalEnds`); they are
  rendered as tarns.

### 5.3 Channel graph quantities

```swift
channelIndegree[down[idx]] += 1 for channel cells

// final contributing area, computed on the authoritative `down` graph
finalArea = topologicalArea(down)
isRiver = finalArea > 1200
flow = finalArea

isMajorJunction(idx): second-largest upstream finalArea >= 30
```

`finalArea` is the single authority for the channel mask, widths and junction
importance.

---

## 6. Stage D–E — segmentation and source thinning

File: `RiverNetwork.build`, lines ~917–965.

- Start cells:
  ```swift
  starts = channel cells with down >= 0 and channelIndegree != 1
  ```
  i.e. sources and junctions.
- **Source thinning**: sort sources by `flow` descending; keep a source only if it is
  **> 180 m** from every already-kept source. Junction starts are all kept.
- `trace(from:)`:
  ```swift
  cells = [start]
  cursor = down[start]
  while cursor >= 0 && cells.count < 1200 {
      cells.append(cursor)
      if channelIndegree[cursor] != 1 { break }   // next junction or mouth
      cursor = down[cursor]
  }
  ```
  So a reach runs from a source/junction to the **next** junction or the sea. The
  junction cell is shared with the downstream reach’s first sample; no interior
  overlap by construction.

### Linking

For each non-mouth reach:

1. Find a reach whose `firstCell == this.lastCell`; else
2. nearest downstream **start position** within 5 m.

On success: `downstream = b`, `b.upstream.append(a)`.

---

## 7. Stage F — bed and water surface

### 7.1 Per-sample bed

Every sample uses the **centreline terrain** as its bed:

```swift
bed = terrain.interpolatedHeight(sample.position)
```

An orientation-dependent cross-section low was tried and rejected: the upstream and
downstream samples at a shared junction have different tangents, so their cross-section
lows could differ by tens of metres.

### 7.2 One connected water profile

1. For each reach, start at `bed[0] + 0.60 m` and run a downstream running minimum:
   ```swift
   level = first.bed + 0.60 m
   for i in samples:
       level = min(level, bed[i] + 0.60 m)
       samples[i].waterOverride = level
   ```
2. Repeat up to 64 times, until no level changes:
   - For every reach with upstreams, `level = min(first.override, all upstream lasts)`.
   - Set the first sample and all upstream last samples to `level`.
   - Re-solve the reach profile from `level`.

Levels only fall, so this converges. The result is downstream-non-increasing, and every
shared junction endpoint has exactly the same water height. There are no 8/30-sample
ramps and no `lowest + 0.3 m` term.

`RiverChannel.waterLine` returns `waterOverride` when finite; otherwise the local
`bed + 0.60 m`.

## 8. Stage G — centreline geometry

File: `makeReach`, lines ~1254–1532.

### 8.1 Base smoothing

```swift
raw = cell centres of the traced path
points = chaikin(raw, passes: 4)          // corner cutting, never overshoots
repeat 16:  one Laplacian pass (0.25/0.5/0.25)
points = resample(points, 3 m)
repeat 80: one Laplacian pass at 3 m
```

Then the meander overlay.

### 8.2 Meander overlay

For each point `i` (after the 200 Laplacian passes):

```swift
travelled = cumulative distance
phase = reach.id * 2.3999632
grain = hash(firstPoint, 1)               // 0..1
half  = 0.5 * rawWidth[sourceIndex]       // width at this fraction of the reach
λ     = half * (14 + 6*grain)
ramp  = min(0.30*total, max(10*half, 30 m))
taper = clamp(min(travelled/ramp, (total-travelled)/ramp), 0, 1)

wave = Σ_k weight[k] * sin(2π*s/(λ*ratio[k]) + phase*(1 + 0.618k))
       ratios  = [1, 1.73, 2.41, 3.77]
       weights = [1.0, 0.55, 0.34, 0.20]

envelope = 0.72 + 0.42 * sin(2π*s/(4.7λ) + 0.73*phase)
wave *= envelope

localCap = 0.35 * local base radius (three-point circumradius)
amplitude = min(1.15*half, localCap) * taper

point += normal * wave * amplitude
```

After the overlay:

```swift
points = resample(points, 3 m)
repeat 30: Laplacian pass
```

This is an **overlay on a smoothed D8 path**, not a curvature-driven meander
migration. It is tapered to zero at both reach ends, so junction approaches are
straight. `localCap` prevents most self-intersections; the gate reports 0.

### 8.3 Samples

For each point:

```swift
width = max(rawWidth[sourceIndex], previousWidth * 0.98)   // non-decreasing
bedRaw = terrain interp at point
bed = min(bedRaw, previousBed)                             // monotonic
tangent = normalise(next - prev);  one tangent-smoothing pass
along = cumulative metres
cell = cells[sourceIndex]       // nearest original cell, for diagnostics
```

### 8.4 Width shaping

```swift
rawWidth = widthForFlow(flow[cell])
           = clamp(1.5 + 0.12*sqrt(flow), 3, 45) m

minChannel = 4 m
reliefLimit = 1.5 m
for each sample:
    width = max(rawWidth, minChannel)
    repeat up to 10:
        if terrain relief across the width <= 1.5 m: break
        width = max(width*0.85, minChannel)
    // bend cap
    radius = local circumradius
    width = min(width, max(1.20*radius, minChannel))
    channelWidth = width
    bendLimit = 0.92*radius
    bendInside = sign of cross product

// width smoothing, only narrowing:
repeat 6:
    average = (w[i-1] + 2*w[i] + w[i+1])/4
    w[i] = min(average, w[i])

// source taper: over first 55 m, width × smoothstep to max(0.16, ...)
```

---

## 9. Stage H — meshes

File: `WorldScene.swift`, `riverGeometry` and `riverBankGeometry`.

### 9.1 Water surface

- 5 vertices across per sample: `f = [-1, -0.5, 0, 0.5, 1]`.
- Every vertex is at the same height `waterLine(sample)`.
- Vertex colour RGB is a fixed tint; **alpha is normalised depth**:
  ```swift
  depth = clamp((fieldWaterLevel(p) - carvedBed(p)) / 1.25 m, 0, 1)
  edge vertices forced to 0
  ```
- Deck lift is **0**: every reach shares the same water height at a junction.
- Unlinked ends get a half-ellipse cap: 16 segments, outward semi-axis `0.62*half`.
- Linked ends get **no cap**.
- Every junction is one **Y-shaped polygon**: each reach is trimmed back
  `1.05 × max incident half-width`; its five cut cross-section vertices are
  deduplicated, angle-sorted around the junction cell and triangulated as a centre fan.
  The fan carries each cut vertex's own water height and depth. There is no disc and no
  overlay lift.

### 9.2 Bank surface

Per reach, two strips (side −1/+1), 9 profile points each:

```
0 waterline                    y = water
1 wet margin                   +1.3–1.8 m
2..5 slope                     up to crest
6..8 apron                     settles to terrain
```

- `crestTarget = water + 0.35 m * (0.95 + 0.18h)`.
- Slope minimum 1.0 m, apron minimum 2.0 m; both scale with half-width.
- On the inside of a bend, slope and apron are compressed to fit inside
  `bendLimit = 0.92*radius`.
- Bank strips are trimmed by `1.0 × max(half-width)` at both junction ends.
- Crest capped at `water + 2.0 m` on steep cuts; the apron still climbs to terrain.
- Waterline vertex is lowered 4 mm to avoid coplanar z-fighting with the water sheet.
- Material id 8 (the same procedural ground-cover shader as the terrain).

### 9.3 Carving

`RiverChannel.Field` stores one circle per sample (`halfWidth`, `waterY`), plus one
confluence circle of radius `1.3 × max incident half-width` at each junction.
Buckets are `0.02 units` (20 m).

```swift
carvedHeight(h, field, x, z):
    s = nearest capsule (water level, signed distance d)
    if d <= 0: return water - 0.45 m
    if d <= 4 m:
        allowed = water - 0.45 m + (d/4)*0.44 m     // wet shelf
    else:
        allowed = water - 0.01 m + (d-4)*0.55        // slope-limited valley
    return min(h, allowed)
```

Inside the capsules the terrain is cut to 0.45 m below water. Outside, a 4 m wet shelf
stays below the water, then the ground may rise at 0.55 vertical/horizontal. On a
steep hillside this cuts a **valley**; on gentle ground it does nothing. The bank
profile samples this carved surface for its terrain heights, so the apron joins the
valley rather than the raw cliff. The render terrain is built at `detail: 2` (≈2.6 m
vertices) with normals from the carved surface.

`WorldScene` also stores the **carved** terrain copy and uses it for every placement
(buildings, roads, bridges, trees, people), so props sit on the valley floor rather
than on the uncarved heightfield. The simulation keeps its canonical terrain.

---

## 10. Stage J — water shader

File: `Shaders.metal`, material 18, lines ~669–743.

- `depth = in.extra` (0 at shore, 1 at 1.25 m+).
- Two ripple layers sampled in channel coordinates:
  `flowUv = (uv.x*5, uv.y*0.45)`, with different scales/speeds.
- Normal perturbation is weak: `mix(0.002, 0.030, detail)`.
- Fresnel: `0.07 + 0.38 * pow(1 - dot(n, viewDir), 4)` (flat normal `n`).
- Body colours: shore `(0.085,0.130,0.115)` → shallow `(0.020,0.090,0.100)` →
  mid `(0.009,0.048,0.078)` → deep `(0.003,0.020,0.040)`.
- Sky reflection: `skyColour(time) * 0.90`, blended by `fres * 0.55`.
- Sun glint: `pow(dot(n, halfDir), 220) * mix(0.015,0.09,detail)`.
- Shore foam: `smoothstep(0.055,0, depth)` × noise breakup + a surge band.
- Debug modes in `shadow.w`: 1 no shadow, 2 magenta, 3 UV, 4 foam.

---

## 11. Clipping and crossings

- Buildings (`CityBuilder.build`): drop if base below water or within 2 m of the water
  edge.
- Streets (`appendStreetLines`, `appendRoadLines`): split where `field.surface`
  distance < 2 m; also reject points not line-of-sight connected to the settlement
  centre without crossing water (`connected`).
- Plots: planted only on the town’s bank (`connected`).
- Crop fields: footprint samples (3×3 local grid) rejected if within 1.5 m of water.
- Civic paving: skipped if the settlement centre is wet.
- Bridges (`WorldScene.appendBridges`): crossings detected with `field.surface`
  distance < 2 m; deck height `max(ground, water) + 1.8 m + arch`; spans > 120 m
  rejected as parallel-road artefacts.
- People/animals: standing/walking guards reject points where
  `riverField.waterLevel != nil`.

---

## 12. Gates / current numbers

`civheadless river <seed> <year>` builds the graph, channel diagnostics and prints
`PASS/FAIL`. Seed 1, year 2336:

```
reaches: 69  sources: 24  junctions: 15  mouths: 4
width: 3.0–21.6 m
max uphill: 0.000 m
min curvature radius: 20.9 m
max adjacent turn: 11.3°
self-intersections: 0
max junction angle: 26.6°
max sample spacing: 3.00 m
linked reaches: 60  max link gap: 0.00 m
inland terminal ends: 5  junction water step: 0.000 m
max parallel channels in a row: 5
water surface rise: 0.000 m  graph identity: OK

bank lip: 0.33–2.00 m (mean 0.38)
channel depth: 0.93–2.60 m (mean 0.98)
water depth: 0.60 m
wet margin: 1.30–1.80 m
waterline welds: 3158/3158
bed above water: 0 probes
submerged: trees 0 buildings 0 road crossings 0
```

Gate thresholds:

- width 8–45 m
- uphill ≤ 0.01 m
- curvature ≥ 0.5 m
- adjacent turn ≤ 40°
- self-intersections 0
- max parallel runs ≤ 14 (measured over a 64-cell / ~250 m window per row)
- linked reaches > 0, link gap ≤ 5 m
- inland terminal ends ≤ 30% of reaches
- junction water step ≤ 0.05 m
- junction angle ≤ 90°
- sample spacing ≤ 5 m

---

## 13. Known failure modes and why they happen

These are the problems still visible in the Timeline app.

### 13.1 Parallel channels / “irrigation canals”

- Root cause: flow is still **D8 on a smooth heightfield**. On a plane, many cells have
  parallel steepest-descent lines. The stream-power passes are weak, routing-only, and
  do not create real valleys in the terrain.
- Mitigations are heuristic: source thinning at 180 m, one spill per sink, a high
  `routeFlow` threshold, and a stream-power routing bias.
- There is **no catchment merging** (no graph contraction of parallel basins) and no
  erosion feedback.
- The `maxParallelChannels` metric is a proxy, not a guarantee. Seeds vary 5–9.

### 13.2 Angular/stepped shorelines — substantially reduced

- The render terrain is now `detail: 2` (≈2.6 m vertices), normals come from the
  carved surface, and the carve feathers 4 m outside the water. The triangular teeth
  that followed 5.2 m terrain triangles are gone at normal viewing distances.
- At extreme zoom the 2.6 m heightfield is still the limit. True adaptive
  river-adjacent tessellation has not been implemented.

### 13.3 Straight junction approaches

- The meander tapers to zero at reach ends (to preserve shared junction cells), so the
  last ~30 m of every tributary is straight.
- Junctions now have a watertight fan, but it is flat: no local rapid, bar or
  slope treatment.

### 13.4 Water profile

- Water is one connected downstream-non-increasing profile over the reach tree: local
  centreline bed + 0.60 m, lowered at junctions to the lowest incident end. There are no
  ramps. It is not a solved hydraulic surface; reverse slopes and junction steps are
  both 0 by construction.

### 13.5 Width not tied to valley

- Width comes from graph flow (`4 + 0.22√flow`) and a relief cap. It is not derived
  from valley width or floodplain. First-order streams are all at least 8 m wide.

### 13.6 Tarns / endorheic basins

- True sinks spill along the priority-flood parent tree, but 5–19 per seed remain
  endorheic and render as rounded caps. No lake polygon or lake shoreline exists.

### 13.7 No terrain coupling

- Rendering the valley shape, bank migration, sediment, and floodplain deposition are
  absent. The routing surface is invisible; the heightfield is unchanged.

---

## 14. Questions for the reviewer

1. **Terrain-scale drainage**: what is the cheapest stable model to produce dendritic
   valleys here — stream-power incision with priority-flood, a coarse-to-fine
   catchment graph, D-infinity/multi-flow, or graph contraction? Target budget: one
   scene build, CPU, 384².
2. **Networks from a smooth heightfield**: how to guarantee a few trunks instead of
   parallel rills without hand-thinning sources.
3. **Water surface**: should this become a global grid/heightfield clipped by a
   channel mask, or a solved 1-D profile per reach with a junction solver?
4. **Shoreline geometry**: how to render a union water polygon and a matching carved
   valley with a coarse terrain grid (adaptive mesh? clipmap? stencil?).
5. **Meander**: is an overlay acceptable, or should meander be curvature-driven
   migration coupled to the valley?
6. **Performance**: current build is ~0.5 s for the river graph; the app rebuilds on
   seed change, not per frame.

---

## 15. Reproduction

```sh
./Scripts/build.sh
./build/bin/civheadless river 1 2336
EVOLVING_WEATHER=0 EVOLVING_WIDTH=1800 EVOLVING_HEIGHT=1100 \
EVOLVING_CAMERA="ex,ey,ez,tx,ty,tz,fov" \
./build/bin/civheadless sim out.png 2336 12 1 0
```

Debug flags:

- `EVOLVING_HIDE_RIVER=1`
- `EVOLVING_HIDE_BANKS=1`
- `EVOLVING_RIVER_MAGENTA=1`
- `EVOLVING_RIVER_UV=1`
- `EVOLVING_RIVER_FOAM=1`

Primary files:

- `Sources/CivRender/RiverNetwork.swift` — graph, routing, samples, diagnostics
- `Sources/CivRender/WorldScene.swift` — water/bank meshes, carving call, bridges
- `Sources/CivRender/RiverNetwork.swift` — `RiverChannel.Field`, `carvedHeight`
- `Sources/CivRender/Shaders.metal` — water material
- `Sources/CivRender/CityBuilder.swift` — clipping
- `Sources/CivCore/WorldGen.swift` — terrain, `river`, `flow`
- `Sources/Headless/main.swift` — `river`, `sim`, `determinism`, `bench`
