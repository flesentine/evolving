# AGENTS.md

This repository builds **Evolving**, a deterministic island-civilisation screen
saver. It is a Swift + Metal project with a headless CLI for reproducible
inspection. River geometry is the most fragile part of the renderer: it connects
a routing graph, a carved heightfield, water/bank meshes and object placement.
Treat river changes as geometry changes, not cosmetic tweaks.

## Non-negotiables

- **One world unit is one kilometre.** `RiverChannel.metresPerUnit` (and
  `RiverNetwork.metresPerUnit`) is `1_000`. A literal such as `0.004` in a height
  or distance expression means **4 m**, not 4 mm. Every threshold, offset,
  clearance, dedupe radius and slope must either be declared in metres and
  divided by `metresPerUnit`, or be explicitly documented as world units.
- **Never push to `main` or `master`, never merge, never force-push.** Automation
  only updates the existing pull-request branch.
- **Keep the world deterministic.** The same seed, year, hour and camera must
  produce byte-stable geometry. Do not introduce unordered iteration into
  geometry that affects output.
- **Do not hide a defect in a diagnostic.** Diagnostics must measure the mesh
  that is actually submitted to the GPU, not only the graph or an intermediate
  profile that the mesh no longer uses.
- Do not edit `.github/workflows/` or `.github/scripts/` during an automatic
  Codex-fix run. Leave changes uncommitted; the workflow commits and pushes them.

## River geometry review requirements

A river review must check all of the following. Report each finding with
`file:line`, the unit, observed vs expected, and the concrete check that exposes
it. A review with zero findings should say so explicitly; a “running” or
“in progress” update is never a finding.

### P0 — block and fix

- Water and terrain are visibly wrong: water above land, floating water, dry
  channel, a channel through a mountain, a hole in a shoreline, or a visible step
  at a junction/mouth.
- Water and bank meshes use different junction trims. Water at `1.05 × R` and
  banks at `1.0 × R` leaves a seam; they must use the same trim.
- A junction fan is not a valid union: boundary not star-shaped, self
  intersecting, triangles over land, or a fan built from a cross-section that
  was trimmed away and never emitted.
- `carvedHeight` raises terrain inside a channel (`d <= 0` must not return a
  value above the original surface). Deep pools must remain carved, not filled.
- A units error: a millimetre-scale intent expressed as metres (for example a
  `0.004` waterline offset = 4 m, or a `0.002` junction dedupe = 2 m), or a
  metre threshold compared directly to world units (`maxUphill` and similar
  gates).
- A graph cycle, a reach with no outlet to the sea/tarn, or a graph identity
  failure (`sources = outlets + Σ(indegree − 1)`) that changes the drawn network.
- Non-determinism, a crash, or a change that lets automation push to the default
  branch, merge, or force-push.

### P1 — fix in the same pass

- The field buckets can miss a query: tarn discs reach `2.5 × half` and junction
  discs `1.3 × half`; the 3×3 bucket neighbourhood must cover the largest radius
  plus the query point, with margin.
- Nearest-entry switching between overlapping water sheets steps the carve. The
  nearest water level must be continuous, or blended across the tie.
- The placement grid is coarser than a narrow channel (the 384² grid is about
  5.22 m; channels can be 3–4 m). Test 3, 5, 10 and 20 m channels at subcell
  offsets: objects, roads, bridges and carved heights must agree with the drawn
  water.
- Terrain paint still uses the simulation river mask (`terrain.river`) instead of
  the rendered network. Ghost blue/wet streaks are visible with
  `EVOLVING_HIDE_RIVER=1`; the paint must follow the same network the mesh draws.
- Tarn disc and end cap overlap without a bank ring, or a pond edge ends against
  rising terrain.
- `settled` is ordered by terrain height while routing uses the deepened `route`
  surface. Use a true topological order or the routing height, so no cell is
  treated as unsettled when its predecessor is ready.
- `topologicalArea` does not assert that every land cell was processed (cycle
  detection), or silently loses area.
- Short reaches are skipped by the ribbon loop but still used as junction cuts,
  leaving a hole or stray triangle.
- Diagnostics are blind to the drawn mesh: `minWidth` checks the sample width
  instead of the clamped channel width; water depth is computed from a
  constructed `bed + 0.60`; junction step checks forced-equal stamped endpoints;
  parallel-channel counts include trimmed rows; waterline welds check the profile
  rather than the trimmed water/fan.
- Simulation and render build two different river graphs, so settlement siting,
  agriculture or roads can disagree with the visible river.

### P2 — report, do not auto-fix

- Duplicate triangles for both windings when back-face culling is enabled.
- Crest cap/apron interpolation producing near-vertical triangles on a steep
  cross-slope.
- Dead parameters, unused functions, stale comments, or a bucket comment that
  says 200 m when `bucketSize = 0.02` units is 20 m.
- Source taper depending on `isSource` after source thinning.

## Required checks before claiming a river fix

Run these from the repository root and paste the relevant output in the PR or
final message. Do not claim a check passed unless it actually ran.

```sh
./Scripts/build.sh
./Scripts/verify.sh
build/bin/civheadless determinism 2336 1
for seed in 1 2 3 4 5 6 7 8 9 10 11; do
  build/bin/civheadless river "$seed" 2336
done
```

For a visual change, also render and inspect at least one still:

```sh
build/bin/civheadless sim build/river-review.png 2336 10 1
# Isolate terrain paint from the water mesh:
EVOLVING_HIDE_RIVER=1 build/bin/civheadless sim build/river-paint-only.png 2336 10 1
```

A river fix is not complete until the same seed produces the same diagnostics
before and after, except for the values the fix intentionally changes. Call out
every intentional diagnostic change.

## Pull-request review etiquette

- Review the current head SHA only. A review of an older commit is stale and
  must not trigger an automatic fix.
- Separate P0/P1 findings from P2 observations.
- If a finding is invalid or needs a product decision, say so explicitly instead
  of making a risky change.
- Keep the automatic-fix loop bounded: at most two OpenCode attempts per pull
  request, then stop for a human.
