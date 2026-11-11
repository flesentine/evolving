# Evolving Timeline — Patch 5 Review and Patch 6 Engineering Handoff

**Review date:** 2026-11-10  
**Basis:** `RIVER_PATCH_5.md` and `patch5-hero.png`, `patch5-town.png`, `patch5-island.png`, `patch5-debug-sheet.png`, `river-aerial.png`. The underlying Swift source was not provided, so implementation-level causes below are hypotheses to verify in `RiverNetwork.swift` / `WorldScene.swift`, not confirmed source-code bugs.

## Executive decision

**Conditional acceptance of the narrower rivers and bank/valley work; reject the current junction rendering as final.** Patch 5 removes the visibly circular confluence pool from Patch 4, and the main river looks reasonably smooth from the hero camera. But the overhead views expose new/highly visible artifacts: long land wedges inside junctions, rectangular water spurs, and abrupt changes in water width. **Patch 6 should be a narrowly scoped water-footprint/terrain-boundary correctness pass, not another round of rendering tricks.** Keep the current routing, widths, and valley profile as baselines until the joins are watertight and visually correct.

## 1. What demonstrably improved

- **No more pale oval confluence disks.** In `patch5-hero.png` and `patch5-town.png`, the obvious overlaid circle artifacts from Patch 4 are gone.
- **A much better hierarchy:** reported nominal widths are 3.0–21.6 m, not the original 8–40.8 m; large lowland rivers and narrower secondary streams are distinguishable.
- **More subdued banks:** the 0.35 m bank-height parameter and slope-limited carving read better than the early raised levees.
- **Sound graph-accounting diagnostics:** 69 reaches, 60 links, 24 leaves, 9 outlets, 15 junction excess are mutually consistent for the final directed forest.
- **Useful narrow-stream implementation disclosure:** the render terrain samples the continuous field at approximately 2.6 m intervals, while the 384² placement copy has approximately 5.22 m spacing. These are distinct; the latter can miss narrow streams.
- **Performance reported:** ~12.38 ms/frame at 6K in this run, but not enough repeated, controlled measurements to declare a hard budget margin.

## 2. Reproducible visual defects (prioritized)

### P0 — Junction land spikes and rectangular spurs

**Location A: `river-aerial.png`, upper central junction, approximately image x=650–860, y=65–245.** Two lengthy, nearly parallel beige triangular banks protrude into what ought to be one continuous join. A narrow, straight-sided, dead-end-looking blue tongue hangs toward the town. It resembles an excavated rectangular slot rather than a waterway. Inspect the same spot in `patch5-town.png`, upper-right area near the branch behind the red-roofed houses; a triangular beige wedge covers or bites into the blue meeting point.

**Location B: `river-aerial.png`, lower-left corner, approximately x=0–160, y=730–850.** A narrow channel suddenly swells into a polygonal plug. A sharp beige wedge intrudes into the water and blue edges meet at kinked segments. This is the strongest evidence that the problem is not only the decorative bank strip; the *water footprint itself* or its alignment with carved ground needs verification.

**Likely classes of cause — investigate, do not assume:**

1. The fan boundary is wrong: all five vertices of each cut cross-section are sorted globally by polar angle. Cross-section interior vertices are not automatically a correctly ordered *external union boundary*. Sorting can interleave arms or produce sliver/overlapping triangles.
2. The assertion that every Y union is star-shaped about the original junction cell is not generally valid for curved approaches, close parallel reaches, asymmetric widths or offset cuts. Even a star-shaped footprint does not mean angular sorting arbitrary interior samples recovers its perimeter.
3. The swept river footprint, junction fan, terrain carving field, and bank-strip footprint may not coincide. A mathematically closed water mesh can still be intersected or visually occluded by land mesh or bank strips. The reported 1.0R versus 1.05R bank/water trim difference is a real mismatch but is unlikely by itself to explain the large spikes seen here.
4. Separate reach ribbons might overlap or terminate at inconsistent positions, or local fan elevation may be under carved terrain at intermediate points. Endpoint height equality is insufficient to prove intermediate triangle visibility.

**Instruction:** DO NOT fix this by another junction disc, a small height offset, extra mesh subdivisions, or more aggressive blending. Make the topological footprint correct first.

### P0 — Inadequate debug coverage of the failing view

The current `patch5-debug-sheet.png` shows four passes of the **hero camera**, where the bad joins are small and partly hidden. Build a second debug sheet from the actual `river-aerial.png` camera with: (a) normal, (b) water-only magenta + triangle wireframe and reach/junction IDs, (c) carved terrain only with bank strips hidden, (d) bank strips only over neutral terrain. Take a third view tightly zoomed to the lower-left polygonal defect. The debug output should show bank geometry separately from terrain; `HIDE_BANKS=1` by itself cannot isolate which of water, terrain, or bank geometry intrudes.

### P1 — Coastal and spring endpoint semantics

`patch5-island.png` still shows the isolated lower-left reach: one end reads blunt, and the outlet appears close to the coastline but cannot be confirmed as physically merging with sea water from this image. Patch 5 itself acknowledges no geometric ocean-contact test. Classify each rendered terminal reach as `coastal mouth`, `closed basin lake`, `inland spring/source`, or an intentional dry/intermittent reach. Do not treat them with one common cap. A small `2.5R` disc is not inherently a realistic endorheic lake. Verify coastal *footprint adjacency* and no beach-colored gap, with both height and mask checks.

### P1 — Width truth and narrow-channel sampling

Patch 5 reports width minimum **3 m**, but also says the rendered `minChannel` is **4 m**. Distinguish nominal river width, ribbon width, field half-width, carved bank width, and collision exclusion width in diagnostics. Test at subcell offsets rather than assuming a 2.6 m vertex grid captures every 3–4 m creek. A 4 m ribbon spans only ~1.5 render-grid cell spacings; tiny streams can disappear or look lopsided depending on alignment. Keep a continuous field evaluated per render vertex, but add localized high-resolution tessellation/mesh or dedicated creek ribbons as needed, not global further mesh upscaling.

### P2 — Aesthetic / geological consistency

`patch5-island.png` still includes several very straight mountain reaches and isolated tributaries, and multiple near-parallel lines. The system needs terrain-informed drainage corridors and river classes (steep creek / foothill / floodplain). That is the next *design* pass, not a substitute for fixing the present geometry. With the active 2 km world scale chosen in Patch 5, a 21.6 m trunk is plausible as a stylized choice but should not be mistaken for a hydrologically derived discharge width. The chosen 2 km scale **is now a declared decision**; do not reopen the old 2 vs 20 km ambiguity without a product reason.

### Separate scene workstream — bridges and farmland

`patch5-town.png` shows long, thin road/bridge strips spanning water without convincing supports; agricultural plots remain visibly flat plates. Treat these separately from river geometry to avoid regressing river rendering while fixing unrelated assets.

## 3. Technical recommendation: use one canonical 2-D wet footprint

Preferred robust approach for Patch 6:

1. **Build continuous swept channel polygons.** For every river reach, construct an oriented strip from continuous/sampled left and right water-bank curves, including variable widths. Generate polygons in world XZ. Check individual strips for local foldovers/self-intersections before unioning.
2. **Form a union at every connected junction** with robust 2-D polygon clipping (or, as a practical no-library fallback, compute a fine *local* signed-distance mask only around the junction and contour it using marching squares). Clipping should return actual exterior boundaries and any holes; never recover a perimeter by angularly sorting all five cut-row vertices.
3. **Triangulate the resulting footprint** using a concave-safe triangulator such as an ear-clipping/earcut-style method or constrained triangulation. For a local raster contour, maintain suitable sample scale (e.g., ~0.25–0.5 m within only a small junction AABB) and remove contour noise. Reuse the existing five-across water ribbon outside the local junction patch for efficiency.
4. **Join topology explicitly.** Match each incident trimmed ribbon's cross-section to the local patch boundary. Any interior cross-section vertices belong to *the cap seam*, not arbitrarily to the external union perimeter. Stitch rows with shared positions and compatible indices, maintaining water elevation from the connected 1-D profile.
5. **Use that same footprint for river field, terrain carving, bank termination and placement.** A field generated from capsules may be a fast approximation away from junctions, but at junctions the field should sample the unified polygon/distance field, including where water intersects the bank. Otherwise land can project into a technically valid water mesh.
6. **Resolve elevation and material consistently.** The incident reaches meet at the same `waterY` at the junction; interpolate gently along the water patch, respecting downhill direction. Do not force every vertex to a common height if it causes an upstream surface rise or creates a visible flat puddle.
7. **Ensure rendered coastal mouths share coverage with the sea.** Detect intersection with the actual ocean water footprint and blend/clip correctly; don't simply extend a blue ribbon across dry beach or raise it to disguise a gap.

**Cheaper fallback if polygon clipping is too much work now:** Limit the junction patch to a small local footprint; rasterize the union of incident strips into a local, high-resolution mask, extract the outer contour, triangulate it, and compute one signed-distance field shared by bank and carving geometry. Run this only around real graph junctions, not across the island. This should remain computationally manageable with approximately 15 junctions in the demonstrated seed.

## 4. Diagnostics that are missing

Existing metrics (`waterline welds 3158/3158`, `self-intersections 0`, `junction water step 0`) do **not** validate the new fan polygons. Add the following tests, computed from the **rendered final mesh**, not only the river graph:

| Test | Acceptance criterion |
|---|---|
| Junction boundary topology | Perimeter loop is simple and consistently oriented; no crossed edges; holes handled explicitly. |
| Triangle integrity | Zero zero-area triangles beyond epsilon, zero inverted winding relative to normal, no triangles extending outside the intended wet union. |
| Seam closure | Each shared ribbon-to-junction boundary segment uses matching vertices and water heights within epsilon; no T-junctions/cracks. |
| Water footprint vs field | Dense XZ probes inside a local junction AABB agree about wet/dry status, with only a small tolerance band at boundary. |
| Terrain clearance | At points under every wet triangle, the rendered terrain is below the water by a required clearance, not only at original ribbon probes. |
| Bank exclusion | Bank meshes have no above-water triangles that penetrate the union wet footprint (except intentional tiny, submerged joining skirts). |
| Endpoint-to-sea continuity | Every `coastal mouth` polygon touches/intersects the ocean footprint at its boundary and matches required level tolerance. |
| Width truth | Log nominal vs rendered ribbon vs field/carve widths at sources, joins and mouths, including 3–6 m cases. |
| Seed variation | 11 current seeds + at least several adversarial junction fixtures: acute Y, near-parallel branches, very unequal widths, 3+ incident arms, S-curve entering a junction. |
| Visual snapshots | Same camera and year before/after, plus overhead defect closeups in normal, water-wireframe, banks-only, carved-terrain-only, field-outline views. |

Maintain deterministic output for the same seed and year. Report scene-build duration separately from the 6K **per-frame** benchmark; the two budgets are not interchangeable. Compare frame times using multiple runs and similar machine load.

## 5. Concrete patch order

### Patch 6A — Diagnose and repair geometry (release blocker)

- Add junction ID, ribbon wireframe, bank-only, and signed-distance footprint-outline visualizations.
- Capture overhead debug shots at the two image locations in `river-aerial.png` above, using identical seed/year/camera.
- Reproduce a minimal 3-arm example in an isolated geometry test and document its input XZ/widths.
- Replace global polar sorting of all cut-row vertices with a valid boundary union and safe triangulation. Align river and bank cut distances.
- Make the shared wet footprint authoritative for terrain carving and bank clipping near junctions.
- Add topology, triangle, terrain-clearance and field-footprint gates.

### Patch 6B — Endpoints and narrow streams

- Validate every coast-bound outlet against the rendered ocean footprint, especially the lower-left island reach.
- Ensure headwaters taper as actual wet geometry and blend into ravines; eliminate blunt or polygonal capped stubs.
- Put experimental lake polygons behind a flag until level/basin tests pass; do not create circles as the only definition of a lake.
- Add detailed 3, 4 and 6 m channel tests at quarter-cell offsets and diagonal orientations.

### Patch 6C — Landscape plausibility (after 6A/6B pass)

- Differentiate mountain creeks, foothill streams and lowland rivers by grade and valley constraint.
- Review overly straight high-elevation streams and unnecessary parallel rills from a whole-island overhead view.
- Keep edits deterministic and avoid adding meander where terrain slope is high.
- Only then revisit water material/foam/rapids.

## 6. Required handoff artifacts from the coding agent

1. Updated implementation brief describing the source-of-truth wet polygon and how carving/banks/placement consume it; note any remaining mismatch explicitly.
2. Before-and-after **aerial** images at the two defective junctions in `river-aerial.png`, not only the hero shot.
3. A zoomed wireframe + IDs view and separate bank-only view of each defect.
4. One table of new polygon/mesh/wet-footprint gates across 11 seeds, including worst-case results.
5. Explicit evidence for ocean adjacency and narrow-channel subcell tests.
6. Controlled build-time and rendering-time measurements; keep the screensaver performant.

### Acceptance standard

From the town overhead camera, the joined blue water must read as one Y-shaped river with no sharp land blade, straight-sided empty slot, false lake, overlay patch, exposed terrain, or abrupt polygonal widening. The lower-left aerial defect must be completely gone. Tests must confirm that the final **rendered triangle mesh and terrain/carve field**, not merely the logical graph, agree. **Do not call it fixed based only on `PASS` from the old river gate.**

---

**Reviewer limitations:** These findings are based on the submitted screenshots and `RIVER_PATCH_5.md` only. The visual defects are directly observable; the precise Swift defect causing each artifact is not proven without reviewing the mesh construction, bank-strip generation, and field-evaluation source together.
