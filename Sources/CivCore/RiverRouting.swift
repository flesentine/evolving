import Foundation
import simd

/// Deterministic graph operations used before any rendered reach is created.
enum RiverRouting {
    /// A catchment start already covered by another selected channel is not
    /// a visible spring. Thin that start and reconstruct complete retained
    /// paths, rather than drawing an artificial loop out of and into water.
    static func pruneCoveredSources(_ input: [RiverReach], area: [Float]) -> (reaches: [RiverReach], cells: [Int]) {
        func half(_ s: RiverSample) -> Float {
            RiverGraph.channelHalfWidth(s)
        }
        func sides(_ s: RiverSample) -> (SIMD2<Float>, SIMD2<Float>) {
            let direction = s.junctionTangent ?? s.tangent
            let side = SIMD2(-direction.y, direction.x) * half(s)
            return (s.position - side, s.position + side)
        }
        func contains(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
            func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
            guard cross(b-a, c-a) != 0 else { return false }
            let d = [cross(b-a, p-a), cross(c-b, p-b), cross(a-c, p-c)]
            return d.allSatisfy { $0 >= 0 } || d.allSatisfy { $0 <= 0 }
        }
        let sources = input.indices.filter { input[$0].upstream.isEmpty }
        var removed = Set<Int>()
        for source in sources {
            // A selected catchment may begin only one routing cell before a
            // larger channel. It cannot form a separate spring and develop the
            // existing 55 m taper before joining. Keep its area in the shared
            // drainage graph, but do not draw this bank-runoff stub as a river.
            let samples = input[source].samples
            let lengthMetres = zip(samples, samples.dropFirst()).reduce(Float(0)) {
                $0 + simd_distance($1.0.position, $1.1.position) * RiverGraph.metresPerUnit
            }
            if input[source].downstream != nil && lengthMetres < 55 {
                removed.insert(source)
                continue
            }
            let tip = sides(input[source].samples[0])
            for other in input.indices where other != source {
                let s = input[other].samples
                var left = false, right = false
                for i in 1..<s.count {
                    let (a,b) = sides(s[i-1]), (c,d) = sides(s[i])
                    left = left || contains(tip.0,a,b,c) || contains(tip.0,b,d,c)
                    right = right || contains(tip.1,a,b,c) || contains(tip.1,b,d,c)
                    if left && right { removed.insert(source); break }
                }
                if removed.contains(source) { break }
            }
        }
        func outlet(_ id: Int) -> Int {
            var current = id, steps = 0
            while let d = input[current].downstream {
                current = d; steps += 1
                precondition(steps <= input.count, "River reach cycle during source thinning")
            }
            return current
        }
        let outlets = Set(sources.map(outlet)).sorted()
        for end in outlets {
            let group = sources.filter { outlet($0) == end }
            if group.allSatisfy({ removed.contains($0) }), let keep = group.sorted(by: {
                let a = area[input[$0].firstCell], b = area[input[$1].firstCell]
                return a == b ? input[$0].firstCell < input[$1].firstCell : a > b
            }).first { removed.remove(keep) }
        }
        var retained = Set<Int>()
        for source in sources where !removed.contains(source) {
            var cursor: Int? = source
            while let id = cursor, retained.insert(id).inserted { cursor = input[id].downstream }
        }
        let ids = input.indices.filter { retained.contains($0) }
        let mapping = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        let result = ids.map { id -> RiverReach in
            var r = input[id]; r.id = mapping[id]!
            r.upstream = r.upstream.compactMap { mapping[$0] }; r.downstream = r.downstream.flatMap { mapping[$0] }
            r.isSource = r.upstream.isEmpty; return r
        }
        return (result, sources.filter { removed.contains($0) }.map { input[$0].firstCell })
    }

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
        let spacing = 180 / RiverGraph.metresPerUnit // existing headwater spacing, 180 m
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
