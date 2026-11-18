import Foundation
import simd

/// Weld canonical water identities and split collinear stops before GPU upload.
/// This joins lake boundaries, trimmed rows and endpoint cap diameters without
/// moving a vertex beyond the existing 0.1 mm numerical boundary tolerance.
enum RiverSurfaceWeld {
    static func apply(_ input: RiverSurface.Geometry) -> RiverSurface.Geometry {
        struct Key: Hashable { let x: Int64; let y: Int64; let z: Int64 }
        let tolerance = 0.0001 / RiverGraph.metresPerUnit // 0.1 mm
        let bucketSize = 20 / RiverGraph.metresPerUnit // 20 m
        func key(_ v: Vertex) -> Key {
            Key(x: Int64((Double(v.position.x) / Double(tolerance)).rounded()),
                y: Int64((Double(v.position.y) / Double(tolerance)).rounded()), z: Int64((Double(v.position.z) / Double(tolerance)).rounded()))
        }
        func bucket(_ x: Int, _ z: Int) -> Int64 { Int64(x) << 32 ^ Int64(UInt32(bitPattern: Int32(z))) }
        func seamTolerance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            if !input.lakeTriangles.isEmpty { return tolerance }
            let onCut = input.junctions.contains { j in j.cuts.contains {
                RiverPolygon.segmentDistance(a, $0.0, $0.1) <= tolerance
                    && RiverPolygon.segmentDistance(b, $0.0, $0.1) <= tolerance
            }} || input.endpointSeams.contains {
                RiverPolygon.segmentDistance(a, $0.0, $0.1) <= tolerance
                    && RiverPolygon.segmentDistance(b, $0.0, $0.1) <= tolerance
            }
            return onCut ? tolerance : 0.000001 / RiverGraph.metresPerUnit
        }
        func identity(_ v: Vertex, vertices: inout [Vertex], cells: inout [Key: [Int]]) -> Int {
            let k = key(v)
            let p = SIMD2(v.position.x, v.position.z)
            // The 0.1 mm weld belongs to declared seams. Applying it to
            // unrelated exterior banks closes narrow land notches into
            // degree-four point contacts. Ordinary identities use 1 µm.
            let identityTolerance = seamTolerance(p, p)
            for dx: Int64 in -1...1 { for dy: Int64 in -1...1 { for dz: Int64 in -1...1 {
                for id in cells[Key(x: k.x + dx, y: k.y + dy, z: k.z + dz)] ?? [] {
                    if simd_distance(vertices[id].position, v.position) <= identityTolerance { return id }
                }
            }}}
            let id = vertices.count; vertices.append(v); cells[k, default: []].append(id); return id
        }
        var vertices: [Vertex] = [], identities: [Key: [Int]] = [:], source: [Int: Int] = [:]
        for i in input.indices {
            let old = Int(i), v = input.vertices[old]
            source[old] = identity(v, vertices: &vertices, cells: &identities)
        }
        var buckets: [Int64: [Int]] = [:]
        for (i, v) in vertices.enumerated() {
            buckets[bucket(Int(floor(v.position.x / bucketSize)), Int(floor(v.position.z / bucketSize))), default: []].append(i)
        }
        var outputVertices: [Vertex] = [], outputIndices: [UInt32] = [], mapping: [Int: Range<Int>] = [:]
        var collapsedFaces = 0, collapsedArea: Double = 0
        for i in stride(from: 0, to: input.indices.count, by: 3) {
            let tri = (0..<3).map { source[Int(input.indices[i + $0])]! }
            let start = outputIndices.count
            let original = tri.map { vertices[$0] }
            if RiverPolygon.area(original) >= 0 {
                let points = original.map { RiverPolygon.point($0) }
                let longest = (0..<3).map { simd_distance(points[$0], points[($0 + 1) % 3]) }.max()!
                let area = abs(RiverPolygon.area(original))
                if 2 * area <= Double(tolerance) * longest {
                    // Canonical welding can collapse a Boolean boundary
                    // sliver. Remove only faces wholly within the 0.1 mm
                    // segment band, and report their count and physical area.
                    collapsedFaces += 1; collapsedArea += area * 1_000_000
                    mapping[i] = start..<start; continue
                }
                let base = UInt32(outputVertices.count); outputVertices.append(contentsOf: original)
                outputIndices.append(contentsOf: [base, base + 1, base + 2]); mapping[i] = start..<outputIndices.count
                continue
            }
            var polygon: [Vertex] = []
            for edge in 0..<3 {
                let a = vertices[tri[edge]], b = vertices[tri[(edge + 1) % 3]]
                let p = SIMD2(a.position.x, a.position.z), q = SIMD2(b.position.x, b.position.z), ab = q - p
                let edgeTolerance = seamTolerance(p, q)
                let length2 = simd_length_squared(ab)
                guard length2 > edgeTolerance * edgeTolerance else { continue }
                let low = simd_min(p, q) - SIMD2(repeating: tolerance)
                let high = simd_max(p, q) + SIMD2(repeating: tolerance)
                var stops: [(Float, Int)] = [(0, tri[edge])]
                for z in Int(floor(low.y / bucketSize))...Int(floor(high.y / bucketSize)) {
                    for x in Int(floor(low.x / bucketSize))...Int(floor(high.x / bucketSize)) {
                        for id in buckets[bucket(x, z)] ?? [] where id != tri[edge] && id != tri[(edge + 1) % 3] {
                            let v = vertices[id], point = SIMD2(v.position.x, v.position.z)
                            let t = simd_dot(point - p, ab) / length2
                            if t > 0 && t < 1 && simd_distance(point, p + ab * t) <= edgeTolerance
                                && abs(v.position.y - (a.position.y + (b.position.y - a.position.y) * t)) <= edgeTolerance {
                                stops.append((t, id))
                            }
                        }
                    }
                }
                stops.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
                var last: Float = -.infinity
                for (t, id) in stops where (t - last) * sqrt(length2) > edgeTolerance {
                    polygon.append(vertices[id]); last = t
                }
            }
            RiverPolygon.append(polygon, vertices: &outputVertices, indices: &outputIndices)
            mapping[i] = start..<outputIndices.count
        }
        // Packing uses shared indices too, rather than only coincident copies.
        var packed: [Vertex] = [], packedIndices: [UInt32] = [], ids: [SIMD3<Float>: UInt32] = [:]
        for old in outputIndices {
            let v = outputVertices[Int(old)]
            // All polygon vertices already use canonical identities. A second
            // tolerance weld in a different traversal order can move them
            // again and invert a narrow face; pack exact identities only.
            if let id = ids[v.position] { packedIndices.append(id) }
            else { let id = UInt32(packed.count); packed.append(v); ids[v.position] = id; packedIndices.append(id) }
        }
        func remap(_ range: Range<Int>) -> Range<Int> {
            guard !range.isEmpty, let a = mapping[range.lowerBound], let b = mapping[range.upperBound - 3] else { return 0..<0 }
            return a.lowerBound..<b.upperBound
        }
        var junctions = input.junctions
        for i in junctions.indices {
            junctions[i].indexRange = remap(junctions[i].indexRange)
            junctions[i].additionalIndices = junctions[i].additionalIndices.map(remap)
        }
        return RiverSurface.Geometry(vertices: packed, indices: packedIndices, junctions: junctions,
                                     ribbonWidths: input.ribbonWidths, lakeTriangles: input.lakeTriangles,
                                     collapsedBoundaryFaces: collapsedFaces, collapsedBoundaryArea: collapsedArea,
                                     endpointSeams: input.endpointSeams)
    }
}
