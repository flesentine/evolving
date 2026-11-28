import Foundation
import simd

enum BronzeCraftCheck {
    private static let metres = RiverGraph.metresPerUnit
    private static let paths = Set(BronzeCraft.allCases.map(\.path))
    private typealias Submitted = (path: String, instance: InstanceData)

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func run(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = try MetalContext()
        var total = 0
        var savedViews = false
        for seed: UInt64 in [8, 1, 10] {
            let terrain = WorldGen.generate(seed: seed)
            let renderer = try Renderer(context: context, terrain: terrain,
                colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
            let supports = try supportPoints(renderer)
            var sim = Simulation(seed: seed, terrain: terrain)
            for year in (seed == 8 ? [790, 810, 1450, 1990, 2010] : [1450]) {
                sim.advance(to: Float(year))
                renderer.updateScene(sim)
                let props = renderer.submittedBuildings().filter { paths.contains($0.path) }
                if sim.era != .bronze {
                    guard props.isEmpty else { throw Failure("Craft props leaked into year \(year)") }
                    continue
                }
                let label = "seed \(seed) year \(year)"
                try inspect(props, supports: supports, renderer: renderer, label: label)
                total += props.count
                if !savedViews, year == 1450, !props.isEmpty {
                    try saveViews(props, renderer: renderer, simulation: sim, directory: directory)
                    renderer.updateScene(sim, refreshRoads: true)
                    let replay = renderer.submittedBuildings().filter { paths.contains($0.path) }
                    guard bits(replay) == bits(props) else { throw Failure("Craft instances differ on replay") }
                    print("PASS \(label): craft transforms and materials match bit for bit on replay")
                    savedViews = true
                }
            }
        }
        guard total > 0, savedViews else { throw Failure("Expected occupied Bronze workshops in the review matrix") }
        print("PASS \(total) submitted craft props across the Bronze review matrix")
    }

    private static func supportPoints(_ renderer: Renderer) throws -> [String: [SIMD3<Float>]] {
        var result: [String: [SIMD3<Float>]] = [:]
        for kind in BronzeCraft.allCases {
            guard let mesh = renderer.scene.buildingMeshes.first(where: { $0.path == kind.path })?.mesh,
                  mesh.indexCount > 0 else { throw Failure("Missing submitted mesh for \(kind.path)") }
            let raw = mesh.vertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
            let vertices = (0..<mesh.vertexCount).map { raw[$0] }
            let bounds = vertices.map(\.position.y)
            let height = bounds.max()! - bounds.min()!
            let acceptable: ClosedRange<Float>
            switch kind {
            case .loom: acceptable = 1.64...1.90
            case .workbench: acceptable = 0.86...1.02
            case .basket: acceptable = 0.34...0.49
            case .pottery: acceptable = 0.43...0.65
            }
            guard acceptable.contains(height) else { throw Failure("Wrong authored scale for \(kind.path): \(height) m") }
            if kind == .workbench {
                let bronze = vertices.filter { $0.uv.x > 0.75 && (0.50..<0.75).contains($0.uv.y) }
                guard bronze.count >= 30, bronze.allSatisfy({ $0.position.y > 0.78 }) else {
                    throw Failure("Expected a metal tool resting on the bench")
                }
            }
            result[kind.path] = vertices.map(\.position).filter { $0.y < -0.066 }
            guard result[kind.path]!.count >= 4 else { throw Failure("Missing authored footing for \(kind.path)") }
        }
        return result
    }

    private static func inspect(_ props: [Submitted], supports: [String: [SIMD3<Float>]],
                                renderer: Renderer, label: String) throws {
        let scene = renderer.scene
        let counts = Dictionary(grouping: props, by: \.path).values.map(\.count)
        guard props.isEmpty || (counts.count == paths.count && Set(counts).count == 1) else {
            throw Failure("\(label) submitted an incomplete workshop")
        }
        let routes = [scene.activityStreets, FieldSurface.Mask(mesh: scene.bronzeAccessMesh),
                      scene.activityRoads, FieldSurface.Mask(mesh: scene.fieldMesh), scene.riverBankFootprint]
        var solid = FieldSurface.Mask()
        for pen in scene.bronzePens {
            for footprint in BronzeEnclosures.footprints(pen) { solid.insertFootprint(footprint) }
        }
        for house in renderer.submittedBuildings() where !paths.contains(house.path) {
            solid.insertFootprint(RiverPlacement.transformed(RiverPlacement.authoredBounds(house.path), by: house.instance.model))
        }
        for prop in props {
            let model = prop.instance.model
            let area = RiverPlacement.transformed(RiverPlacement.authoredBounds(prop.path), by: model)
            let centre = NeolithicPeople.xz(model.columns.3)
            let scale = simd_length(SIMD3(model.columns.1.x, model.columns.1.y, model.columns.1.z)) * metres
            guard abs(scale - 1) < 0.001, !solid.intersectsFootprint(area),
                  routes.allSatisfy({ !$0.intersectsFootprint(area) }),
                  !scene.riverField.intersectsFootprint(area, margin: 0.30 / metres),
                  area.allSatisfy({ !scene.terrain.isWater(x: $0.x, z: $0.y) }),
                  renderer.bronzeCourts.contains(where: { simd_distance($0, centre) <= 8 / metres })
            else { throw Failure("\(label) wrong scale or obstructed craft prop at \(centre)") }
            solid.insertFootprint(area)
            for p in supports[prop.path, default: []] {
                let v = model * SIMD4(p, 1)
                let gap = (v.y - scene.renderedTerrainHeight(at: NeolithicPeople.xz(v))) * metres
                guard gap <= 0.008, gap >= -0.17 else {
                    throw Failure("\(label) craft prop footing is \(gap) m from terrain, \(prop.path) at \(centre)")
                }
            }
        }
        print("PASS \(label): \(props.count / paths.count) complete workshops with grounded, clear props")
    }

    private static func bits(_ props: [Submitted]) -> [UInt32] {
        props.flatMap { entry in
            let m = entry.instance.model.columns
            return [m.0, m.1, m.2, m.3, entry.instance.color, entry.instance.material].flatMap {
                [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern, $0.w.bitPattern]
            }
        }
    }

    private static func saveViews(_ props: [Submitted], renderer: Renderer, simulation: Simulation,
                                  directory: URL) throws {
        let benches = props.filter { $0.path == BronzeCraft.workbench.path }
        let looms = props.filter { $0.path == BronzeCraft.loom.path }
        let pairs = benches.compactMap { bench -> (InstanceData, InstanceData)? in
            let position = NeolithicPeople.xz(bench.instance.model.columns.3)
            guard let loom = looms.first(where: {
                simd_distance(position, NeolithicPeople.xz($0.instance.model.columns.3)) < 2 / metres
            }) else { return nil }
            return (bench.instance, loom.instance)
        }
        guard let picked = pairs.first else { throw Failure("Missing a loom next to a workbench") }
        let model = picked.0.model
        let bench = NeolithicPeople.xz(model.columns.3)
        let loom = NeolithicPeople.xz(picked.1.model.columns.3)
        let middle = (loom + bench) * 0.5
        let front = simd_normalize(NeolithicPeople.xz(model.columns.2))
        let side = SIMD2(front.y, -front.x)
        // Leave room for Timeline's 4 m near plane. A narrower lens
        // keeps the props legible without clipping the top of the loom.
        let close = middle + (front * 4.50 + side * 0.42) / metres
        let toolTarget = bench - front * (0.26 / metres)
        let details = toolTarget + (front * 3.165 + side * 1.875) / metres
        let views: [(String, SIMD2<Float>, SIMD2<Float>, Float, Float, Float)] = [
            ("court-close", middle, close, 6.13, 0.56, 31),
            ("tool-and-pottery", toolTarget, details, 5.89, 0.52, 19)
        ]
        for (name, p, eye, eyeHeight, targetHeight, fov) in views {
            let ground = renderer.scene.renderedTerrainHeight(at: p)
            let eyeGround = renderer.scene.renderedTerrainHeight(at: eye)
            let view = RiverReviewView(seed: simulation.seed, year: simulation.year, hour: 13.25, season: 0.68,
                precipitation: 0, snow: false, animationTime: 24,
                eye: [eye.x, max(ground, eyeGround) + eyeHeight / metres, eye.y],
                target: [p.x, ground + targetHeight / metres, p.y], fov: fov, width: 1440, height: 900,
                provenance: "BRZ-06 production workshop — \(name)")
            try view.write(to: directory.appendingPathComponent(name + ".json"))
        }
    }
}
