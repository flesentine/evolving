import Foundation
import simd

enum BronzeCourtCheck {
    private static let metres = RiverGraph.metresPerUnit
    private static let domestic = Set(BronzeHome.allCases.map(\.path))

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func run(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = try MetalContext()
        for seed: UInt64 in [8, 1, 10] {
            let terrain = WorldGen.generate(seed: seed)
            let renderer = try Renderer(context: context, terrain: terrain,
                colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
            var simulation = Simulation(seed: seed, terrain: terrain)
            let years = seed == 8 ? [810, 1450, 1990] : [1450]
            for year in years {
                simulation.advance(to: Float(year))
                renderer.updateScene(simulation)
                try inspect(renderer, seed: seed, year: year)
                if seed == 8, year == 810 {
                    try reviewedHomes(renderer, simulation: simulation)
                }
                if seed == 8, year == 1450 {
                    try views(renderer, simulation: simulation, directory: directory)
                }
            }
        }
    }

    private static func inspect(_ renderer: Renderer, seed: UInt64, year: Int) throws {
        let scene = renderer.scene
        let walks = renderer.bronzeWalks.keys.sorted().flatMap { renderer.bronzeWalks[$0] ?? [] }
        let lanes = FieldSurface.Mask(mesh: scene.yardMesh)
        let roads = scene.activityRoads
        let banks = scene.riverBankFootprint
        let crops = FieldSurface.Mask(mesh: scene.fieldMesh)
        let houses = renderer.submittedBuildings()
        guard scene.streetMesh == nil, let mesh = scene.yardMesh, let indexBuffer = mesh.indexBuffer,
              !renderer.bronzeCourts.isEmpty, !walks.isEmpty else {
            throw Failure("Seed \(seed) year \(year) should submit courts and paths without radial streets")
        }

        var solids = FieldSurface.Mask()
        let domesticHouses = houses.filter { domestic.contains($0.path) }
        guard !domesticHouses.isEmpty else { throw Failure("Seed \(seed) year \(year) has no occupied courts") }
        for house in houses {
            let model = house.instance.model
            let bounds = RiverPlacement.authoredBounds(house.path)
            let footprint = RiverPlacement.transformed(bounds, by: model)
            guard footprint.count == 4, !solids.intersectsFootprint(footprint),
                  !lanes.intersectsFootprint(footprint), !roads.intersectsFootprint(footprint),
                  !banks.intersectsFootprint(footprint), !crops.intersectsFootprint(footprint),
                  !scene.riverField.intersectsFootprint(footprint, margin: 2 / metres) else {
                throw Failure("Seed \(seed) year \(year) intersecting footprint for \(house.path) at \(model.columns.3)")
            }
            solids.insertFootprint(footprint)
            if domestic.contains(house.path) {
                let front = bounds.map(\.y).max()!
                let doorstep = model * SIMD4(0, 0, front + 0.40, 1)
                let p = SIMD2(doorstep.x, doorstep.z)
                guard walks.contains(where: { simd_distance($0.a, p) < 0.015 / metres }) else {
                    throw Failure("Seed \(seed) year \(year) has a domestic front without a submitted path at \(p)")
                }
            }
        }

        let points = mesh.vertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
        let indices = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        for start in stride(from: 0, to: mesh.indexCount, by: 3) {
            let triangle = (0..<3).map { points[Int(indices[start + $0])].position }
            let footprint = triangle.map { SIMD2($0.x, $0.z) }
            guard !scene.riverField.intersectsFootprint(footprint),
                  !banks.intersectsFootprint(footprint), !roads.intersectsFootprint(footprint) else {
                throw Failure("Seed \(seed) year \(year) court or lane triangle intersects a bank, river or through-road")
            }
            for (point, vertex) in zip(footprint, triangle) {
                let lift = vertex.y - scene.renderedTerrainHeight(at: point)
                guard abs(lift - FieldSurface.cropLift) <= 0.02 / metres else {
                    throw Failure("Seed \(seed) year \(year) lane lift is \(lift * metres) m")
                }
            }
        }
        guard renderer.bronzeCourts.allSatisfy(lanes.covers),
              walks.allSatisfy({ walk in
                  walk.samples(step: 0.2 / metres).allSatisfy(lanes.covers)
                      && !solids.intersectsFootprint(walk.outline)
              }) else { throw Failure("Seed \(seed) year \(year) gap or blocked walking corridor") }
        print("PASS seed \(seed) year \(year): \(domesticHouses.count) occupied domestic plots, \(renderer.bronzeCourts.count) courts, \(walks.count) covered walks, \(mesh.indexCount / 3) grounded lane triangles")
    }

    private static func reviewedHomes(_ renderer: Renderer, simulation: Simulation) throws {
        guard let town = simulation.settlements.first(where: { $0.name == "Norimton" }) else {
            throw Failure("Missing Norimton in seed 8")
        }
        // The archived NEO-12 review framed the mean of the two checked homes,
        // blended 68% toward them from the settlement centre.
        let archivedFocus = SIMD2<Float>(0.14659758, -0.056551687)
        let cluster = (archivedFocus - SIMD2(town.x, town.z) * 0.32) / 0.68
        let boundary = NeolithicInheritance.boundaryHomes(for: simulation, in: renderer.scene)
            .filter { $0.settlement == town.id }
        let pairs = boundary.indices.flatMap { a in
            boundary.indices.dropFirst(a + 1).map { (boundary[a], boundary[$0]) }
        }
        func origin(_ home: NeolithicInheritance.Home) -> SIMD2<Float> {
            NeolithicPeople.xz(home.instance.model.columns.3)
        }
        let reviewed = pairs.filter {
            $0.0.court == $0.1.court && simd_distance((origin($0.0) + origin($0.1)) * 0.5, cluster) < 0.015 / metres
        }
        guard reviewed.count == 1, let pair = reviewed.first else {
            throw Failure("Couldn't identify the two reviewed Norimton homes")
        }
        let submitted = renderer.submittedBuildings()
        guard [pair.0, pair.1].allSatisfy({ home in
            submitted.contains { $0.path == home.path && $0.instance.model == home.instance.model }
        }) else { throw Failure("The two reviewed Norimton footprints did not both survive") }
        print("PASS exact transforms for both reviewed Norimton houses at year 810")
    }

    private static func views(_ renderer: Renderer, simulation: Simulation, directory: URL) throws {
        let metres = Self.metres
        let walks = renderer.bronzeWalks.values.flatMap { $0 }
        let candidates = renderer.bronzeCourts.filter { centre in
            walks.count(where: { simd_distance($0.b, centre) < 0.015 / metres }) >= 3
        }
        guard let norimton = simulation.settlements.first(where: { $0.name == "Norimton" }),
              let centre = candidates.min(by: {
                  let target = SIMD2(norimton.x, norimton.z)
                  return simd_distance_squared($0, target) < simd_distance_squared($1, target)
              }) else { throw Failure("No three-home court for the middle Bronze review") }
        let ground = renderer.scene.renderedTerrainHeight(at: centre)
        let target = SIMD3(centre.x, ground + 1 / metres, centre.y)
        let views: [(String, SIMD3<Float>, Float)] = [
            ("court-close-1450", SIMD3(12, 16, 18), 48),
            ("court-overhead-1450", SIMD3(6, 60, 8), 48)
        ]
        for (name, offset, fov) in views {
            let eye = target + offset / metres
            let view = RiverReviewView(seed: simulation.seed, year: simulation.year, hour: 14.5,
                season: 0.68, precipitation: 0, snow: false, animationTime: 24,
                eye: [eye.x, eye.y, eye.z], target: [target.x, target.y, target.z],
                fov: fov, width: 1440, height: 900, provenance: "BRZ-04 occupied Bronze court — \(name)")
            try view.write(to: directory.appendingPathComponent(name + ".json"))
        }
    }
}
