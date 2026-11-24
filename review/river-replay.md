# Deterministic review playback

A Timeline view saved after fractional playback could reconstruct the camera and year but show a different settlement history. The simulation advanced its fractional clock while dropping ticks whenever the individual step was shorter than one year.

The simulation now executes every crossed whole-year boundary at its integer year. It then exposes the requested fractional year to Timeline and the renderer. This preserves direct reconstruction and makes repeated quarter-year advances equivalent to it. The review format does not require a new field.

The regression in `civheadless riverfixtures` compares settlement fields, chronicle entries, era and population totals at eight seed/year checkpoints. Before the repair, seed 1 had three settlements after quarter-year playback to year 100 and six after direct reconstruction. The repaired test passes both paths at all eight checkpoints. An incrementally advanced Metal render of the saved world's central junction at year 4594 matched its direct-replay PNG byte for byte.

The native build, verification, installation and installed saver, Player and Timeline smoke checks passed locally. See [river release evidence](river-release.md) for the geometry and camera comparisons.
