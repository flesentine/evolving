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
        func samples(_ points: [SIMD2<Float>], width: Float) -> [RiverSample] {
            points.enumerated().map { i, p in
                let tangent = simd_normalize(points[min(i + 1, points.count - 1)] - points[max(i - 1, 0)])
                return RiverSample(position: p / RiverGraph.metresPerUnit, bed: 0.0994,
                    width: width / RiverGraph.metresPerUnit, tangent: tangent,
                    channelWidth: width / RiverGraph.metresPerUnit,
                    sourceWidthFactor: i == 0 ? 0.3 / width : 1)
            }
        }
        let covered = [
            RiverReach(id: 0, samples: samples([SIMD2(0,0), SIMD2(10,10), SIMD2(20,0)], width: 4),
                downstream: 2, isSource: true, firstCell: 0, lastCell: 2),
            RiverReach(id: 1, samples: samples([SIMD2(0,-50), SIMD2(0,0), SIMD2(20,0)], width: 10),
                downstream: 2, isSource: true, firstCell: 1, lastCell: 2),
            RiverReach(id: 2, samples: samples([SIMD2(20,0), SIMD2(40,0)], width: 12),
                upstream: [0,1], isMouth: true, firstCell: 2, lastCell: 3)]
        let pruned = RiverRouting.pruneCoveredSources(covered, area: [1300,2500,3800,3800])
        guard pruned.cells == [0], pruned.reaches.count == 2,
              pruned.reaches[0].firstCell == 1, pruned.reaches[0].downstream == 1,
              pruned.reaches[1].upstream == [0], pruned.reaches[1].downstream == nil else {
            print("FAIL covered-source thinning: exclusive loop or outlet path lost"); return false
        }
        print("covered-source fixture: hidden spring/exclusive loop removed, complete main path retained: PASS")
        var short = covered
        short[0].samples = samples([SIMD2(18,7), SIMD2(20,0)], width: 4)
        let shortResult = RiverRouting.pruneCoveredSources(short, area: [1300,2500,3800,3800])
        guard shortResult.cells == [0], shortResult.reaches.count == 2,
              shortResult.reaches[1].upstream == [0], shortResult.reaches[0].firstCell == 1 else {
            print("FAIL short spring: insufficient taper length or complete outlet path lost"); return false
        }
        print("7 m spring stub fixture: removed; downstream catchment and complete main path retained: PASS")
        let continued = RiverGraph.mergeContinuations(shortResult.reaches)
        guard continued.count == 1, continued[0].upstream.isEmpty, continued[0].downstream == nil,
              continued[0].firstCell == 1, continued[0].lastCell == 3,
              continued[0].samples.count == shortResult.reaches.reduce(0,{ $0+$1.samples.count })-1 else {
            print("FAIL obsolete junction collapse: complete path or endpoint provenance lost"); return false
        }
        print("obsolete junction fixture: one continuous reach, full source-to-outlet path and provenance retained: PASS")
        // A one-metre endpoint stamp formerly held a two-metre fall.
        // Verify the submitted row levels after grading, including fixed
        // spring and lake controls and the shared receiving endpoint.
        var graded = [RiverReach(id:0,samples:(0...100).map { i in
            RiverSample(position:SIMD2(Float(i)/RiverGraph.metresPerUnit,0),
                bed:99.4/RiverGraph.metresPerUnit,width:4/RiverGraph.metresPerUnit,
                tangent:SIMD2(1,0),channelWidth:4/RiverGraph.metresPerUnit,along:Float(i),
                waterOverride:Float(i == 100 ? 100 : 102)/RiverGraph.metresPerUnit)
        },downstream:1,isSource:true),
        RiverReach(id:1,samples:(0...10).map { i in
            RiverSample(position:SIMD2(Float(100+i)/RiverGraph.metresPerUnit,0),
                bed:99.4/RiverGraph.metresPerUnit,width:4/RiverGraph.metresPerUnit,
                tangent:SIMD2(1,0),channelWidth:4/RiverGraph.metresPerUnit,along:Float(i),
                waterOverride:100/RiverGraph.metresPerUnit)
        },upstream:[0],isMouth:true)]
        let ground = RiverEndpointValidation.fixtureTerrain()
        let originalLevels = graded.map { $0.samples.map { $0.waterOverride } }
        let beforeGrade = RiverGeometryChecks.maximumEdgeGrade(RiverSurface.build(ground,network:graded))
        RiverGraph.smoothWaterGrades(&graded,upstreamFirst:[0,1],fixed:[Set([0]),Set([10])])
        let afterGrade = RiverGeometryChecks.maximumEdgeGrade(RiverSurface.build(ground,network:graded))
        var profileGrade: Float = 0
        for r in graded.indices { for i in graded[r].samples.indices {
            guard graded[r].samples[i].waterOverride <= originalLevels[r][i] else { return false }
            if i > 0 {
                let a = graded[r].samples[i-1], b = graded[r].samples[i]
                profileGrade = max(profileGrade,abs(a.waterOverride-b.waterOverride)*RiverGraph.metresPerUnit/(b.along-a.along))
            }
        }}
        guard graded[0].samples[0].waterOverride == 102/RiverGraph.metresPerUnit,
              graded[1].samples.last!.waterOverride == 100/RiverGraph.metresPerUnit,
              graded[0].samples.last!.waterOverride == graded[1].samples[0].waterOverride,
              profileGrade <= 0.101, afterGrade < beforeGrade*0.25 else {
            print("FAIL approach grade: submitted \(beforeGrade) -> \(afterGrade), profile \(profileGrade)"); return false
        }
        print("submitted water grade fixture: \(beforeGrade) -> \(afterGrade) m/m (>4× reduction); 1:10 profile, fixed source/lake controls, no raising, connected seam: PASS")
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
