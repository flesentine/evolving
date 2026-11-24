import Foundation
import simd

extension RiverGraph {
    /// Source thinning can remove an arm of an old confluence. Its remaining
    /// one-in/one-out node is now an ordinary channel, not a junction patch.
    /// Reconnect its complete sample path before solving profiles and widths.
    static func mergeContinuations(_ input: [RiverReach], terrain: Terrain? = nil,
                                   receivers: [Int] = []) -> [RiverReach] {
        guard input.contains(where: { $0.upstream.count == 1 }) else { return input }
        var chains: [[Int]] = [], assigned = Set<Int>()
        for start in input.indices where input[start].upstream.count != 1 {
            var chain = [start]; assigned.insert(start)
            var tail = start
            while let next = input[tail].downstream, input[next].upstream.count == 1 {
                precondition(assigned.insert(next).inserted, "River continuation cycle")
                chain.append(next); tail = next
            }
            chains.append(chain)
        }
        precondition(assigned.count == input.count, "River continuation lost a reach")
        var mapping: [Int:Int] = [:]
        for (id,chain) in chains.enumerated() { for old in chain { mapping[old] = id } }
        return chains.enumerated().map { id,chain in
            var reach = input[chain[0]], joins: [Int] = []
            for next in chain.dropFirst() {
                joins.append(reach.samples.count-1)
                reach.samples.append(contentsOf:input[next].samples.dropFirst())
            }
            let tail = input[chain.last!]
            reach.id = id; reach.downstream = tail.downstream.map { mapping[$0]! }
            reach.upstream = reach.upstream.map { mapping[$0]! }
            reach.lastCell = tail.lastCell; reach.endpoint = tail.endpoint
            reach.isMouth = tail.isMouth; reach.incomingArea = tail.incomingArea
            reach.junctionsPrepared = false
            guard !joins.isEmpty else { return reach }
            if let terrain, !receivers.isEmpty {
                joins = roundContinuationBends(&reach, joins: joins, terrain: terrain, receivers: receivers)
            }
            let positions = reach.samples.map { $0.position }
            var affected = Set<Int>()
            for join in joins { for i in max(join-2,1)...min(join+2,positions.count-2) { affected.insert(i) } }
            for i in affected.sorted() {
                let direction = positions[i+1]-positions[i-1]
                if simd_length_squared(direction) > 0 { reach.samples[i].tangent = simd_normalize(direction) }
            }
            let tangents = reach.samples.map { $0.tangent }
            for i in affected.sorted() {
                let direction = tangents[i-1]+2*tangents[i]+tangents[i+1]
                if simd_length_squared(direction) > 0 { reach.samples[i].tangent = simd_normalize(direction) }
                let ab = positions[i]-positions[i-1], ac = positions[i+1]-positions[i-1], bc = positions[i+1]-positions[i]
                let cross = ab.x*ac.y-ab.y*ac.x
                if abs(cross) > 0.00000001/(metresPerUnit*metresPerUnit) { // 0.01 mm²
                    let radius = simd_length(ab)*simd_length(ac)*simd_length(bc)/(2*abs(cross))
                    reach.samples[i].bendLimit = min(reach.samples[i].bendLimit,radius*0.92)
                    reach.samples[i].bendInside = cross > 0 ? 1 : -1
                }
            }
            var along: Float = 0
            for i in reach.samples.indices {
                if i > 0 { along += simd_distance(positions[i-1],positions[i])*metresPerUnit }
                reach.samples[i].along = along; reach.samples[i].phase = reach.samples[0].phase
                reach.samples[i].junctionTangent = nil; reach.samples[i].junctionLimit = .greatestFiniteMagnitude
            }
            return reach
        }
    }

    /// Refit the sharp corner left when two independently smoothed reaches
    /// are concatenated. Keep the replacement inside the raw drainage corridor.
    private static func roundContinuationBends(_ reach: inout RiverReach, joins: [Int],
                                               terrain: Terrain, receivers: [Int]) -> [Int] {
        var raw: [SIMD2<Float>] = []
        var cell = reach.firstCell
        for _ in receivers.indices {
            guard receivers.indices.contains(cell) else { break }
            raw.append(SIMD2(terrain.worldX(cell % terrain.size), terrain.worldZ(cell / terrain.size)))
            if cell == reach.lastCell { break }
            cell = receivers[cell]
        }
        guard cell == reach.lastCell, raw.count > 1 else { return joins }
        let corridor = terrain.cellSize * sqrt(Float(2)) * 0.5 // one raw cell half diagonal
        func withinCorridor(_ point: SIMD2<Float>) -> Bool {
            zip(raw, raw.dropFirst()).contains { a, b in
                let edge = b - a
                let length = simd_length_squared(edge)
                guard length > 0 else { return simd_distance(point, a) <= corridor }
                let u = min(max(simd_dot(point - a, edge) / length, 0), 1)
                return simd_distance(point, a + edge * u) <= corridor
            }
        }
        var offset = 0
        var recheck: [Int] = []
        for (index, originalJoin) in joins.enumerated() {
            let join = originalJoin + offset
            let pivot = reach.samples[join].position
            let previous = recheck.last ?? 0
            let next = index + 1 < joins.count ? joins[index + 1] + offset : reach.samples.count - 1
            let extent = 8 / metresPerUnit
            var low = join, high = join
            while low > previous && simd_distance(reach.samples[low].position, pivot) < extent { low -= 1 }
            while high < next && simd_distance(reach.samples[high].position, pivot) < extent { high += 1 }
            guard low < join - 1, high > join + 1 else { recheck.append(join); continue }
            let start = reach.samples[low], end = reach.samples[high]
            let incoming = simd_normalize(pivot - start.position)
            let outgoing = simd_normalize(end.position - pivot)
            guard simd_dot(incoming, outgoing) < cos(Float.pi / 12) else { recheck.append(join); continue }
            let curve = (0...32).map { step -> SIMD2<Float> in
                let t = Float(step) / 32
                let a = start.position + (pivot - start.position) * t
                let b = pivot + (end.position - pivot) * t
                return a + (b - a) * t
            }
            guard curve.allSatisfy(withinCorridor) else { recheck.append(join); continue }
            let points = resample(curve, spacing: 2 / metresPerUnit)
            let replacement = points.indices.map { i -> RiverSample in
                if i == 0 { return start }
                if i == points.count - 1 { return end }
                let t = Float(i) / Float(points.count - 1)
                let p = points[i]
                let tangent = simd_normalize(points[i + 1] - points[i - 1])
                var sample = t < 0.5 ? start : end
                sample.position = p
                sample.bed = terrain.interpolatedHeight(x: p.x, z: p.y)
                sample.tangent = tangent
                sample.width = start.width + (end.width - start.width) * t
                sample.channelWidth = start.channelWidth + (end.channelWidth - start.channelWidth) * t
                let side = SIMD2(-tangent.y, tangent.x)
                for _ in 0..<10 {
                    let heights = [-1, -0.5, 0, 0.5, 1].map { fraction -> Float in
                        let q = p + side * (Float(fraction) * sample.channelWidth * 0.5)
                        return terrain.interpolatedHeight(x: q.x, z: q.y)
                    }
                    if heights.max()! - heights.min()! <= 1.5 / metresPerUnit { break }
                    let nextWidth = max(sample.channelWidth * 0.85, 4 / metresPerUnit)
                    if nextWidth >= sample.channelWidth { break }
                    sample.channelWidth = nextWidth
                }
                sample.bendLimit = .greatestFiniteMagnitude
                sample.bendInside = 0
                sample.cell = -1
                return sample
            }
            reach.samples.replaceSubrange(low...high, with: replacement)
            let last = low + replacement.count - 1
            offset += last - high
            recheck.append(contentsOf: low...last)
        }
        return recheck
    }
}
