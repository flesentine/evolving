import Foundation
import simd

enum BronzeRoofCheck {
    private struct Face {
        let origin: SIMD3<Float>
        let edgeA: SIMD3<Float>
        let edgeB: SIMD3<Float>
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Compare the nearest geometric intersection with the nearest surviving
    /// front face. A reversed section otherwise passes a two-sided ray test
    /// by showing the opposite side of the cone through the missing roof.
    private static func covers(_ start: SIMD3<Float>, direction: SIMD3<Float>, faces: [Face]) -> Bool {
        var nearest = Float.infinity
        var nearestFront = Float.infinity
        for face in faces {
            let p = simd_cross(direction, face.edgeB)
            let determinant = simd_dot(face.edgeA, p)
            guard abs(determinant) > 0.000001 else { continue }
            let fromCorner = start - face.origin
            let u = simd_dot(fromCorner, p) / determinant
            guard u >= -0.00001, u <= 1.00001 else { continue }
            let q = simd_cross(fromCorner, face.edgeA)
            let v = simd_dot(direction, q) / determinant
            guard v >= -0.00001, u + v <= 1.00001 else { continue }
            let distance = simd_dot(face.edgeB, q) / determinant
            guard distance > 0 else { continue }
            nearest = min(nearest, distance)
            if determinant > 0 { nearestFront = min(nearestFront, distance) }
        }
        return nearest.isFinite && nearestFront <= nearest + 0.0001 // 0.1 mm in authored metres.
    }

    static func run(directory: URL?) throws {
        let seed: UInt64 = 8
        let terrain = WorldGen.generate(seed: seed)
        var simulation = Simulation(seed: seed, terrain: terrain)
        simulation.advance(to: 810)
        let renderer = try Renderer(context: MetalContext(), terrain: terrain,
                                     colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
        renderer.updateScene(simulation)
        let paths = Set(BuildingCatalog.bronze.map(\.path))
        let meshes = renderer.scene.buildingMeshes.filter { paths.contains($0.path) }
        guard meshes.count == paths.count else { throw Failure("Missing Bronze Age render meshes") }

        var allFailures = 0
        var allProbes = 0
        for (path, mesh) in meshes {
            guard let indexBuffer = mesh.indexBuffer, mesh.indexCount.isMultiple(of: 3) else {
                throw Failure("Missing submitted triangle indices for \(path)")
            }
            let vertices = mesh.vertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
            let indices = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
            let roofTop = (0..<mesh.vertexCount).map { vertices[$0].position.y }.max() ?? 0
            let faces = stride(from: 0, to: mesh.indexCount, by: 3).compactMap { index -> Face? in
                let a = vertices[Int(indices[index])]
                let b = vertices[Int(indices[index + 1])]
                let c = vertices[Int(indices[index + 2])]
                // The thatch occupies the first tile of the building atlas.
                guard [a, b, c].allSatisfy({ $0.uv.x < 0.25 && $0.uv.y < 0.25 }) else { return nil }
                return Face(origin: a.position, edgeA: b.position - a.position, edgeB: c.position - a.position)
            }
            var failures = 0
            for sector in 0..<40 {
                let angle = (Float(sector) + 0.37) * (2 * .pi / 40)
                let x = cos(angle), z = sin(angle)
                // Mesh coordinates here are authored metres, before town placement.
                for height in [Float(4.4), (4.4 + roofTop) * 0.5, roofTop - 1.0] {
                    if !covers(SIMD3(x * 20, height, z * 20), direction: SIMD3(-x, 0, -z), faces: faces) {
                        failures += 1
                    }
                }
                for radius: Float in [0.07, 1.5, 3.5] {
                    if !covers(SIMD3(x * radius, roofTop + 4, z * radius), direction: SIMD3(0, -1, 0), faces: faces) {
                        failures += 1
                    }
                }
                allProbes += 6
            }
            if failures > 0 { print("FAIL \(path): \(failures)/240 exterior coverage probes") }
            allFailures += failures
        }
        guard allFailures == 0 else {
            throw Failure("\(allFailures)/\(allProbes) exterior rays miss the nearest roof under back-face culling")
        }
        let houses = renderer.submittedBuildings().filter { paths.contains($0.path) }
        guard !houses.isEmpty else { throw Failure("Year 810 submits no Bronze Age houses") }
        print("PASS \(allProbes) exterior coverage probes on \(meshes.count) uploaded roofs, \(houses.count) Bronze Age building instances at year 810")
        if let directory {
            try prototype(directory: directory, renderer: renderer, simulation: simulation, houses: houses)
        }
    }
    private static func prototype(directory: URL, renderer: Renderer, simulation: Simulation,
                                  houses: [(path: String, instance: InstanceData)]) throws {
        guard let town = simulation.settlements.first(where: { $0.name == "Norimton" }) else {
            throw Failure("Norimton is missing from the review seed")
        }
        let centre = SIMD2(town.x, town.z)
        let metres = RiverGraph.metresPerUnit
        let nearby = houses.filter { house in
            simd_distance(NeolithicPeople.xz(house.instance.model.columns.3), centre)
                <= CityBuilder.cityRadius(town.population)
        }
        // Pick the dry approach with the most room in front of one of
        // Norimton's actual buildings so the doorway and eaves are visible.
        let placements = nearby.flatMap { house in
            let model = house.instance.model
            let origin = model.columns.3
            let front = simd_normalize(NeolithicPeople.xz(model.columns.2))
            let side = SIMD2(front.y, -front.x)
            return [-9 as Float, 9].map { across -> (String, SIMD4<Float>, SIMD2<Float>, Float) in
                let point = NeolithicPeople.xz(origin) + (front * 16 + side * across) / metres
                let other = nearby.filter { $0.instance.model != model }
                let spacing = other.map {
                    simd_distance(point, NeolithicPeople.xz($0.instance.model.columns.3))
                }.min() ?? 0
                return (house.path, origin, point, spacing)
            }
        }
        guard let (path, origin, point, _) = placements.filter({
            !renderer.scene.terrain.isWater(x: $0.2.x, z: $0.2.y)
        }).max(by: { $0.3 < $1.3 }) else {
            throw Failure("No dry camera approach to a Norimton roundhouse")
        }
        let eyeY = max(renderer.scene.renderedTerrainHeight(at: point), origin.y) + 5.5 / metres
        let view = RiverReviewView(seed: simulation.seed, year: simulation.year, hour: 14.5,
            season: 0.68, precipitation: 0, snow: false, animationTime: 24,
            eye: [point.x, eyeY, point.y], target: [origin.x, origin.y + 4 / metres, origin.z],
            fov: 46, width: 1440, height: 900, provenance: "BRZ-01 Norimton prototype — \(path)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try view.write(to: directory.appendingPathComponent("prototype.json"))
        print("PASS actual Norimton prototype \(path), seed 8 year 810")
    }

}
