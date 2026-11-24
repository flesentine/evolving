import simd

enum RiverContinuationRegression {
    static func run() -> Bool {
        let terrain = WorldGen.generate(seed: 1)
        let graph = terrain.riverGraph ?? RiverGraph.build(terrain)
        let mesh = RiverChannel.Field(terrain: terrain, network: graph.reaches).mesh
        let faces = stride(from: 0, to: mesh.indices.count, by: 3).compactMap { start -> [Vertex]? in
            let face = (0..<3).map { mesh.vertices[Int(mesh.indices[start + $0])] }
            return RiverPolygon.area(face) < 0 ? face : nil
        }
        // Metre coordinates in the fixed seed-1 junction-8 review scene.
        // Interior points avoid testing an ambiguous boundary or triangle ID.
        let probes: [(name: String, x: Float, z: Float, wet: Bool)] = [
            ("former tongue, upper", 489, 316, true),
            ("former tongue, middle", 495, 324, true),
            ("former tongue, downstream", 501, 331, true),
            ("preserved dry wedge, upper", 469, 282, false),
            ("preserved dry wedge, lower", 473, 288, false),
        ]
        var passed = true
        for probe in probes {
            let point = SIMD2(probe.x, probe.z) / RiverGraph.metresPerUnit
            let wet = faces.contains { RiverChannel.Field.probe($0, point).distance <= 0 }
            let matches = wet == probe.wet
            print("seed-1 junction footprint: \(probe.name) at (\(probe.x), \(probe.z)) m, expected \(probe.wet ? "wet" : "dry"), got \(wet ? "wet" : "dry"): \(matches ? "PASS" : "FAIL")")
            passed = passed && matches
        }
        return passed
    }
}
