# River Patch 6A — completion implementation

Base: `e72eb508c096c2b45bfcb8d2d9991977e60c2687`. Work stays on
`codex/river-patch6a-confluence-footprint`. No automation files are changed.
The current acceptance report, comparisons and reproducible views are in
[river-completion](review/river-completion/README.md). Earlier review directories
remain historical evidence, not current validation.

## One drainage authority

`CivCore.RiverGraph` owns selected sources, receiver cells, contributing area,
reaches and terminal basins. WorldGen builds it once. Simulation water distance,
fertility and conservative siting masks derive from it; the renderer reuses it.
Placement retains exact continuous wet-footprint checks below the raster scale.

Source thinning preserves complete retained paths and downstream catchment area.
Covered starts and exclusive headwater arms shorter than the existing 55 m spring
ramp are removed, retaining an outlet's strongest source if necessary. Obsolete
one-in/one-out junctions become continuous reaches. Ties and traversal are stable.
Channel smoothing stays inside the original drainage-cell corridor.

## Canonical submitted water

The merged 1.05 junction trim remains the minimum. Shared cuts now cover every
spatial overlap interval, including approaches that separate and overlap again.
Consumed reaches join their incident junctions into one Boolean patch. Both water
and banks use those same cuts. CoreGraphics normalizes exterior loops and holes
in local metres; concave-safe triangulation replaces the old centre fan.

Cross-section constraints account for bend radius, width convergence and exact
swept-row winding. A tributary's entire terminal section must fit the receiving
stem's actual footprint, not merely match its scalar width. The largest incoming
catchment selects the main stem. Canonical seam vertices are welded before upload.

Connected water grades approach receiving levels gradually instead of dropping
at the final stamped sample. The normal approach bound is 0.10 m/m; fixed spring
and lake controls allow naturally steeper headwaters where necessary. This only
lowers existing river levels and preserves those controls. Submitted edge grades
are reported separately; the profile bound is not misrepresented as a universal
bound on junction triangle slopes.

Springs have actual 0.30 m tips and earth banks closing their cap. Coastal mouths
use exact intersections with the original submitted terrain triangles to reach
true sea level (0 world units) before any swept row enters the ocean. Overlapping
coplanar river/ocean sheets are removed; sea-level river faces are submitted once
through the shared ocean material. Boats and piers use the same sea datum. Only
classified terminal inland basins create terrain-bounded lake polygons, including
dry islands and shoreline banks. Continuing drainage paths remain rivers.

## Terrain, banks and placement

`RiverChannel.Field` indexes the final indexed water triangles. Carving only
lowers original terrain and preserves deep pools. Existing detail-2 terrain uses
local support constraints; exact water/terrain triangle intersections verify
clearance. No global terrain-resolution increase was required.

Banks are clipped against the exact wet footprint. Newly clipped shoreline
vertices use its water level and the existing 4 mm submerged soil seam; dry toe
vertices are grounded against the submitted terrain after clipping. These are
soil changes, not water-height offsets. Spring, junction and lake banks use the
same footprint. Coastal banks are additionally clipped against the original
island sea footprint, so soil strips cannot become jetties offshore. The
controlled coast fixture measures 99.995 m² of old intrusion versus zero after
clipping while retaining the 100 m² landward half. Diagnostics expose raw numerical overlap and separately gate
interior overlap beyond the declared 0.1 mm boundary band.

Buildings use their actual authored mesh bounds transformed by each instance,
including offset origins. Static furniture and crops also receive footprint
exclusion. Exact wet intervals handle roads and narrow crossings. The headless
placement check uses the same supported terrain as WorldScene.

## Material and reproducible review

The shader reads the actual submitted terrain vertex heights and reconstructs
its a-c triangle interpolation per fragment. Depth and world-space ripple domains
remain continuous across ribbons and junctions. Monotone absorption retains the
stylized palette. Ocean depth uses the same submitted-terrain interpolation. A
continuous optical transition over 1 m of water-surface elevation matches the
ocean material exactly at sea level; it changes colour only, independently of
the new coastal geometry checks. No extra foam is added. There are no decorative confluence discs, new foam coverups or
water shader-height offsets.

Timeline's **Save Review View…** exports seed, year, hour, season, camera/FOV,
weather, animation time and physical viewport from the displayed frame. Replay:

```sh
build/bin/civheadless riverreview view.json output-directory all
```

The seven production passes are normal, flat water, wireframe, water height,
depth, terrain-only and banks-only, with reach/junction IDs and input geometry.
The original screenshot camera was not recorded: corresponding saved-world views
are explicitly labelled reconstructions. Existing Timeline navigation is retained.

## Acceptance

The report links actual build/verify/install results, seeds 1–11 plus the saved
world, independent determinism runs, adversarial and subcell fixtures, controlled
GPU triangulation comparisons, the 108-view visual matrix and performance logs.
Generation/layout and geometry hashes intentionally change; identical inputs
within this source version remain deterministic. Required current-head CI and a
clean current-head review remain release gates. This agent does not merge PRs.
