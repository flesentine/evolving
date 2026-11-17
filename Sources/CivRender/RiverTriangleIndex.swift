import Foundation
import simd

/// Deterministic nearest-surface hierarchy. Carving must see the nearest drawn
/// water at every distance: a finite bucket halo cannot bound a deep valley.
struct RiverTriangleIndex {
    struct Record {
        let triangle: [Vertex]
        let low: SIMD2<Float>
        let high: SIMD2<Float>
        let minWater: Float
        let gradient: Float // vertical / horizontal, dimensionless
    }
    private struct Node {
        var low: SIMD2<Float>
        var high: SIMD2<Float>
        var left = -1
        var right = -1
        var start = 0
        var count = 0
    }
    let records: [Record]
    private let nodes: [Node]
    private let order: [Int]
    private let surfaceIDs: [Int]
    /// Relative-distance interpolation: the neighbouring water profile is
    /// blended over one nearest-surface distance. A fixed tiny tie strip
    /// creates a tall wall between rivers at very different elevations.

    init(_ triangles: [[Vertex]]) {
        let records = triangles.map { triangle -> Record in
            let points = triangle.map { SIMD2($0.position.x, $0.position.z) }
            let a = RiverPolygon.point(triangle[0]), b = RiverPolygon.point(triangle[1])
            let c = RiverPolygon.point(triangle[2]), ab = b - a, ac = c - a
            let dyB = Double(triangle[1].position.y - triangle[0].position.y)
            let dyC = Double(triangle[2].position.y - triangle[0].position.y)
            let determinant = RiverPolygon.cross(ab, ac)
            var gradient: Float = 0
            if abs(determinant) > 1e-30 { // world-unit² numerical predicate
                let dx = (dyB * ac.y - dyC * ab.y) / determinant
                let dz = (ab.x * dyC - ac.x * dyB) / determinant
                gradient = Float(hypot(dx, dz))
            }
            return Record(triangle: triangle,
                          low: points.reduce(SIMD2(repeating: .greatestFiniteMagnitude), simd_min),
                          high: points.reduce(SIMD2(repeating: -.greatestFiniteMagnitude), simd_max),
                          minWater: triangle.map { $0.position.y }.min()!, gradient: gradient)
        }
        // Outside a wet union, a closest point always lies on its exterior.
        // Index only triangles incident to exposed edges. Interior triangles
        // remain available for exact wet/support queries, but do not bias or
        // slow the outside water-profile interpolation.
        struct Edge: Hashable { let a: SIMD3<Float>; let b: SIMD3<Float> }
        struct Face: Hashable { let a: SIMD3<Float>; let b: SIMD3<Float>; let c: SIMD3<Float> }
        func less(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
            if a.x != b.x { return a.x < b.x }
            if a.z != b.z { return a.z < b.z }
            return a.y < b.y
        }
        func edges(_ id: Int) -> [Edge] {
            let p = records[id].triangle.map { $0.position }
            return (0..<3).map { i in
                let a = p[i], b = p[(i + 1) % 3]
                return less(a, b) ? Edge(a: a, b: b) : Edge(a: b, b: a)
            }
        }
        var counts: [Edge: Int] = [:], unique: Set<Face> = [], upward: [Int] = []
        for id in records.indices where RiverPolygon.area(records[id].triangle) < 0 {
            let points = records[id].triangle.map { $0.position }.sorted(by: less)
            if !unique.insert(Face(a: points[0], b: points[1], c: points[2])).inserted { continue }
            upward.append(id)
            for edge in edges(id) { counts[edge, default: 0] += 1 }
        }
        let boundary = upward.filter { id in edges(id).contains { counts[$0] == 1 } }
        let surfaceIDs = boundary.isEmpty ? upward : boundary
        var nodes: [Node] = [], order: [Int] = []
        func build(_ ids: [Int]) -> Int {
            let low = ids.reduce(SIMD2<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, records[$1].low) }
            let high = ids.reduce(SIMD2<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, records[$1].high) }
            let index = nodes.count
            nodes.append(Node(low: low, high: high))
            if ids.count <= 8 {
                nodes[index].start = order.count; nodes[index].count = ids.count
                order.append(contentsOf: ids.sorted())
            } else {
                let axis = high.x - low.x >= high.y - low.y ? 0 : 1
                let sorted = ids.sorted {
                    let a = records[$0].low[axis] + records[$0].high[axis]
                    let b = records[$1].low[axis] + records[$1].high[axis]
                    return a == b ? $0 < $1 : a < b
                }
                let middle = sorted.count / 2
                let left = build(Array(sorted[..<middle])), right = build(Array(sorted[middle...]))
                nodes[index].left = left; nodes[index].right = right
            }
            return index
        }
        if !surfaceIDs.isEmpty { _ = build(surfaceIDs) }
        self.records = records; self.nodes = nodes; self.order = order; self.surfaceIDs = surfaceIDs
    }

    private func distance(_ p: SIMD2<Float>, _ node: Node) -> Float {
        let d = simd_max(simd_max(node.low - p, p - node.high), .zero)
        return simd_length(d)
    }

    func nearest(_ p: SIMD2<Float>, exhaustive: Bool = false) -> (water: Float, distance: Float)? {
        guard !surfaceIDs.isEmpty else { return nil }
        var best = Float.greatestFiniteMagnitude, bestID = Int.max, level: Float = 0
        func visit(_ id: Int) {
            let value = RiverChannel.Field.probe(records[id].triangle, p)
            if value.distance < best || (value.distance == best && id < bestID) {
                best = value.distance; bestID = id; level = value.water
            }
        }
        if exhaustive {
            for id in surfaceIDs { visit(id) }
        } else {
            var stack = [0]
            while let index = stack.popLast() {
                let node = nodes[index]
                // A millimetre guard prevents Float rounding from pruning a
                // mathematical tie. It does not change the resulting surface.
                if distance(p, node) > max(best, 0) + 0.001 / RiverChannel.metresPerUnit { continue }
                if node.count > 0 {
                    for offset in node.start..<(node.start + node.count) { visit(order[offset]) }
                } else {
                    let left = distance(p, nodes[node.left]), right = distance(p, nodes[node.right])
                    if left <= right { stack.append(node.right); stack.append(node.left) }
                    else { stack.append(node.left); stack.append(node.right) }
                }
            }
        }
        guard best < .greatestFiniteMagnitude else { return nil }
        if best > 0 {
            let support = best
            // Stable primitive order keeps floating-point accumulation byte
            // stable regardless of traversal order or hierarchy pruning.
            var sum: Double = 0, weight: Double = 0
            // Sorting by values would make equal-valued geometry ambiguous;
            // recompute the final small tie set in canonical triangle order.
            let ties = exhaustive ? surfaceIDs : candidateIDs(p, radius: best + support)
            for id in ties {
                let value = RiverChannel.Field.probe(records[id].triangle, p)
                if value.distance - best < support {
                    let w = pow(Double(1 - (value.distance - best) / support), 2)
                    sum += Double(value.water) * w; weight += w
                }
            }
            if weight > 0 { level = Float(sum / weight) }
        }
        return (level, best)
    }

    func candidateIDs(_ p: SIMD2<Float>, radius: Float) -> [Int] {
        guard !nodes.isEmpty else { return [] }
        var stack = [0], ids: [Int] = []
        while let index = stack.popLast() {
            let node = nodes[index]
            if distance(p, node) > radius + 0.001 / RiverChannel.metresPerUnit { continue }
            if node.count > 0 { ids.append(contentsOf: order[node.start..<(node.start + node.count)]) }
            else { stack.append(node.right); stack.append(node.left) }
        }
        return ids.sorted()
    }
}
