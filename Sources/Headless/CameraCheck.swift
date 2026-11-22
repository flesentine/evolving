import Foundation
import simd

/// Real renderer regression: preserve the visible shot, pan in screen directions
/// at several bearings/elevations, and reach a whole-island zoom distance.
enum CameraCheck {
    static func run(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let terrain = WorldGen.generate(seed: 6393821808673518700)
        var simulation = Simulation(seed: 6393821808673518700, terrain: terrain)
        simulation.advance(to: 4583)
        let renderer = try Renderer(context: MetalContext(), terrain: terrain,
                                    colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
        renderer.hourOverride = 10
        renderer.updateScene(simulation)
        try checkTreePlacement(renderer: renderer, simulation: simulation)
        let metres = RiverNetwork.metresPerUnit
        let epsilon = 0.001 / metres // 1 mm camera-position roundoff tolerance
        let original = Renderer.Camera(eye: SIMD3(-0.15, 0.40, -0.05),
                                       target: SIMD3(0.18, 0.06, 0.25), fov: 52) // world units
        renderer.cameraOverride = original
        _ = try Snapshot.write(renderer: renderer, width: 1600, height: 1000, time: 0,
                               to: directory.appendingPathComponent("before-pan.png"))
        renderer.beginFreeCamera()
        precondition(simd_distance(renderer.cameraOverride!.eye, original.eye) < epsilon
                     && renderer.cameraOverride!.fov == original.fov, "first gesture jumps the visible camera")
        renderer.panCamera(dx: 0.15, dy: 0.10)
        _ = try Snapshot.write(renderer: renderer, width: 1600, height: 1000, time: 0,
                               to: directory.appendingPathComponent("after-pan.png"))
        for yaw: Float in [0, .pi / 2, .pi, .pi * 1.5] {
            for pitch: Float in [-0.15, 0.03, 0.083, 0.35, 1.0, 1.50] {
                renderer.endFreeCamera()
                let distance = 300 / metres
                let target = SIMD3<Float>(0, 40 / metres, 0)
                let eye = target + SIMD3(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch)) * distance
                renderer.cameraOverride = Renderer.Camera(eye: eye, target: target, fov: 48)
                renderer.beginFreeCamera()
                precondition(simd_distance(renderer.cameraOverride!.eye, eye) < epsilon,
                             "camera takeover changes a low/street/overhead angle")
                renderer.panCamera(dx: 0.05, dy: 0.05)
                let camera = renderer.cameraOverride!
                let matrix = perspective(fovyRadians: degreesToRadians(camera.fov), aspect: 1.6,
                                         near: 4 / metres, far: 30) // far is 30 world units
                    * lookAt(eye: camera.eye, center: camera.target, up: SIMD3(0, 1, 0))
                let point = matrix * SIMD4(target, 1)
                precondition(point.x / point.w > 0 && point.y / point.w > 0,
                             "positive drag must move the world right/up at every bearing")

                renderer.endFreeCamera()
                renderer.cameraOverride = Renderer.Camera(eye: eye, target: target, fov: 48)
                let capture = yaw == 0 && pitch == 0.083
                if capture {
                    _ = try Snapshot.write(renderer: renderer, width: 1600, height: 1000, time: 0,
                                           to: directory.appendingPathComponent("low-shot-before-orbit.png"))
                }
                let yawDelta: Float = 0.1
                renderer.orbitCamera(dx: yawDelta, dy: 0)
                let orbit = renderer.cameraOverride!
                let expectedEye = target + SIMD3(cos(yaw + yawDelta) * cos(pitch), sin(pitch),
                                                  sin(yaw + yawDelta) * cos(pitch)) * distance
                guard simd_distance(orbit.eye, expectedEye) < epsilon,
                      orbit.target == target, orbit.fov == 48 else {
                    throw NSError(domain: "CameraCheck", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "first horizontal orbit moved the captured shot off its pitch at \(pitch) rad"
                    ])
                }
                if capture {
                    _ = try Snapshot.write(renderer: renderer, width: 1600, height: 1000, time: 0,
                                           to: directory.appendingPathComponent("low-shot-after-orbit.png"))
                }
                if pitch < 0.10 || pitch > 1.35 {
                    let inward: Float = pitch < 0.10 ? 0.01 : -0.01
                    renderer.orbitCamera(dx: 0, dy: -inward)
                    precondition(simd_distance(renderer.cameraOverride!.eye, orbit.eye) < epsilon,
                                 "vertical drag must not move farther outside the manual range")
                    renderer.orbitCamera(dx: 0, dy: inward)
                    let expectedHeight = target.y + sin(pitch + inward) * distance
                    precondition(abs(renderer.cameraOverride!.eye.y - expectedHeight) < epsilon,
                                 "vertical drag toward the manual range must move without snapping")
                }
            }
        }
        renderer.zoomCamera(10000)
        precondition(abs(simd_distance(renderer.cameraOverride!.eye, renderer.cameraOverride!.target)
                         - 4000 / metres) < epsilon, "cannot zoom out to whole island")
        _ = try Snapshot.write(renderer: renderer, width: 1600, height: 1000, time: 0,
                               to: directory.appendingPathComponent("whole-island.png"))
        renderer.zoomCamera(0.000001)
        precondition(abs(simd_distance(renderer.cameraOverride!.eye, renderer.cameraOverride!.target)
                         - 8 / metres) < epsilon, "close zoom limit changed unexpectedly")
        renderer.endFreeCamera()
        precondition(renderer.cameraOverride == nil, "Auto must release the manual camera")
        print("PASS rendered camera: initial shot/FOV preserved; pan and orbit at 4 bearings × 6 pitches; gradual return to manual pitch range; 8 m–4 km zoom; Auto reset")
    }

    private static func checkTreePlacement(renderer: Renderer, simulation: Simulation) throws {
        let field = renderer.scene.riverField
        let expected = CityBuilder.trees(terrain: renderer.scene.terrain,
            settlements: simulation.settlements, seed: simulation.seed, riverField: field)
        let oldNative = CityBuilder.trees(terrain: simulation.terrain,
            settlements: simulation.settlements, seed: simulation.seed, riverField: field)
        let conifers = expected.conifers.map { $0.model.columns.3 }
        let broadleaves = expected.broadleaves.map { $0.model.columns.3 }
        let rendered = renderer.renderedTreeOrigins()
        guard !conifers.isEmpty, !broadleaves.isEmpty,
              rendered.conifers == conifers, rendered.broadleaves == broadleaves,
              rendered.conifers != oldNative.conifers.map({ $0.model.columns.3 })
                || rendered.broadleaves != oldNative.broadleaves.map({ $0.model.columns.3 }) else {
            throw NSError(domain: "CameraCheck", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "tree instance buffers must match carved placement terrain and expose the old native mismatch"
            ])
        }
        print("PASS rendered trees: \(conifers.count) conifers and \(broadleaves.count) broadleaves match the shared placement terrain; the old native path differs")
    }
}
