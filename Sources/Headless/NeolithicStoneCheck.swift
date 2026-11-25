import Foundation
import Metal
import simd

enum NeolithicStoneCheck {
    private static let metres = RiverGraph.metresPerUnit

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func exposureFixtures() throws {
        var terrain = WorldGen.generate(seed: 1, size: 65)
        terrain.lakeWater = []
        func fill(_ height: (Float, Float) -> Float) {
            terrain.height = terrain.height.indices.map { i in
                height(terrain.worldX(i % terrain.size), terrain.worldZ(i / terrain.size))
            }
        }
        fill { x, _ in (x > 0.085 ? -20 : 12) / metres }
        guard NeolithicCoast.isExposed(.zero, terrain: terrain),
              !NeolithicCoast.isExposed(SIMD2(-0.4, 0), terrain: terrain),
              !NeolithicCoast.isExposed(SIMD2(0.3, 0), terrain: terrain) else {
            throw Failure("Open shelf, inland or submerged exposure fixture failed")
        }
        fill { x, _ in (x > 0.085 ? -20 : (x > 0.02 ? 50 : 12)) / metres }
        guard !NeolithicCoast.isExposed(.zero, terrain: terrain) else {
            throw Failure("A ridge-screened shelf was incorrectly exposed")
        }
        fill { x, z in ((x > 0.085 && abs(z) < 0.025) ? -20 : 12) / metres }
        guard !NeolithicCoast.isExposed(.zero, terrain: terrain) else {
            throw Failure("A narrow water corridor was mistaken for an open coast")
        }
        print("PASS open shelf, inland, submerged, ridge-screened and narrow water fixtures")
    }

    static func run(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try exposureFixtures()
        let paths = BuildingCatalog.neolithicStone.map(\.path)
        for path in paths {
            let asset = try CivMesh.load(named: path + ".civmesh")
            guard asset.maximum.y < 2.6, asset.minimum.y < -1.54,
                  stride(from: 0, to: asset.indices.count, by: 3).allSatisfy({ i in
                      let a = asset.vertices[Int(asset.indices[i])].position
                      let b = asset.vertices[Int(asset.indices[i + 1])].position
                      let c = asset.vertices[Int(asset.indices[i + 2])].position
                      return simd_length_squared(simd_cross(b - a, c - a)) > 1e-12
                  }) else { throw Failure("\(path) has invalid slab faces or height") }
            print("PASS \(path): \(asset.indices.count / 3) non-degenerate triangles, \(asset.maximum.y) m above origin")
        }
        let year: Float = 790
        var candidates: [UInt64] = []
        for seed in UInt64(1)...11 {
            let terrain = WorldGen.generate(seed: seed)
            var sim = Simulation(seed: seed, terrain: terrain)
            sim.advance(to: year)
            let geometry = CityBuilder.build(settlements: sim.settlements, era: .neolithic,
                                            year: year, terrain: terrain, seed: seed)
            let count = paths.map { geometry.buildings[$0, default: []].count }
            print("seed \(seed) plan: stone turf \(count[0]), stone passage \(count[1])")
            if count.allSatisfy({ $0 > 0 }) { candidates.append(seed) }
        }
        for seed in candidates {
            let terrain = WorldGen.generate(seed: seed)
            var sim = Simulation(seed: seed, terrain: terrain)
            sim.advance(to: year)
            let renderer = try Renderer(context: MetalContext(), terrain: terrain,
                                        colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
            let scene = renderer.scene
            let geometry = CityBuilder.build(settlements: sim.settlements, era: .neolithic,
                                            year: year, terrain: scene.terrain, seed: seed,
                                            riverField: scene.riverField, renderedGround: scene.renderedTerrainHeight(at:))
            guard paths.allSatisfy({ !geometry.buildings[$0, default: []].isEmpty }) else { continue }
            renderer.updateScene(sim)
            for path in paths {
                let bounds = RiverPlacement.authoredBounds(path)
                let instances = geometry.buildings[path, default: []]
                for item in instances {
                    let model = item.model
                    let base = model.columns.3
                    let footprint = RiverPlacement.transformed(bounds, by: model)
                    guard NeolithicCoast.isExposed(SIMD2(base.x, base.z), terrain: scene.terrain),
                          RiverPlacement.dry(item, bounds: bounds, field: scene.riverField, setbackMetres: 2),
                          footprint.allSatisfy({ !scene.terrain.isWater(x: $0.x, z: $0.y)
                              && scene.renderedTerrainHeight(at: $0) >= base.y - 1.55 * model.columns.1.y - 0.005 / metres
                              && scene.renderedTerrainHeight(at: $0) <= base.y + 0.005 / metres }) else {
                        throw Failure("Unsuitable stone home at \(base)")
                    }
                }
                print("PASS seed \(seed): \(instances.count) exposed, dry and supported \(path) placements")
                let model = instances[0].model
                let base = model.columns.3
                let centre = SIMD3(base.x, base.y, base.z)
                let front = simd_normalize(SIMD3(model.columns.2.x, 0, model.columns.2.z))
                let side = SIMD3(front.z, 0, -front.x)
                let up = SIMD3<Float>(0, 1, 0)
                let forwardOffset = front * (12 / metres)
                let sideOffset = side * (7 / metres)
                let heightOffset = up * (5 / metres)
                let eye = centre + forwardOffset + sideOffset + heightOffset
                let target = centre + up / metres
                let name = path.components(separatedBy: "neolithic-stone-").last!
                for (weather, precipitation) in [("daylight", Float(0)), ("rain", Float(0.88))] {
                    let record = RiverReviewView(seed: seed, year: year, hour: 14.5, season: 0.73,
                        precipitation: precipitation, snow: false, animationTime: 24,
                        eye: [eye.x, eye.y, eye.z], target: [target.x, target.y, target.z],
                        fov: 39, width: 1440, height: 900, provenance: "NEO-04 production stone home")
                    let file = "\(name)-\(weather)"
                    try record.write(to: directory.appendingPathComponent(file + ".json"))
                    NeolithicReference.apply(record, to: renderer)
                    _ = try Snapshot.write(renderer: renderer, width: record.width, height: record.height,
                                           time: record.animationTime, to: directory.appendingPathComponent(file + ".png"))
                }
            }
            return
        }
        throw Failure("No seed in 1–11 placed both stone homes on suitable built plots")
    }
}
