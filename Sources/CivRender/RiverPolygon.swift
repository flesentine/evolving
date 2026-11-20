import Foundation
import simd
import CoreGraphics

/// Deterministic XZ polygon operations. The macOS 13 Boolean engine resolves
/// the full wet union in local metres. Convex half-plane subtraction clips
/// banks; ear clipping triangulates normalized loops without a centre fan.
enum RiverPolygon {
    static let epsilon = 0.0001 / Double(RiverChannel.metresPerUnit) // 0.1 mm
    static let areaEpsilon = 0.00000001 / pow(Double(RiverChannel.metresPerUnit), 2) // m²

    static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        a.x * b.y - a.y * b.x
    }
    static func point(_ v: Vertex) -> SIMD2<Double> {
        SIMD2(Double(v.position.x), Double(v.position.z))
    }
    static func area(_ polygon: [Vertex]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        let origin = point(polygon[0])
        return (1..<(polygon.count - 1)).reduce(0) {
            $0 + cross(point(polygon[$1]) - origin, point(polygon[$1 + 1]) - origin)
        } * 0.5
    }
    static func interpolate(_ a: Vertex, _ b: Vertex, _ t: Float) -> Vertex {
        Vertex(position: a.position + (b.position - a.position) * t,
               normal: a.normal + (b.normal - a.normal) * t,
               color: a.color + (b.color - a.color) * t,
               uv: a.uv + (b.uv - a.uv) * t)
    }
    static func clip(_ polygon: [Vertex], a: SIMD2<Double>, b: SIMD2<Double>,
                     inside: Bool, margin: Double = 0) -> [Vertex] {
        guard !polygon.isEmpty else { return [] }
        let edge = b - a
        func distance(_ v: Vertex) -> Double {
            (cross(edge, point(v) - a) + margin * simd_length(edge)) * (inside ? 1 : -1)
        }
        var output: [Vertex] = []
        var previous = polygon.last!, dp = distance(previous)
        for current in polygon {
            let dc = distance(current)
            if (dp >= 0) != (dc >= 0) {
                output.append(interpolate(previous, current, Float(dp / (dp - dc))))
            }
            if dc >= 0 { output.append(current) }
            previous = current; dp = dc
        }
        var clean: [Vertex] = []
        for v in output {
            if let last = clean.last, simd_length(point(v) - point(last)) <= epsilon { continue }
            clean.append(v)
        }
        if clean.count > 1, simd_length(point(clean[0]) - point(clean.last!)) <= epsilon {
            clean.removeLast()
        }
        // A half-plane intersection of convex polygons stays convex. Float
        // interpolation can leave micron-wide backtracking chains; recover
        // the convex exterior of this *convex clip result* before another cut.
        // This is never used to convexify the complete junction union.
        let sorted = clean.sorted { point($0).x == point($1).x ? point($0).y < point($1).y : point($0).x < point($1).x }
        func chain(_ values: [Vertex]) -> [Vertex] {
            var result: [Vertex] = []
            for v in values {
                while result.count >= 2,
                      cross(point(result[result.count - 1]) - point(result[result.count - 2]),
                            point(v) - point(result[result.count - 1])) <= 0 { result.removeLast() }
                result.append(v)
            }
            return result
        }
        guard sorted.count >= 3 else { return [] }
        var lower = chain(sorted), upper = chain(Array(sorted.reversed()))
        lower.removeLast(); upper.removeLast()
        let hull = lower + upper
        return abs(area(hull)) > areaEpsilon ? hull : []
    }
    static func subtract(_ polygon: [Vertex], _ cutter: [Vertex], margin: Double = 0) -> [[Vertex]] {
        var remainder = polygon
        var result: [[Vertex]] = []
        let boundary = area(cutter) >= 0 ? cutter : Array(cutter.reversed())
        for i in boundary.indices {
            guard !remainder.isEmpty else { break }
            let a = point(boundary[i]), b = point(boundary[(i + 1) % boundary.count])
            let outside = clip(remainder, a: a, b: b, inside: false, margin: margin)
            if !outside.isEmpty { result.append(outside) }
            remainder = clip(remainder, a: a, b: b, inside: true, margin: margin)
        }
        return result
    }
    static func overlaps(_ a: [Vertex], _ b: [Vertex]) -> Bool {
        let ax = a.map { $0.position.x }, az = a.map { $0.position.z }
        let bx = b.map { $0.position.x }, bz = b.map { $0.position.z }
        return ax.min()! < bx.max()! && bx.min()! < ax.max()!
            && az.min()! < bz.max()! && bz.min()! < az.max()!
    }
    static func union(_ triangles: [[Vertex]], flatAttributes: Bool = false) -> [[Vertex]] {
        guard let first = triangles.first?.first else { return [] }
        // CoreGraphics' macOS 13 path Boolean engine returns the actual
        // exterior/holes, rather than exposing an arrangement of overlapping
        // triangle edges. Work in local metres to retain small features.
        let origin = point(first), scale = Double(RiverChannel.metresPerUnit)
        let path = CGMutablePath()
        for triangle in triangles where abs(area(triangle)) > areaEpsilon {
            let ordered = area(triangle) > 0 ? triangle : Array(triangle.reversed())
            for (i, vertex) in ordered.enumerated() {
                let p = (point(vertex) - origin) * scale
                if i == 0 { path.move(to: CGPoint(x: p.x, y: p.y)) }
                else { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
            }
            path.closeSubpath()
        }
        let normalized = path.normalized(using: .winding)
        var loops: [[Vertex]] = [], current: [Vertex] = []
        normalized.applyWithBlock { element in
            func vertex(_ p: CGPoint) -> Vertex {
                var v = first
                v.position.x = Float(Double(p.x) / scale + origin.x)
                v.position.z = Float(Double(p.y) / scale + origin.y)
                if flatAttributes {
                    v.position.x = Float((Double(v.position.x) / epsilon).rounded() * epsilon)
                    v.position.z = Float((Double(v.position.z) / epsilon).rounded() * epsilon)
                }
                if flatAttributes { return v }
                let p = point(v)
                var best = Double.greatestFiniteMagnitude, attributes = first
                for triangle in triangles {
                    let a = point(triangle[0]), b = point(triangle[1]), c = point(triangle[2])
                    let denominator = cross(b - a, c - a)
                    if abs(denominator) < 1e-30 { continue } // world-unit² predicate
                    let w1 = cross(p - a, c - a) / denominator
                    let w2 = cross(b - a, p - a) / denominator, w0 = 1 - w1 - w2
                    let outside = max(-w0, max(-w1, -w2))
                    if outside < best {
                        best = outside
                        let weights = SIMD3<Float>(max(Float(w0), 0), max(Float(w1), 0), max(Float(w2), 0))
                        let sum = weights.x + weights.y + weights.z
                        attributes.color = (triangle[0].color * weights.x + triangle[1].color * weights.y + triangle[2].color * weights.z) / sum
                        attributes.uv = (triangle[0].uv * weights.x + triangle[1].uv * weights.y + triangle[2].uv * weights.z) / sum
                    }
                }
                v.color = attributes.color; v.uv = attributes.uv
                return v
            }
            switch element.pointee.type {
            case .moveToPoint:
                if current.count >= 3 { loops.append(current) }
                current = [vertex(element.pointee.points[0])]
            case .addLineToPoint: current.append(vertex(element.pointee.points[0]))
            case .closeSubpath:
                if current.count >= 3 { loops.append(current) }
                current = []
            default: preconditionFailure("Linear river union unexpectedly contains a curve")
            }
        }
        if current.count >= 3 { loops.append(current) }
        // CoreGraphics specifies a weakly-simple result: zero-area spurs
        // can walk out and back through the same vertex. Split repeated
        // vertices into actual loops and discard only zero-area walks.
        var simple: [[Vertex]] = []
        for loop in loops {
            var active: [Vertex] = []
            var positions: [SIMD2<Float>: Int] = [:]
            for v in loop + [loop[0]] {
                let key = SIMD2(v.position.x, v.position.z)
                if let start = positions[key] {
                    let closed = Array(active[start...])
                    if abs(area(closed)) > areaEpsilon { simple.append(closed) }
                    active.removeSubrange((start + 1)...)
                    positions = [:]
                    for (i, p) in active.enumerated() { positions[SIMD2(p.position.x, p.position.z)] = i }
                } else {
                    positions[key] = active.count; active.append(v)
                }
            }
        }
        loops = simple
        // Restore collinear cut-row vertices removed by path normalization.
        // They are seam constraints, never perimeter candidates sorted by angle.
        let candidates = flatAttributes ? [] : triangles.flatMap { $0 }
        loops = loops.compactMap { loop in
            var split: [Vertex] = []
            for i in loop.indices {
                let a = loop[i], b = loop[(i + 1) % loop.count]
                let ab = point(b) - point(a), length2 = simd_length_squared(ab)
                if length2 <= epsilon * epsilon { continue }
                var stops: [(Double, Vertex)] = [(0, a)]
                for v in candidates {
                    let ap = point(v) - point(a), t = simd_dot(ap, ab) / length2
                    if t > epsilon / sqrt(length2), t < 1 - epsilon / sqrt(length2),
                       abs(cross(ab, ap)) / sqrt(length2) <= epsilon {
                        // Preserve the straight union edge while reinstating
                        // its original seam subdivision to numerical tolerance.
                        stops.append((t, interpolate(a, b, Float(t))))
                    }
                }
                stops.sort { $0.0 < $1.0 }
                var previous = -Double.infinity
                for (t, v) in stops where (t - previous) * sqrt(length2) > epsilon {
                    split.append(v); previous = t
                }
            }
            return abs(area(split)) > areaEpsilon ? split : nil
        }
        func contains(_ loop: [Vertex], _ p: SIMD2<Double>) -> Bool {
            var inside = false
            for i in loop.indices {
                let a = point(loop[i]), b = point(loop[(i + 1) % loop.count])
                if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            }
            return inside
        }
        let classified = loops
        loops = classified.indices.compactMap { i in
            let loop = classified[i]
            let depth = classified.indices.filter { $0 != i && contains(classified[$0], point(loop[0])) }.count
            guard depth % 2 == 1 else { return loop }
            let hole = CGMutablePath()
            let holeOrigin = point(loop[0]), holeScale = scale * 1000 // local millimetres
            for (j, vertex) in loop.enumerated() {
                let p = (point(vertex) - holeOrigin) * holeScale
                if j == 0 { hole.move(to: CGPoint(x: p.x, y: p.y)) }
                else { hole.addLine(to: CGPoint(x: p.x, y: p.y)) }
            }
            hole.closeSubpath()
            // Discard a numerical sliver hole only if its entire interior
            // lies within the declared 0.1 mm boundary tolerance. Real holes
            // retain a nonempty inset and are triangulated explicitly below.
            let band = hole.copy(strokingWithWidth: 2 * epsilon * holeScale,
                                 lineCap: .butt, lineJoin: .miter, miterLimit: 10)
            return hole.subtracting(band).isEmpty ? nil : loop
        }
        let hasHoles = loops.indices.contains { i in
            loops.indices.contains { j in j != i && contains(loops[j], point(loops[i][0])) }
        }
        if !hasHoles { return loops }
        // Explicit hole support: decompose the normalized contour into
        // disjoint vertical wet intervals using even-odd containment. Only
        // true perimeter vertices define slabs, not interior triangle edges.
        var xs = loops.flatMap { $0.map { Double($0.position.x) } }.sorted()
        xs = xs.enumerated().filter { $0.offset == 0 || $0.element != xs[$0.offset - 1] }.map(\.element)
        var pieces: [[Vertex]] = []
        for i in 0..<(xs.count - 1) {
            let left = xs[i], right = xs[i + 1], mid = (left + right) * 0.5
            var crossings: [(a: Vertex, b: Vertex, z: Double)] = []
            func at(_ a: Vertex, _ b: Vertex, _ x: Double) -> Vertex {
                let t = (x - Double(a.position.x)) / Double(b.position.x - a.position.x)
                var v = interpolate(a, b, Float(t)); v.position.x = Float(x)
                v.position.z = Float(Double(a.position.z) + Double(b.position.z - a.position.z) * t)
                return v
            }
            for loop in loops {
                for j in loop.indices {
                    let a = loop[j], b = loop[(j + 1) % loop.count]
                    if Double(min(a.position.x, b.position.x)) < mid && Double(max(a.position.x, b.position.x)) > mid {
                        crossings.append((a, b, Double(at(a, b, mid).position.z)))
                    }
                }
            }
            crossings.sort { $0.z < $1.z }
            precondition(crossings.count % 2 == 0, "Unclosed river union boundary")
            for j in stride(from: 0, to: crossings.count, by: 2) {
                let low = crossings[j], high = crossings[j + 1]
                let polygon = [at(low.a, low.b, left), at(low.a, low.b, right),
                               at(high.a, high.b, right), at(high.a, high.b, left)]
                if abs(area(polygon)) > areaEpsilon { pieces.append(polygon) }
            }
        }
        // Split vertical slab seams at neighbouring interval endpoints.
        let points = pieces.flatMap { $0 }
        let verticalPoints = Dictionary(grouping: points, by: { $0.position.x })
        return pieces.map { polygon in
            var split: [Vertex] = []
            for i in polygon.indices {
                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                let ab = point(b) - point(a), length2 = simd_length_squared(ab)
                if length2 <= epsilon * epsilon { continue }
                var stops: [Double] = [0]
                if ab.x == 0 {
                    for v in verticalPoints[a.position.x] ?? [] {
                        let t = simd_dot(point(v) - point(a), ab) / length2
                        if t > 0 && t < 1 { stops.append(t) }
                    }
                }
                stops.sort(); var previous = -Double.infinity
                for t in stops where (t - previous) * sqrt(length2) > epsilon {
                    split.append(interpolate(a, b, Float(t))); previous = t
                }
            }
            return split
        }
    }
    static func append(_ polygon: [Vertex], vertices: inout [Vertex], indices: inout [UInt32]) {
        var polygon = polygon.reduce(into: [Vertex]()) { result, vertex in
            if result.last.map({ simd_distance(point($0), point(vertex)) > epsilon }) ?? true { result.append(vertex) }
        }
        if polygon.count > 1, simd_distance(point(polygon[0]), point(polygon.last!)) <= epsilon { polygon.removeLast() }
        guard polygon.count >= 3, abs(area(polygon)) > areaEpsilon else { return }
        // Weakly-simple contours can carry zero-area out-and-back walks
        // after Boolean/slab clipping. Split repeated geometric identities
        // into actual loops; retain every nonzero loop with the same winding.
        var active: [Vertex] = [], loops: [[Vertex]] = []
        for vertex in polygon + [polygon[0]] {
            if let start = active.firstIndex(where: {
                simd_distance(point($0), point(vertex)) <= epsilon
                    && abs(Double($0.position.y - vertex.position.y)) <= epsilon
            }) {
                let loop = Array(active[start...])
                if abs(area(loop)) > areaEpsilon { loops.append(loop) }
                active.removeSubrange((start + 1)...)
            } else { active.append(vertex) }
        }
        if loops.count != 1 || loops[0].count != polygon.count {
            // Boolean clipping can leave a long sliver narrower than the
            // declared 0.1 mm numerical boundary band. Confirm its entire
            // interior is in that band before collapsing the contour.
            if loops.isEmpty || !loops.allSatisfy({ (area($0) < 0) == (area(polygon) < 0) }) {
                let path = CGMutablePath(), origin = point(polygon[0])
                let scale = Double(RiverChannel.metresPerUnit) * 1000 // local millimetres
                for (i, vertex) in polygon.enumerated() {
                    let p = (point(vertex) - origin) * scale
                    if i == 0 { path.move(to: CGPoint(x: p.x, y: p.y)) }
                    else { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
                }
                path.closeSubpath()
                let band = path.copy(strokingWithWidth: 2 * epsilon * scale,
                    lineCap: .butt, lineJoin: .miter, miterLimit: 10)
                if path.subtracting(band).isEmpty { return }
            }
            if loops.isEmpty || !loops.allSatisfy({ (area($0) < 0) == (area(polygon) < 0) }) {
                FileHandle.standardError.write(Data(("Weak contour decomposition failed: " + polygon.map { String(describing: $0.position) }.joined(separator: ", ") + "\n").utf8))
            }
            precondition(!loops.isEmpty, "Nonzero water contour lost during weak-loop decomposition")
            let sign = area(polygon) < 0
            precondition(loops.allSatisfy { (area($0) < 0) == sign }, "Water holes require explicit contour decomposition")
            for loop in loops { append(loop, vertices: &vertices, indices: &indices) }
            return
        }
        // Ear clipping retains every collinear seam stop. It also works when
        // a slab is only one Float ULP wide and has no representable interior
        // centre point. No junction-centre or convex-piece centre fans.
        let ordered = area(polygon) < 0 ? polygon : Array(polygon.reversed())
        let base = UInt32(vertices.count)
        vertices.append(contentsOf: ordered)
        var remaining = Array(ordered.indices)
        func collapsedBoundary(_ ids: [Int]) -> Bool {
            let points = ids.map { point(ordered[$0]) }
            let low = points.reduce(SIMD2<Double>(repeating: .greatestFiniteMagnitude), simd_min)
            let high = points.reduce(SIMD2<Double>(repeating: -.greatestFiniteMagnitude), simd_max)
            let axis = high.x - low.x >= high.y - low.y ? 0 : 1
            let a = points.min { $0[axis] < $1[axis] }!, b = points.max { $0[axis] < $1[axis] }!
            let ab = b - a, length2 = simd_length_squared(ab)
            if length2 == 0 { return true }
            return points.allSatisfy {
                let t = min(max(simd_dot($0 - a, ab) / length2, 0), 1)
                return simd_distance($0, a + ab * t) <= epsilon
            }
        }
        if collapsedBoundary(remaining) {
            // Entire Boolean residue is within the declared numerical band;
            // there is no representable wet interior beyond that band.
            vertices.removeSubrange(Int(base)..<vertices.count)
            return
        }
        while remaining.count > 3 {
            var best: Int?, bestQuality: Double = -1
            for i in remaining.indices {
                let a = remaining[(i + remaining.count - 1) % remaining.count]
                let b = remaining[i], c = remaining[(i + 1) % remaining.count]
                let triangle = [ordered[a], ordered[b], ordered[c]]
                if area(triangle) >= 0 { continue }
                var rest = remaining; rest.remove(at: i)
                if collapsedBoundary(rest) { continue }
                let aa = point(ordered[a]), bb = point(ordered[b]), cc = point(ordered[c])
                let contains = rest.contains { id in
                    if id == a || id == c { return false }
                    let p = point(ordered[id])
                    return cross(bb - aa, p - aa) <= 0
                        && cross(cc - bb, p - bb) <= 0 && cross(aa - cc, p - cc) <= 0
                }
                if contains { continue }
                let longest2 = max(simd_length_squared(bb-aa), simd_length_squared(cc-bb), simd_length_squared(aa-cc))
                let quality = abs(area(triangle)) / longest2
                if quality > bestQuality { bestQuality = quality; best = i }
            }
            if let i = best {
                let a = remaining[(i + remaining.count - 1) % remaining.count]
                let b = remaining[i], c = remaining[(i + 1) % remaining.count]
                indices.append(contentsOf: [base + UInt32(a), base + UInt32(b), base + UInt32(c)])
                remaining.remove(at: i)
            } else {
                let text = "Non-simple river polygon: " + remaining.map { String(describing: ordered[$0].position) }.joined(separator: ", ") + "\n"
                FileHandle.standardError.write(Data(text.utf8))
                preconditionFailure("River footprint contains a non-simple or collapsed polygon")
            }
        }
        if remaining.count == 3 {
            indices.append(contentsOf: remaining.map { base + UInt32($0) })
        }
    }
    static func segmentDistance(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let t = min(max(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-20), 0), 1)
        return simd_distance(p, a + ab * t)
    }
    /// Checks the submitted triangulation's boundary graph using a 1 µm
    /// positional weld tolerance. Every perimeter vertex must have degree two;
    /// incidence > 2, loose interior edges, and crossed loops fail the gate.
    static func boundaryFailures(_ triangles: [[Vertex]], report: Bool = false) -> Int {
        let tolerance: Double = 0.000001 / Double(RiverChannel.metresPerUnit)
        struct Cell: Hashable { var x: Int; var z: Int }
        struct Edge: Hashable { var a: Int; var b: Int }
        var cells: [Cell: [Int]] = [:], points: [SIMD2<Double>] = []
        func identity(_ p: SIMD2<Double>) -> Int {
            let x = Int(floor(p.x / tolerance)), z = Int(floor(p.y / tolerance))
            for dx in -1...1 {
                for dz in -1...1 {
                    for id in cells[Cell(x: x + dx, z: z + dz)] ?? [] {
                        if simd_distance(p, points[id]) <= tolerance { return id }
                    }
                }
            }
            let id = points.count; points.append(p)
            cells[Cell(x: x, z: z), default: []].append(id)
            return id
        }
        var edges: [Edge: Int] = [:]
        for triangle in triangles {
            let ids = triangle.map { identity(point($0)) }
            for i in 0..<3 {
                let a = ids[i], b = ids[(i + 1) % 3]
                if a == b { continue }
                edges[Edge(a: min(a, b), b: max(a, b)), default: 0] += 1
            }
        }
        var degree: [Int: Int] = [:], failures = 0
        for edge in edges.keys.sorted(by: { ($0.a, $0.b) < ($1.a, $1.b) }) {
            let count = edges[edge]!
            if count > 2 {
                failures += 1
                if report && failures <= 20 { print("water edge incidence \(count): \(points[edge.a]), \(points[edge.b])") }
            }
            if count == 1 {
                degree[edge.a, default: 0] += 1; degree[edge.b, default: 0] += 1
            }
        }
        failures += degree.values.filter { $0 != 2 }.count
        if report {
            for id in degree.keys.sorted().filter({ degree[$0] != 2 }).prefix(20) {
                print("water boundary degree \(degree[id]!): \(points[id])")
            }
        }
        let boundary = edges.keys.filter { edges[$0] == 1 }.sorted { ($0.a, $0.b) < ($1.a, $1.b) }
        for i in boundary.indices {
            let a = boundary[i], p = points[a.a], r = points[a.b] - p
            for j in 0..<i {
                let b = boundary[j]
                if a.a == b.a || a.a == b.b || a.b == b.a || a.b == b.b { continue }
                let q = points[b.a], direction = points[b.b] - q
                let denominator = cross(r, direction)
                if abs(denominator) < 1e-24 { continue } // world-unit² predicate
                let t = cross(q - p, direction) / denominator
                let u = cross(q - p, r) / denominator
                if t > 0 && t < 1 && u > 0 && u < 1 { failures += 1 }
            }
        }
        return failures
    }

}
