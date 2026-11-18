import Foundation
import simd

/// Scan the upward triangles actually submitted to the GPU. Intervals are
/// unioned before counting, so overlapping faces, internal ribbon edges and
/// trimmed-away profile rows cannot manufacture extra channel runs.
enum RiverMeshCrossings {
    static func maximum(_ mesh: RiverSurface.Geometry, terrain: Terrain) -> Int {
        struct Triangle { let p: [SIMD2<Float>]; let low: SIMD2<Float>; let high: SIMD2<Float> }
        let triangles: [Triangle] = stride(from: 0, to: mesh.indices.count, by: 3).compactMap { i in
            let tri = (0..<3).map { mesh.vertices[Int(mesh.indices[i + $0])] }
            guard RiverPolygon.area(tri) < 0 else { return nil }
            let p = tri.map { SIMD2($0.position.x, $0.position.z) }
            return Triangle(p: p, low: p.reduce(SIMD2(repeating: .greatestFiniteMagnitude), simd_min),
                            high: p.reduce(SIMD2(repeating: -.greatestFiniteMagnitude), simd_max))
        }
        let span = 250 / RiverNetwork.metresPerUnit // same 250 m window as the legacy graph statistic
        let tolerance = 0.0001 / RiverNetwork.metresPerUnit // 0.1 mm boundary weld tolerance
        var maximum = 0
        for axis in 0..<2 {
            let other = 1 - axis
            for row in 0..<terrain.size {
                let coordinate = terrain.worldX(row)
                var intervals: [(Float, Float)] = []
                for tri in triangles where coordinate >= tri.low[axis] && coordinate <= tri.high[axis] {
                    var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
                    for i in 0..<3 {
                        let a = tri.p[i], b = tri.p[(i + 1) % 3]
                        if (a[axis] <= coordinate && b[axis] > coordinate)
                            || (b[axis] <= coordinate && a[axis] > coordinate) {
                            let t = (coordinate - a[axis]) / (b[axis] - a[axis])
                            let value = a[other] + (b[other] - a[other]) * t
                            low = min(low, value); high = max(high, value)
                        }
                    }
                    if high > low { intervals.append((low, high)) }
                }
                intervals.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
                var runs: [(Float, Float)] = []
                for interval in intervals {
                    if let last = runs.last, interval.0 <= last.1 + tolerance {
                        runs[runs.count - 1].1 = max(last.1, interval.1)
                    } else { runs.append(interval) }
                }
                var right = 0
                for left in runs.indices {
                    right = max(right, left)
                    while right < runs.count && runs[right].0 < runs[left].0 + span { right += 1 }
                    maximum = max(maximum, right - left)
                }
            }
        }
        return maximum
    }
}
