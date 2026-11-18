import Foundation
import simd

enum RiverRoutingFixtures {
    static func run() -> Bool {
        let tree = RiverRouting.accumulate(receivers: [2, 2, 3, -1], land: [0, 1, 2, 3])
        guard tree.unprocessed == 0, tree.area == [1, 1, 3, 4] else {
            print("FAIL routing accumulation: contributing area lost"); return false
        }
        let cycle = RiverRouting.accumulate(receivers: [1, 0, -1], land: [0, 1, 2])
        guard cycle.unprocessed == 2 else { print("FAIL routing cycle detection"); return false }
        // Two nearby headwaters merge downstream. Thinning the weaker one
        // must remove its entire exclusive arm, including intermediate cells
        // that used to be retained as orphan junction starts. A distant third
        // source and both complete outlet paths must survive.
        let n = 8, a = 49, b = 50, c = 55
        var down = [Int](repeating: -1, count: n * n)
        for (i, d) in [(a, 41), (41, 33), (33, 34), (b, 42), (42, 34),
                       (34, 35), (c, 47), (47, 39), (39, 35), (35, 27),
                       (27, 19), (19, 11), (11, 3)] { down[i] = d }
        let paths = [a, 41, 33, b, 42, 34, c, 47, 39, 35, 27, 19, 11, 3]
        var channel = [Bool](repeating: false, count: n * n)
        for i in paths { channel[i] = true }
        var area = [Float](repeating: 4000, count: n * n)
        area[a] = 1300; area[b] = 1500; area[c] = 1600
        let selected = RiverRouting.select(channel: channel, receivers: down, area: area,
                                            size: n, cellSize: 100 / RiverNetwork.metresPerUnit)
        guard selected.sources == [c, b], [a, 41, 33].allSatisfy({ !selected.channel[$0] }),
              [b, 42, 34, c, 47, 39, 35, 27, 19, 11, 3].allSatisfy({ selected.channel[$0] }) else {
            print("FAIL source thinning: orphan arm or incomplete outlet path"); return false
        }
        area[a] = area[b]
        let tied = RiverRouting.select(channel: channel, receivers: down, area: area,
                                        size: n, cellSize: 100 / RiverNetwork.metresPerUnit)
        guard tied.sources == [c, a], !tied.channel[b], !tied.channel[42] else {
            print("FAIL deterministic source tie"); return false
        }
        let terrain = WorldGen.generate(seed: 6393821808673518700)
        let network = RiverNetwork.build(terrain).reaches
        let mesh = RiverSurface.build(terrain, network: network)
        let sources = network.filter { $0.upstream.isEmpty }
        for source in sources {
            guard let first = source.samples.first else { return false }
            let side = RiverChannel.sideVector(first)
            // Check the submitted cap/ribbon vertices, not the tapered input
            // channelWidth that the old minimum-width clamp ignored.
            for sign: Float in [-1, 1] {
                let expected = first.position + side * (sign * 0.15 / RiverNetwork.metresPerUnit)
                guard mesh.vertices.contains(where: {
                    simd_distance(SIMD2($0.position.x, $0.position.z), expected)
                        < 0.0001 / RiverNetwork.metresPerUnit // 0.1 mm
                }) else { print("FAIL submitted spring width: \(source.id)"); return false }
            }
        }
        // Two disjoint, very narrow ribbons cross one exact scanline; a
        // duplicate upward face must not increase the number of wet runs.
        var vertices: [Vertex] = [], indices: [UInt32] = []
        let metres = RiverNetwork.metresPerUnit
        for x: Float in [0, 20] {
            let base = UInt32(vertices.count)
            for (dx, z): (Float, Float) in [(-0.15, -10), (0.15, -10), (-0.15, 10), (0.15, 10)] {
                vertices.append(Vertex(position: SIMD3((x + dx) / metres, 100 / metres, z / metres),
                                       normal: SIMD3(0, 1, 0), rgb: SIMD3(repeating: 1)))
            }
            indices.append(contentsOf: [base, base + 2, base + 1, base + 1, base + 2, base + 3,
                                        base, base + 2, base + 1])
        }
        let ribbons = RiverSurface.Geometry(vertices: vertices, indices: indices, junctions: [], ribbonWidths: [])
        guard RiverMeshCrossings.maximum(ribbons, terrain: terrain) == 2 else {
            print("FAIL submitted wet-run union: narrow water or duplicate face miscounted"); return false
        }
        print("routing fixtures: area conservation, cycle detection, complete-path thinning, source tie: PASS")
        print("submitted spring tips: \(sources.count) sources, 0.30 m cap width: PASS")
        print("submitted wet-run fixture: two 0.30 m ribbons plus duplicate face: PASS")
        return true
    }
}
