import Foundation
import simd

/// Checks submitted triangles, not stamped endpoint profiles. Every intersection
/// polygon is convex; extrema of the difference of two affine height planes
/// occur at its vertices, so terrain clearance is exhaustive over each overlap.
enum RiverGeometryChecks {
    /// Deliberately broken submitted meshes must fail before a repair can be
    /// trusted. No graph/profile data participates in these fixtures.
    static func fixtures() -> Bool {
        let side = 3, count = side * side
        let terrain = Terrain(size: side, seed: 1, height: Array(repeating: 0, count: count),
            flow: Array(repeating: 0, count: count), river: Array(repeating: 0, count: count),
            moisture: Array(repeating: 0, count: count), slope: Array(repeating: 0, count: count),
            biome: Array(repeating: 0, count: count), fertility: Array(repeating: 0, count: count),
            waterDistance: Array(repeating: 0, count: count), ao: Array(repeating: 1, count: count))
        func v(_ x: Float, _ y: Float, _ z: Float) -> Vertex {
            Vertex(position: SIMD3(x, y, z), normal: SIMD3(0, 1, 0), rgb: .zero)
        }
        var ground: [Vertex] = []
        for j in 0..<5 { for i in 0..<5 { ground.append(v(Float(i) / 2 - 1, 0, Float(j) / 2 - 1)) }}
        let face = [v(-0.4, 0.1, -0.3), v(0, 0.1, 0.4), v(0.4, 0.1, -0.3)]
        func mesh(_ faces: [[Vertex]]) -> RiverSurface.Geometry {
            let vertices = faces.flatMap { $0 }
            return RiverSurface.Geometry(vertices: vertices, indices: vertices.indices.map { UInt32($0) },
                junctions: [], ribbonWidths: [])
        }
        let valid = run(mesh([face]), terrain: terrain, submitted: ground)
        let duplicate = run(mesh([face, face]), terrain: terrain, submitted: ground)
        var raised = face
        for i in raised.indices { raised[i].position.y += 0.002 / RiverGraph.metresPerUnit } // 2 mm
        let incompatible = run(mesh([face, raised]), terrain: terrain, submitted: ground)
        ground[12].position.y = 0.101 // 101 m peak inside the 100 m sheet
        let collision = run(mesh([face]), terrain: terrain, submitted: ground)
        // A triangle touching the middle of an unsplit edge creates a loose
        // endpoint connection despite both component faces being valid.
        let loose = [face, [face[0], v(-0.2, 0.1, -0.3), v(-0.3, 0.1, -0.5)]]
        let passed = valid.interiorOverlapArea == 0 && valid.minExactClearance > 0
            && duplicate.interiorOverlapArea > 1 && incompatible.overlapHeightError > 0.001
            && collision.minExactClearance < 0 && RiverPolygon.boundaryFailures(loose) > 0
        let water = [v(0,0,0),v(0,0,0.01),v(0.01,0,0)] // 10 m right triangle
        let skirt = [v(0.001,-0.000004,0.00000002),v(0.002,-0.000004,0.00000002),v(0.0015,-0.000004,0.00000005)] // 4 mm submerged, <=0.05 mm penetration
        let broadBank = skirt.map { vertex -> Vertex in var x = vertex; x.position.z += 0.001; x.position.y = 0.001; return x } // 1 m inland/above water
        let rawBand = abs(areaOfIntersection(skirt,water)) * 1_000_000
        let bandInterior = abs(areaOfIntersection(skirt,water,inset:RiverPolygon.epsilon)) * 1_000_000
        let broadInterior = abs(areaOfIntersection(broadBank,water,inset:RiverPolygon.epsilon)) * 1_000_000
        guard rawBand > 0.000001, bandInterior == 0, broadInterior > 0.000001 else {
            print("bank exclusion predicate: FAIL"); return false
        }
        print("bank exclusion predicate: PASS (raw boundary band reported; real interior bank overlap rejected)")
        print("submitted mesh regression fixtures: \(passed ? "PASS" : "FAIL") (duplicate sheets, incompatible heights, interior terrain collision, incomplete endpoint)")
        return passed
    }
    private static func areaOfIntersection(_ a:[Vertex],_ b:[Vertex],inset:Double = 0) -> Double {
        RiverPolygon.area(intersection(a,b,inset:inset))
    }
    static func maximumEdgeGrade(_ mesh:RiverSurface.Geometry) -> Float {
        var maximum: Float = 0
        for i in stride(from:0,to:mesh.indices.count,by:3) {
            let tri = (0..<3).map { mesh.vertices[Int(mesh.indices[i+$0])].position }
            for j in 0..<3 {
                let a = tri[j], b = tri[(j+1)%3], distance = simd_length(SIMD2(a.x-b.x,a.z-b.z))
                if distance > 0 { maximum = max(maximum,abs(a.y-b.y)/distance) }
            }
        }
        return maximum
    }
    struct Result {
        var rawOverlapArea: Double = 0
        var interiorOverlapArea: Double = 0
        var overlapHeightError: Float = 0
        var exactTerrainPieces = 0
        var minExactClearance: Float = .greatestFiniteMagnitude
    }
    static func intersection(_ polygon: [Vertex], _ boundary: [Vertex], inset: Double = 0) -> [Vertex] {
        let boundary = RiverPolygon.area(boundary) >= 0 ? boundary : Array(boundary.reversed())
        var polygon = polygon
        for i in boundary.indices {
            polygon = RiverPolygon.clip(polygon, a: RiverPolygon.point(boundary[i]),
                b: RiverPolygon.point(boundary[(i + 1) % boundary.count]), inside: true, margin: -inset)
            if polygon.isEmpty { break }
        }
        return polygon
    }
    static func run(_ mesh: RiverSurface.Geometry, terrain: Terrain, submitted: [Vertex], report: Bool = false) -> Result {
        let metres = RiverGraph.metresPerUnit
        var result = Result()
        let triangles = stride(from: 0, to: mesh.indices.count, by: 3).compactMap { i -> [Vertex]? in
            let t = (0..<3).map { mesh.vertices[Int(mesh.indices[i + $0])] }
            return RiverPolygon.area(t) < 0 ? t : nil
        }
        let bucket: Float = 20 / metres
        var buckets: [Int64: [Int]] = [:]
        func key(_ x: Int, _ z: Int) -> Int64 { Int64(x) << 32 ^ Int64(UInt32(bitPattern: Int32(z))) }
        for (id, t) in triangles.enumerated() {
            let x = t.map { $0.position.x }, z = t.map { $0.position.z }
            for j in Int(floor(z.min()! / bucket))...Int(floor(z.max()! / bucket)) {
                for i in Int(floor(x.min()! / bucket))...Int(floor(x.max()! / bucket)) {
                    buckets[key(i, j), default: []].append(id)
                }
            }
        }
        var visited: Set<UInt64> = []
        for cell in buckets.keys.sorted() {
            let ids = buckets[cell]!
            for i in ids.indices { for j in (i + 1)..<ids.count {
                let a = ids[i], b = ids[j], pair = UInt64(a) << 32 | UInt64(b)
                if !visited.insert(pair).inserted || !RiverPolygon.overlaps(triangles[a], triangles[b]) { continue }
                let overlap = intersection(triangles[a], triangles[b])
                let area = abs(RiverPolygon.area(overlap)) * 1_000_000
                result.rawOverlapArea += area
                let interior = intersection(triangles[a], triangles[b], inset: 0.0001 / Double(metres))
                if report && result.interiorOverlapArea == 0 && abs(RiverPolygon.area(interior))*1_000_000 > 0.000001 {
                    print("overlapping submitted upward faces \(a),\(b): \(triangles[a].map { $0.position }) / \(triangles[b].map { $0.position })")
                }
                result.interiorOverlapArea += abs(RiverPolygon.area(interior)) * 1_000_000
                if area > 0.000001 { // 1 mm², physical area
                    for v in overlap {
                        let p = SIMD2(v.position.x, v.position.z)
                        result.overlapHeightError = max(result.overlapHeightError,
                            abs(v.position.y - RiverChannel.Field.probe(triangles[b], p).water) * metres)
                    }
                }
            }}
        }
        let n = (terrain.size - 1) * 2 + 1, spacing = terrain.cellSize / 2
        for t in triangles {
            let x = t.map { $0.position.x }, z = t.map { $0.position.z }
            let i0 = min(max(Int(floor((x.min()! + 1) / spacing)), 0), n - 2)
            let i1 = min(max(Int(floor((x.max()! + 1) / spacing)), 0), n - 2)
            let j0 = min(max(Int(floor((z.min()! + 1) / spacing)), 0), n - 2)
            let j1 = min(max(Int(floor((z.max()! + 1) / spacing)), 0), n - 2)
            for j in j0...j1 { for i in i0...i1 {
                let a = submitted[j * n + i], b = submitted[j * n + i + 1]
                let c = submitted[(j + 1) * n + i + 1], d = submitted[(j + 1) * n + i]
                for ground in [[a, c, b], [a, d, c]] {
                    let overlap = intersection(t, ground)
                    if overlap.count < 3 { continue }
                    result.exactTerrainPieces += 1
                    for v in overlap {
                        let p = SIMD2(v.position.x, v.position.z)
                        let y = RiverChannel.Field.probe(ground, p).water
                        result.minExactClearance = min(result.minExactClearance, (v.position.y - y) * metres)
                    }
                }
            }}
        }
        return result
    }
}
