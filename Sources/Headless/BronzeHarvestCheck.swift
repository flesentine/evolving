import Foundation
import simd

enum BronzeHarvestCheck {
    private static let metres = RiverGraph.metresPerUnit

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }

    static func run(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let matrix: [(UInt64, [Float])] = [(8, [810, 1450, 1990]), (1, [1450]), (10, [1450])]
        for (seed, years) in matrix {
            let terrain = WorldGen.generate(seed: seed)
            var sim = Simulation(seed: seed, terrain: terrain)
            let renderer = try Renderer(context: MetalContext(), terrain: terrain,
                colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
            for year in years {
                sim.advance(to: year)
                renderer.updateScene(sim)
                let fingerprint = try geometry(renderer, seed: seed, year: year)
                if seed == 8 && year == 1450 {
                    try weather(renderer, directory: directory)
                    renderer.updateScene(sim)
                    guard try geometry(renderer, seed: seed, year: year, report: false) == fingerprint
                    else { throw Failure("Rebuild changes submitted harvest geometry") }
                }
            }
            if seed == 8 {
                sim.advance(to: 2010)
                renderer.updateScene(sim)
                guard renderer.scene.cerealMesh == nil, renderer.bronzeHarvest.isEmpty,
                      renderer.submittedHarvest(.wheat).isEmpty,
                      !renderer.submittedBuildings().contains(where: {
                          $0.path == BronzeHarvest.hearthPath || $0.path == BronzeHarvest.potPath
                      }) else { throw Failure("Bronze harvest geometry persisted into Classical") }
            }
        }
        print("PASS exact rebuild and Classical transition")
    }

    private static func geometry(_ renderer: Renderer, seed: UInt64, year: Float,
                                 report: Bool = true) throws -> [SIMD4<Float>] {
        let stations = renderer.bronzeHarvest
        let scene = renderer.scene
        guard let mesh = scene.cerealMesh, let ib = mesh.indexBuffer, !stations.isEmpty,
              Set(stations.map(\.court.town)).count == stations.count
        else { throw Failure("Expected one or more unique harvest stations for seed \(seed) year \(year)") }
        let blockers = [scene.activityRoads, scene.activityStreets, scene.riverBankFootprint,
                        FieldSurface.Mask(mesh: scene.bronzeAccessMesh), FieldSurface.Mask(mesh: scene.fieldMesh)]
        var reserves = FieldSurface.Mask()
        var fixtures: [(String, InstanceData)] = []
        for entry in renderer.submittedBuildings() {
            if entry.path == BronzeHarvest.hearthPath || entry.path == BronzeHarvest.potPath {
                fixtures.append(entry)
            } else {
                reserves.insertFootprint(RiverPlacement.transformed(
                    RiverPlacement.authoredBounds(entry.path), by: entry.instance.model))
            }
        }
        for pen in scene.bronzePens {
            for footprint in BronzeEnclosures.footprints(pen) { reserves.insertFootprint(footprint) }
        }
        for routine in renderer.bronzePeople { reserves.insertFootprint(routine.clearance) }
        func clear(_ area: [SIMD2<Float>]) -> Bool {
            !scene.riverField.intersectsFootprint(area) && !reserves.intersectsFootprint(area)
                && !blockers.contains { $0.intersectsFootprint(area) }
                && area.allSatisfy { !scene.terrain.isWater(x: $0.x, z: $0.y) }
        }
        var fingerprint: [SIMD4<Float>] = []
        let soil = FieldSurface.Mask(mesh: mesh)
        let verts = mesh.vertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
        let indices = ib.contents().assumingMemoryBound(to: UInt32.self)
        for i in stride(from: 0, to: mesh.indexCount, by: 3) {
            let triangle = (0..<3).map { verts[Int(indices[i + $0])].position }
            let centre = triangle.reduce(.zero, +) / 3
            guard clear(triangle.map { SIMD2($0.x, $0.z) }),
                  abs(centre.y - scene.renderedTerrainHeight(at: SIMD2(centre.x, centre.z))
                      - FieldSurface.cropLift) <= 0.003 / metres
            else { throw Failure("Submitted cereal triangle intersects a footprint or loses terrain support") }
            fingerprint += triangle.map { SIMD4($0, 1) }
        }
        var cropCount = 0
        for part in [NeolithicHarvest.Part.wheat, .barley] {
            let crop = renderer.submittedHarvest(part)
            guard crop.count >= stations.count * 25 else { throw Failure("Too few submitted \(part.rawValue) tufts") }
            let bounds = RiverPlacement.authoredBounds(part.path)
            for item in crop {
                let p = item.model.columns.3
                let area = RiverPlacement.transformed(bounds, by: item.model)
                guard soil.height(at: SIMD2(p.x, p.z)) == p.y, area.allSatisfy(soil.covers)
                else { throw Failure("Submitted \(part.rawValue) is off its seedbed") }
                fingerprint.append(contentsOf: [item.model.columns.0, item.model.columns.1, item.model.columns.2, p])
            }
            cropCount += crop.count
        }
        fixtures += renderer.submittedHarvest(.sheaves).map { (NeolithicHarvest.Part.sheaves.path, $0) }
        guard fixtures.count == stations.count * 3 else { throw Failure("Incomplete submitted hearth, pot, or bundles") }
        for (path, item) in fixtures {
            let p = item.model.columns.3
            let area = RiverPlacement.transformed(RiverPlacement.authoredBounds(path), by: item.model)
            guard clear(area), !soil.intersectsFootprint(area),
                  abs(p.y - scene.renderedTerrainHeight(at: SIMD2(p.x, p.z))) < 0.001 / metres,
                  BronzeHome.foundationSamples(area).allSatisfy({
                      abs(p.y - scene.renderedTerrainHeight(at: $0)) < 0.081 / metres
                  }) else { throw Failure("Submitted \(path) intersects a footprint or loses support") }
            reserves.insertFootprint(area)
            fingerprint.append(contentsOf: [item.model.columns.0, item.model.columns.1, item.model.columns.2, p])
        }
        if report {
            print("PASS seed \(seed) year \(Int(year)): \(stations.count) stations, \(cropCount) tufts, \(mesh.indexCount / 3) soil triangles")
        }
        return fingerprint
    }

    private static func weather(_ renderer: Renderer, directory: URL) throws {
        let station = renderer.bronzeHarvest[0]
        let centre = (station.plots[0].centre + station.plots[1].centre) * 0.5
        let outward = station.plots[0].along
        let hearth = station.hearth.model.columns.3
        let target = centre - outward * (1.6 / metres)
        let eye = target + (outward * 12.5 + station.plots[0].across * 2.0) / metres
        let ground = renderer.scene.renderedTerrainHeight(at: target)
        var view = RiverReviewView(seed: 8, year: 1450, hour: 13.25, season: 0.68,
            precipitation: 0, snow: false, animationTime: 26,
            eye: [eye.x, ground + 10 / metres, eye.y], target: [target.x, ground, target.y],
            fov: 43, width: 1440, height: 900, provenance: "BRZ-08 saved Bronze court harvest")
        func capture(_ label: String, _ record: RiverReviewView) throws -> Data {
            NeolithicReference.apply(record, to: renderer)
            let url = directory.appendingPathComponent(label + ".png")
            try record.write(to: directory.appendingPathComponent(label + ".json"))
            _ = try Snapshot.write(renderer: renderer, width: record.width, height: record.height,
                                   time: record.animationTime, to: url)
            return try Data(contentsOf: url)
        }
        _ = try capture("daylight", view)
        guard renderer.submittedHearthLights.isEmpty else { throw Failure("Hearth spills daylight glow") }
        view.hour = 18.65
        let dusk = try capture("dusk", view)
        let lights = renderer.submittedHearthLights
        let smoke = renderer.submittedHearthSmoke()
        guard lights.contains(where: { $0.x == hearth.x && $0.z == hearth.z && $0.w > 0 }),
              smoke.contains(where: {
                  let p = $0.model.columns.3
                  return $0.color.w > 0 && p.y > hearth.y
                      && simd_distance(SIMD2(p.x, p.z), SIMD2(hearth.x, hearth.z)) < 2 / metres
              }) else { throw Failure("Reference dusk camera has no submitted fire light or plume") }
        guard try capture("dusk-replay", view) == dusk,
              renderer.submittedHearthLights == lights,
              renderer.submittedHearthSmoke().map(\.model) == smoke.map(\.model)
        else { throw Failure("Saved dusk frame is not deterministic") }
        view.precipitation = 0.70
        _ = try capture("rain", view)
        guard renderer.submittedHearthLights.count == lights.count,
              zip(renderer.submittedHearthLights, lights).allSatisfy({ $0.w < $1.w }),
              renderer.submittedHearthSmoke().count == smoke.count,
              zip(renderer.submittedHearthSmoke(), smoke).allSatisfy({ $0.color.w <= $1.color.w })
        else { throw Failure("Rain does not dampen the working hearth") }
        view.precipitation = 0
        view.animationTime += 0.87
        _ = try capture("dusk-later", view)
        guard renderer.submittedHearthLights != lights,
              renderer.submittedHearthSmoke().map(\.model) != smoke.map(\.model)
        else { throw Failure("The working hearth does not flicker or drift") }
        print("PASS submitted dusk light and smoke, exact frame replay, flicker, plume drift and rain damping")
    }
}
