import Foundation
import simd

enum NeolithicLivestockCheck {
    private static let metres = RiverGraph.metresPerUnit

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }

    private static func checkMeshes() throws {
        let heights: [ClosedRange<Float>] = [0.80...1.05, 1.25...1.60, 0.65...0.82]
        var total = 0
        for species in NeolithicLivestock.Species.allCases {
            var seen = Set<Data>()
            for pose in NeolithicLivestock.poses where pose.species == species {
                let name = pose.path + ".civmesh"
                let mesh = try CivMesh.load(named: name)
                guard let url = AssetStore.url(named: name),
                      try seen.insert(Data(contentsOf: url)).inserted,
                      heights[species.rawValue].contains(mesh.maximum.y),
                      abs(mesh.minimum.y) <= 0.005,
                      mesh.indices.count.isMultiple(of: 3),
                      mesh.vertices.allSatisfy({ $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite })
                else { throw Failure("Invalid or duplicate mesh: \(name)") }
                for i in stride(from: 0, to: mesh.indices.count, by: 3) {
                    let ids = mesh.indices[i..<i+3].map(Int.init)
                    guard ids.allSatisfy({ $0 < mesh.vertices.count }) else {
                        throw Failure("Invalid index in \(name)")
                    }
                    let a = mesh.vertices[ids[0]].position
                    let b = mesh.vertices[ids[1]].position
                    let c = mesh.vertices[ids[2]].position
                    guard simd_length_squared(simd_cross(b - a, c - a)) > 1e-16 else {
                        throw Failure("Degenerate triangle in \(name)")
                    }
                }
                total += mesh.indices.count / 3
            }
            let walkFrames = (0..<4).map { NeolithicLivestock.gait(species, at: Float($0) * 0.22).pose.frame }
            let feeding = NeolithicLivestock.gait(species, at: 9)
            let later = NeolithicLivestock.gait(species, at: 14)
            let resumed = NeolithicLivestock.gait(species, at: 16)
            guard walkFrames == [0, 1, 2, 3], feeding.pose.isFeeding, later.pose.isFeeding,
                  feeding.distance == later.distance, resumed.distance > later.distance,
                  !resumed.pose.isFeeding else { throw Failure("Incorrect gait cycle for \(species.name)") }
        }
        print("PASS 15 distinct grounded meshes, \(total) triangles, four gait frames and feeding for each species")
    }

    static func run(directory: URL) throws {
        try checkMeshes()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let seed: UInt64 = 1
        let year: Float = 450
        let terrain = WorldGen.generate(seed: seed)
        var simulation = Simulation(seed: seed, terrain: terrain)
        simulation.advance(to: year)
        let renderer = try Renderer(context: MetalContext(), terrain: terrain,
                                    colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
        renderer.updateScene(simulation)
        let living = simulation.settlements.filter { $0.isAlive }
        let roads = renderer.scene.activityRoads
        let banks = renderer.scene.riverBankFootprint
        // A previous cattle camera was centred on this bank apron. The
        // terrain alone put its legs under the separately submitted bank mesh.
        let bankProbe = SIMD2<Float>(-0.00191556, 0.2529707)
        guard banks.covers(bankProbe) else { throw Failure("Missing submitted apron at regression point") }
        var selected: [Int: (NeolithicLivestock.Placement, Float)] = [:]
        var checked = 0
        for time: Float in [3, 5, 8, 10, 12, 14, 18, 24, 30] {
            let placements = NeolithicLivestock.placements(in: renderer.scene, settlements: living,
                                                            seed: seed, time: time)
            let replay = NeolithicLivestock.placements(in: renderer.scene, settlements: living,
                                                         seed: seed, time: time)
            guard placements.count == replay.count,
                  zip(placements, replay).allSatisfy({ $0.pose == $1.pose && $0.instance.model == $1.instance.model })
            else { throw Failure("Livestock placement changed on replay") }
            for placement in placements {
                let origin = placement.instance.model.columns.3
                let ground = renderer.scene.renderedTerrainHeight(at: SIMD2(origin.x, origin.z))
                let corners = RiverPlacement.authoredBounds(placement.pose.path)
                let footprint = RiverPlacement.transformed(corners, by: placement.instance.model)
                guard origin.y == ground,
                      !banks.intersectsFootprint(footprint),
                      NeolithicLivestock.hoovesSupported(placement.pose, by: placement.instance.model,
                                                        in: renderer.scene),
                      !NeolithicLivestock.roadOrCrop(footprint, in: renderer.scene, roads: roads),
                      RiverPlacement.dry(placement.instance, bounds: corners, field: renderer.scene.riverField,
                                         setbackMetres: 0.40)
                else { throw Failure("Livestock is unsupported or intersects river: \(placement.pose.path)") }
                let index = placement.pose.species.rawValue * 2 + (placement.pose.isFeeding ? 1 : 0)
                let previous = selected[index]?.0.instance.model
                if previous == nil || placement.instance.model.columns.1.y > previous!.columns.1.y {
                    selected[index] = (placement, time)
                }
                checked += 1
            }
        }
        print("PASS \(checked) deterministic grounded placements clear of water, banks, roads, and crops across nine animation times")

        for index in 0..<6 {
            guard let (placement, time) = selected[index] else { throw Failure("Missing review pose \(index)") }
            let model = placement.instance.model
            let position = model.columns.3
            let across = simd_normalize(SIMD2(model.columns.0.x, model.columns.0.z))
            let forward = simd_normalize(SIMD2(model.columns.2.x, model.columns.2.z))
            let afternoon = SIMD2<Float>(-0.43, 0.38)
            let side: Float = simd_dot(across, afternoon) >= 0 ? 1 : -1
            let offset = across * (side * 6 / metres) + forward * (2.5 / metres)
            let target = SIMD3(position.x, position.y + 0.60 / metres, position.z)
            let eye = target + SIMD3(offset.x, 1.8 / metres, offset.y)
            let name = placement.pose.species.name + (placement.pose.isFeeding ? "-feed" : "-walk")
            let view = RiverReviewView(seed: seed, year: year, hour: 14, season: 0.68,
                precipitation: 0, snow: false, animationTime: time, eye: [eye.x, eye.y, eye.z],
                target: [target.x, target.y, target.z], fov: 25, width: 1440, height: 900,
                provenance: "NEO-09 normal-world \(name)")
            try render(view, name: name, renderer: renderer, directory: directory)
            guard renderer.submittedNeolithicLivestockCounts()[placement.pose.index] > 0 else {
                throw Failure("No submitted batch for \(name)")
            }
        }

        guard let settlement = living.first else { throw Failure("No settlement for grazing comparison") }
        let centre = renderer.scene.renderedTerrainHeight(at: SIMD2(settlement.x, settlement.z))
        let overview = RiverReviewView(seed: seed, year: year, hour: 14, season: 0.68,
            precipitation: 0, snow: false, animationTime: 12,
            eye: [settlement.x + 44 / metres, centre + 60 / metres, settlement.z + 38 / metres],
            target: [settlement.x, centre, settlement.z], fov: 52, width: 1440, height: 900,
            provenance: "NEO-09 matched inland grazing range")
        try render(overview, name: "grazing-range", renderer: renderer, directory: directory)
        print("PASS native Metal submitted all six species and activity combinations")
    }

    private static func render(_ view: RiverReviewView, name: String, renderer: Renderer, directory: URL) throws {
        try view.write(to: directory.appendingPathComponent(name + ".json"))
        NeolithicReference.apply(view, to: renderer)
        _ = try Snapshot.write(renderer: renderer, width: view.width, height: view.height,
                               time: view.animationTime,
                               to: directory.appendingPathComponent(name + "-after.png"))
    }
}
