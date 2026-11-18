import Foundation
import simd

/// Deterministic graph operations used before any rendered reach is created.
enum RiverRouting {
    static func accumulate(receivers: [Int], land: [Int])
        -> (area: [Float], order: [Int], unprocessed: Int) {
        var pending = [Int](repeating: 0, count: receivers.count)
        for i in land where receivers[i] >= 0 { pending[receivers[i]] += 1 }
        var area = [Float](repeating: 0, count: receivers.count)
        for i in land { area[i] = 1 }
        var queue = land.filter { pending[$0] == 0 }
        var processed = [Bool](repeating: false, count: receivers.count)
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            processed[i] = true
            let d = receivers[i]
            if d >= 0 {
                area[d] += area[i]
                pending[d] -= 1
                if pending[d] == 0 { queue.append(d) }
            }
        }
        return (area, queue, land.reduce(0) { $0 + (processed[$1] ? 0 : 1) })
    }

    /// Thin headwaters, then reconstruct the union of their complete outlet
    /// paths. Keeping old junction starts after removing sources leaves orphan
    /// channel fragments, which acquire artificial new headwaters downstream.
    static func select(channel: [Bool], receivers: [Int], area: [Float],
                       size: Int, cellSize: Float) -> (channel: [Bool], sources: [Int]) {
        var incoming = [Int](repeating: 0, count: channel.count)
        for i in channel.indices where channel[i] && receivers[i] >= 0 && channel[receivers[i]] {
            incoming[receivers[i]] += 1
        }
        let candidates = channel.indices.filter { channel[$0] && incoming[$0] == 0 && receivers[$0] >= 0 }
            .sorted { area[$0] == area[$1] ? $0 < $1 : area[$0] > area[$1] }
        let spacing = 180 / RiverNetwork.metresPerUnit // existing headwater spacing, 180 m
        func point(_ i: Int) -> SIMD2<Float> { SIMD2(Float(i % size), Float(i / size)) * cellSize }
        var sources: [Int] = []
        for i in candidates where sources.allSatisfy({ simd_distance(point(i), point($0)) > spacing }) {
            sources.append(i)
        }
        var selected = [Bool](repeating: false, count: channel.count)
        for source in sources {
            var i = source
            while i >= 0 && channel[i] && !selected[i] {
                selected[i] = true
                i = receivers[i]
            }
        }
        return (selected, sources)
    }
}
