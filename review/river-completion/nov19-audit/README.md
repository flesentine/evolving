# Expanded audit — release blocker

Current code: a88128ed72869cf0af59ee4fe53bffdd8cf7abfe. Existing macOS build and detection CI both passed, but no fresh exact-head Codex review was found. PR returned to draft after this independent audit. No source or installed software changes were made in this session.

Seed 14: 9.534342 m² elevated water over original ocean, expected <=0.000001 m²; four junction shore closure failures, expected zero within 1 mm XY / 1 cm Y. The first reported shore gap is 1.066935 m from the bank mesh, expected <=0.001 m.

Relevant investigation: Sources/CivCore/RiverCoastalControls.swift:9 only applies coastal controls to terminal coastal reaches; Sources/CivRender/RiverJunctionShore.swift supplies junction shore profiles. Whether the failing water belongs to a linked reach or the union patch still requires tracing. This is not yet a demonstrated cause or a fix.

Reproduce with `build/bin/civheadless river 14 2336`; replay seed14-coastal-junction.json through riverreview with all passes. Original render outputs remain in ../work/nov19-audit/seed14-render/.
