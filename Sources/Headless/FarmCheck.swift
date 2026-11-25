import Foundation
import simd

/// Read the same field, road and terrain buffers that the renderer draws.
enum FarmCheck {
    private enum Failure: Error { case geometry }
    private static let metres = RiverGraph.metresPerUnit

    private static func validate(_ scene: WorldScene, label: String, checkParcelOverlaps: Bool = false) throws -> FieldSurface.Mask {
        guard let mesh = scene.fieldMesh, let indexBuffer = mesh.indexBuffer else { throw Failure.geometry }
        let vertices = mesh.vertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
        let indices = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        let roads = FieldSurface.Mask(mesh: scene.roadMesh)
        let streets = FieldSurface.Mask(mesh: scene.streetMesh)
        var parcels = FieldSurface.Mask()
        var heightError: Float = 0
        var failures = 0
        var area: Double = 0, roadOverlap: Double = 0, wetOverlap: Double = 0, parcelOverlap: Double = 0
        for i in stride(from: 0, to: mesh.indexCount, by: 3) {
            let triangle = (0..<3).map { vertices[Int(indices[i + $0])] }
            let faceArea = RiverPolygon.area(triangle)
            if faceArea >= -RiverPolygon.areaEpsilon { failures += 1 }
            area += abs(faceArea)
            let points = triangle.map(\.position)
            let centre = (points[0] + points[1] + points[2]) / 3
            for p in points + [centre, (points[0] + points[1]) * 0.5, (points[1] + points[2]) * 0.5,
                               (points[2] + points[0]) * 0.5] {
                let soil = scene.renderedTerrainHeight(at: SIMD2(p.x, p.z))
                heightError = max(heightError, abs(p.y - soil - FieldSurface.cropLift) * metres)
                if soil < 0.24 / metres { failures += 1 }
            }
            func overlap(_ obstacles: [[Vertex]]) -> Double {
                obstacles.reduce(0) {
                    $0 + abs(RiverPolygon.area(RiverGeometryChecks.intersection(triangle, $1)))
                        * Double(metres) * Double(metres)
                }
            }
            roadOverlap += overlap(roads.nearby(triangle) + streets.nearby(triangle))
            wetOverlap += overlap(scene.riverField.nearbyTriangles(triangle).filter {
                RiverPolygon.area($0) < 0 && RiverPolygon.overlaps(triangle, $0)
            })
            if checkParcelOverlaps { parcelOverlap += overlap(parcels.nearby(triangle)) }
            parcels.insert(triangle)
        }
        print(String(format: "%@: %d triangles, %.1f m² of crops, max soil error %.3f mm, overlaps (road %.6f, river %.6f, parcel %.6f m²), %d invalid",
                     label, mesh.indexCount / 3, area * Double(metres) * Double(metres),
                     heightError * 1000, roadOverlap, wetOverlap, parcelOverlap, failures))
        guard heightError < 0.002, roadOverlap < 0.02, wetOverlap < 0.02,
              parcelOverlap < 0.02, failures == 0 else { throw Failure.geometry }
        return parcels
    }

    static func fixtures() throws {
        var terrain = WorldGen.generate(seed: 1, size: 65)
        for z in 0..<terrain.size {
            for x in 0..<terrain.size {
                terrain.height[terrain.index(x, z)] = 27 / metres + terrain.worldX(x) * 0.18
            }
        }
        terrain.lakeWater = []
        let samples = (-20...20).map { i in
            RiverSample(position: SIMD2(1.37, Float(i) * 5) / metres,
                        bed: 19.4 / metres, width: 4 / metres, tangent: SIMD2(0, 1),
                        channelWidth: 4 / metres, along: Float(i + 20) * 5, waterOverride: 20 / metres)
        }
        let reach = RiverReach(id: 0, samples: samples, isSource: true, isMouth: true)
        terrain.riverGraph = RiverGraph(reaches: [reach], diagnostics: RiverDiagnostics())
        let scene = try WorldScene(context: MetalContext(), terrain: terrain)
        let road = RoadBuilder.Segment(from: 0, to: 1,
            points: [SIMD2(11.31, -45) / metres, SIMD2(11.31, 45) / metres], built: 0)
        try scene.rebuildRoads([road], color: SIMD3(repeating: 0.33), bridgeColor: SIMD3(repeating: 0.42),
                               marking: nil, width: 3.6 / metres, surface: .asphalt, bridge: .concrete)

        func plot(_ x: Float, _ z: Float, width: Float, depth: Float, rotation: Float) -> InstanceData {
            let center = SIMD2(x, z) / metres
            let y = scene.terrain.interpolatedHeight(x: center.x, z: center.y)
            return InstanceData(model: translation(SIMD3(center.x, y, center.y))
                * rotationY(rotation) * scaleMatrix(SIMD3(width, 0.7, depth) / metres),
                color: SIMD4(0.47, 0.41, 0.26, 0))
        }
        let first = plot(0.19, -0.44, width: 42, depth: 25, rotation: 0.13)
        let second = plot(9, 7, width: 29, depth: 17, rotation: -0.27)
        let oldOnSlope = plot(119, -45, width: 35, depth: 22, rotation: 0)
        try scene.rebuildFields([first, second, oldOnSlope])
        let coverage = try validate(scene, label: "controlled slope, overlapping plots, road and narrow river",
                                    checkParcelOverlaps: true)

        func planted(_ x: Float, _ z: Float) -> Bool {
            let p = SIMD2(x, z) / metres
            let r: Float = 0.02 / metres
            let query = [p + SIMD2(-r, -r), p + SIMD2(r, -r), p + SIMD2(r, r), p + SIMD2(-r, r)].map {
                Vertex(position: SIMD3($0.x, 0, $0.y), normal: SIMD3(0, 1, 0), rgb: .zero)
            }
            return coverage.nearby(query).contains {
                abs(RiverPolygon.area(RiverGeometryChecks.intersection(query, $0))) > RiverPolygon.areaEpsilon
            }
        }
        let westBank = (-18 ... -12).contains { planted(Float($0), 2) }
        let eastBank = (15...18).contains { planted(Float($0), 2) }
        let wetClear = scene.riverField.waterLevel(at: SIMD2(1.37, 0) / metres) != nil && !planted(1.37, 0)
        let roadClear = !planted(11.31, 0)
        print("controlled coverage: west bank \(westBank), east bank \(eastBank), wet lane clear \(wetClear), dry road clear \(roadClear)")
        guard westBank, eastBank, wetClear, roadClear, planted(105, -45), planted(134, -45) else {
            throw Failure.geometry
        }
        let oldPlane = oldOnSlope.model.columns.3.y + 0.75 / metres
        let west = scene.renderedTerrainHeight(at: SIMD2(105, -45) / metres)
        let east = scene.renderedTerrainHeight(at: SIMD2(134, -45) / metres)
        guard oldPlane - west > 0.5 / metres, east - oldPlane > 0.5 / metres else { throw Failure.geometry }
        print(String(format: "PASS controlled fixture: old flat top floats %.2f m on the west and sinks %.2f m on the east; new plots cover both dry sides and keep road and river clear",
                     (oldPlane - west) * metres, (east - oldPlane) * metres))
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
        let scene = renderer.scene
        let coverage = try validate(scene, label: "seed \(seed), year \(year)", checkParcelOverlaps: true)

        let plots = CityBuilder.build(settlements: simulation.settlements, era: simulation.era,
            year: simulation.year, terrain: scene.terrain, seed: seed, riverField: scene.riverField).fields
        let positions = plots.map { SIMD2($0.model.columns.3.x, $0.model.columns.3.z) }
        let slopes = positions.map { simd_length(scene.terrain.gradientAt(x: $0.x, z: $0.y)) }
        let largeFields = plots.indices.filter { i in
            let p = positions[i], r: Float = 3 / metres
            let a = simd_length(plots[i].model.columns.0), b = simd_length(plots[i].model.columns.2)
            guard a >= 9 / metres, b >= 9 / metres else { return false }
            let q = [p + SIMD2(-r, -r), p + SIMD2(r, -r), p + SIMD2(r, r), p + SIMD2(-r, r)].map {
                Vertex(position: SIMD3($0.x, 0, $0.y), normal: SIMD3(0, 1, 0), rgb: .zero)
            }
            let covered = coverage.nearby(q).reduce(0) {
                $0 + abs(RiverPolygon.area(RiverGeometryChecks.intersection(q, $1)))
            }
            return covered > 24 / pow(Double(metres), 2)
        }
        let hillside = largeFields.filter { slopes[$0] <= 0.48 }.max { slopes[$0] < slopes[$1] }
            ?? largeFields.first
        let nearbyWater = largeFields.filter {
            scene.riverField.isNearWater(at: positions[$0], margin: 27 / metres)
        }
        guard let hillside else { throw Failure.geometry }
        let corners = [hillside, nearbyWater.first ?? largeFields[0]]
        var records = ""
        for (i, index) in corners.enumerated() {
            let p = positions[index]
            let ground = scene.renderedTerrainHeight(at: p)
            let offset: SIMD2<Float> = i == 0 ? SIMD2(34, -40) / metres : SIMD2(-22, 22) / metres
            let eyeXZ = p + offset
            let eyeY = max(ground, scene.renderedTerrainHeight(at: eyeXZ)) + (i == 0 ? 30 : 88) / metres
            let eye = SIMD3(eyeXZ.x, eyeY, eyeXZ.y), target = SIMD3(p.x, ground, p.y)
            let camera = Renderer.Camera(eye: eye, target: target, fov: 48)
            renderer.cameraOverride = camera
            _ = try Snapshot.write(renderer: renderer, width: 1400, height: 900, time: 0,
                                   to: directory.appendingPathComponent("field-\(i).png"))
            records += [eye.x, eye.y, eye.z, target.x, target.y, target.z, camera.fov]
                .map { String($0) }.joined(separator: ",") + "\n"
        }
        try records.write(to: directory.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
    }
}
