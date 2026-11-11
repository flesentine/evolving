# Evolving Timeline — river system review and rebuild plan

**Review basis:** `RIVER_IMPLEMENTATION.md` (630 lines) and the November 9, 2026 screenshot. The Swift/Metal source files themselves were **not** supplied, so code-level faults below are inferred from the brief and need checking against the implementation.

## Executive verdict

The rivers look like artificial canals chiefly because **the drainage network, terrain surface, river geometry, and water surface are not being generated as one coherent system**. The network is extracted from a lightly modified routing copy of a coarse heightfield, but the visible terrain has not acquired the broad valleys that should guide those rivers. The final ribbon is instead dug into a coarse render mesh with a 0.5 m edge fade. No amount of ripple, foam, or water tint changes will fix that.

**Order of operations:** (1) lock scale and repair topology, (2) make the render mesh accurately honor the river cut, (3) add actual valley shaping, (4) make channels join and change width naturally, (5) improve river styling, and only then (6) tune water shading.

## What is visible in the screenshot

1. **Triangular sawtooth bank geometry** along the mountain-foot channel: shore edges follow large terrain triangles rather than a smooth continuous water boundary.
2. **A second channel runs roughly parallel to the principal channel** instead of clearly joining it, creating an irrigation-canal look.
3. **The hillside tributary looks like a straight blue slot** rather than a stream flowing in a landform-shaped gully. Its width and banks look too uniform.
4. **Continuous hard, raised banks** on both sides of stretches resemble flood-control levees. The bank height formula explicitly adds a crest ~1.15 m above the water everywhere.
5. **Channel junctions are not convincing**: confluence geometry is disabled (`junctions = []`) and smoothing/tapering straightens tributary approaches.
6. **The steep water courses lack a distinct cascade/rapid treatment**. A normal flat-surface river ribbon is not an adequate visual model for every gradient.

The screenshot alone cannot prove which individual algorithm causes each issue. The corresponding documented stages make these the likely explanations.

## 1. First fix the underlying correctness issues

### P0-A. Resolve the physical scale and grid resolution

The brief says `1 world unit = 1,000 m`, making the `[-1,+1]` terrain **2 km across**, but a code comment says **20 km**. At a 384 x 384 grid:

| Assumed world size | Cell spacing | 8 m stream width relative to cell | 1,200-cell drainage area |
|---|---:|---:|---:|
| 2 km | 5.22 m | 1.53 cells | 0.0327 km² |
| 20 km | 52.2 m | 0.15 cells | 3.27 km² |

The width threshold and terrain spacing cannot be evaluated coherently until this is resolved. Under the 2 km interpretation, the system can produce an approximately 8–12 m channel from a tiny drainage basin; under the 20 km interpretation, the same channels are narrower than one terrain cell. **Keep physical distance and artistic screen-space exaggeration as separate quantities**. Put the chosen metres-per-world-unit constant in one shared location and add unit tests for cell spacing, width, runoff-area threshold, and carved depth.

### P0-B. Derive the channel mask from the *final* routing graph

The brief's Stage A saves `routeFlow` from its last pass **before** the final incision in that pass. It thresholds `isRiver = routeFlow > 1200`. Stages B–C then flood and reroute an already changed `route` surface, including spill paths. That means the channel mask/flow field can describe a different drainage network from `down`.

**Required sequence:**

1. Generate/condition the routing heightfield.
2. Create **one acyclic final downstream receiver per valid drainage cell**, including explicit depression/lake handling.
3. Recompute contributing area or runoff on that **final** receiver graph.
4. Derive the channel mask from that accumulated area.
5. Prune/render tributaries and then recompute *post-pruning* junctions, sources and links.
6. Only then construct reaches and meshes.

Retain `filled`, `parent`, and `popOrder` as aids to routing; do not use earlier passes' accumulation as the final authoritative network.

### P0-C. Verify D8 chooses gradient, not just the lowest neighboring elevation

Stage C's pseudocode is `argmin(route[n])` for all eight neighbors. That is **not** true steepest descent: a diagonal neighbor is `sqrt(2)` times farther away than an axial neighbor. Select the largest positive `(z_here - z_neighbor) / distance`, with a deterministic tie-break. On filled flats use an ordered drainage potential / flood parent so no cycles can form. This error can contribute a grid-direction bias even before smoothing.

### P0-D. Use actual topological order for accumulation

`channelFlow` is accumulated in `reverse popOrder`. A Priority-Flood traversal order is **not automatically** a topological order for a downstream graph that was subsequently assembled from a mixture of steepest-neighbor routing and spill-parent overrides. The comment in the brief even calls reverse pop order “downstream first,” whereas accumulation requires **upstream before downstream**.

Use donor/indegree counts and a queue of leaves:

```swift
// down[i] is the authoritative receiver; -1 denotes an outlet or lake.
var pendingDonors = [Int](repeating: 0, count: cellCount)
for i in validCells where down[i] >= 0 { pendingDonors[down[i]] += 1 }
var area = runoffAreaPerCell  // precipitation-weighted if desired; otherwise cell area
var queue = validCells.filter { pendingDonors[$0] == 0 }
var visited = 0
while let i = popFront(&queue) {
    visited += 1
    let j = down[i]
    if j >= 0 {
        area[j] += area[i]
        pendingDonors[j] -= 1
        if pendingDonors[j] == 0 { pushBack(&queue, j) }
    }
}
precondition(visited == validCells.count, "Drainage graph has a cycle")
```

Use an O(1) FIFO index, not a costly `removeFirst()` array operation. If there are lakes, terminate flow into explicit lake nodes that can overflow to an outlet.

### P0-E. Audit the reported source/junction counts

The sample diagnostics are **19 sources, 46 junctions, 1 mouth, 10 inland terminal ends**. If those quantities describe the same pruned river forest, something is inconsistent.

For a directed forest in which each channel node has at most one downstream edge, the identity is:

`number of sources = number of terminal outlets + sum_over_junctions(incoming_degree - 1)`.

Thus even **46 binary junctions and a single outlet require at least 47 sources**. Your 19 could be the **retained** source count while 46 junctions still reflect the **unpruned** graph. That would mean source thinning removes the start of a tributary without removing its cells and recomputing degrees. Alternatively, the metrics may refer to different definitions. Either way, instrument the graph after all trimming and verify the identity.

**Do not** thin sources by only discarding `starts`. Prune the intended upstream channel *edges*, then reconstruct indegrees, junctions, reaches, widths and confluences. Prefer pruning using drainage area, tributary length, and confluence importance, not a global 180 m nearest-source rule.

### P0-F. Separate water-surface tests from bed-height tests

`bed = min(previousBed, ...)` guarantees a non-increasing *bed*, but `waterY = max(bed + 0.60 m, lowestUnder + 0.30 m)` does **not** necessarily guarantee a non-increasing *water surface*. A downstream sample can have a larger `lowestUnder` because of terrain and smoothing. Junction endpoint levels have been forced equal and therefore trivially pass the junction-step test, even if the preceding ramp makes an ugly pool/slope.

Track `maxPositiveWaterSurfaceSlope`, `maxWaterRampSlope`, `bedBelowWaterEverywhere`, and `maxSlopeChangeNearJunction` independently. Evaluate the entire continuous water network, not just shared endpoints.

### P0-G. Revisit boundary conditions and inland terminal ends

The priority flood seeds all four map edges as well as sea cells. Confirm that a high land edge is genuinely an allowed outlet; otherwise boundary behavior can draw rivers toward artificial off-map exits. The 10–20 inland terminal ends per seed should be either legitimate closed-basin lakes rendered with lake polygons **or** drainage-routing bugs. A rounded ribbon cap is not an adequate tarn.

## 2. Recommended routing / landscape model

### Cheapest robust hydrology on a 384² CPU grid

**Keep D8 for the final, one-receiver river tree, but condition the DEM and recalculate the entire drainage graph consistently.** D8 itself is not the fatal problem. D-infinity or multiple-flow-direction routing can better represent diffuse runoff on slopes, but neither inherently produces a visually superior single-stem river network. If using MFD for hillslope runoff, collapse it to a consistent dominant receiver for channel geometry.

A good pipeline is:

```text
seeded base terrain + sea mask + chosen world scale
       |
   priority-flood/depression classification
       |
   downstream receiver (true steepest slope; flood-safe flats)
       |
   topological accumulation of runoff / drainage area
       |
   optional 3–8 bounded stream-power incision iterations on a copy
       |    incision ~ K * area^m * positiveSlope^n
       |    recompute drainage after each iteration
       |
   final receiver + final accumulated flow (ONE authority)
       |
   channel extraction + topology-preserving prune
       |
   valley carving on render/worldgen terrain
       |
   valley-constrained centerlines + junction smoothing
       |
   connected water-surface profile
       |
   adaptive river-aware terrain mesh, banks and water patches
       |
   shared collision/placement/bridge river field
```

The existing three constant 0.12 m incisions for cells with flow >250 are **not a stream-power model**: incision should depend on drainage area *and* gradient, subject to a stable cap. Use the classic `E = K A^m S^n` form as a *terrain-shaping heuristic* (not necessarily a full physical simulation), plus a modest hillslope smoothing pass near the valleys. Keep it deterministic. The first implementation should be visually conservative and should not create enormous trenches through steep slopes.

### How to create a few trunks instead of dozens of canals

There is no sound rule that says every smooth random heightfield will naturally drain into one or two pretty trunks. **The terrain's large-scale relief determines its basins.** You can prune/merge small same-basin tributaries, but contracting arbitrary neighboring channels after routing may require rivers to cross drainage divides or flow uphill.

For the biggest improvement, impose **macro geography before microscale noise**: one main ridge structure, broad downhill valley corridors, and a small number of major outlet basins; then let D8 + priority flood find the drainage inside those basins. As an artistic option, place 1–3 major valley/trunk corridors in the terrain-generation stage and shape the terrain along them *before* deriving rivers. This is more controllable and often prettier than trying to force attractive rivers out of a random terrain after the fact.

For minor streams, maintain a hierarchy: headwater trickles or dry gullies, medium tributaries, main-stem rivers. Not every drainage branch should be rendered as a full-width blue channel from mountain top to sea. A channel may not even have permanent surface water until runoff exceeds a threshold.

## 3. Shorelines: the most obvious visual repair

### What is going wrong

At 2 km scale, a 384² vertex grid samples terrain every ~5.22 m. The carve fades back to raw terrain over **0.5 m**, less than one tenth of a cell. Triangles crossing that tiny transition cannot reproduce its shape. The screenshot shows exactly the kind of tooth-like artifacts this creates. Increasing the number of vertices *across the water ribbon* will not solve a bank generated from undersampled *terrain triangles*.

### First-choice implementation

Use **adaptive terrain tessellation around the river network**. Subdivide render-mesh patches that intersect a bank and a small surrounding valley radius, targeting roughly 0.5–1.5 m spacing at the near-shot 2 km physical scale; keep the original coarse mesh far away. Stitch LOD boundaries. For a 20 km physical map, scale your subdivision target based on actual rendered river widths, not a fixed factor of 4.

The river geometry and the carved terrain should share **one continuous centerline/width/elevation representation**:

- Replace nearest sampled-circle lookups with **closest point on a swept segment/capsule** and interpolate width, bed and water elevation along the segment. Keep spatial bucketing for performance.
- Make the *water edge* an explicit smooth curve, not a position inferred from the nearest coarse terrain vertex.
- Use a broad, smooth valley-incision profile beyond the actual channel, with separate controls for riverbed, bank slope, and natural floodplain/valley transition. A 0.5 m edge feather is too narrow.
- Avoid a uniform 1.15 m bank crest on both sides. Natural banks follow local terrain; low-gradient alluvial channels have subtle banks, mountain streams can have rock cuts, and artificial levees should appear only near settlements if the civilization builds them.
- Match river/ground vertices at the true shoreline or explicitly clip/subdivide triangles there. The water ribbon should not require 4 cm per-reach deck offsets to hide intersections.

**Pragmatic fallback:** If adaptive tessellation is too invasive, generate a continuous local *riverbed + banks terrain ribbon* that cleanly replaces or occludes the corresponding ground triangles. This can deliver a large screenshot improvement faster, but inspect overlaps on steep slopes and confluences.

### Confluence geometry

The water mesh currently disables confluence patches (`junctions = []`) and bank strips are trimmed near junctions. This is a predictable source of gaps, overlapping planes and acute triangular seams. Build a smooth local confluence polygon/patch for every real junction, merging all incoming bank edges and enforcing one water level at the common vertex. Blend tangents over a distance scaled to channel width rather than forcing straight reach ends. Test triangle quality, holes, overlaps and bank continuity separately from endpoint weld counts.

## 4. Centerlines and meanders

**Remove the giant smoothing stack as the default solution.** Four Chaikin passes + 16 Laplacian passes + 200 Laplacian passes + synthetic four-frequency sine noise + 30 more passes is a lot of geometry processing, much of which deliberately straightens away the valleys that routing discovered.

Instead:

1. Simplify the D8 polyline with a small, terrain-aware tolerance.
2. Fit a curvature-limited cubic spline **constrained to the original low-elevation corridor**; preserve important saddle crossings and junction nodes.
3. Fit the *entire trunk through junctions* or use coupled tangent constraints so reaches do not independently straighten the first/last 30 m.
4. Permit greater sinuosity on low-gradient, wide floodplains; limit offsets on steep hillsides, near gorges, buildings, and narrow valleys.
5. For floodplain rivers, optionally apply a few gentle curvature-driven migration steps (`bend displacement ~ curvature`, capped and damped); do not add a sinusoidal offset everywhere.
6. Verify the new curve never cuts through a ridge, overlaps its own banks, reverses the water gradient, or crosses an unrelated reach.

A stylized meander overlay is fine if your priority is an attractive screensaver rather than geomorphological accuracy. It needs to be **slope- and valley-aware**. Wide, low-gradient rivers should gently curve; steep mountain streams should mostly follow narrow gullies with occasional cascades, not identical oscillations.

Do **not** solve sharp bends by shrinking the water width to fit the curvature after the fact. Smooth/re-route the bend to satisfy a sensible radius relative to width.

## 5. Water elevation, confluences, and widths

### Water surface

Use the river graph as a **single 1-D network** with shared elevations at nodes. Compute a connected downstream-nonincreasing water surface, then interpolate smoothly along reaches. Derive elevations from the intended bed, minimum cover/depth, slope restrictions, and downstream/outlet boundary conditions; if constraints are inconsistent, reshape the *rendered bed/valley* or explicitly classify a lake/waterfall rather than conceal the problem with arbitrary 8- and 30-sample junction ramps. A full 2-D hydraulic simulation is disproportionate for a deterministic screensaver unless flooding is a gameplay mechanic.

For very steep sections, draw cascades/waterfalls as a separate visual class (foam, wet rock, segmented stepped flow) rather than representing the entire drop as one long flat ribbon.

### Widths

The current raw width `clamp(4 + 0.22*sqrt(flow), 8, 45)` is not tied to real contributing area in m² or climate. Also, `flow` from the early routing pass may not match the final graph. Tie visual widths to **final runoff/drainage area**, perhaps `width = w0 * (Q/Q0)^b` with `b` in roughly the 0.3–0.5 range as a stylized starting point, then clamp by channel class and available valley. Treat this as an artistic tuning law, not a universal hydrologic constant.

Use gradually tapered tiny headwaters, medium tributaries and main channels; preserve width increase at confluences without sudden jumps. A first-order river should not already resemble a canal.

## 6. Diagnostics and acceptance tests that matter

The current pass criteria are too weak for visual quality. `maxParallelChannels <= 14`, `minimum curvature radius >= 0.5 m`, and zero junction endpoint height step do not guarantee a convincing river network.

**Topology and hydrology tests (hard fail):**

- Every channel cell has zero or one downstream receiver; all paths terminate at an explicitly classified sea outlet, boundary outlet or lake; no cycles or unclassified dead ends.
- Topological area accumulation matches independent brute-force checks on small grids; area is conserved at confluences.
- Sources/junctions/outlets satisfy the forest identity **after** pruning. The 19-vs-46 count discrepancy is either resolved or explicitly explained by separate metric definitions.
- Connected source-to-mouth paths exist; no orphan channel segments, duplicate reach coverage, or dry gaps in the river mask.
- All centerline water-surface elevations are downstream-nonincreasing, including transitions across junctions; no visibly excessive artificial flats unless classified as lakes.
- Every channel segment connects to a valid downstream segment or an explicitly modeled terminal waterbody.

**Geometry tests (hard fail):**

- No land triangle crosses above the water inside the intended wet polygon at close camera distances.
- No open seams at junctions, zero-area triangles, inverted banks, self-intersecting swept edges, or UV discontinuities.
- All bridges actually span a continuous wetted polygon and land on dry, connected road endpoints.
- Bank curvature and centerline curvature are validated against local width, not only an absolute 0.5 m bound.

**Visual-quality metrics and review images:**

- Report basin count, sea outlets, river hierarchy, permanent-water length, water area fraction, branch-angle distribution, and median/maximum water-width-to-grid-cell ratio.
- Replace the “parallel runs <= 14” pass threshold with a more meaningful **nearby same-direction channel separation and unmerged length** diagnostic. Flag prolonged channels in the same local valley when they should converge.
- Render matching camera positions with: raw heightfield, accumulated area heatmap, final receiver/channel graph, water-only, bank-only, terrain wireframe, signed-distance field, and final shaded image.
- Generate a contact sheet of **at least 10–20 seeds** (mountain stream, town and main-stem views) and evaluate *before/after with identical camera, seed, and era*. Include automated topology results underneath. One successful headless seed cannot represent the distribution.
- Record stage timings (`flood`, `route`, `area`, `prune`, `spline`, `heightfield carving`, `tessellate`, `mesh`, `build field`) and actual memory allocation, not just a combined 0.5 s river-graph time.

**Target acceptance for the first rebuild:** clearly continuous confluences; no obvious black triangle sawteeth near water in close camera images; no inexplicable parallel canals through the same narrow valley; visible main stems with proportional, narrower tributaries; and no slope-climbing water surfaces or dead ends without real lakes.

## 7. Performance priorities

At 384² (~147k cells), priority flood, final D8 and linear topological accumulation are modest work for a seed-change-only scene build. A few bounded erosion passes and selective local tessellation are reasonable starting points. The much larger cost risk is generating too many river-bank triangles, recalculating nearest segments naively for every terrain vertex, and repeatedly smoothing long high-resolution polylines.

- Cache the final receiver map, accumulated runoff, river network and its bounding boxes per `(seed, terrainVersion, scaleVersion)`.
- Retain a bucketed/spatial-indexed representation of *segments*, not independent per-sample circles.
- Only subdivide terrain patches intersecting the narrow river/valley corridor, with LOD by camera distance if needed.
- Limit resampling to a resolution appropriate for visible geometry; use consistent deterministic float order and tie-breaks.
- Avoid solving a real-time 2-D fluid model. The world rebuilds on seed changes, not at 60 frames/s.

## 8. Timeline-specific opportunities beyond the six questions

**Rivers should drive civilization, not simply avoid buildings.** The brief says Simulation owns a D8 `river` mask while `RiverNetwork` generates its own render-only network, then CityBuilder clips features against the rendered field. Ideally, the *same* authoritative hydrology should inform where early towns grow, where farmland concentrates, which banks are accessible, and where roads/bridges must connect. If separate sim and render rivers are retained, establish an explicit consistency test.

Visually and historically:

- **Before settlement:** natural valleys, watercourse-adjacent vegetation, wetlands, floodplains, deltas or small coastal estuaries.
- **Medieval:** settlement naturally hugs water and bridges/ford crossings become transportation focal points; avoid grid streets simply terminating at a water stripe.
- **Industrial:** quays, mills, controlled riverfronts and occasional human-built levees/canals may appear. In fact, the current artificial-looking straight canals would make more sense **here**, not as the universal natural-water look.
- **Modern:** engineered banks, reservoirs and embankments can be an era-specific overlay without changing the river topology entirely. A few credible historical diversions are more convincing than universal straight waterways.
- Add a *visual class* per reach: alpine rivulet, canyon creek, alluvial stream, main river, delta branch, lake shore or engineered canal. Vary banks, flow shader, width and local vegetation by class. This will make the system look much less repetitive than one shader/mesh profile for all terrain.

## 9. Concrete implementation order for an engineering agent

### Patch 1 — correctness + diagnostics (no art changes yet)

Files likely impacted: `RiverNetwork.swift`, `Sources/Headless/main.swift`.

- Consolidate physical scale.
- Fix D8 axial/diagonal slope logic.
- Recompute final routing and area consistently and in true topological order.
- Replace source-only thinning with graph-edge pruning and recalculate counts.
- Verify cycle-free graph, source/junction identity, outlet classification, downstream water-surface heights and per-stage timings.
- Keep a golden image of the user-provided seed/camera and a multi-seed test pack.

### Patch 2 — visible geometry, highest immediate return

Files likely impacted: `WorldScene.swift`, `RiverNetwork.swift`.

- Replace circle-based nearest field with swept-segment SDF/proximity, keeping buckets.
- Add river-adjacent terrain tessellation or a clean replacement bank terrain strip.
- Widen and reshape valley erosion; remove the unconditional raised crest.
- Enable/rebuild watertight confluence geometry.
- Remove per-reach 4 cm water-deck lifts where geometry now joins properly.

### Patch 3 — believable landforms and rivers

Files likely impacted: `WorldGen.swift`, `RiverNetwork.swift`, `WorldScene.swift`.

- Add a deterministic macro-valley organization layer and bounded area/slope-based erosion on a routing/render copy.
- Replace heavy Laplacian + four-harmonic meander overlays with a valley-constrained, slope-aware curve fit.
- Implement distinct water/shore classes for tiny mountain tributaries, alluvial rivers, steep cascades and lakes.
- Keep settlements/roads aligned with the final network; migrate to a single worldgen hydrology authority if possible.

### Patch 4 — visual polish

Files likely impacted: `Shaders.metal`, `CityBuilder.swift`, `WorldScene.swift`.

- Tune transparency, depth color, reflection and foam only after terrain geometry is sound.
- Add subtle inside-bend bars, outside-bend erosion, wet soils, riverbank vegetation, small ripples/rapids, deltas and coherent bridges.
- Compare ten or more deterministic seeds and eras before declaring victory.

## 10. Direct answers to the brief's six questions

1. **Best cheap drainage model?** Priority-flood conditioning + final D8 receiver tree + true topological accumulation + a small bounded area/slope-driven incision loop. Avoid making D-infinity or graph contraction the first big rewrite.
2. **Few trunks without source thinning?** Give world generation plausible broad basins/valleys and outlet locations, recompute final area, extract hierarchical streams and prune complete tributaries by importance. An arbitrary smooth terrain cannot guarantee aesthetically pleasing major trunks.
3. **1-D or global 2-D water surface?** A *global connected 1-D network profile* for channel water height; 2-D polygons for lakes, estuaries and shoreline geometry. No full hydraulic solver needed.
4. **Shoreline remedy?** Adaptive river-adjacent terrain tessellation or a clean replacement carved-bank strip, using continuous swept-segment distance and explicit shoreline geometry. A stencil alone can hide some land-water overlaps but won't create plausible valley banks.
5. **Meander overlay?** Allowed for a stylized screensaver, but limit it to low-gradient valley segments, carry coherent tangents through confluences and constrain against the valley. Full bank migration is optional and not required initially.
6. **~0.5 s build?** Optimize for seed-change rendering, not per-frame hydrology. 384² is modest. Profile stage costs, cache results, make local tessellation adaptive and keep the water surface kinematic.

## Supporting references

- Landlab documentation: D8 flow accumulation and pit/depression routing: https://landlab.readthedocs.io/en/latest/tutorials/flow_direction_and_accumulation/the_FlowAccumulator.html
- Landlab example integrating D8 and Barnes lake mapping: https://landlab.readthedocs.io/en/latest/tutorials/terrain_analysis/drainage_density/drainage_density.html
- Barnes et al., 2014, Priority-Flood depression filling: https://rbarnes.org/sci/2014_barnes_depressions_published.pdf
- Stream-power law background and model: https://esurf.copernicus.org/articles/13/875/2025/index.html
- Howard & Knutson (1984), curvature-based river meandering: https://doi.org/10.1029/WR020i011p01659

---

**Bottom line:** Stop trying to make the *line* of water more sophisticated while the underlying terrain does not contain a coherent valley. Correct the topology, shape terrain to the river, give the shoreline enough triangles to exist, then tune meanders and shaders. That ordering should improve the screenshot more than another few hundred smoothing iterations or higher-resolution water textures.
