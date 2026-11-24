import Foundation
import simd

/// Checks supports and drive surfaces in the uploaded road mesh.
enum BridgeCheck {
    private static let metres = RiverNetwork.metresPerUnit
    private enum Failure: Error { case structure }

    private static func validate(_ scene: WorldScene, label: String) throws {
        guard let mesh = scene.roadMesh, let indexBuffer = mesh.indexBuffer else { throw Failure.structure }
        let verts = UnsafeBufferPointer(start: mesh.vertexBuffer.contents().assumingMemoryBound(to: Vertex.self),
                                        count: mesh.vertexCount)
        let faces = UnsafeBufferPointer(start: indexBuffer.contents().assumingMemoryBound(to: UInt32.self),
                                        count: mesh.indexCount)
        var crossingAtVertex: [Int: Int] = [:]
        var supports = 0, piers = 0, errors = 0
        for (i, bridge) in scene.roadBridges.enumerated() {
            for vertex in bridge.deckRows { crossingAtVertex[vertex] = i }
            let deck = bridge.deckRows.map { verts[$0].position.y }.min()!
            if bridge.foundations.count != 2 { errors += 1 }
            for support in bridge.foundations + bridge.piers {
                let corners = support.suffix(4).map { j in SIMD2(verts[j].position.x, verts[j].position.z) }
                let footing = support.map { verts[$0].position.y }.min()!
                let top = support.map { verts[$0].position.y }.max()!
                if corners.count != 4 || !corners.allSatisfy({
                    footing < scene.renderedTerrainHeight(at: $0) - 0.30 / metres
                }) || abs(deck - top) > 0.25 / metres { errors += 1 }
                if bridge.foundations.contains(support), scene.riverField.intersectsFootprint(corners) { errors += 1 }
            }
            supports += bridge.foundations.count
            piers += bridge.piers.count
        }
        var deckFaces = Array(repeating: 0, count: scene.roadBridges.count)
        var measuredWater = Set<Int>()
        var wetLaneSamples = 0
        var minimumClearance = Float.infinity
        for i in stride(from: 0, to: faces.count, by: 3) {
            let a = Int(faces[i]), b = Int(faces[i + 1]), c = Int(faces[i + 2])
            guard let bridge = crossingAtVertex[a], crossingAtVertex[b] == bridge,
                  crossingAtVertex[c] == bridge else { continue }
            deckFaces[bridge] += 1
            let road = [verts[a], verts[b], verts[c]]
            for water in scene.riverField.nearbyTriangles(road) where RiverPolygon.area(water) < 0 {
                let overlap = RiverGeometryChecks.intersection(road, water)
                guard abs(RiverPolygon.area(overlap)) > RiverPolygon.areaEpsilon else { continue }
                measuredWater.insert(bridge)
                for vertex in overlap {
                    let p = SIMD2(vertex.position.x, vertex.position.z)
                    let waterY = RiverChannel.Field.probe(water, p).water
                    minimumClearance = min(minimumClearance, (vertex.position.y - waterY) * metres)
                }
            }
        }
        for (i, crossing) in scene.roadBridges.enumerated()
            where deckFaces[i] != (crossing.deckRows.count / 5 - 1) * 8 || !measuredWater.contains(i) {
            errors += 1
        }
        for key in scene.bridgeDrivePaths.keys.sorted() {
            let route = scene.bridgeDrivePaths[key]!
            for distance in stride(from: Float(0), through: route.length, by: 0.75 / metres) {
                for forward in [true, false] {
                    let pose = route.pose(progress: distance / route.length, forward: forward).position
                    if let water = scene.riverField.waterLevel(at: SIMD2(pose.x, pose.z)) {
                        wetLaneSamples += 1
                        if (pose.y - water) * metres < 2.59 { errors += 1 }
                    }
                }
            }
        }
        print(String(format: "%@: %d spans, %d dry abutments, %d piers, %.3f m minimum deck clearance, %d uncovered wet strips, %d structure errors",
                     label, scene.roadBridges.count, supports, piers, minimumClearance, scene.unbridgedRoadPoints.count, errors))
        for p in scene.unbridgedRoadPoints.prefix(8) {
            print(String(format: "unbridged at (%.3f, %.3f) m", p.x * metres, p.y * metres))
        }
        print("verified \(wetLaneSamples) vehicle lane positions over water")
        guard !scene.roadBridges.isEmpty, minimumClearance >= 2.59, errors == 0,
              scene.unbridgedRoadPoints.isEmpty else { throw Failure.structure }
    }

    static func run(directory: URL, seed: UInt64, year: Float) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let terrain = WorldGen.generate(seed: seed)
        var simulation = Simulation(seed: seed, terrain: terrain)
        simulation.advance(to: year)
        let renderer = try Renderer(context: MetalContext(), terrain: terrain,
            colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
        renderer.hourOverride = 10
        renderer.seasonOverride = 0.7
        renderer.weatherOverride = 0
        renderer.snowOverride = false
        renderer.updateScene(simulation)
        try validate(renderer.scene, label: "seed \(seed), year \(year)")

        // Compare the same crossing and camera with the earlier renderer.
        let crossings = renderer.scene.roadBridges.sorted {
            $0.deckRows.count == $1.deckRows.count ? $0.deckRows.lowerBound < $1.deckRows.lowerBound :
                $0.deckRows.count > $1.deckRows.count
        }
        var cameras = ""
        for (index, crossing) in crossings.prefix(3).enumerated() {
            let p = crossing.centre
            let direction = crossing.direction
            let side = SIMD2(-direction.y, direction.x)
            let offset = side * (35 / metres) - direction * (22 / metres)
            let eyeXZ = p + offset
            let ground = renderer.scene.renderedTerrainHeight(at: eyeXZ)
            let eye = SIMD3(eyeXZ.x, max(crossing.waterLevel + 26 / metres, ground + 24 / metres), eyeXZ.y)
            let target = SIMD3(p.x, crossing.waterLevel + 2 / metres, p.y)
            let camera = Renderer.Camera(eye: eye, target: target, fov: 44)
            renderer.cameraOverride = camera
            let values = [eye.x, eye.y, eye.z, target.x, target.y, target.z, camera.fov]
            cameras += values.map { String($0) }.joined(separator: ",") + "\n"
            _ = try Snapshot.write(renderer: renderer, width: 1200, height: 800, time: 0,
                                   to: directory.appendingPathComponent("crossing-\(index).png"))
        }
        try cameras.write(to: directory.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
    }

    static func fixtures() throws {
        var terrain = WorldGen.generate(seed: 1, size: 65)
        terrain.height = Array(repeating: 108 / metres, count: terrain.height.count)
        terrain.lakeWater = []
        let widths: [Float] = [3, 6, 14, 34]
        let reaches = widths.enumerated().map { i, width -> RiverReach in
            let x = (Float(i) * 210 - 316) / metres
            let samples = (-20...20).map { row in
                RiverSample(position: SIMD2(x, Float(row) * 6 / metres),
                            bed: 99.4 / metres, width: width / metres, tangent: SIMD2(0, 1),
                            channelWidth: width / metres, along: Float(row + 20) * 6,
                            waterOverride: 100 / metres)
            }
            return RiverReach(id: i, samples: samples, isSource: true, isMouth: true)
        }
        terrain.riverGraph = RiverGraph(reaches: reaches, diagnostics: RiverDiagnostics())
        let scene = try WorldScene(context: MetalContext(), terrain: terrain)
        var roads = widths.indices.map { i -> RoadBuilder.Segment in
            let x = Float(i) * 210 - 316
            let lateral: Float = i.isMultiple(of: 2) ? 1.31 : 14.27
            return RoadBuilder.Segment(from: 0, to: 1,
                points: [SIMD2(x - 49, -lateral) / metres, SIMD2(x + 51, lateral) / metres], built: 0)
        }
        // A bank road within two metres of the nominal shoreline stays dry.
        let shoreX: Float = -316 + 1.5 + 2.2
        roads.append(RoadBuilder.Segment(from: 0, to: 1,
            points: [SIMD2(shoreX, -48) / metres, SIMD2(shoreX, 48) / metres], built: 0))
        roads.append(RoadBuilder.Segment(from: 2, to: 3,
            points: [SIMD2(-348, 33) / metres, SIMD2(-316, 35) / metres], built: 0,
            trailingApproach: [SIMD2(-311, 35) / metres, SIMD2(-302, 35) / metres]))

        for era: Era in [.medieval, .industrial, .modern] {
            let style = Renderer.roadStyle(for: era)
            try scene.rebuildRoads(roads, color: style.color, bridgeColor: style.bridge,
                marking: style.marking, width: style.width, surface: RoadSurface.forRoad(era),
                bridge: BridgeStyle.forEra(era))
            try validate(scene, label: "controlled \(era.name)")
            guard scene.roadBridges.count == widths.count + 1, scene.unbridgedRoadPoints.isEmpty,
                  scene.roadBridges.contains(where: { !$0.piers.isEmpty }) else { throw Failure.structure }
        }

        let style = Renderer.roadStyle(for: .bronze)
        try scene.rebuildRoads(roads, color: style.color, bridgeColor: style.bridge,
            marking: style.marking, width: style.width, surface: .dirt, bridge: .ford)
        guard scene.roadBridges.isEmpty, scene.roadMesh != nil else { throw Failure.structure }
        print("PASS 15 raised crossings at 3–34 m widths, including oblique and trimmed approaches, dry-bank controls and separate early fords")
    }
}
