import Foundation
import simd

extension RiverGraph {
    /// Source thinning can remove an arm of an old confluence. Its remaining
    /// one-in/one-out node is now an ordinary channel, not a junction patch.
    /// Reconnect its complete sample path before solving profiles and widths.
    static func mergeContinuations(_ input: [RiverReach]) -> [RiverReach] {
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
}
