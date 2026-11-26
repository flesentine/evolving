import Foundation
import simd

enum NeolithicBarrowCheck {
    private static let metres = RiverGraph.metresPerUnit

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func run(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = try MetalContext()
        let seed: UInt64 = 1
        let terrain = WorldGen.generate(seed: seed)
        var sim = Simulation(seed: seed, terrain: terrain)
        let renderer = try Renderer(context: context, terrain: terrain,
                                    colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
        for year: Float in [599, 600, 720, 799.5, 800] {
            sim.advance(to: year)
            renderer.updateScene(sim)
            let batch = renderer.submittedBarrow()
            if year == 599 || year == 800 {
                guard batch.instances.isEmpty, renderer.neolithicBarrow == nil else {
                    throw Failure("Year \(year): long barrow outside the late-Neolithic window")
                }
                print("PASS year \(year): no long barrow submitted")
                continue
            }
            guard let barrow = renderer.neolithicBarrow else {
                guard year != 600, batch.instances.isEmpty else {
                    throw Failure("Year \(year): unexpected empty placement or stale Metal instance")
                }
                print("PASS year \(year): no eligible site on the current settlement layout")
                continue
            }
            guard let clearance = renderer.neolithicHerdClearance,
                  batch.instances.map(\.model) == [barrow.instance.model], !batch.vertices.isEmpty else {
                throw Failure("Year \(year): expected one long barrow in the production Metal batch")
            }
            let scene = renderer.scene
            let origin = barrow.instance.model.columns.3
            let point = SIMD2(origin.x, origin.z)
            let nearest = sim.settlements.filter(\.isAlive).min {
                simd_distance_squared(point, SIMD2($0.x, $0.z)) < simd_distance_squared(point, SIMD2($1.x, $1.z))
            }
            let town = SIMD2(barrow.settlement.x, barrow.settlement.z)
            guard nearest?.id == barrow.settlement.id, simd_distance(point, town) * metres >= 71,
                  min(barrow.shoulderDrops.x, barrow.shoulderDrops.y) >= 0.7,
                  clearance.allows(barrow.footprint, in: scene),
                  !scene.riverField.intersectsFootprint(barrow.footprint, margin: 2 / metres),
                  renderer.neolithicHerds.allSatisfy({ herd in
                     !RiverPlacement.rectanglesOverlap(barrow.footprint, herd.route.envelope)
                  }) else { throw Failure("Year \(year): ridge, hamlet or footprint validation failed") }

            let model = batch.instances[0].model
            let x = simd_normalize(NeolithicPeople.xz(model.columns.0))
            let z = SIMD2(-x.y, x.x)
            let shoulders = [point - x * (18 / metres), point + x * (18 / metres)]
            guard shoulders.allSatisfy({ (origin.y - scene.renderedTerrainHeight(at: $0)) * metres >= 0.65 }),
                  simd_dot(z, town - point) >= -0.1 / metres else { throw Failure("Ridge or entrance is misaligned") }
            var footings = 0
            for vertex in batch.vertices {
                let p = model * SIMD4(vertex.position, 1)
                let xz = NeolithicPeople.xz(p)
                guard !scene.terrain.isWater(x: xz.x, z: xz.y),
                      scene.renderedTerrainHeight(at: xz) > 0,
                      scene.riverField.waterLevel(at: xz) == nil else { throw Failure("Submitted mound reaches wet ground") }
                if vertex.position.y <= -0.58 {
                    footings += 1
                    guard (scene.renderedTerrainHeight(at: xz) - p.y) * metres >= 0.025 else {
                        throw Failure("A submitted footing is exposed")
                    }
                }
            }
            guard footings > 0 else { throw Failure("The submitted mesh has no footing") }
            print("PASS year \(year): one mound \(Int(simd_distance(point, town) * metres)) m from \(barrow.settlement.name), ridge drops \(barrow.shoulderDrops), \(footings) buried footing vertices")
            if year == 600 {
                let late = NeolithicBarrow.place(year: 799.5, in: scene, settlements: sim.settlements,
                                                clearance: clearance, herds: renderer.neolithicHerds)
                guard late?.instance.model == model else {
                    throw Failure("A qualified site was rejected before the Bronze Age boundary")
                }
                print("PASS identical eligible terrain still places its barrow at fractional year 799.5")
                renderer.updateScene(sim)
                guard renderer.submittedBarrow().instances.map(\.model) == [model] else {
                    throw Failure("Late-Neolithic placement changed when the scene was rebuilt")
                }
                print("PASS deterministic rebuild of the submitted instance")
                try render(directory: directory, renderer: renderer, barrow: barrow, seed: seed, year: year)
            }
        }

        // A raised, entirely dry plateau surrounded by the sea, with a live
        // settlement at the centre and ample unoccupied land around it.
        let size = 65
        let count = size * size
        let heights: [Float] = (0..<count).map { cell in
            let distance = simd_length(SIMD2(Float(cell % size - 32), Float(cell / size - 32)))
            return max(-10, min(30, (23 - distance) * 10)) / metres
        }
        let zero = [Float](repeating: 0, count: count)
        let island = Terrain(size: size, seed: seed, height: heights, flow: zero,
                             river: [UInt8](repeating: 0, count: count), moisture: zero, slope: zero,
                             biome: heights.map { $0 > 0 ? Terrain.Biome.grass.rawValue : Terrain.Biome.shallow.rawValue },
                             fertility: zero, waterDistance: zero, ao: [Float](repeating: 1, count: count),
                             maxHeight: 30 / metres)
        let flat = try WorldScene(context: context, terrain: island)
        let hamlet = Settlement(id: 1, name: "Plateau fixture", x: 0, z: 0, founded: 20,
                                population: 60, prominence: 0, site: 0)
        let empty = FieldSurface.Mask()
        let clearance = NeolithicHerds.Clearance(buildingsAndActors: empty, fields: empty, cereal: empty,
                                                  roads: empty, paths: empty, banks: empty)
        let dry = [SIMD2<Float>(-0.25, -0.25), SIMD2(0.25, -0.25), SIMD2(0.25, 0.25), SIMD2(-0.25, 0.25)]
        guard clearance.allows(dry, in: flat),
              dry.allSatisfy({ abs(flat.renderedTerrainHeight(at: $0) * metres - 30) < 0.01 }),
              flat.renderedTerrainHeight(at: SIMD2(0.95, 0)) < 0,
              NeolithicBarrow.place(year: 720, in: flat, settlements: [hamlet], clearance: clearance, herds: []) == nil
        else { throw Failure("The dry plateau island must suppress the landmark") }
        print("PASS dry plateau island with a live hamlet: no suitable ridge, no long barrow")
    }

    private static func render(directory: URL, renderer: Renderer, barrow: NeolithicBarrow.Placement,
                               seed: UInt64, year: Float) throws {
        let model = barrow.instance.model
        func position(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
            let p = model * SIMD4(x, y, z, 1)
            return SIMD3(p.x, p.y, p.z)
        }
        let origin = position(0, 0, 0)
        let town = SIMD2(barrow.settlement.x, barrow.settlement.z)
        let middle = (SIMD2(origin.x, origin.z) + town) / 2
        let ground = renderer.scene.renderedTerrainHeight(at: middle)
        let ridgeTarget = SIMD3(middle.x, ground, middle.y)
        let ridgeEye = ridgeTarget + SIMD3<Float>(-13, 131, 35) / metres
        for (name, eye, target, fov): (String, SIMD3<Float>, SIMD3<Float>, Float) in [
            ("entrance", position(9, 5, 22), position(0, 1.3, 7.3), 40),
            ("mound", position(24, 15, 27), position(0, 0.9, 0), 40),
            ("overhead", ridgeEye, ridgeTarget, 47)
        ] {
            let view = RiverReviewView(seed: seed, year: year, hour: 15, season: 0.68, precipitation: 0,
                snow: false, animationTime: 24, eye: [eye.x, eye.y, eye.z], target: [target.x, target.y, target.z],
                fov: fov, width: 1440, height: 900, provenance: "NEO-11 production long barrow — \(name)")
            try view.write(to: directory.appendingPathComponent(name + ".json"))
            NeolithicReference.apply(view, to: renderer)
            _ = try Snapshot.write(renderer: renderer, width: view.width, height: view.height, time: view.animationTime,
                                   to: directory.appendingPathComponent(name + ".png"))
        }
    }
}
