import Foundation
import simd

enum NeolithicHouseCheck {
    private static let metres = RiverGraph.metresPerUnit

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func roofCheck(_ path: String, wall: SIMD2<Float>, clipped: Bool) throws {
        let asset = try CivMesh.load(named: path + ".civmesh")
        let triangles = stride(from: 0, to: asset.indices.count, by: 3).map { index in
            (0..<3).map { asset.vertices[Int(asset.indices[index + $0])].position }
        }
        guard triangles.allSatisfy({ triangle in
            simd_length_squared(simd_cross(triangle[1] - triangle[0], triangle[2] - triangle[0])) > 1e-12
        }) else { throw Failure("\(path) contains a degenerate face") }
        let roof = triangles.filter { triangle in
            triangle.allSatisfy { $0.y >= 2.11 }
                && simd_cross(triangle[1] - triangle[0], triangle[2] - triangle[0]).y > 1e-6
        }
        var probes = 0
        for u in 0...24 {
            for v in 0...24 {
                let point = SIMD2(Float(u) / 12 - 1, Float(v) / 12 - 1) * (wall * 0.5)
                if clipped && abs(point.x) + abs(point.y) > (wall.x + wall.y) * 0.5 - 0.56 { continue }
                guard roof.contains(where: { triangle in
                    let points = triangle.map { SIMD2($0.x, $0.z) }
                    func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
                    return (0..<3).allSatisfy { i in
                        cross(points[(i + 1) % 3] - points[i], point - points[i]) <= 1e-4
                    }
                }) else { throw Failure("\(path) has an uncovered roof probe at \(point) metres") }
                probes += 1
            }
        }
        print("PASS \(path): \(probes) upward roof-coverage probes, \(triangles.count) non-degenerate triangles")
    }

    static func run(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try roofCheck("variants/neolithic-square-hip", wall: SIMD2(5, 5), clipped: false)
        try roofCheck("variants/neolithic-long-gable", wall: SIMD2(4.7, 5.9), clipped: false)
        try roofCheck("variants/neolithic-clipped-thatched", wall: SIMD2(5.45, 4.85), clipped: true)

        let seed: UInt64 = NeolithicReference.seed
        let year = NeolithicReference.year
        let terrain = WorldGen.generate(seed: seed)
        var simulation = Simulation(seed: seed, terrain: terrain)
        simulation.advance(to: year)
        let renderer = try Renderer(context: MetalContext(), terrain: terrain,
                                    colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
        let scene = renderer.scene
        let field = scene.riverField
        let geometry = CityBuilder.build(settlements: simulation.settlements, era: .neolithic,
                                        year: year, terrain: scene.terrain, seed: seed,
                                        riverField: field, renderedGround: scene.renderedTerrainHeight(at:))
        let paths = BuildingCatalog.neolithic.map(\.path)
        guard Set(geometry.buildings.keys.filter { $0.hasPrefix("variants/neolithic-") }) == Set(paths) else {
            throw Failure("The placed house catalog is missing an inland variant or contains legacy houses")
        }

        struct House {
            let path: String
            let position: SIMD3<Float>
            let front: SIMD2<Float>
        }
        var houses: [House] = []
        var occupied: [[SIMD2<Float>]] = []
        for path in paths {
            let instances = geometry.buildings[path, default: []]
            guard !instances.isEmpty else { throw Failure("No placed instance of \(path)") }
            let local = RiverPlacement.authoredBounds(path)
            guard local.count == 4 else { throw Failure("Missing bounds for \(path)") }
            for instance in instances {
                let model = instance.model
                let footprint = RiverPlacement.transformed(local, by: model)
                guard !scene.riverField.intersectsFootprint(footprint, margin: 0) else {
                    throw Failure("Placed house crosses the river at \(model.columns.3)")
                }
                guard !occupied.contains(where: { RiverPlacement.rectanglesOverlap($0, footprint) }) else {
                    throw Failure("Overlapping house roofs at \(model.columns.3)")
                }
                occupied.append(footprint)
                let floor = model.columns.3.y
                let skirtBottom = floor - 1.55 * model.columns.1.y
                guard footprint.allSatisfy({ point in
                    let y = scene.renderedTerrainHeight(at: point)
                    return y >= skirtBottom - 0.005 / metres && y <= floor + 0.005 / metres
                }) else { throw Failure("The terrain does not meet the foundation at \(model.columns.3)") }
                let base = model.columns.3
                houses.append(House(path: path, position: SIMD3(base.x, base.y, base.z),
                    front: simd_normalize(SIMD2(model.columns.2.x, model.columns.2.z))))
            }
            print("PASS \(instances.count) dry, supported, nonoverlapping placements for \(path)")
        }

        // Score the actual two door directions and keep both within the review camera.
        var best: (a: House, b: House, direction: SIMD2<Float>, score: Float)?
        let town = simulation.largestSettlement()!
        for (index, a) in houses.enumerated() {
            for b in houses.dropFirst(index + 1) where a.path != b.path {
                let separation = simd_distance(a.position, b.position) * metres
                guard (8...16).contains(separation) else { continue }
                let midpoint = (a.position + b.position) * 0.5
                let focusDistance = simd_distance(SIMD2(midpoint.x, midpoint.z), SIMD2(town.x, town.z))
                guard focusDistance < 0.085, simd_dot(a.front, b.front) > 0.05 else { continue }
                let direction = simd_normalize(a.front + b.front)
                let side = SIMD2(-direction.y, direction.x)
                let lateral = abs(simd_dot(side, SIMD2(a.position.x - b.position.x, a.position.z - b.position.z))) * metres
                let score = lateral + 5 * simd_dot(a.front, b.front) - abs(separation - 11) * 0.2
                if score > (best?.score ?? -.infinity) { best = (a, b, direction, score) }
            }
        }
        guard let pair = best else { throw Failure("No distinct neighboring inland houses with visible doors") }
        print("PASS neighboring review houses: \(pair.a.path), \(pair.b.path)")
        let centre = (pair.a.position + pair.b.position) * 0.5
        let direction = SIMD3(pair.direction.x, 0, pair.direction.y)
        let up = SIMD3<Float>(0, 1, 0)
        let close = (centre + (direction * 21 + up * 8) / metres, centre + up * (1.6 / metres), Float(42))
        let overhead = (centre + (direction * 4 + up * 39) / metres, centre, Float(45))

        renderer.updateScene(simulation)
        for (name, camera) in [("close", close), ("overhead", overhead)] {
            let (eye, target, fov) = camera
            let view = RiverReviewView(seed: seed, year: year, hour: 15, season: 0.68, precipitation: 0,
                snow: false, animationTime: 24, eye: [eye.x, eye.y, eye.z], target: [target.x, target.y, target.z],
                fov: fov, width: 1440, height: 900, provenance: "NEO-03 neighboring production houses")
            try view.write(to: directory.appendingPathComponent(name + ".json"))
            NeolithicReference.apply(view, to: renderer)
            _ = try Snapshot.write(renderer: renderer, width: view.width, height: view.height,
                                   time: view.animationTime, to: directory.appendingPathComponent(name + "-after.png"))
        }
    }
}
