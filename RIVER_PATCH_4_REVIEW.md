# Evolving Timeline — Patch 4 River Review and Patch 5 Direction

**Review date:** 2026-11-10  
**Materials reviewed:** `RIVER_PATCH_4.md`, `patch4-debug-sheet.png`, `patch4-hero.png`, `patch4-town.png`, `patch4-island.png`  
**Scope:** visual / architectural review of supplied brief and renders; **not** a line-by-line audit of the Swift source.

## Verdict

**Keep Patch 4 as the visual baseline, but do not sign off on the river system yet.** Width hierarchy, lower bank crests, and reduced cliff cuts are real improvements. The remaining high-impact defects are (1) visibly artificial water junction geometry; (2) disconnected-looking mouths and headwaters; (3) headwater and mountain routing not sufficiently controlled by credible valleys; and (4) inconsistent water/terrain/civilization geometry at small scales. The confluence changes are especially revealing: the system replaced a square fan with a circle, but the *waterbody union* is still missing.

Do **not** use the next pass on water colors, foam, or randomizing more meanders. Fix topology and geometry first.

## 1. What genuinely improved

- Width function changed to `1.5 + 0.12 * sqrt(flow)` and 3–45 m clamping; reported seed-1 width is **3.0–21.6 m**, down from 8.0–40.8 m. The image looks less like an oversized canal network.
- Bank crest is now **0.35 m** nominal (reported mean lip **0.38 m**). This reduces the continuous raised-levee appearance compared with Patch 3.
- Reducing the 200 smoothing passes to 80 retains somewhat more terrain-scale curvature.
- Replacing terminal caps with pond water is an attempt to distinguish closed basins from abruptly terminated rivers. However, fixed-radius ponds are not adequate lake geometry (see below).
- The graph accounting from Patch 3 remains valid: 69 reaches, 24 source reaches, 9 outlets (4 mouths + 5 inland ends), 15 junction excess, 60 links. The graph identity test is useful, **but proves only bookkeeping**.

## 2. Visible regressions / remaining failures

### P0-A. Circular water overlays and unnatural confluences

**Image evidence:** In `patch4-town.png`, the main river in front of the medieval village shows two pale, lens-shaped patches on its surface. Behind the two red-roofed buildings, the tributary junction still has a conspicuously flared, almost squared-off head.

**Implementation clue:** The new junction is a **24-segment circular pool**, radius `1.05 × max(incident halfWidth)`, lifted **2 mm** above the ribbons, with centre depth-shading and zero-depth rim. That is a draw-order patch, not an integrated river surface. The disk's material gradient and 2-mm elevation can easily reveal its circular footprint. The screenshot is consistent with this explanation; verify by toggling or highlighting each pool independently.

**Fix:** Replace the inserted circle with a **single nonoverlapping water polygon** at each junction. Two workable approaches:

1. **Preferred:** Convert incident ribbon bank edges to 2-D polygons, locally union their X/Z footprints, extract outer shore boundary, triangulate the union, and assign continuous water elevation/depth/UV attributes. Use robust polygon clipping rather than inventing ad hoc branch-specific overlap cases. Rebuild bank strips around the union's *outer boundary*, not each incoming reach's end.
2. **Cheaper fallback:** Trim each ribbon back ~1–2 local widths and construct a watertight Y-shaped junction polygon from the ordered left/right cut-bank vertices. Triangulate once and blend attributes from adjacent reaches. Handle two-way and 3+-way joins explicitly, and reject self-intersecting boundary loops.

**Hard rule:** no overlaid discs or intersecting coplanar water meshes, no full-width abrupt rectangular steps, no separate circular material rings. At the actual source code level, disable the `2-mm` disc depth-test workaround rather than trying a different lift.

**Important:** A zero endpoint water-height step and `0` centreline self-intersections cannot detect duplicate water triangles, extraneous edges, shader-depth discontinuities or a weird shoreline silhouette.

### P0-B. Source, tarn and sea endings look artificial

**Image evidence:** `patch4-island.png` still shows a long, almost ruler-straight channel near the lower-left coastline with a blunt inland termination and an outlet that appears to stop at or just before the beach. Treat the sea gap as a **visual suspicion** until an ocean-mask debug overlay confirms whether water surfaces physically meet. Other short upland channels seem to emerge from arbitrary slope locations.

**Fixes:**
- **Coastal outlet:** follow the final flow path to the first sea cell; intersect the river footprint with the coastline and join the river's rendered water surface to the ocean surface with no visible beach-height gap. The coastal waterline and river surface must reconcile (possibly via a brief estuary profile). Special-case shoreline triangulation as needed.
- **Headwater:** only show perennial blue water above a specified drainage area / moisture threshold; below it render a narrow intermittent stream, rocky wash, vegetated hollow, or no water. Taper a true source smoothly over several local widths, and hide the terminus in an actual spring, pond or valley hollow, not a tube cap.
- **Endorheic basin:** don't draw an arbitrary `2.5 × halfWidth` circle at every end. Flood to a stable basin spill level and contour the surrounding heightfield to obtain a lake/tarn polygon; or omit permanent standing water for tiny dry depressions. A flooded basin should have a consistent rim and plausible depth.

### P0-C. 3 m channels cannot be trusted on a 5.2 m cached carving grid

**Implementation clue:** The original terrain is 384×384 over 2 km: spacing ~**5.22 m**; the scene stores a carved copy at that resolution, while the draw mesh is `detail:2` (~**2.61 m** vertices). The new minimum full channel width is **3 m**. If detail-2 vertices only interpolate the already carved 384-grid copy, they do **not** sample an accurate 3 m incision. The ribbon may be smooth while the terrain cross-section is under-resolved or missed entirely.

**Fix:** Make one authoritative continuously sampled `renderHeight(x,z)` from original height interpolation and the *continuous river-distance field*. Evaluate it at every detailed terrain vertex (or create higher-resolution tiles around channels) and use the **same** surface for normals and object placement. Don't carve only the 384-grid then expect an interpolated 768-grid to recover a narrow cut.

For source widths 3–6 m, validate cross-sections at different subcell offsets and orientations. Make sure the terrain never protrudes through water or forms asymmetrical pinches because the centreline happens to pass between coarse height samples. Preserve a canonical simulation terrain if needed, but keep scene collision and rendering on the same sampled surface.

### P1-D. Drainage network still looks painted onto mountains

**Image evidence:** The middle mountain has a long nearly straight down-slope stream with awkward heading changes. Elsewhere the steep channels don't appear to originate from an actual network of erosional hollows. Island-scale view still has sparse, oversized-looking blue lines on steep slopes.

**Fix sequencing:** After topology and local geometry, replace route-only incision with a drainage/erosion loop that actually shapes the **base rendered terrain** (while maintaining a stable simulation contract). Precondition drainage with priority-flood; compute area on final directed receivers; use slope- and area-dependent incision constrained by local valley profiles. Differentiate:
- steep headwater: narrow, valley-following, limited meander, sometimes intermittent;
- foothill: moderately winding, narrow floodplain, tributary joins;
- lowland trunk: wider and slower with variable bends and broader floodplains.

Don't force sine-wave meanders in mountains. The shape of the existing valley is more important than adding noise.

### P1-E. Rivers still wear a mechanically uniform bank profile

Lowering the crest helped a lot, but the same wet-shelf and slope-limited carve is applied regardless of hydrologic class. A 4 m shelf adjacent to a 3 m-wide brook is proportionally enormous; the visible pale fringe can still resemble a highway shoulder.

**Fix:** Scale margin/shelf width by local channel width, slope, valley curvature, and sediment/soil type; use asymmetric inside/outside bends and very low-amplitude natural texture. Where the surrounding terrain already gently approaches the water, create **no positive bank crest**. Avoid adding decorative material rings at junctions. Keep strong banks only where an actual undercut or bluff is justified.

### P1-F. Road, bridge and field defects are now very visible

**Image evidence:** Long narrow road/street meshes bridge the larger rivers without obvious supports or suitable bridge geometry; roads appear to run beyond the crossing as thin strips. Several agricultural field plates float or cut into slopes. Town paving has sharp slab edges above terrain/water in places.

The brief explicitly acknowledges the field-plate issue. Do **not** bury this inside river debugging; track it as a separate **scene placement / infrastructure** defect. In near-term fixes, any road-water intersection must create a bona fide bridge deck with supports/approaches or stop. Build fields as terrain-conforming meshes (grid subdivided and individually draped), or place farms only on sufficiently flat ground.

## 3. More serious architecture question: there are still two river worlds

The brief says the simulation keeps its canonical `terrain.river` and `terrain.flow`, while a separate render-only drainage graph computes water and valleys. That risks a mismatch between **where civilization expects a river** and **where one actually appears**. The scene's carved copy helps props sit on ground, but it doesn't necessarily reconcile strategic siting, agriculture, transport, and long-term settlement development.

**Recommendation:** Make deterministic `RiverNetwork(seed, baseTerrain)` shared data: stable centreline graph, water footprints, catchment, river classes, mouths/ponds. Simulation consumes network semantics without mutating its canonical elevation; renderer produces detailed carved geometry. The same river source of truth should be reused across years, particularly because this is a historic progression screensaver. Treat this as a later architecture pass after the P0 geometry defects.

## 4. Why current diagnostics can all pass on a bad render

The current checks establish graph identity, downhill water elevation, welded endpoints, no centreline crossings, and no exposed bed probes. They don't establish:

- Whether two water triangles overlap, cause rings, or produce a discontinuity in depth coloration.
- Whether banks merge as one natural Y shoreline instead of a patchwork of circular caps.
- Whether a coastal mouth actually touches ocean geometry.
- Whether a nominal 3 m stream is present in the **carved terrain** at all grid offsets.
- Whether its basin is credible given river width, catchment area, and slope.
- Whether bridges and civic paving occupy the water footprint illegally.
- Whether a screenshot at normal screen distance looks natural.

Add gates for **connected waterbody polygons**, **overlapping water triangle area**, **water-to-sea distance at each mouth**, **centerline-vs-terrain carve alignment at random subcell locations**, **shore-boundary validity**, **road-water crossing coverage**, and **real river-class/width distribution**. Pair those with mandatory visual review; no automatic metric alone proves realism.

## 5. Patch 5 implementation order

**Phase A — Fix water junction geometry (non-negotiable).**

1. Add `EVOLVING_RIVER_JUNCTION_IDS=1`, `EVOLVING_RIVER_WIREFRAME=1`, and a `junctionPoolOnly` toggle to isolate the problematic shapes. Produce crops of the main river's two visible lens-shaped artifacts and the tributary behind red-roofed houses.
2. Remove the extra elevated round-pool mesh. Generate a single waterbody surface across each junction using local footprint union / Y-polygon method.
3. Compute coherent water elevation, edge-depth blend, and UV/tangent across junctions. Derive bank outer shore from the final water footprint.
4. Assert no overlapping coplanar water triangles / holes / invalid polygon topology and no visual rings.

**Phase B — Fix endpoints and narrow-stream carve.**

5. Produce a debug overlay of each outlet tagged `ocean`, `lake`, `sink`, or `headwater` and draw the sea mask. For each coastal outlet, demonstrate actual water-mesh contact.
6. Replace constant-radius terminal pond disks with flooded-basin polygons, or suppress dry closed basins.
7. Evaluate carve height directly on detail-2 geometry or in a sufficiently fine local tile. Run 3–6 m cross-section probes at multiple subcell offsets.

**Phase C — Drainage realism.**

8. Limit permanent visible water based on catchment and slope; preserve small gullies without making them blue rivers.
9. Shape the terrain with erosion-informed valley paths, then regenerate/reconcile routing if necessary. Keep networks deterministic.
10. Vary channel classes and bank profiles; don't use universal sine meanders or identical 4 m shelves.

**Phase D — Related scene cleanup (separate task).**

11. Repair bridges/road clipping and terrain-conforming crop fields. These are obvious in the town views but should not block completion of water geometry fixes.

## 6. Required Patch 5 evidence / acceptance criteria

Provide **same seed, same year, same camera** comparisons to Patch 4; changing the view hides regressions.

1. `patch5-town.png` at exactly the Patch 4 town camera, plus a close zoom on the former tributary plug. **No floating circular shading discs, no square/flared pool at Y junction.**
2. `patch5-hero.png` and debug sheet at the Patch 4 camera. Include **water only, terrain only, banks hidden, junction IDs and wireframe**, not just magenta water.
3. `patch5-island.png` at the same island camera with all mouth/headwater/outlet types labeled. Show at least one second seed with the previous worst parallel-channel case.
4. Cross-section plot or diagnostics for a **3 m, 5 m, 10 m, and 20 m** channel at multiple grid alignments. No protruding terrain/water voids; same height function for render and collision.
5. Water surface geometry: zero non-manifold junction edges, no unintended duplicate triangles or visible rings, valid closed outer shore for each waterbody.
6. Explicit coastal connectivity: every marked ocean mouth contacts the ocean waterbody/mask within the chosen tolerance, not merely 'downstream linked' in the graph.
7. Retain graph identities and determinism across all 11 seeds; report build time and separate median/p95 frame time with consistent benchmark conditions. Patch 4 reported 17.92 ms/frame vs Patch 3's 11.63 ms/frame, but the author notes machine load variability, so **do not infer a definite regression** without a controlled rerun.

## 7. Important scale decision

The brief still says **1 world unit = 1,000 m; island width ~2 km**, while an older comment says 20 km. Choose one value, assert it in diagnostics, and make every width/depth/shelf/valley threshold use it. At 2 km width, an 8–22 m perennial trunk may be visually oversized for many tiny basins; derive it from the desired stylized biome and climate rather than a magic square-root coefficient alone. At 20 km, the entire terrain LOD and minimum river width must be revisited. Stop carrying both interpretations.

## Final direction to coding agent

> **Stop solving river junctions with decorative circles.** The next pass must create a true joined water footprint with coherent shorelines, test river/ocean contact, and resolve 3 m channels against the actual carved terrain. Keep the narrower channels and lower banks from Patch 4. Do not spend Patch 5 on shaders, foam, or extra meander noise. Return fixed-camera before/after images and geometry diagnostics, not only PASS gates.
