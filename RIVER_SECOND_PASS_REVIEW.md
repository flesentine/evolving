# Evolving Timeline — river rebuild review, pass 2

**Review date:** 2026-11-10  
**Inputs:** `RIVER_IMPLEMENTATION.md` (original), `RIVER_IMPLEMENTATION(1).md` (updated), initial Medieval screenshot, updated Year 0 / Neolithic screenshot.  
**Limit:** The actual `.swift` / `.metal` sources were not supplied. Conclusions about code refer to the implementation briefs and must be checked against source. The screenshots are not a controlled same-seed/same-year A/B.

## Bottom line

**The implementation is more numerically coherent but the result still looks like engineered canals cut through terrain.** The visible failure is now strongly dominated by the interaction between river surface height, terrain carving, bank geometry and a centerline that does not follow a physically developed valley.

Do not spend the next iteration improving foam, water color or global terrain resolution. **Fix river–terrain coupling first.**

## What changed, and whether it helped

| Updated system | Assessment |
|---|---|
| True gradient-based D8 routing, including diagonal distance | Correctness improvement. Keep. |
| Topological contributing-area accumulation on the final routing graph | Correct direction; audit the graph and channel-mask recomputation. |
| Connected, monotonically nonincreasing water profile | Better invariant; may generate severe terrain cuts or abrupt junction drops if imposed on incompatible beds. |
| Render terrain detail 2 (~2.6 m vs ~5.2 m) | Helps triangle-edge artifacts but does not cure deep cut geometry. |
| Channel capsules instead of nearest-center circles | Improvement in continuity; keep. |
| 4.0 m carve feather instead of 0.5 m | Too narrow wherever the river is more than a few meters below surrounding terrain. |
| Bank crest capped at water + 2.0 m | Does not address vertical exposed cuts or apron joining original high ground. |
| Max river width grew from 14.1 m to 40.8 m in reported seed | Needs investigation: source/area scale and wide cross-sections may exacerbate the canal effect. |
| Confluence water patches still disabled | Important remaining geometry flaw. |
| River still generated on routing-only copy; real world terrain not valley-shaped | **Primary underlying problem unchanged.** |

## New screenshot: specific failures

### A. Northwest / upper-left: gouged cliffs and hanging terrain

Multiple channels have tall, near-vertical artificial cuts, knife-like interchannel ridges, and exposed triangular faces. The blue river segments and green bank strips do not form a natural landform. There is also a blunt-ended channel; verify whether it is a deliberately terminal lake, a missing confluence patch, or an orphan reach.

**Likely causes**: river carving lowers terrain to `waterY - 0.45 m`, then returns to unmodified terrain over just 4 m; cross-sectional difference may be far greater than the transition can accommodate. An apron extending from `water + <=2 m` back up to original ground can still create a huge wall.

### B. Central / mountain base: overly parallel waterways

Multiple roughly parallel channels occupy the same broad downhill direction. Some bank geometry appears as long, thin olive ribbons beside blue water. The system still lacks basin-level channel hierarchy and actual broad valley formation; source thinning alone is not enough.

### C. Right mountain: a uniform blue chute

A stream plunges down a steep snowy slope, then wraps around the mountain base in a nearly constant-width smooth U-turn. It resembles an irrigation aqueduct or amusement-park flume more than a stream in a mountain gully. Narrow the steep headwaters, align with visible ravine relief, and use grade-dependent rapid/rock treatment. Avoid adding a decorative sine wave to solve this.

### D. Bottom-right reach: suspicious hard transition

The main blue ribbon changes direction/width at an abrupt, almost geometric-looking junction. Inspect reach endpoints, confluence patch omission, discontinuous width, and steep transitions in generated bank geometry.

### E. Persistent raised-bank effect

The 9-point bank strips force a distinct wet margin and crest above the water along nearly every channel. Natural rivers need variable bank relief, sometimes barely noticeable from a distant camera. Restrict explicit embankments to human modifications in later eras.

## Critical implementation questions and potential bugs

### 1. Graph identity may still be misleading

New output reports `69 reaches`, `60 linked`, `19 sources`, `15 junctions`, `4 mouths`, `5 inland terminal ends`, plus `graph identity: OK`.

If `60 linked` means 60 reaches have a downstream edge, there are **9 terminal reaches** (`69 - 60`). That agrees with four mouths plus five inland terminals. But, under the standard definition of a directed forest, **19 source leaves with 9 outlets allow only 10 net binary confluences**, not 15. Formula:

`source_leaves = terminal_outlets + Σ_junctions (number_of_upstream_reaches_at_junction - 1)`.

Therefore those counters **cannot all represent the same final pruned reach forest with 15 genuine confluences**, unless one or more counters uses a different definition or a non-tree case is being excluded. Do not blindly trust `graph identity: OK`. Print per-component counts, and validate every actual link and the identity on the complete post-pruning reach graph. If the five inland terminals are excluded by design, state that clearly and validate them separately.

### 2. Recompute the *channel* after the final routing graph

The new brief recomputes `finalArea` and `isRiver = finalArea > 1200` in Stage C, but describes Stage C spill routing as `channel = isRiver initially`, and the pipeline still traces `channel`. Confirm the exact ordering and that every mask/indegree/source/junction/reach computation is rebuilt after `finalArea`, not kept from the previous route.

### 3. The connected profile might be over-constrained

The algorithm sets each reach to a running minimum of `bed + 0.60 m`, then lowers all junction endpoints to the minimum incident level. **Downhill and exact endpoint equality are not enough** to guarantee natural geometry. They can hide a steep drop or cause the water to cut far below adjacent unmodified land. Also, a perfectly level 0.60 m depth in diagnostics does not test whether the original terrain is many meters above the wet surface just a few meters away.

Track water-versus-original-ground differences, steep grade changes, endpoint profile curvature, maximum *original terrain* excavation, and maximum cross-section slope. At every confluence, solve a smooth shared node *in the terrain-adjusted valley*, not an endpoint-only minimum that forces distant channels to match.

### 4. Check units in all revised code

The map still has contradictory 2 km vs 20 km interpretations. The updated brief presents 0.12 m stream-power cuts, a 4.0 m feather and a 0.45 m bed cut, but the underlying terrain height is expressed in *world units*. Confirm `meters / metresPerUnit` conversions in every implementation. Never substitute raw meter numbers into `terrain.height` arrays without converting.

### 5. Update stale technical documentation

The new brief's Stage 7 says junction ramps were removed, but section 13.4 still describes ramps. Section 12 reports 5 inland terminal ends, whereas section 13.6 says about 10 per seed. Those contradictions do not prove the code is wrong, but they weaken the usefulness of this review brief.

## Engineering action plan — in order

### Phase 0 — reproducible debugging (before changing more code)

1. Fix one seed, year, exact camera and view settings and create baseline renders. Keep the original screenshot and updated screenshot only as qualitative comparisons; they are different years.
2. Render `EVOLVING_HIDE_BANKS=1`, then `EVOLVING_HIDE_RIVER=1`, then magenta-water and terrain wireframe. Identify whether each visible wall originates from terrain carving or separate bank strips.
3. Overlay centerline, original-terrain height, carved height, water height, channel width, source/junction/outlet IDs, and downstream arrows.
4. At five representative samples (NW cliff, central parallel channels, mountain chute, U-turn, lower-right join), dump a 100-m cross-section: original terrain height, final terrain height, water height, channel width, valley width. Print max and 95th-percentile cut depth.

### Phase 1 — fix topology before building prettier meshes

- Define valid terminal types: ocean, boundary outlet, genuine closed-basin lake, and errors; stop treating rounded caps as lakes.
- Make the post-spill, post-prune graph the single authority for all reaches, flow, water width and junctions.
- Validate per-connected-component forest identity, exact reach links, and source-to-outlet continuity. Print and investigate 9 terminals vs 19 sources/15 confluences.
- Eliminate needless same-valley parallel channels with terrain/basin guidance and graph-aware pruning; do not arbitrarily fuse streams across ridgelines.

### Phase 2 — **develop valleys**, then fit river geometry inside them

- On a dedicated render heightfield, carve a **multi-scale valley corridor** around selected main stems and tributaries, separately from the narrow wet channel. This doesn't change the simulation's canonical elevation unless you explicitly want erosion to affect settlements.
- Make the landscape-wide corridor wide enough that elevation transitions have plausible slopes. Start with valley radii of several channel widths (e.g. 3–8× as *tuning candidates*, strongly terrain/slope dependent), rather than a fixed 4 m regardless of cut depth.
- Limit exposed-bank steepness based on terrain type. If a plausible cross-section cannot fit a river at the proposed centerline, move the centerline toward a local terrain low / reroute; do not excavate a vertical trench to force it to fit.
- Separate a smooth valley-floor height from the water surface: adjust the valley bed and its channel bottom *together*, then recompute water. Do not solve water and cut the land afterward as independent operations.
- Have at least three river classes: steep headwater creek, confined foothill stream, and lowland/main-stem river. These need different width, curvature, valley width, bank and shader behavior.
- The terrain's dominant slopes and outlet basins should inform channel placement before fine smoothing. A few broad natural trunks are better than many parallel blue strings.

### Phase 3 — remove manufactured bank strips

- Make terrain the primary bank geometry. Do not create a positive raised crest at every channel edge.
- Let the bank blend into the valley floor or mountain wall without a distinct continuous lip. Where needed, mesh the channel edge as a *replacement* cross-section, not a raised add-on to another surface.
- Keep narrow explicit levees only for later historical civilizations that actually build flood works.
- Reduce visually identical widths: headwaters should often be narrower and broken by rocks/rapids; trunk widths should grow smoothly with final drainage area.

### Phase 4 — water geometry and junctions

- Enable proper union/confluence water patches and rebuild local bank meshes at junctions; do not depend on overlapping ribbons or a disabled confluence disc.
- Build one continuous waterline graph with shared elevations, **plus bounded local slope and cut-depth constraints**. If a channel cannot meet that slope while remaining inside terrain, modify the valley or classify as rapid/waterfall, not a smooth flat pool with a sudden plunge.
- Let a stream through steep mountains show cascades, rocks, narrowed sections and faster water, instead of the same calm ribbon seen in lowland sections.
- Preserve the existing capsule-based field and finer terrain detail; consider adaptive tessellation only if close-up triangle artifacts remain after valley-shape correction.

### Phase 5 — polish after landscape is right

Only then tune blue/green water gradients, ripples, Fresnel, foam and era-specific structures.

## Acceptance tests the agent should implement

**Numerical hard fails**

- Every post-pruned reach has exactly one correctly classified downstream connection or a legitimate terminal.
- Graph identity checked over all components and counters with documented definitions.
- No water surface uphill; no impossible unclassified drop; exact shared confluence water elevation **and** bounded short-range slope change.
- No discontinuity, gap or unpatched triangle at a confluence.
- Max channel excavation relative to original ground, measured across an actual valley cross-section, stays inside a slope-aware design budget; exceptions are classified cliffs/gorges.
- Centerline remains in a physically justified valley and does not need extreme excavation to clear the water width.

**Visual acceptance**

- No artificial vertical green canyon walls on ordinary grassy hillsides.
- No long raised lips on both sides of natural streams.
- No blunt blue river ends except convincingly rendered lakes/ocean boundaries.
- No long same-direction parallel rivers in the same valley unless explicitly modeling a real braided system.
- Mountain channels look narrow, gullied and fast; lowland channels wider and meandering.
- At least 12 fixed seed/camera test views (including mountains, junctions, valley plains) look acceptable; failures on one seed are not hidden by average metrics.

## Immediate assignment to coding agent

> Prior fixes improved numerical flow and reduced some shore triangles, but the new image has unacceptable artificial cliff trenches, suspended-looking narrow ridges, broken or blunt tributary ends, flat-width mountain chutes and uniform raised levees. Do **not** change shaders or add more generic terrain resolution. Instrument cross-sections with original ground, carved ground, river water, centerline, and bank-strip geometry; check units and complete post-pruning graph identity (69 reaches, 60 linked, 19 sources, 15 junctions, 4 mouths, 5 inland ends). Then implement actual terrain-coupled valley shaping with width- and slope-dependent bank transitions, preserve natural gullies, remove automatic positive bank crests, patch confluences, and constrain water profiles by plausible terrain cut and slope instead of just monotonicity. Provide same-seed, same-camera before/after renders, including water-only, terrain-only, and banks-hidden debug images. A passing gate is not success unless the landscape visually looks like a natural drainage network.

**Priority:** A natural-looking terrain/river landform is the release criterion, not just passing `civheadless river` metrics.
