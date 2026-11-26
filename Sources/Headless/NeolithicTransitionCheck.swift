import Foundation
import simd

enum NeolithicTransitionCheck {
    private static let metres = RiverGraph.metresPerUnit
    private static let housePaths = Set((BuildingCatalog.neolithic + BuildingCatalog.neolithicStone).map(\.path))
    private typealias Submitted = (path: String, instance: InstanceData)

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func houses(_ renderer: Renderer) -> [Submitted] {
        renderer.submittedBuildings().filter { housePaths.contains($0.path) }
    }

    private static func footprint(_ house: Submitted) -> [SIMD2<Float>] {
        RiverPlacement.transformed(RiverPlacement.authoredBounds(house.path), by: house.instance.model)
    }

    private static func exact(_ lhs: Submitted, _ rhs: Submitted) -> Bool {
        lhs.path == rhs.path && lhs.instance.model == rhs.instance.model
            && lhs.instance.color == rhs.instance.color && lhs.instance.material == rhs.instance.material
    }

    static func run(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = try MetalContext()
        var savedReview = false
        for seed: UInt64 in [8, 1, 10] {
            let terrain = WorldGen.generate(seed: seed)
            var late = Simulation(seed: seed, terrain: terrain)
            late.advance(to: 790)
            var boundary = late
            boundary.advance(to: NeolithicInheritance.boundaryYear)
            var bronze = boundary
            bronze.advance(to: 810)
            guard late.era == .neolithic, boundary.year == 799, bronze.era == .bronze else {
                throw Failure("Era boundaries changed")
            }
            let renderer = try Renderer(context: context, terrain: terrain,
                                         colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
            // Open directly in the Bronze Age, before the renderer has drawn any Neolithic scene.
            renderer.updateScene(bronze)
            let inherited = houses(renderer)
            let bronzeMeshes = renderer.submittedBuildings().filter { $0.path.hasPrefix("variants/bronze-") }
            guard !bronzeMeshes.isEmpty, !inherited.isEmpty else {
                throw Failure("Seed \(seed) should show both histories in the Bronze Age")
            }
            let scene = renderer.scene
            let fields = FieldSurface.Mask(mesh: scene.fieldMesh)
            let roads = scene.activityRoads
            let streets = scene.activityStreets
            let banks = scene.riverBankFootprint
            let other = renderer.submittedBuildings().filter { !housePaths.contains($0.path) }.map { footprint($0) }
            for house in inherited {
                let corners = footprint(house)
                let model = house.instance.model
                let heights = corners.map { scene.renderedTerrainHeight(at: $0) }
                guard corners.count == 4, heights.allSatisfy({
                    $0 >= model.columns.3.y - 1.55 * model.columns.1.y - 0.005 / metres
                        && $0 <= model.columns.3.y + 0.005 / metres
                }), RiverPlacement.dry(house.instance, bounds: RiverPlacement.authoredBounds(house.path),
                                       field: scene.riverField, setbackMetres: 2),
                    !roads.intersectsFootprint(corners), !streets.intersectsFootprint(corners),
                    !banks.intersectsFootprint(corners), !fields.intersectsFootprint(corners),
                    !other.contains(where: { RiverPlacement.rectanglesOverlap(corners, $0) })
                else { throw Failure("Seed \(seed) retained an obstructed or unsupported home at \(model.columns.3)") }
            }

            renderer.updateScene(boundary)
            let lastHouses = houses(renderer)
            guard inherited.allSatisfy({ home in lastHouses.filter { exact(home, $0) }.count == 1 }) else {
                throw Failure("Seed \(seed) created a new footprint disguised as a surviving house")
            }
            let boundaryHomes = NeolithicInheritance.boundaryHomes(for: bronze, in: scene)
            let owners = Dictionary(grouping: inherited.compactMap { house in
                boundaryHomes.first { exact(house, ($0.path, $0.instance)) }
            }, by: \.settlement)
            guard owners.values.joined().count == inherited.count,
                  owners.allSatisfy({ id, homes in
                      bronze.settlements.contains { $0.isAlive && $0.id == id }
                          && homes.count <= 4 && Set(homes.map(\.court)).count == 1
                  }) else { throw Failure("Seed \(seed) kept a house from an abandoned hamlet or mixed courts") }

            renderer.updateScene(late)
            let early = houses(renderer)
            renderer.updateScene(bronze)
            let forward = houses(renderer)
            guard forward.count == inherited.count,
                  zip(forward, inherited).allSatisfy({ exact($0, $1) }) else {
                throw Failure("Seed \(seed) differs between direct open and Timeline scrub to year 810")
            }
            print("PASS seed \(seed): \(inherited.count) exact year-799 houses in \(owners.count) living hamlets, valid clearances and identical scrub")
            if savedReview { continue }
            for town in late.settlements where town.isAlive {
                guard bronze.settlements.contains(where: {
                    $0.id == town.id && $0.isAlive && $0.name == town.name && $0.founded == town.founded
                        && $0.x == town.x && $0.z == town.z
                }) else { continue }
                let retained = owners[town.id, default: []]
                let matches = retained.filter { home in
                    early.contains { prior in
                        prior.path == home.path && zip(footprint(prior), home.footprint).allSatisfy {
                            simd_distance($0, $1) <= 0.70 / metres
                        }
                    }
                }
                guard matches.count >= 2 else { continue }
                try render(directory: directory, renderer: renderer, late: late, bronze: bronze,
                           town: town, homes: matches)
                print("PASS \(town.name), seed \(seed): unchanged settlement centre and \(matches.count) recognizable year-790 footprints within 0.70 m at year 810")
                savedReview = true
                break
            }
        }
        guard savedReview else { throw Failure("No recognizable group survived in the fixed 790 / 810 review matrix") }
    }

    private static func verifyPeople(_ renderer: Renderer) throws {
        var homes = FieldSurface.Mask()
        for house in houses(renderer) { homes.insertFootprint(footprint(house)) }
        let people = renderer.submittedPersonOrigins()
        guard !people.isEmpty, people.allSatisfy({ !homes.covers($0) }) else {
            throw Failure("A Bronze Age pedestrian passes through an inherited home")
        }
    }

    private static func render(directory: URL, renderer: Renderer, late: Simulation, bronze: Simulation,
                               town: Settlement, homes: [NeolithicInheritance.Home]) throws {
        let origins = homes.map { $0.instance.model.columns.3 }
        let cluster = origins.reduce(SIMD4<Float>.zero, +) / Float(origins.count)
        let centre = SIMD2(town.x, town.z)
        let focus = SIMD2(cluster.x, cluster.z) * 0.68 + centre * 0.32
        let ground = renderer.scene.renderedTerrainHeight(at: focus)
        let target = SIMD3(focus.x, ground + 1.0 / metres, focus.y)
        let outward = simd_normalize(SIMD2(cluster.x, cluster.z) - centre)
        let oblique = SIMD3(outward.x * 35 + outward.y * 14, 34, outward.y * 35 - outward.x * 14) / metres
        for simulation in [late, bronze] {
            renderer.updateScene(simulation)
            for (name, offset, fov): (String, SIMD3<Float>, Float) in [
                ("hamlet", oblique, 48),
                ("overhead", SIMD3<Float>(4, 95, 14) / metres, 47)
            ] {
                let eye = target + offset
                let view = RiverReviewView(seed: simulation.seed, year: simulation.year, hour: 14.5,
                    season: 0.68, precipitation: 0, snow: false, animationTime: 24,
                    eye: [eye.x, eye.y, eye.z], target: [target.x, target.y, target.z],
                    fov: fov, width: 1440, height: 900, provenance: "NEO-12 \(town.name) transition — \(name)")
                let base = directory.appendingPathComponent("\(name)-\(Int(simulation.year))")
                try view.write(to: base.appendingPathExtension("json"))
                NeolithicReference.apply(view, to: renderer)
                _ = try Snapshot.write(renderer: renderer, width: view.width, height: view.height,
                                       time: view.animationTime, to: base.appendingPathExtension("png"))
                if simulation.era == .bronze { try verifyPeople(renderer) }
            }
        }
    }
}
