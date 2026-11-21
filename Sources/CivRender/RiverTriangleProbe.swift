import simd

/// Immutable coefficients for repeated queries of one submitted water face.
/// Keep the arithmetic and edge order identical to Field.probe: that uncached
/// implementation remains the independent reference used by geometry fixtures.
struct RiverTriangleProbe {
    private struct Edge {
        let start: SIMD2<Float>
        let delta: SIMD2<Float>
        let lengthSquared: Float
        let water: Float
        let waterDelta: Float
    }
    private let origin: SIMD2<Double>
    private let ab: SIMD2<Double>
    private let ac: SIMD2<Double>
    private let denominator: Double
    private let water: SIMD3<Float>
    private let edges: [Edge]

    init(_ triangle: [Vertex]) {
        let a = RiverPolygon.point(triangle[0]), b = RiverPolygon.point(triangle[1])
        let c = RiverPolygon.point(triangle[2])
        origin = a; ab = b-a; ac = c-a
        denominator = RiverPolygon.cross(b-a,c-a)
        water = SIMD3(triangle[0].position.y,triangle[1].position.y,triangle[2].position.y)
        edges = (0..<3).map { i in
            let j = (i+1)%3
            let start = SIMD2(triangle[i].position.x,triangle[i].position.z)
            let end = SIMD2(triangle[j].position.x,triangle[j].position.z)
            let delta = end-start
            // World-unit² numerical floor, identical to the uncached reference.
            return Edge(start:start,delta:delta,lengthSquared:max(simd_length_squared(delta),1e-20),
                        water:triangle[i].position.y,waterDelta:triangle[j].position.y-triangle[i].position.y)
        }
    }

    func probe(_ p: SIMD2<Float>) -> (distance: Float, water: Float) {
        guard abs(denominator) > 1e-30 else { // world-unit² numerical predicate, same as Field.probe
            return (.greatestFiniteMagnitude,0)
        }
        let q = SIMD2<Double>(Double(p.x),Double(p.y))
        let v = RiverPolygon.cross(q-origin,ac)/denominator
        let w = RiverPolygon.cross(ab,q-origin)/denominator
        let u = 1-v-w
        let inside = min(u,min(v,w)) >= -1e-8 // dimensionless barycentric tolerance
        var distance = Float.greatestFiniteMagnitude, edgeWater: Float = 0
        for edge in edges {
            let t = min(max(simd_dot(p-edge.start,edge.delta)/edge.lengthSquared,0),1)
            let d = simd_distance(p,edge.start+edge.delta*t)
            if d < distance {
                distance = d
                edgeWater = edge.water+edge.waterDelta*t
            }
        }
        let level = Float(u)*water.x+Float(v)*water.y+Float(w)*water.z
        return (inside ? -max(distance,Float.leastNonzeroMagnitude) : distance,
                inside ? level : edgeWater)
    }
}
