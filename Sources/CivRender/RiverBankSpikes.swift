import Foundation
import simd

/// Convex projecting corners on the actual junction shoreline are not ordinary
/// concave land wedges between tributaries. Both adjoining edges must exceed
/// 25 cm; numerical slivers in the 0.1 mm boundary band do not count.
enum RiverBankSpikes {
    static func count(_ mesh: RiverSurface.Geometry, report: Bool = false) -> Int {
        struct Edge: Hashable { let a: Int; let b: Int }
        var identities: [SIMD3<Float>: Int] = [:], points: [SIMD2<Float>] = []
        var counts: [Edge: Int] = [:], directed: [(Int, Int, Bool)] = []
        func identity(_ v: Vertex) -> Int {
            if let id = identities[v.position] { return id }
            let id = points.count; identities[v.position] = id
            points.append(SIMD2(v.position.x, v.position.z)); return id
        }
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let tri = (0..<3).map { mesh.vertices[Int(mesh.indices[i + $0])] }
            guard RiverPolygon.area(tri) < 0 else { continue }
            let owned = mesh.junctions.contains { $0.indexRange.contains(i) || $0.additionalIndices.contains { $0.contains(i) } }
            let ids = tri.map(identity)
            for j in 0..<3 {
                let a = ids[j], b = ids[(j + 1) % 3]
                counts[Edge(a: min(a,b), b: max(a,b)), default: 0] += 1
                directed.append((a,b,owned))
            }
        }
        var incoming: [Int: [Int]] = [:], outgoing: [Int: [Int]] = [:], junction = Set<Int>()
        for (a,b,owned) in directed where counts[Edge(a: min(a,b), b: max(a,b))] == 1 {
            incoming[b, default: []].append(a); outgoing[a, default: []].append(b)
            if owned { junction.insert(a); junction.insert(b) }
        }
        let minimumEdge = 0.25 / RiverGraph.metresPerUnit // 25 cm
        let minimumInteriorAngleDegrees: Float = 100 // includes rectangular 90° terminal-row spurs
        var failures = 0
        for id in junction.sorted() {
            guard let a = incoming[id], a.count == 1, let b = outgoing[id], b.count == 1 else { continue }
            let p = points[id], previous = points[a[0]], next = points[b[0]]
            let inReviewRegion = mesh.junctions.contains { j in
                guard let (lo,hi) = j.reviewBounds else { return true }
                return p.x >= lo.x && p.x <= hi.x && p.y >= lo.y && p.y <= hi.y
            }
            guard inReviewRegion else { continue }
            let u = previous - p, v = next - p
            guard min(simd_length(u), simd_length(v)) > minimumEdge else { continue }
            let turn = (p.x - previous.x) * (next.y - p.y) - (p.y - previous.y) * (next.x - p.x)
            guard turn < 0 else { continue } // convex water tip, not an inner-bank notch
            let angle = acos(min(max(simd_dot(simd_normalize(u), simd_normalize(v)), -1), 1)) * 180 / .pi
            if angle < minimumInteriorAngleDegrees {
                failures += 1
                if report && failures <= 8 { print("junction projecting water corner at \(p), interior angle \(angle) degrees; expected >= 100") }
            }
        }
        return failures
    }

    static func fixture() -> Bool {
        func reach(_ id: Int, _ start: SIMD2<Float>, _ end: SIMD2<Float>, nominal: Float, drawn: Float) -> RiverReach {
            let direction = simd_normalize(end - start)
            let samples = (0...30).map { i -> RiverSample in
                let t = Float(i) / 30, p = (start + (end - start) * t) / RiverGraph.metresPerUnit
                return RiverSample(position: p, bed: 99.4 / RiverGraph.metresPerUnit,
                    width: nominal / RiverGraph.metresPerUnit, tangent: direction,
                    channelWidth: drawn / RiverGraph.metresPerUnit, along: simd_distance(start,end) * t,
                    waterOverride: 100 / RiverGraph.metresPerUnit)
            }
            return RiverReach(id: id, samples: samples)
        }
        var network = [reach(0, SIMD2(-20,20), .zero, nominal: 12, drawn: 12),
                       reach(1, SIMD2(-20,0), .zero, nominal: 20, drawn: 4),
                       reach(2, .zero, SIMD2(20,0), nominal: 22, drawn: 4)]
        network[0].downstream = 2; network[1].downstream = 2; network[2].upstream = [0,1]
        network[0].incomingArea = 1200; network[1].incomingArea = 20000
        for i in 0...1 { network[i].samples[network[i].samples.count-1].width = 22 / RiverGraph.metresPerUnit }
        var input: [[Vertex]] = []
        for r in network { for i in 1..<r.samples.count {
            func row(_ s: RiverSample) -> [Vertex] {
                let side = RiverChannel.sideVector(s) * RiverChannel.halfWidth(s)
                return [-1,1].map { sign in
                    let p = s.position + side * Float(sign)
                    return Vertex(position: SIMD3(p.x, 0.1, p.y), normal: SIMD3(0,1,0), rgb: .zero) // 100 m water
                }
            }
            let a = row(r.samples[i-1]), b = row(r.samples[i])
            input.append([a[0],a[1],b[0]]); input.append([a[1],b[1],b[0]])
        }}
        var vertices: [Vertex] = [], indices: [UInt32] = []
        for piece in RiverPolygon.union(input) { RiverPolygon.append(piece, vertices: &vertices, indices: &indices) }
        let legacy = RiverSurface.Geometry(vertices: vertices, indices: indices,
            junctions: [.init(id: 2, input: input, indexRange: 0..<indices.count, cuts: [],
                reviewBounds: (SIMD2(-0.01,-0.01), SIMD2(0.01,0.01)))], ribbonWidths: []) // 20 m review box, world units
        var terrain = RiverEndpointValidation.fixtureTerrain(); terrain.riverGraph = nil
        let repaired = RiverSurface.build(terrain, network: network)
        let before = count(legacy), after = count(repaired)
        print("receiving-width spur fixture: before \(before), after \(after): \(before > 0 && after == 0 ? "PASS" : "FAIL")")
        return before > 0 && after == 0
    }
}
