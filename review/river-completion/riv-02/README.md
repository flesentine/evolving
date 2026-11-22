# RIV-02 · River continuation regression

Run `build/bin/civheadless riverfixtures` after building. The seed-1 fixture tests five interior points against the upward faces of the final indexed water mesh. Three points sample the former land tongue between reaches 6 and 7, and two separate points protect the dry wedge upstream. The test uses world positions rather than face IDs so triangulation can change without changing the result.

The same fixture was compiled against the pre-fix continuation and graph from `85c75dc` and the repaired geometry from `b5a0525`. The old version fails at all three tongue points and passes both dry probes. The repaired version passes all five, including through the actual CLI. [Before output](fixture-before.txt) · [After output](fixture-after.txt) · [RIV-01 before and after screenshots](../riv-01/README.md)

This ticket changes the headless checks only. Existing final-mesh and endpoint validation was rerun on seeds 1–17 and the saved world at year 2336, plus the saved world at year 4594.

The upper and central junctions, hooked branch, and seed-14 coastal join were replayed in daylight and at night. Seven of eight PNGs are byte-identical to their retained references. The seed-14 night render differs in eight RGB channel values, with a maximum difference of 3/255. The diff and close-up inspection show no recurrence of the land tongue or coastal overlap. The saved-world cameras are reconstructions. [Image comparison](pixel-comparison.txt) · [Reference captures](../coastal-junction-fix/README.md)

Fresh replay PNGs and the full seed logs are available locally in `review/river-completion/work/riv-02/`. RIV-03 tracks release review.

[All 19 seed/year results](seed-results.txt)
