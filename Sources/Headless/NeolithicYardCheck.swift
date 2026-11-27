import Foundation
import simd

enum NeolithicYardCheck {
    private static let metres = RiverGraph.metresPerUnit

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }

    private static func verify(_ scene: WorldScene) throws {
        guard let mesh = scene.yardMesh, let indexBuffer = mesh.indexBuffer else {
            throw Failure("No submitted yard mesh")
        }
        let vertices = mesh.vertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
        let indices = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        let layout = scene.neolithicYards
        let ground = FieldSurface.Mask(mesh: mesh)
        var pathProbes = 0
        for yard in layout.yards {
            guard yard.connections.count >= 2, ground.covers(yard.centre) else {
                throw Failure("An emitted yard has no shared walkable centre")
            }
            for connection in yard.connections {
                for (a, b) in zip(connection.points, connection.points.dropFirst()) {
                    let steps = Int(ceil(simd_distance(a, b) * metres / 0.3))
                    for i in 0...steps {
                        let point = a + (b - a) * (Float(i) / Float(steps))
                        guard ground.covers(point) else {
                            throw Failure("A submitted path has a gap at \(point)")
                        }
                        pathProbes += 1
                    }
                }
            }
            for section in yard.fenceSections {
                guard !ground.intersectsFootprint(section),
                      !scene.riverField.intersectsFootprint(section, margin: 0) else {
                    throw Failure("Fence interrupts a yard or crosses water")
                }
            }
        }
        for i in stride(from: 0, to: mesh.indexCount, by: 3) {
            let triangle = (0..<3).map { vertices[Int(indices[i + $0])].position }
            let centroid = (triangle[0] + triangle[1] + triangle[2]) / 3
            let centre = SIMD2(centroid.x, centroid.z)
            let expected = scene.renderedTerrainHeight(at: centre) + FieldSurface.cropLift
            guard abs(centroid.y - expected) <= 0.002 / metres,
                  !scene.terrain.isWater(x: centre.x, z: centre.y),
                  !scene.riverField.intersectsFootprint(triangle.map { SIMD2($0.x, $0.z) }) else {
                throw Failure("A submitted yard triangle floats, sinks, or touches wet ground at \(centre)")
            }
        }

        let sections = layout.yards.reduce(0) { $0 + $1.fenceSections.count }
        let posts = layout.fences.filter { abs($0.model.columns.1.y - 0.76 / metres) < 1e-7 }
        guard sections > 0, posts.count == sections * 3 else { throw Failure("Missing fence posts") }
        for post in posts {
            let origin = post.model.columns.3
            let terrain = scene.renderedTerrainHeight(at: SIMD2(origin.x, origin.z))
            guard abs(origin.y - terrain - 0.30 / metres) <= 0.002 / metres else {
                throw Failure("A fence post is floating or buried")
            }
        }
        let cube = RiverPlacement.bounds(Geometry.cube())
        for step in layout.steps {
            let footprint = RiverPlacement.transformed(cube, by: step.model)
            let bottom = step.model.columns.3.y - step.model.columns.1.y * 0.5
            guard footprint.allSatisfy({ scene.renderedTerrainHeight(at: $0) >= bottom - 0.002 / metres }),
                  !scene.riverField.intersectsFootprint(footprint) else {
                throw Failure("A doorway step floats or crosses water")
            }
        }
        print("PASS \(layout.yards.count) shared yards, \(pathProbes) doorway-to-centre probes, "
            + "\(mesh.indexCount / 3) dry terrain triangles, \(sections) open fence sections, \(posts.count) grounded posts, \(layout.steps.count) supported steps")
    }

    static func run(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reviews: [(String, UInt64, Float)] = [
            ("inland", 1, 450), ("coastal", 6, 790), ("coastal", 5, 790), ("coastal", 8, 790),
            ("coastal", 1, 790), ("coastal", 6, 720), ("coastal", 5, 720),
            ("coastal", 8, 720), ("coastal", 1, 720)
        ]
        for (label, seed, year) in reviews {
            let terrain = WorldGen.generate(seed: seed)
            var simulation = Simulation(seed: seed, terrain: terrain)
            simulation.advance(to: year)
            let renderer = try Renderer(context: MetalContext(), terrain: terrain,
                                        colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
            renderer.updateScene(simulation)
            print("\(label), seed \(seed), year \(year)")
            if renderer.scene.yardMesh != nil { try verify(renderer.scene) }
            let candidates = renderer.scene.neolithicYards.yards.filter { yard in
                yard.connections.contains { $0.entrance.stone } == (label == "coastal")
            }
            guard let yard = candidates.max(by: {
                ($0.connections.count, $0.fenceSections.count) < ($1.connections.count, $1.fenceSections.count)
            }) else {
                if label == "inland" { throw Failure("No inland shared yard to review") }
                print("No linked stone doors in this world and year")
                continue
            }

            let centre = yard.centre
            let ground = renderer.scene.renderedTerrainHeight(at: centre)
            let target = SIMD3(centre.x, ground, centre.y)
            let aim = yard.connections.first!.entrance.forward
            let offset = aim * (9 / metres) + SIMD2(-aim.y, aim.x) * (7 / metres)
            let eye = target + SIMD3(offset.x, 23 / metres, offset.y)
            let view = RiverReviewView(seed: seed, year: year, hour: 14, season: 0.68,
                precipitation: 0, snow: false, animationTime: 27, eye: [eye.x, eye.y, eye.z],
                target: [target.x, target.y, target.z], fov: 45, width: 1440, height: 900,
                provenance: "NEO-05 shared \(label) yard and door paths")
            try view.write(to: directory.appendingPathComponent(label + ".json"))
            NeolithicReference.apply(view, to: renderer)
            _ = try Snapshot.write(renderer: renderer, width: view.width, height: view.height,
                                   time: view.animationTime,
                                   to: directory.appendingPathComponent(label + "-after.png"))
            if label == "coastal" { return }
        }
        throw Failure("No shared yard connecting to a stone dwelling in the coastal review matrix")
    }
}
