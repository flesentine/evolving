import Foundation
import simd

/// Stable local triangle queries for clipping and shoreline construction.
struct RiverTriangleBuckets {
    let triangles: [[Vertex]]
    private let buckets: [Int64: [Int]]
    private let size: Float = 20 / RiverGraph.metresPerUnit
    private static func key(_ x: Int, _ z: Int) -> Int64 { Int64(x) << 32 ^ Int64(UInt32(bitPattern: Int32(z))) }
    init(_ triangles: [[Vertex]]) {
        self.triangles = triangles
        var map: [Int64: [Int]] = [:]
        let s: Float = 20 / RiverGraph.metresPerUnit
        for (id, t) in triangles.enumerated() {
            let low = t.reduce(SIMD2<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, SIMD2($1.position.x, $1.position.z)) }
            let high = t.reduce(SIMD2<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, SIMD2($1.position.x, $1.position.z)) }
            for z in Int(floor(low.y / s))...Int(floor(high.y / s)) {
                for x in Int(floor(low.x / s))...Int(floor(high.x / s)) { map[Self.key(x, z), default: []].append(id) }
            }
        }
        buckets = map
    }
    func near(_ triangle: [Vertex]) -> [[Vertex]] {
        let low = triangle.reduce(SIMD2<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, SIMD2($1.position.x, $1.position.z)) }
        let high = triangle.reduce(SIMD2<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, SIMD2($1.position.x, $1.position.z)) }
        var ids: Set<Int> = []
        for z in Int(floor(low.y / size))...Int(floor(high.y / size)) {
            for x in Int(floor(low.x / size))...Int(floor(high.x / size)) {
                for id in buckets[Self.key(x, z)] ?? [] { ids.insert(id) }
            }
        }
        return ids.sorted().map { triangles[$0] }
    }
}
