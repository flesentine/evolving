import Foundation

/// Replay a portable view through the production renderer, then isolate each
/// contributing layer without rebuilding a diagnostic-only water surface.
enum RiverReview {
    static func lakeFixture(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let terrain = RiverEndpointValidation.fixtureTerrain()
        let renderer = try Renderer(context: MetalContext(), terrain: terrain,
            colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
        renderer.hourOverride = 10; renderer.seasonOverride = 0.3
        renderer.weatherOverride = 0; renderer.snowOverride = false
        renderer.cameraOverride = Renderer.Camera(eye: SIMD3(0.5, 0.6, 0.6),
            target: SIMD3(0.05, 0.1, 0), fov: 52) // world units
        for mode in ["normal", "flat", "wire", "terrain", "banks"] {
            renderer.riverReviewMode = mode == "normal" ? "" : mode
            _ = try Snapshot.write(renderer: renderer, width: 1600, height: 1000,
                time: 0, to: directory.appendingPathComponent(mode + ".png"))
        }
        print("bounded lake/island fixture rendered; reproduce with riverlakefixture \(directory.path)")
    }

    static func replay(_ record: RiverReviewView, directory: URL, allPasses: Bool, includeIDs: Bool = true) throws {
        _ = try record.validated()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let terrain = WorldGen.generate(seed: record.seed)
        var simulation = Simulation(seed: record.seed, terrain: terrain)
        simulation.advance(to: record.year)
        let renderer = try Renderer(context: MetalContext(), terrain: terrain,
            colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
        renderer.hourOverride = record.hour; renderer.seasonOverride = record.season
        renderer.weatherOverride = record.precipitation; renderer.snowOverride = record.snow
        renderer.cameraOverride = Renderer.Camera(eye: SIMD3(record.eye[0], record.eye[1], record.eye[2]),
            target: SIMD3(record.target[0], record.target[1], record.target[2]), fov: record.fov)
        renderer.updateScene(simulation)
        for mode in allPasses ? ["normal", "flat", "wire", "height", "depth", "terrain", "banks"] : ["normal"] {
            renderer.riverReviewMode = mode == "normal" ? "" : mode
            let output = directory.appendingPathComponent(mode + ".png")
            _ = try Snapshot.write(renderer: renderer, width: record.width, height: record.height,
                time: record.animationTime, to: output)
            try verifyCapture(record, renderer: renderer)
            print("wrote \(output.path)")
        }
        try record.write(to: directory.appendingPathComponent("view.json"))
        if allPasses && includeIDs {
            try RiverDebugImage.write(terrain: terrain, network: renderer.scene.riverField.network,
                field: renderer.scene.riverField, directory: directory.appendingPathComponent("junction-ids"))
        }
        print("review view: \(record.provenance), seed \(record.seed), year \(record.year)")
    }

    private static func verifyCapture(_ expected: RiverReviewView, renderer: Renderer) throws {
        guard var actual = renderer.lastReviewView else { throw SnapshotError.write("frame did not produce a review record") }
        actual.provenance = expected.provenance
        guard actual == expected else { throw SnapshotError.write("rendered camera/weather/time differs from requested review record: \(actual)") }
    }

    /// Every frame gets a portable record, so any visual failure can be
    /// replayed with all isolation passes without manually finding its camera.
    static func matrix(_ directory: URL) throws {
        for seed: UInt64 in Array(1...11) + [6393821808673518700] {
            let terrain = WorldGen.generate(seed: seed)
            var simulation = Simulation(seed: seed, terrain: terrain); simulation.advance(to: 2336)
            let renderer = try Renderer(context: MetalContext(), terrain: terrain,
                colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
            renderer.updateScene(simulation)
            let town = simulation.largestSettlement()
            let p = town.map { SIMD2($0.x, $0.z) } ?? .zero
            let y = renderer.scene.terrain.interpolatedHeight(x: p.x, z: p.y)
            let target = SIMD3<Float>(p.x, y + 5 / RiverGraph.metresPerUnit, p.y)
            let views: [(String, SIMD3<Float>, SIMD3<Float>)] = [
                ("island", SIMD3(1.6, 1.9, 1.6), SIMD3(0, 0.025, 0)), // world units
                ("town", target + SIMD3(0.14, 0.16, 0.20), target),
                ("overhead", target + SIMD3(0, 0.45, 0.001), target)]
            for (name, eye, look) in views {
                for (condition, hour, rain, snow): (String, Float, Float, Bool) in [
                    ("day", 10, 0, false), ("night", 22, 0, false), ("rain", 10, 0.8, false)] {
                    let record = RiverReviewView(seed: seed, year: simulation.year, hour: hour, season: 0.7,
                        precipitation: rain, snow: snow, animationTime: 40,
                        eye: [eye.x, eye.y, eye.z], target: [look.x, look.y, look.z],
                        fov: 52, width: 1600, height: 1000, provenance: "automated \(name) / \(condition) acceptance view")
                    let out = directory.appendingPathComponent("\(seed)/\(name)-\(condition)")
                    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                    renderer.hourOverride = hour; renderer.seasonOverride = record.season
                    renderer.weatherOverride = rain; renderer.snowOverride = snow
                    renderer.cameraOverride = Renderer.Camera(eye: eye, target: look, fov: record.fov)
                    _ = try Snapshot.write(renderer: renderer, width: record.width, height: record.height,
                        time: record.animationTime, to: out.appendingPathComponent("normal.png"))
                    try verifyCapture(record, renderer: renderer)
                    try record.write(to: out.appendingPathComponent("view.json"))
                    print("matrix seed \(seed): \(name)-\(condition)")
                }
            }
        }
    }
}
