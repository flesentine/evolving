import Foundation
import simd

/// Gates on the same indexed water, bank triangles, and detail-2 terrain
/// vertices that WorldScene uploads. The older profile gate remains separate.
enum RiverMeshValidation {
    struct Result {
        var junctions = 0, triangles = 0, invalid = 0, footprintMisses = 0
        var wetProbes = 0, dryProbes = 0, clearanceFailures = 0, bankIntrusions = 0
        var seamFailures = 0, topologyFailures = 0
        var outsideArea: Double = 0, outsideToleranceArea: Double = 0
        var minClearance: Float = .greatestFiniteMagnitude
        var maxSeamStep: Float = 0
        var minRenderedWidth: Float = 0, maxRenderedWidth: Float = 0
        var wholeWaterTriangles = 0, wholeWaterProbes = 0, wholeWaterFailures = 0
        var referenceProbes = 0
        var maxReferenceError: Float = 0
        var maxWholeCarveEdgeChange: Float = 0
        var passes: Bool {
            wholeWaterFailures == 0 && maxReferenceError <= 0.001 && topologyFailures == 0 && invalid == 0 && footprintMisses == 0 && clearanceFailures == 0
                && bankIntrusions == 0 && seamFailures == 0 && outsideToleranceArea < 0.000001 // 1 mm² residual beyond the 0.1 mm boundary band
        }
        var summary: String {
            """
            -- final junction mesh --
            actual ribbon width \(String(format: "%.2f–%.2f m", minRenderedWidth, maxRenderedWidth))
            junctions \(junctions), triangles \(triangles), invalid winding/area \(invalid)
            footprint probes wet \(wetProbes), dry \(dryProbes), mismatches \(footprintMisses)
            boundary topology failures \(topologyFailures)
            outside swept union \(String(format: "%.6f", outsideArea)) m²; beyond 0.1 mm boundary band \(String(format: "%.9f", outsideToleranceArea)) m²
            rendered terrain clearance min \(String(format: "%.3f", minClearance)) m, failures \(clearanceFailures)
            whole river triangles \(wholeWaterTriangles), terrain probes \(wholeWaterProbes), failures \(wholeWaterFailures)
            unbounded terrain reference \(referenceProbes) probes, max error \(String(format: "%.6f", maxReferenceError)) m
            max adjacent-vertex carve change \(String(format: "%.3f", maxWholeCarveEdgeChange)) m
            above-water bank intrusions \(bankIntrusions)
            cut seam failures \(seamFailures), max height error \(String(format: "%.6f", maxSeamStep)) m
            \(passes ? "PASS final junction mesh" : "FAIL final junction mesh")
            """
        }
    }

    static func run(_ terrain: Terrain, network: [RiverReach], field: RiverChannel.Field) -> Result {
        var result = Result()
        let mesh = field.mesh
        result.minRenderedWidth = mesh.ribbonWidths.min() ?? 0
        result.maxRenderedWidth = mesh.ribbonWidths.max() ?? 0
        let carved = RiverChannel.carvedTerrain(terrain, field: field)
        let support = RiverChannel.supportedTerrain(carved, field: field, radius: RiverChannel.terrainSupportRadius(terrain))
        let vertices = WorldScene.terrainVertices(carved, detail: 2, riverField: field, coarseSupport: support)
        let banks = WorldScene.riverBankGeometry(carved, network: network, field: field)
        func terrainHeight(_ p: SIMD2<Float>) -> Float {
            WorldScene.renderedTerrainHeight(p, terrain: terrain, vertices: vertices)
        }
        for junction in mesh.junctions {
            let before = result
            result.junctions += 1
            let final = stride(from: junction.indexRange.lowerBound, to: junction.indexRange.upperBound, by: 3).map { i in
                (0..<3).map { mesh.vertices[Int(mesh.indices[i + $0])] }
            }
            guard !final.isEmpty else { result.invalid += 1; continue }
            let topology = RiverPolygon.boundaryFailures(final)
            result.topologyFailures += topology
            if topology > 0 { print("J\(junction.id): boundary topology failures \(topology)") }
            for triangle in final {
                result.triangles += 1
                if RiverPolygon.area(triangle) >= 0 { result.invalid += 1 }
                // Exact subtraction exposes any triangle crossing outside the
                // intended union, even if a centroid happens to lie inside.
                var outside = [triangle]
                for input in junction.input where RiverPolygon.overlaps(triangle, input) {
                    outside = outside.flatMap { RiverPolygon.subtract($0, input) }
                }
                result.outsideArea += outside.reduce(0) { $0 + abs(RiverPolygon.area($1)) } * 1_000_000
                var beyondBand = [triangle]
                for input in junction.input where RiverPolygon.overlaps(triangle, input) {
                    beyondBand = beyondBand.flatMap { RiverPolygon.subtract($0, input, margin: RiverPolygon.epsilon) }
                }
                result.outsideToleranceArea += beyondBand.reduce(0) { $0 + abs(RiverPolygon.area($1)) } * 1_000_000
                // Barycentric grid checks every triangle, not only cut rows.
                for i in 0...4 {
                    for j in 0...(4 - i) {
                        let p = triangle[0].position * (Float(i) / 4)
                            + triangle[1].position * (Float(j) / 4)
                            + triangle[2].position * (Float(4 - i - j) / 4)
                        let clearance = (p.y - terrainHeight(SIMD2(p.x, p.z))) * RiverChannel.metresPerUnit
                        result.minClearance = min(result.minClearance, clearance)
                        if clearance < 0.01 { result.clearanceFailures += 1 } // 1 cm
                    }
                }
            }
            let points = junction.input.flatMap { $0.map { SIMD2($0.position.x, $0.position.z) } }
            let lo = points.reduce(SIMD2<Float>(repeating: .greatestFiniteMagnitude), simd_min)
            let hi = points.reduce(SIMD2<Float>(repeating: -.greatestFiniteMagnitude), simd_max)
            let step: Float = 0.5 / RiverChannel.metresPerUnit // 0.5 m subcell probes
            for ix in 0...Int(ceil((hi.x - lo.x) / step)) {
                for iz in 0...Int(ceil((hi.y - lo.y) / step)) {
                    let p = lo + SIMD2((Float(ix) + 0.25) * step, (Float(iz) + 0.25) * step)
                    let intended = junction.input.contains { RiverChannel.Field.probe($0, p).distance <= 0 }
                    let drawn = final.contains { RiverChannel.Field.probe($0, p).distance <= 0 }
                    if intended { result.wetProbes += 1 } else { result.dryProbes += 1 }
                    if intended != drawn { result.footprintMisses += 1 }
                    if drawn, field.waterLevel(at: p) == nil { result.footprintMisses += 1 }
                }
            }
            for (a, b, y) in junction.cuts {
                for i in 0...16 {
                    let p = a + (b - a) * (Float(i) / 16)
                    // Numerical containment tolerance is 0.1 mm at seams.
                    let matches = final.map { RiverChannel.Field.probe($0, p) }
                        .filter { $0.distance <= 0.0001 / RiverChannel.metresPerUnit }
                    if matches.isEmpty { result.seamFailures += 1; continue }
                    let error = matches.map { abs($0.water - y) * RiverChannel.metresPerUnit }.min()!
                    result.maxSeamStep = max(result.maxSeamStep, error)
                    if error > 0.001 {
                        result.seamFailures += 1
                        if i == 8 { print("seam J\(junction.id) at \(p), expected \(y), error \(error) m") }
                    } // 1 mm
                }
            }
            if result.clearanceFailures != before.clearanceFailures || result.seamFailures != before.seamFailures
                || result.bankIntrusions != before.bankIntrusions {
                print("J\(junction.id): triangles \(final.count), terrain failures \(result.clearanceFailures - before.clearanceFailures), seam failures \(result.seamFailures - before.seamFailures), bank intrusions \(result.bankIntrusions - before.bankIntrusions)")
            }
        }
        struct Face: Hashable { let a: SIMD3<Float>; let b: SIMD3<Float>; let c: SIMD3<Float> }
        func face(_ triangle: [Vertex]) -> Face {
            let p = triangle.map { $0.position }.sorted {
                if $0.x != $1.x { return $0.x < $1.x }
                if $0.z != $1.z { return $0.z < $1.z }
                return $0.y < $1.y
            }
            return Face(a: p[0], b: p[1], c: p[2])
        }
        var upward: Set<Face> = []
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let triangle = (0..<3).map { mesh.vertices[Int(mesh.indices[i + $0])] }
            if RiverPolygon.area(triangle) < 0 { upward.insert(face(triangle)) }
        }
        // Inspect every submitted water triangle, not only junction patches.
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let triangle = (0..<3).map { mesh.vertices[Int(mesh.indices[i + $0])] }
            result.wholeWaterTriangles += 1
            let area = RiverPolygon.area(triangle)
            if area == 0 || (area > 0 && !upward.contains(face(triangle))) { result.invalid += 1 }
            let centre = triangle.reduce(SIMD3<Float>.zero) { $0 + $1.position } / 3
            for p in triangle.map({ $0.position }) + [centre] {
                let clearance = (p.y - terrainHeight(SIMD2(p.x, p.z))) * RiverChannel.metresPerUnit
                result.wholeWaterProbes += 1
                if clearance < 0.01 { result.wholeWaterFailures += 1 }
            }
        }
        // Test the actual clipped bank triangles against all nearby submitted
        // water, including the long straight/parallel runs outside junctions.
        for i in stride(from: 0, to: banks.indices.count, by: 3) {
            let bank = (0..<3).map { banks.vertices[Int(banks.indices[i + $0])] }
            let centre = bank.reduce(SIMD2<Float>.zero) { $0 + SIMD2($1.position.x, $1.position.z) } / 3
            for water in field.nearbyTriangles(centre) where RiverPolygon.overlaps(bank, water) {
                var overlap = bank
                let boundary = RiverPolygon.area(water) > 0 ? water : Array(water.reversed())
                for k in 0..<3 {
                    overlap = RiverPolygon.clip(overlap, a: RiverPolygon.point(boundary[k]),
                                                b: RiverPolygon.point(boundary[(k + 1) % 3]), inside: true)
                }
                if abs(RiverPolygon.area(overlap)) * 1_000_000 > 0.000001 { result.bankIntrusions += 1 }
            }
        }
        // Reference the submitted dry terrain too. Select the strongest carve
        // changes and deterministic bucket-line samples, then reconstruct the
        // exact render pipeline by scanning *all* water triangles, with no BVH
        // or bucket acceleration. This catches cutoff walls outside wet areas.
        let n = (terrain.size - 1) * 2 + 1
        var strongest: [(change: Float, index: Int)] = []
        var bucketSamples: [Int] = []
        for j in 0..<n {
            for i in 0..<n {
                let index = j * n + i, p = vertices[index].position
                let raw = terrain.interpolatedHeight(x: p.x, z: p.z)
                let depth = raw - p.y
                var change: Float = 0
                for other in [i > 0 ? index - 1 : index, j > 0 ? index - n : index] {
                    let q = vertices[other].position
                    let otherDepth = terrain.interpolatedHeight(x: q.x, z: q.z) - q.y
                    change = max(change, abs(depth - otherDepth))
                }
                result.maxWholeCarveEdgeChange = max(result.maxWholeCarveEdgeChange, change * RiverChannel.metresPerUnit)
                if strongest.count < 16 || change > strongest.last!.change {
                    strongest.append((change, index))
                    strongest.sort { $0.change == $1.change ? $0.index < $1.index : $0.change > $1.change }
                    if strongest.count > 16 { strongest.removeLast() }
                }
                // 20 m bucket lines, sampled where a real carve exists.
                let bucketDistance = abs((p.x / (20 / RiverChannel.metresPerUnit)).rounded() - p.x / (20 / RiverChannel.metresPerUnit))
                if depth > 0.01 / RiverChannel.metresPerUnit && bucketDistance < 0.08 && (i + j * 17) % 97 == 0 {
                    bucketSamples.append(index)
                }
            }
        }
        var coarseCache: [Int: Float] = [:]
        func coarse(_ i: Int, _ j: Int) -> Float {
            let index = terrain.index(i, j)
            if let value = coarseCache[index] { return value }
            let value = field.carvedHeight(terrain.height[index], at: SIMD2(terrain.worldX(i), terrain.worldZ(j)), supportRadius: 0, exhaustive: true)
            coarseCache[index] = value
            return value
        }
        let selected = Set(strongest.map { $0.index } + Array(bucketSamples.prefix(16))).sorted()
        for index in selected {
            let p = vertices[index].position
            let fi = (p.x + 1) * 0.5 * Float(terrain.size - 1)
            let fj = (p.z + 1) * 0.5 * Float(terrain.size - 1)
            let i = min(max(Int(floor(fi)), 0), terrain.size - 2), j = min(max(Int(floor(fj)), 0), terrain.size - 2)
            let u = min(max(fi - Float(i), 0), 1), v = min(max(fj - Float(j), 0), 1)
            let top = coarse(i, j) + (coarse(i + 1, j) - coarse(i, j)) * u
            let bottom = coarse(i, j + 1) + (coarse(i + 1, j + 1) - coarse(i, j + 1)) * u
            let raw = top + (bottom - top) * v
            let expected: Float
            if (index % n) % 2 == 0 && (index / n) % 2 == 0 {
                let ci = (index % n) / 2, cj = (index / n) / 2
                expected = field.supportedHeight(coarse(ci, cj), at: SIMD2(p.x, p.z),
                    supportRadius: RiverChannel.terrainSupportRadius(terrain), exhaustive: true)
            } else {
                expected = field.carvedHeight(raw, at: SIMD2(p.x, p.z),
                    supportRadius: RiverChannel.terrainSupportRadius(terrain), exhaustive: true)
            }
            result.referenceProbes += 1
            result.maxReferenceError = max(result.maxReferenceError, abs(expected - p.y) * RiverChannel.metresPerUnit)
        }
        return result
    }

    /// Adversarial unions with metre-valued coordinates and widths. Checks
    /// area/topology via dense independent wet/dry probes and subtraction.
    static func fixtures() -> Bool {
        let cases: [[(SIMD2<Float>, Float)]] = [
            [(SIMD2(-12, -12), 4), (SIMD2(12, -12), 4), (SIMD2(0, 15), 6)],
            [(SIMD2(-2, -18), 3), (SIMD2(2, -18), 3), (SIMD2(0, 15), 6)],
            [(SIMD2(-15, -8), 3), (SIMD2(13, -12), 20), (SIMD2(0, 18), 12)],
            [(SIMD2(-15, 0), 5), (SIMD2(0, -15), 5), (SIMD2(15, 0), 5), (SIMD2(0, 18), 10)],
            [(SIMD2(-12, -12), 4), (SIMD2(12, -12), 4), (SIMD2(0, 15), 6)]
        ]
        var failures = 0
        for (id, arms) in cases.enumerated() {
            var triangles: [[Vertex]] = []
            for (armIndex, arm) in arms.enumerated() {
                let (end, width) = arm
                let side = simd_normalize(SIMD2(-end.y, end.x)) * width * 0.5
                func v(_ p: SIMD2<Float>) -> Vertex {
                    Vertex(position: SIMD3(p.x / 1000, 0.1, p.y / 1000), normal: SIMD3(0, 1, 0), rgb: SIMD3(repeating: 1))
                }
                let a = v(-side), b = v(side), c = v(end - side), d = v(end + side)
                if id == 4 && armIndex == 0 {
                    let path: [SIMD2<Float>] = [.zero, SIMD2(-7, -3), SIMD2(-5, -8), end]
                    for i in 0..<(path.count - 1) {
                        let direction = simd_normalize(path[i + 1] - path[i])
                        let side = SIMD2(-direction.y, direction.x) * width * 0.5
                        let a = v(path[i] - side), b = v(path[i] + side)
                        let c = v(path[i + 1] - side), d = v(path[i + 1] + side)
                        triangles.append([a, b, c]); triangles.append([b, d, c])
                    }
                } else { triangles.append([a, b, c]); triangles.append([b, d, c]) }
            }
            let pieces = RiverPolygon.union(triangles)
            var vertices: [Vertex] = [], indices: [UInt32] = []
            for piece in pieces { RiverPolygon.append(piece, vertices: &vertices, indices: &indices) }
            let final = stride(from: 0, to: indices.count, by: 3).map { i in
                (0..<3).map { vertices[Int(indices[i + $0])] }
            }
            for ix in -80...80 {
                for iz in -80...80 {
                    let p = SIMD2((Float(ix) + 0.25) * 0.25 / 1000, (Float(iz) + 0.25) * 0.25 / 1000)
                    if triangles.contains(where: { RiverChannel.Field.probe($0, p).distance <= 0 })
                        != final.contains(where: { RiverChannel.Field.probe($0, p).distance <= 0 }) { failures += 1 }
                }
            }
            print("junction fixture \(id): \(final.count) triangles")
        }
        // A ring fixture explicitly verifies hole preservation, rather than
        // treating every exterior loop as a filled polygon.
        var ring: [[Vertex]] = []
        for (x0, z0, x1, z1): (Float, Float, Float, Float) in [
            (-10, -10, -5, 10), (5, -10, 10, 10), (-5, -10, 5, -5), (-5, 5, 5, 10)
        ] {
            func v(_ x: Float, _ z: Float) -> Vertex {
                Vertex(position: SIMD3(0.37 + x / 1000, 0.1, 0.62 + z / 1000),
                       normal: SIMD3(0, 1, 0), rgb: .zero)
            }
            ring.append([v(x0, z0), v(x1, z0), v(x0, z1)])
            ring.append([v(x1, z0), v(x1, z1), v(x0, z1)])
        }
        var ringVertices: [Vertex] = [], ringIndices: [UInt32] = []
        for piece in RiverPolygon.union(ring) {
            RiverPolygon.append(piece, vertices: &ringVertices, indices: &ringIndices)
        }
        let ringFinal = stride(from: 0, to: ringIndices.count, by: 3).map { i in
            (0..<3).map { ringVertices[Int(ringIndices[i + $0])] }
        }
        let ringArea = ringFinal.reduce(0) { $0 + abs(RiverPolygon.area($1)) } * 1_000_000
        if ringFinal.contains(where: { RiverChannel.Field.probe($0, SIMD2(0.37, 0.62)).distance <= 0 })
            || abs(ringArea - 300) > 0.01 || RiverPolygon.boundaryFailures(ringFinal) != 0 { failures += 1 }
        print(String(format: "hole fixture: %.3f m² (expected 300 m²)", ringArea))
        var stressFailures = 0
        for fixture in 0..<100 {
            let origin = SIMD2<Float>(Float(fixture % 10) * 0.08, Float(fixture / 10) * 0.08)
            var triangles: [[Vertex]] = []
            for arm in 0..<3 {
                let angle = Float(arm) * 2.1 + Float(fixture) * 0.03
                let direction = SIMD2<Float>(cos(angle), sin(angle))
                let side = SIMD2(-direction.y, direction.x) * 0.003
                for row in 0..<6 {
                    let a = origin + direction * Float(row) * 0.003
                    let b = origin + direction * Float(row + 1) * 0.003
                    func v(_ p: SIMD2<Float>) -> Vertex {
                        Vertex(position: SIMD3(p.x, 0.01, p.y), normal: SIMD3(0,1,0), rgb: .zero)
                    }
                    triangles.append([v(a-side), v(a+side), v(b-side)])
                    triangles.append([v(a+side), v(b+side), v(b-side)])
                }
            }
            let pieces = RiverPolygon.union(triangles)
            var vertices: [Vertex] = [], indices: [UInt32] = []
            for piece in pieces { RiverPolygon.append(piece, vertices: &vertices, indices: &indices) }
            let final = stride(from: 0, to: indices.count, by: 3).map { i in (0..<3).map { vertices[Int(indices[i+$0])] } }
            let failures = RiverPolygon.boundaryFailures(final)
            if failures > 0 { stressFailures += failures }
        }

        failures += stressFailures
        print("translated/rotated junction fixtures: 100, topology failures \(stressFailures)")
        let terrain = WorldGen.generate(seed: 1)
        var narrowChecks = 0
        for width: Float in [3, 4, 5, 6, 10, 20] {
            for offset: Float in [0, 0.25, 0.5, 0.75] {
                for diagonal in [false, true] {
                    let tangent = simd_normalize(diagonal ? SIMD2<Float>(1, 1) : SIMD2<Float>(0, 1))
                    let side = SIMD2(-tangent.y, tangent.x)
                    let centre = SIMD2<Float>(offset * terrain.cellSize, offset * terrain.cellSize)
                    let samples = [-1, 1].map { sign in
                        RiverSample(position: centre + tangent * Float(sign) * 15 / 1000,
                                    bed: 0.0994, width: width / 1000, tangent: tangent,
                                    channelWidth: width / 1000, along: Float(sign + 1) * 15,
                                    waterOverride: 0.1) // 100 m test water elevation, world units
                    }
                    let reach = RiverReach(id: 0, samples: samples, isSource: true, isMouth: true)
                    let field = RiverChannel.Field(terrain: terrain, network: [reach])
                    let wet = centre + side * (width * 0.49 / 1000)
                    let dry = centre + side * ((width * 0.5 + 0.05) / 1000)
                    if field.waterLevel(at: wet) == nil || field.waterLevel(at: dry) != nil
                        || !field.isNearWater(at: centre, margin: 0)
                        || RiverChannel.carvedHeight(0.2, field: field, x: wet.x, z: wet.y) > 0.09956
                        || RiverChannel.carvedHeight(0.01, field: field, x: centre.x, z: centre.y) > 0.01 {
                        failures += 1
                    }
                    narrowChecks += 1
                }
            }
        }
        print("narrow channel/subcell fixtures: \(narrowChecks) cases (3/4/5/6/10/20 m, axial + diagonal, quarter-cell offsets)")
        print("adversarial union fixtures: \(failures == 0 ? "PASS" : "FAIL") (\(failures) mismatches)")
        return failures == 0
    }
}
