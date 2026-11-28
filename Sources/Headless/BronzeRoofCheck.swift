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
        let hits = intersections(start, direction: direction, faces: faces)
        return hits.nearest.isFinite && hits.front <= hits.nearest + 0.0001 // 0.1 mm in authored metres.
    }

    private static func intersections(_ start: SIMD3<Float>, direction: SIMD3<Float>,
                                      faces: [Face]) -> (nearest: Float, front: Float) {
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
        return (nearest, nearestFront)
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
            let faces = thatchFaces(mesh, vertices: vertices, indices: indices)
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
        let domestic = Set(BronzeHome.allCases.map(\.path))
        let houses = renderer.submittedBuildings().filter { domestic.contains($0.path) }
        guard !houses.isEmpty else { throw Failure("Year 810 submits no Bronze Age houses") }
        print("PASS \(allProbes) exterior coverage probes on \(meshes.count) legacy roofs, \(houses.count) domestic building instances at year 810")
        if let directory {
            try prototype(directory: directory, renderer: renderer, simulation: simulation, houses: houses)
        }
    }
    private static func thatchFaces(_ mesh: Mesh, vertices: UnsafePointer<Vertex>,
                                    indices: UnsafePointer<UInt32>) -> [Face] {
        stride(from: 0, to: mesh.indexCount, by: 3).compactMap { index in
            let a = vertices[Int(indices[index])]
            let b = vertices[Int(indices[index + 1])]
            let c = vertices[Int(indices[index + 2])]
            // Thatch occupies the first tile of the building atlas.
            guard [a, b, c].allSatisfy({ $0.uv.x < 0.25 && $0.uv.y < 0.25 }) else { return nil }
            return Face(origin: a.position, edgeA: b.position - a.position, edgeB: c.position - a.position)
        }
    }

    static func runFamily(directory: URL) throws {
        let seed: UInt64 = 8
        let terrain = WorldGen.generate(seed: seed)
        var simulation = Simulation(seed: seed, terrain: terrain)
        let renderer = try Renderer(context: MetalContext(), terrain: terrain,
                                     colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
        let forms = BronzeHome.allCases
        let paths = Set(forms.map(\.path))
        var bottoms: [String: [SIMD3<Float>]] = [:]
        for form in forms {
            guard let mesh = renderer.scene.buildingMeshes.first(where: { $0.path == form.path })?.mesh,
                  let indexBuffer = mesh.indexBuffer, mesh.indexCount.isMultiple(of: 3) else {
                throw Failure("Missing uploaded mesh for \(form.path)")
            }
            let vertices = mesh.vertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
            let indices = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
            let positions = (0..<mesh.vertexCount).map { vertices[$0].position }
            bottoms[form.path] = positions.filter { $0.y <= -BronzeHome.skirtDepth + 0.05 }
            guard let peak = positions.map(\.y).max(), bottoms[form.path]!.count >= 64 else {
                throw Failure("Missing continuous foundation skirt for \(form.path)")
            }
            let faces = thatchFaces(mesh, vertices: vertices, indices: indices)
            var probes = 0
            for sector in 0..<64 {
                let angle = (Float(sector) + 0.37) * (2 * .pi / 64)
                let x = cos(angle), z = sin(angle)
                let eave: Float = form == .uplandStone ? 1.78 : 2.09
                for fraction: Float in [0.10, 0.27, 0.49, 0.72, 0.91] {
                    let y = eave + fraction * (peak - eave)
                    guard covers(SIMD3(x * 12, y, z * 12), direction: SIMD3(-x, 0, -z), faces: faces) else {
                        throw Failure("Missing front-facing thatch at \(form.path), sector \(sector), y=\(y) m")
                    }
                    probes += 1
                }
                for radius: Float in [0.04, 0.75, 1.65, 2.48, 2.80] {
                    guard covers(SIMD3(x * radius, peak + 2, z * radius), direction: SIMD3(0, -1, 0), faces: faces) else {
                        throw Failure("Missing overhead thatch at \(form.path), sector \(sector), r=\(radius) m")
                    }
                    probes += 1
                }
            }
            if form == .porched {
                for x: Float in [-0.50, -0.25, 0, 0.25, 0.50] {
                    for z: Float in [3.30, 3.55, 3.80] {
                        guard covers(SIMD3(x, peak + 2, z), direction: SIMD3(0, -1, 0), faces: faces) else {
                            throw Failure("Uncovered porch at x=\(x), z=\(z) m")
                        }
                        probes += 1
                    }
                }
            }
            for index in 0..<mesh.vertexCount {
                let vertex = vertices[index]
                let p = vertex.position
                guard (vertex.uv.x >= 0.25 || vertex.uv.y >= 0.25), p.y > 1.45 else { continue }
                let roof = intersections(SIMD3(p.x, peak + 2, p.z), direction: SIMD3(0, -1, 0), faces: faces)
                guard roof.front.isFinite, p.y <= peak + 2 - roof.front + 0.005 else {
                    throw Failure("Wall or post projects through thatch on \(form.path) at \(p) m")
                }
            }
            print("PASS \(form.path): \(probes) roof probes under back-face culling, no wall or post protrusions")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metres = RiverGraph.metresPerUnit
        for year in [810, 1450, 1990, 2010] {
            simulation.advance(to: Float(year))
            renderer.updateScene(simulation)
            let homes = renderer.submittedBuildings().filter { paths.contains($0.path) }
            if year == 2010 {
                guard homes.isEmpty else { throw Failure("BRZ-03 domestic meshes leaked into Classical plots") }
                break
            }
            guard !homes.isEmpty, year == 810 || Set(homes.map(\.path)) == paths else {
                throw Failure("Expected occupied plots and eligible upland placements in year \(year)")
            }
            for (path, instance) in homes {
                let model = instance.model
                let bounds = RiverPlacement.transformed(RiverPlacement.authoredBounds(path), by: model)
                let ground = renderer.scene.renderedTerrainHeight
                let foundation = BronzeHome.foundationSamples(bounds)
                let heights = foundation.map(ground)
                guard abs(heights.max()! - model.columns.3.y) < 0.02 / metres,
                      !renderer.scene.riverField.intersectsFootprint(bounds, margin: 2 / metres),
                      foundation.allSatisfy({ !terrain.isWater(x: $0.x, z: $0.y) }) else {
                    throw Failure("Dry ground or footing check failed for \(path) in year \(year)")
                }
                for base in bottoms[path]! {
                    let world = model * SIMD4(base, 1)
                    let bed = ground(SIMD2(world.x, world.z))
                    guard world.y <= bed + 0.02 / metres else {
                        throw Failure("Exposed skirt at \(path) in year \(year): \((world.y - bed) * metres) m")
                    }
                }
            }
            let counts = forms.map { form in "\(form.rawValue) \(homes.count(where: { $0.path == form.path }))" }
            print("PASS seed \(seed) year \(year): dry ground and skirt contact on \(homes.count) houses (\(counts.joined(separator: ", ")))")
            if year == 1450 {
                try familyViews(directory: directory, renderer: renderer, simulation: simulation, homes: homes)
            }
        }
        print("PASS no Bronze domestic batches in Classical at year 2010")
    }

    private static func familyViews(directory: URL, renderer: Renderer, simulation: Simulation,
                                    homes: [(path: String, instance: InstanceData)]) throws {
        let metres = RiverGraph.metresPerUnit
        let buildings = renderer.submittedBuildings()
        for form in BronzeHome.allCases {
            let cameras = homes.filter { $0.path == form.path }.flatMap { home in
                let model = home.instance.model
                let origin = model.columns.3
                let front = simd_normalize(NeolithicPeople.xz(model.columns.2))
                let side = SIMD2(front.y, -front.x)
                return [Float(-5), 5].map { across -> (SIMD4<Float>, SIMD2<Float>, Float) in
                    let point = NeolithicPeople.xz(origin) + (front * 9.5 + side * across) / metres
                    let spacing = buildings.filter { $0.instance.model != model }.map {
                        simd_distance(point, NeolithicPeople.xz($0.instance.model.columns.3))
                    }.min() ?? 0
                    return (origin, point, spacing)
                }
            }
            guard let (origin, approach, _) = cameras.filter({
                !renderer.scene.terrain.isWater(x: $0.1.x, z: $0.1.y)
            }).max(by: { $0.2 < $1.2 }) else { throw Failure("No dry camera approach for \(form.path)") }
            let eyeY = max(renderer.scene.renderedTerrainHeight(at: approach), origin.y) + 4.2 / metres
            let views = [
                ("close", SIMD3(approach.x, eyeY, approach.y), Float(43)),
                ("overhead", SIMD3(origin.x - 8 / metres, origin.y + 30 / metres, origin.z + 6 / metres), Float(44)),
            ]
            for (label, eye, fov) in views {
                let view = RiverReviewView(seed: simulation.seed, year: simulation.year, hour: 14.5,
                    season: 0.68, precipitation: 0, snow: false, animationTime: 24,
                    eye: [eye.x, eye.y, eye.z], target: [origin.x, origin.y + 1.65 / metres, origin.z],
                    fov: fov, width: 1440, height: 900, provenance: "BRZ-03 production \(form.path) \(label)")
                try view.write(to: directory.appendingPathComponent("\(form.rawValue)-\(label).json"))
            }
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
