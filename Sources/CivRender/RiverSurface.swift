import Foundation
import simd

/// Canonical indexed wet footprint. Field queries and GPU submission consume
/// this same geometry; it is independent of carving and Metal device state.
enum RiverSurface {
    struct Junction {
        var id: Int
        var input: [[Vertex]]
        var indexRange: Range<Int>
        var cuts: [(SIMD2<Float>, SIMD2<Float>, Float)]
    }
    struct Geometry {
        var vertices: [Vertex]
        var indices: [UInt32]
        var junctions: [Junction]
        var ribbonWidths: [Float]
    }
    /// A degree-two continuation has one geometric cross-section, even when
    /// its two reach-local width/tangent estimates differ. Keep every other
    /// sample and every graph identity unchanged.
    static func prepared(_ input: [RiverReach]) -> [RiverReach] {
        var network = input
        for d in network.indices where network[d].upstream.count == 1 {
            let a = network[d].upstream[0]
            guard let first = network[d].samples.first, let last = network[a].samples.last else { continue }
            let half = max(RiverChannel.halfWidth(first), RiverChannel.halfWidth(last))
            let sum = first.tangent + last.tangent
            let tangent = first.tangent == last.tangent ? first.tangent
                : (simd_length_squared(sum) > 1e-12 ? simd_normalize(sum) : first.tangent)
            network[d].samples[0].channelWidth = half * 2
            network[d].samples[0].sourceWidthFactor = 1
            network[d].samples[0].tangent = tangent
            let index = network[a].samples.count - 1
            network[a].samples[index].channelWidth = half * 2
            network[a].samples[index].sourceWidthFactor = 1
            network[a].samples[index].tangent = tangent
        }
        return network
    }

    /// Shared row trims for banks and water. The merged 1.05 factor is a
    /// minimum; acute arms must be cut beyond their actual swept overlap.
    static func ranges(_ network: [RiverReach]) -> (first: [Int], last: [Int]) {
        let metres = RiverChannel.metresPerUnit
        var firstKept = [Int](repeating: 0, count: network.count)
        var lastKept = [Int](repeating: 0, count: network.count)
        for reach in network {
            let samples = reach.samples
            guard samples.count >= 2 else { continue }
            let total = samples.last?.along ?? 0
            var startTrim: Float = 0
            if !reach.upstream.isEmpty, let first = samples.first {
                var radius = RiverChannel.halfWidth(first)
                for a in reach.upstream where a < network.count {
                    if let end = network[a].samples.last {
                        radius = max(radius, RiverChannel.halfWidth(end))
                    }
                }
                startTrim = radius * RiverChannel.junctionTrimFactor * metres
            }
            var endTrim: Float = 0
            if let d = reach.downstream, d < network.count,
               let first = network[d].samples.first, let last = samples.last {
                endTrim = max(RiverChannel.halfWidth(last),
                              RiverChannel.halfWidth(first)) * RiverChannel.junctionTrimFactor * metres
            }
            var fs = 0
            while fs < samples.count - 1 && samples[fs].along < startTrim {
                fs += 1
            }
            var le = samples.count - 1
            while le > fs && total - samples[le].along < endTrim {
                le -= 1
            }
            firstKept[reach.id] = fs
            lastKept[reach.id] = le
        }

        func ends(_ sample: RiverSample) -> (SIMD2<Float>, SIMD2<Float>) {
            let side = RiverChannel.sideVector(sample) * RiverChannel.halfWidth(sample)
            return (sample.position - side, sample.position + side)
        }
        func crosses(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> Bool {
            let aa = SIMD2<Double>(Double(a.x), Double(a.y)), bb = SIMD2<Double>(Double(b.x), Double(b.y))
            let cc = SIMD2<Double>(Double(c.x), Double(c.y)), dd = SIMD2<Double>(Double(d.x), Double(d.y))
            let ab = bb - aa, cd = dd - cc
            let denominator = RiverPolygon.cross(ab, cd)
            if abs(denominator) < 1e-18 { return false } // world-unit² predicate
            let t = RiverPolygon.cross(cc - aa, cd) / denominator
            let u = RiverPolygon.cross(cc - aa, ab) / denominator
            return t > 0 && t < 1 && u > 0 && u < 1
        }
        func intersects(_ sample: RiverSample, _ reach: RiverReach) -> Bool {
            let (a, b) = ends(sample)
            guard reach.samples.count >= 2 else { return false }
            for i in 0..<(reach.samples.count - 1) {
                let (c, d) = ends(reach.samples[i]), (e, f) = ends(reach.samples[i + 1])
                let points = [c, d, f, e]
                // Segment crossing or either endpoint strictly inside the strip.
                if (0..<4).contains(where: { crosses(a, b, points[$0], points[($0 + 1) % 4]) }) { return true }
                func vertex(_ p: SIMD2<Float>) -> Vertex {
                    Vertex(position: SIMD3(p.x, 0, p.y), normal: SIMD3(0, 1, 0), rgb: .zero)
                }
                let triangles = [[vertex(c), vertex(d), vertex(e)], [vertex(d), vertex(f), vertex(e)]]
                if triangles.contains(where: {
                    RiverChannel.Field.probe($0, a).distance < -Float(RiverPolygon.epsilon)
                        || RiverChannel.Field.probe($0, b).distance < -Float(RiverPolygon.epsilon)
                }) { return true }
            }
            return false
        }
        for d in network.indices where network[d].upstream.count >= 2 {
            let arms = [d] + network[d].upstream
            for arm in arms {
                let samples = network[arm].samples
                guard samples.count >= 2 else { continue }
                if arm == d {
                    while firstKept[arm] < samples.count - 1,
                          arms.contains(where: { $0 != arm && intersects(samples[firstKept[arm]], network[$0]) }) {
                        firstKept[arm] += 1
                    }
                } else {
                    while lastKept[arm] > 0,
                          arms.contains(where: { $0 != arm && intersects(samples[lastKept[arm]], network[$0]) }) {
                        lastKept[arm] -= 1
                    }
                }
            }
        }
        // Consumed reaches connect junctions into one patch. Re-evaluate
        // the remaining external cuts against every arm of that component,
        // not just the immediate graph neighbours. Cuts only move outward,
        // so this bounded fixed point is deterministic and terminates.
        for _ in 0..<max(network.count, 1) {
            let previousFirst = firstKept, previousLast = lastKept
            var parent = Array(network.indices)
            func root(_ index: Int) -> Int {
                var index = index
                while parent[index] != index { index = parent[index] }
                return index
            }
            for reach in network where !reach.upstream.isEmpty {
                if let downstream = reach.downstream, lastKept[reach.id] <= firstKept[reach.id] {
                    let a = root(reach.id), b = root(downstream)
                    parent[max(a, b)] = min(a, b)
                }
            }
            var groups: [Int: [Int]] = [:]
            for d in network.indices where !network[d].upstream.isEmpty {
                groups[root(d), default: []].append(d)
            }
            for id in groups.keys.sorted() {
                let members = groups[id]!
                let arms = Set(members + members.flatMap { network[$0].upstream }).sorted()
                for node in members {
                    for arm in [node] + network[node].upstream {
                        guard firstKept[arm] < lastKept[arm] else { continue }
                        let samples = network[arm].samples
                        if arm == node {
                            while firstKept[arm] < samples.count - 1,
                                  arms.contains(where: { $0 != arm && intersects(samples[firstKept[arm]], network[$0]) }) {
                                firstKept[arm] += 1
                            }
                        } else {
                            while lastKept[arm] > 0,
                                  arms.contains(where: { $0 != arm && intersects(samples[lastKept[arm]], network[$0]) }) {
                                lastKept[arm] -= 1
                            }
                        }
                    }
                }
            }
            if firstKept == previousFirst && lastKept == previousLast { break }
        }
        return (firstKept, lastKept)
    }

    static func build(_ t: Terrain,
                      network input: [RiverReach]) -> Geometry {
        let network = prepared(input)
        var verts: [Vertex] = []
        var indices: [UInt32] = []
        var junctions: [Junction] = []
        var ribbonWidths: [Float] = []
        var consumedCaps: [Int: [[Vertex]]] = [:]
        let up = SIMD3<Float>(0, 1, 0)
        let acrossCount = RiverChannel.across.count
        let metres = RiverChannel.metresPerUnit

        func depthValue(_ p: SIMD2<Float>, _ lineY: Float, edge: Bool) -> Float {
            edge ? 0 : 0.45 / 1.25
        }

        let trims = ranges(network)
        let firstKept = trims.first, lastKept = trims.last

        func tint(_ sample: RiverSample) -> SIMD3<Float> {
            sample.width > 0.026
                ? SIMD3<Float>(0.025, 0.09, 0.16)
                : SIMD3<Float>(0.04, 0.14, 0.20)
        }

        for reach in network {
            let samples = reach.samples
            guard samples.count >= 2 else { continue }
            let fs = firstKept[reach.id]
            let le = lastKept[reach.id]
            if le > fs {
                let base = UInt32(verts.count)

                for i in fs...le {
                    let sample = samples[i]
                    let side = RiverChannel.sideVector(sample)
                    let half = RiverChannel.halfWidth(sample)
                    let line = RiverChannel.waterLine(t, sample)
                    let colour = tint(sample)
                    let along = sample.along / max(sample.width * 3.0, 1e-5)
                    let rowStart = verts.count
                    for (k, f) in RiverChannel.across.enumerated() {
                        let p = sample.position + side * (half * f)
                        let u = Float(k) / Float(acrossCount - 1)
                        let edge = k == 0 || k == acrossCount - 1
                        let depth = depthValue(p, line.y, edge: edge)
                        verts.append(Vertex(position: SIMD3(p.x, line.y, p.y),
                                            normal: up,
                                            color: SIMD4(colour, depth),
                                            uv: SIMD2(u, along)))
                    }
                    ribbonWidths.append(simd_distance(verts[rowStart].position, verts[verts.count - 1].position) * metres)
                }
                for i in fs..<le {
                    let row = UInt32(i - fs)
                    for k in 0..<(acrossCount - 1) {
                        let a = base + row * UInt32(acrossCount) + UInt32(k)
                        let b = a + 1
                        let c = a + UInt32(acrossCount)
                        let d = c + 1
                        indices.append(contentsOf: [a, b, c, b, d, c])
                    }
                }

            }
            // Caps remain at actual unlinked endpoints, even when a short
            // reach is entirely owned by a junction patch.
            for end in [0, samples.count - 1] {
                let capVertexStart = verts.count, capIndexStart = indices.count
                let sample = samples[end]
                let isStart = end == 0 && reach.upstream.isEmpty
                let isEnd = end == samples.count - 1 && reach.downstream == nil
                guard isStart || isEnd else { continue }
                let side = RiverChannel.sideVector(sample)
                let half = RiverChannel.halfWidth(sample)
                let line = RiverChannel.waterLine(t, sample)
                let colour = tint(sample)
                let along = sample.along / max(sample.width * 3.0, 1e-5)
                let capDepth = depthValue(sample.position, line.y,
                                          edge: false) * 0.7
                let centre = UInt32(verts.count)
                verts.append(Vertex(position: SIMD3(sample.position.x, line.y,
                                                   sample.position.y),
                                    normal: up,
                                    color: SIMD4(colour, capDepth),
                                    uv: SIMD2(0.5, along)))
                var ring: [UInt32] = []
                ring.reserveCapacity(17)
                let segments = 16
                let outward = sample.tangent * (isStart ? -1 : 1)
                for k in 0...segments {
                    let a = Float(k) / Float(segments) * Float.pi
                    let p = sample.position + side * (half * cos(a))
                        + outward * (half * 0.62 * sin(a))
                    ring.append(UInt32(verts.count))
                    verts.append(Vertex(position: SIMD3(p.x, line.y, p.y),
                                        normal: up,
                                        color: SIMD4(colour, 0),
                                        uv: SIMD2(0.5, along)))
                }
                for k in 0..<segments {
                    indices.append(contentsOf: [centre, ring[k], ring[k + 1]])
                    indices.append(contentsOf: [centre, ring[k + 1], ring[k]])
                }
                if le <= fs {
                    for i in stride(from: capIndexStart, to: indices.count, by: 6) {
                        consumedCaps[reach.id, default: []].append((0..<3).map { verts[Int(indices[i + $0])] })
                    }
                    indices.removeSubrange(capIndexStart...)
                    verts.removeSubrange(capVertexStart...)
                }
            }
        }

        // Boolean union of the actual swept strips that were cut from the
        // ribbons. Normalized exterior loops are ear-clipped; no
        // assumption about a star-shaped junction or angular perimeter order.
        // If trims consume a whole short reach, its two junctions form one
        // patch. Never build a fan from a row that has no emitted ribbon.
        var parent = Array(network.indices)
        func root(_ id: Int) -> Int {
            var id = id
            while parent[id] != id { id = parent[id] }
            return id
        }
        for reach in network where !reach.upstream.isEmpty {
            if let downstream = reach.downstream, lastKept[reach.id] <= firstKept[reach.id] {
                let a = root(reach.id), b = root(downstream)
                parent[max(a, b)] = min(a, b)
            }
        }
        var groups: [Int: [Int]] = [:]
        for d in network.indices where !network[d].upstream.isEmpty {
            groups[root(d), default: []].append(d)
        }
        for id in groups.keys.sorted() {
            let members = groups[id]!
            let d = members[0]
            var input: [[Vertex]] = []
            var cuts: [(SIMD2<Float>, SIMD2<Float>, Float)] = []
            var included: Set<Int64> = []
            var includedCaps: Set<Int> = []
            for node in members {
            let arms = [node] + network[node].upstream
            for arm in arms {
                let samples = network[arm].samples
                guard samples.count >= 2 else { continue }
                if includedCaps.insert(arm).inserted { input.append(contentsOf: consumedCaps[arm] ?? []) }
                let range = arm == node ? 0..<firstKept[arm]
                    : lastKept[arm]..<(samples.count - 1)
                for i in range {
                    let key = Int64(arm) << 32 | Int64(i)
                    if !included.insert(key).inserted { continue }
                    func row(_ index: Int) -> [Vertex] {
                        let sample = samples[index]
                        let side = RiverChannel.sideVector(sample)
                        return RiverChannel.across.map { f in
                            let p = sample.position + side * RiverChannel.halfWidth(sample) * f
                            return Vertex(position: SIMD3(p.x, RiverChannel.waterLine(t, sample).y, p.y),
                                          normal: up, color: SIMD4(tint(sample), abs(f) == 1 ? 0 : 0.36))
                        }
                    }
                    let a = row(i), b = row(i + 1)
                    for k in 0..<(acrossCount - 1) {
                        input.append([a[k], a[k + 1], b[k]])
                        input.append([a[k + 1], b[k + 1], b[k]])
                    }
                }
                let hasRibbon = lastKept[arm] > firstKept[arm]
                var cutIndex: Int?
                if hasRibbon { cutIndex = arm == node ? firstKept[arm] : lastKept[arm] }
                if let cutIndex {
                    let sample = samples[cutIndex]
                    let side = RiverChannel.sideVector(sample) * RiverChannel.halfWidth(sample)
                    cuts.append((sample.position - side, sample.position + side, RiverChannel.waterLine(t, sample).y))
                }
            }
            }
            let startIndex = indices.count
            let pieces = RiverPolygon.union(input)
            // The cuts are outside incident-strip overlap and are exact
            // boundary constraints. Junction cells anchor the local grade.
            let controls = members.compactMap { network[$0].samples.first }.map {
                ($0.position, $0.position, RiverChannel.waterLine(t, $0).y)
            }
            func level(_ p: SIMD2<Float>) -> Float {
                var sum: Double = 0, weight: Double = 0
                for (a, b, y) in cuts + controls {
                    let distance = RiverPolygon.segmentDistance(p, a, b)
                    if distance < 0.0001 / metres { return y } // 0.1 mm
                    let w = 1 / Double(distance * distance)
                    sum += Double(y) * w; weight += w
                }
                return Float(sum / max(weight, 1))
            }
            for piece in pieces {
                let polygon = piece.map { v -> Vertex in
                    var v = v
                    v.position.y = level(SIMD2(v.position.x, v.position.z))
                    return v
                }
                RiverPolygon.append(polygon, vertices: &verts, indices: &indices)
            }
            junctions.append(Junction(id: d, input: input,
                                      indexRange: startIndex..<indices.count, cuts: cuts))
        }

        // Closed-basin tarn: a round pond at the terminal sample.
        for reach in network where reach.downstream == nil && !reach.isMouth {
            guard let last = reach.samples.last else { continue }
            let centre = last.position
            let lineY = RiverChannel.waterLine(t, last).y
            let radius = RiverChannel.halfWidth(last) * 2.5
            let colour = tint(last)
            let centreDepth = depthValue(centre, lineY, edge: false) * 0.9
            let centreIndex = UInt32(verts.count)
            verts.append(Vertex(position: SIMD3(centre.x, lineY + 0.000002,
                                               centre.y),
                                normal: up,
                                color: SIMD4(colour, centreDepth),
                                uv: SIMD2(0.5, 0.5)))
            let segments = 24
            var ringIndices: [UInt32] = []
            ringIndices.reserveCapacity(segments)
            for k in 0..<segments {
                let a = Float(k) / Float(segments) * 2 * Float.pi
                let p = centre + SIMD2<Float>(cos(a), sin(a)) * radius
                ringIndices.append(UInt32(verts.count))
                verts.append(Vertex(position: SIMD3(p.x, lineY + 0.000002, p.y),
                                    normal: up,
                                    color: SIMD4(colour, 0),
                                    uv: SIMD2(0.5, 0.5)))
            }
            for k in 0..<segments {
                let n = (k + 1) % segments
                indices.append(contentsOf: [centreIndex, ringIndices[k],
                                            ringIndices[n]])
                indices.append(contentsOf: [centreIndex, ringIndices[n],
                                            ringIndices[k]])
            }
        }
        return Geometry(vertices: verts, indices: indices, junctions: junctions, ribbonWidths: ribbonWidths)
    }

}
