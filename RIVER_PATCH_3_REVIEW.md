# Evolving Timeline — Patch 3 River Review & Patch 4 Directive

**Review basis:** `RIVER_PATCH_3.md` and four supplied PNGs (`patch3-debug-sheet.png`, `patch3-hero.png`, `patch3-island.png`, `patch3-town.png`). **Scope limitation:** No Swift source files were supplied in this turn. Items marked *suspected* should be validated against actual code or diagnostic renders, not treated as proven implementation bugs.

## Executive verdict

Patch 3 is a real improvement over the previous river trenches: steep, synthetic green canyon walls are reduced, the water cuts into the rendered terrain, the placement systems consume the carved scene copy, and the reach graph's bookkeeping is now internally consistent. The debugging sheet is useful and verifies visually that the carved ground exists with water and decorative banks hidden.

**Do not sign off on visual realism.** The whole-island image still shows ruler-straight mountain streams, abrupt blue endpoints and angular joining geometry. The medieval town image contains an especially conspicuous *square blue junction/plug* behind the red-roof houses. Rendering appears watertight in some places but still visually unnatural. The main remaining limitation is not the shader; it's network location/scale and the mapping from river ribbons to the surrounding terrain.

## What was actually fixed (retain)

- Scene uses a carved terrain copy for scene placement, while the simulation retains canonical terrain.
- Slope-limited valley carving replaced 4 m cliff-like transitions.
- Per-reach arbitrary deck lifts removed.
- Reach forest has the expected identities: 69 reaches, 60 links, 9 outlets, 24 source leaves, 15 junction excess. `69 - 60 = 9`, `24 = 9 + 15`. This resolves the old confusing source metric; do not regress it.
- Diagnostics include water elevation, welded endpoints, determinism and visual toggles.

## P0 — Reject square confluences and blunt water endpoints

**Evidence:** `patch3-town.png`, just uphill of the two red-roofed half-timbered houses, shows a short side stream entering a larger channel via what looks like a squared, upstanding blue polygon. The whole-island view shows other right-angle/kinked joins.

**Likely locus to inspect:** Junction polygon generation currently deduplicates incident endpoints, angle-sorts around the grid junction centre, then triangulates a centre-fan at a shared water height. This guarantees shared elevation but not a good 2D water footprint, a simple non-self-intersecting ring, sensible shoreline tangents, or consistent geometry at abrupt branch angles. Bank strips may also overlap/terminate unevenly. It is not yet proven whether the rectangle is the junction fan, a channel cap, a bank/water exposure, or a height mismatch in neighboring mesh parts. Use targeted debug views to distinguish these.

**Next implementation:**

1. Add a **junction-only debug mode** with separate tints for upstream ribbons, downstream ribbon, fan, bank strips and carved terrain; show top-down wireframe triangles and junction IDs.
2. Construct a **true 2D union of the swept ribbon footprints** in a local area around each confluence. Use polygon boolean union (then triangulate the resulting possibly concave shape) or a signed-distance field + marching squares + triangulation. Do not assume that polar-sorting endpoint vertices around a common centre produces a valid shoreline polygon. Use a union that merges the water areas smoothly rather than filling a large arbitrary centre fan.
3. Smooth the **boundary** of each join with local tangent continuity, preserving the actual watershed centerline and original channel widths. Run bank construction against the final union boundary, not against separately trimmed reach ends.
4. Reject degeneracy: no positive-area overlaps, holes, T-junctions, winding inversions, triangles with near-zero area, or above-water vertical faces except deliberate waterfall faces.
5. Validate the exact medieval-town camera after the change: the square blue block must be gone, with the two channel edges joining continuously.

**Acceptance:** Show a close top-down *and* oblique crop of at least 10 confluences from multiple seeds, with separate wireframe and natural-shader renders. Both the water footprint and the bank/terrain footprint should be continuous.

## P0 — Finish source, terminal, and coast semantics

**Evidence:** `patch3-island.png` contains a conspicuous isolated reach in the lower-left coastal region with an abrupt inland end; several other short blue headwaters/branches appear to start or stop at full width. The apparent coastal join should be checked numerically (camera/projection may hide overlap).

**Changes:**

- Define four distinct endpoint categories: `headwater`, `confluence`, `coastalMouth`, `closedBasinLake` (plus *intentional manmade terminus* when appropriate in later eras).
- **Headwaters** taper from narrow/subvisual flow, not an 8 m-wide flat cap. Very small streams can be terrain grooves or dry/wet seasonal beds rather than full opaque water ribbons.
- **Coastal mouths:** require the final wet polygon to intersect the sea surface continuously at compatible surface elevations; terrain carve must open a sea connection. Include coast/river union checks, not just proximity of centreline samples.
- **Closed basins:** generate a proper small lake/tarn polygon at a reasonable spill/fill elevation, or stop drawing the incoming river if the basin is too small to resolve. A rounded cap is not a lake. The report shows **five** inland terminations among nine outlets, so this is not negligible.
- Reject free-floating/interior blue blobs, straight cut-off terminals, and unknown endpoint classifications.

**Acceptance:** Annotated island screenshot with every 1 of the 24 graph source leaves and 9 outlets marked by type. For each outlet: show actual water contact with sea or a lake polygon; for each headwater: demonstrate width reduction before it ends.

## P0 — Settle world scale and hydrology-width calibration

The earlier and updated briefs disagree on whether two world units correspond to ~2 km or ~20 km. Patch 3 gives river width 8.0–40.8 m. Without one shared scale, the visual plausibility and channel-generation thresholds are impossible to calibrate meaningfully.

- At **2 km across**, the 384² grid is ~5.2 m/cell and an accumulation threshold of 1,200 cells corresponds to only ~0.033 km² of drainage area before masking/edge effects. An 8 m minimum full-water width is then implausibly large for many sources.
- At **20 km across**, the grid would be ~52 m/cell. A `detail: 2` render would be ~26 m spacing, not the claimed 2.6 m, so narrow river cross-sections would be radically undersampled.

**Changes:** Define one `worldMetresPerUnit` in a shared unit system. Every terrain distance, river width/length, mesh step, threshold, bank width, settlement footprint and diagnostics should derive from it. Print physical world span, effective cell spacing, area threshold, and width distribution in `civheadless`.

**Width model:** Use contributing **area** plus slope/rainfall or proxy discharge to derive width; apply a much smaller starting width for mountain headwaters and permit dry streams. Widen smoothly downstream, not simply with distance from a source. Expose a visual override to compare plausible width bands; don't just lower every width by a constant percentage.

**Acceptance:** Whole-island view has a readable hierarchy: many faint/narrow tributaries, a few medium streams, and one or two dominant trunk rivers. Every wide reach should have an appropriately broad upstream drainage area.

## P1 — Stop using one centreline style for every river

**Evidence:** The central mountain's channel appears as a near ruler-straight blue line with a few hard changes of course, while the lowland main stems are also relatively straight/parallel. Patch 3 says the old smoothing and sinusoidal overlay remain in place.

- Remove or radically reduce the `200` Laplacian smoothing passes; that process can erase the very gully-scale detail the drainage model generates.
- Build distinct classes based on slope, stream order, contributing area and local valley confinement:
  - **Mountain/headwater:** narrow, valley-confined, irregular, sometimes stepped; little broad meandering; optionally rapids where grade demands.
  - **Foothill:** moderate sinuosity, following terrain drainage lines and valley bottoms.
  - **Lowland:** broad alluvial valleys, stronger but *nonperiodic* meanders, gradual bank transitions, wider floodplains.
- Do not sinusoidally displace a path outside its viable valley corridor. Consider channel displacement only where local slope/valley width permits it.
- Avoid making the mountain water a continuous dark-blue ribbon painted over slopes. If the gradient is very high, use a bedrock stream/rapids representation, or exclude that reach from full-width open water.

**Acceptance:** Three cropped examples of mountain, foothill, and lowland reaches with distinctly different geometry, not just different widths or shader colors.

## P1 — Coordinate rendered valley geometry with actual drainage routing

The report explicitly acknowledges that the flow-routing heightfield and the displayed carved heightfield are separate. Visual terrain can therefore be made to support a route *after* the path is picked, even where that route would not naturally be supported by the visible landform.

Use either a controlled route–incise–reroute preprocessing loop on a working terrain, or an explicit pre-generated drainage/valley corridor integrated into the base terrain generation. Keep deterministic simulation behavior unchanged by treating this as a reproducible derived world surface. Revalidate that river paths run within their catchments and down actual low ground on the final displayed terrain—not just monotone water line arrays.

Add an elevation cross-section overlay: raw terrain, routed terrain, carved terrain, bed, water surface, and maximum cut depth along each river. Flag reaches that require implausibly deep/large-scale carving to exist.

## P1 — Fix the bank/lip and carving edge cases

The current ground function inside the channel returns a fixed `water - 0.45 m`, while outside the water it returns `min(originalHeight, allowedSlopeHeight)`. Inspect the case where original terrain is **already below** `water - 0.45 m` inside the channel: this branch can *raise* the bed rather than carve it. If uplift is not intended, the interior should respect the original lower surface (e.g., a `min`), with a well-defined bed-depth target from actual flow.

The imposed 0.55 rise is a local distance-to-water ceiling; it does not by itself guarantee smooth curvature, naturally asymmetrical banks, or visual hydrologic validity. Across two nearby branches, switching which channel is "nearest" can introduce abrupt field transitions if the referenced surface heights differ. Inspect the terrain field under adjacent channels and their confluences for this issue.

- Remove the mandatory positive crest from natural streams. Use a natural terrain bank, optionally with locally asymmetric cut bank/point bar where slope/curvature allow. Reserve raised levees for explicit later-era human infrastructure.
- Vary soil/grass/rock transition across the bank instead of a near-constant pale margin.
- Check **where** the carve is sampled: if only 384×384 `carved.height` is generated and the 2× render mesh merely interpolates it, the higher vertex count does not add new river-boundary detail. Evaluate the high-resolution channel field at render vertices or use adaptive near-river refinement.

## P2 — Stop equating numerical PASS with visual PASS

The current gates validate internal mechanics well, but do not address things visible in these screenshots. Add automatic reproducible image captures and geometry tests:

| Gate | What it must detect |
|---|---|
| Coastal continuity | Wet channel intersects sea; no beach gap or dead-end coast polygon |
| Source taper | Every natural headwater narrows before its first visible segment |
| Junction union | Simple valid union footprint, no overlapping/degenerate triangles, no rectangular fill extrusion |
| Width hierarchy | Width trend by stream order/area and physically meaningful units |
| Slope class | Steep-gradient reaches are not broad lowland-looking dark ribbons |
| Valley plausibility | Max incision depth/volume and lateral carve radius per reach |
| Bank profile | No artificial continuous positive berm except era-specific human construction |
| Field transition | No discontinuities caused by switching nearest reach/capsule |
| Road and bridge contact | Bridges connect to usable road ends, deck clears water; no road clipped mid-span |
| Deterministic screenshots | Same seed and era always produce identical river footprints |

Capture a standard panel for seed 1 at **year 2336 and year 3506**, plus at least three different topologies/seeds. Include three cameras: whole-island, 45-degree junction detail, and ground-level riverbank detail. A single nice hero screenshot should never count as proof.

## Separate visual defect (non-river work)

The farm fields in the hero and town images are conspicuous thick, flat rectangular platforms. The patch notes explicitly say the attempted lowering created triangles and was reverted. Fix in a separate geometry task: construct a terrain-following quad/triangulated field footprint with a tiny offset, or generate a graded/terraced farm plot with proper retaining edges where appropriate. Do not alter river geometry merely to hide farm-field floating.

## Patch 4 implementation sequence

1. **Instrument and reproduce** the square town join, the left-coast terminal, and a central mountain stream with IDs + local wireframe/cross-section screenshots.
2. **Fix confluence footprint union and cap types**; remove blue plugs, self-overlaps and blunt stubs before other work.
3. **Unify physical scale** and recalibrate flow-area threshold and headwater widths.
4. **Implement terrain/slope-dependent river classes** and reduce destructive smoothing.
5. **Integrate routing and visible valleys**; remove continuous artificial bank crests.
6. **Expand gates + standard image panel**; only then consider water shader/foam/rapids aesthetic enhancements.

## Hand-off instruction (copy directly to coding agent)

> Treat Patch 3 as an improvement but not complete. Do not work on shader/foam effects yet. Start by reproducing the square blue join in `patch3-town.png`, the isolated coastal reach in `patch3-island.png`, and the ruler-straight mountain channel. Diagnose each with per-branch wireframe and IDs before changing code. Fix physically meaningful source/outlet categories and replace the angle-sorted confluence centre-fan with valid union geometry. Resolve the 2-km/20-km unit contradiction before retuning widths. Render side-by-side comparisons for the same seeds, years and cameras with no debug overlays. Keep the existing graph identities, determinism and scene-placement fixes. Report actual code changes and performance delta, and flag any unverified visual issue honestly.

**Reviewer caveat:** The supplied report is a design/implementation summary, not the complete Swift source. Claims about code branches above are based on the pseudocode in that report. The exact origin of the square blue shape still needs direct debugging.
