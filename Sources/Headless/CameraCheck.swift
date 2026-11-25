import Foundation
import simd

/// Real renderer regression: preserve the visible shot, pan in screen directions
/// at several bearings/elevations, and reach a whole-island zoom distance.
enum CameraCheck {
    private enum AutomaticFailure: Error {
        case acceptance
    }

    /// Sample fifteen minutes of the production camera at the saver's cadence.
    /// Optional Metal captures use those same times and the live Auto path.
    static func automatic(directory: URL, seed: UInt64, year: Float, render: Bool) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let terrain = WorldGen.generate(seed: seed)
        var simulation = Simulation(seed: seed, terrain: terrain)
        simulation.advance(to: year)
        let renderer = try Renderer(context: MetalContext(), terrain: terrain,
                                    colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
        renderer.hourOverride = 10
        renderer.seasonOverride = 0.7
        renderer.weatherOverride = 0
        renderer.snowOverride = false
        renderer.updateScene(simulation)
        let metres = RiverNetwork.metresPerUnit
        var minimumClearance = Float.infinity
        var minimumTownSightline = Float.infinity
        var maximumTurn: Float = 0
        var maximumZoomStep: Float = 0
        var previous = renderer.automaticCamera(time: 0)
        var closeBearings: Set<Int> = []
        var heldFieldsOfView: Set<Int> = []
        var trace = "time_s,eye_x_km,eye_y_km,eye_z_km,target_x_km,target_y_km,target_z_km,fov_deg\n"

        for frame in 0...(900 * 30) {
            let time = Float(frame) / 30
            let camera = renderer.automaticCamera(time: time)
            let eye = SIMD2(camera.eye.x, camera.eye.z)
            let target = SIMD2(camera.target.x, camera.target.z)
            let radius = simd_distance(eye, target)
            let ground = renderer.scene.renderedTerrainHeight(at: eye)
            minimumClearance = min(minimumClearance, (camera.eye.y - max(ground, 0)) * metres)
            let direction = simd_normalize(camera.target - camera.eye)
            let previousDirection = simd_normalize(previous.target - previous.eye)
            let angle = atan2(simd_length(simd_cross(direction, previousDirection)), simd_dot(direction, previousDirection))
            maximumTurn = max(maximumTurn, angle * 180 / .pi)
            let framing = simd_distance(camera.eye, camera.target) * tan(degreesToRadians(camera.fov * 0.5))
            let previousFraming = simd_distance(previous.eye, previous.target) * tan(degreesToRadians(previous.fov * 0.5))
            maximumZoomStep = max(maximumZoomStep, abs(log(framing / previousFraming)))

            if frame.isMultiple(of: 30) {
                let next = renderer.automaticCamera(time: time + 1)
                if camera.fov == next.fov {
                    heldFieldsOfView.insert(Int(camera.fov.rounded()))
                    if radius < 800 / metres {
                        let azimuth = atan2(eye.y - target.y, eye.x - target.x)
                        closeBearings.insert(Int(floor((azimuth + .pi) / (.pi / 4))))
                        for distance in stride(from: Float(30) / metres, to: radius, by: 2 / metres) {
                            let line = camera.target + (camera.eye - camera.target) * (distance / radius)
                            let height = renderer.scene.renderedTerrainHeight(at: SIMD2(line.x, line.z))
                            minimumTownSightline = min(minimumTownSightline, (line.y - height) * metres)
                        }
                    }
                }
                trace += "\(time),\(camera.eye.x),\(camera.eye.y),\(camera.eye.z),"
                trace += "\(camera.target.x),\(camera.target.y),\(camera.target.z),\(camera.fov)\n"
            }
            if render && frame.isMultiple(of: 60) {
                let url = directory.appendingPathComponent(String(format: "frame-%03d.png", frame / 60))
                _ = try Snapshot.write(renderer: renderer, width: 800, height: 500, time: time, to: url)
                guard let shown = renderer.lastReviewView,
                      shown.eye == [camera.eye.x, camera.eye.y, camera.eye.z],
                      shown.target == [camera.target.x, camera.target.y, camera.target.z],
                      shown.fov == camera.fov else { throw AutomaticFailure.acceptance }
            }
            previous = camera
        }
        try trace.write(to: directory.appendingPathComponent("camera.csv"), atomically: true, encoding: .utf8)
        print("Auto camera seed \(seed), year \(year), 27001 poses over 900 seconds")
        print(String(format: "min eye clearance %.2f m, min held town/valley sightline %.2f m", minimumClearance, minimumTownSightline))
        print(String(format: "max turn %.3f°/frame, max framing change %.3f%%/frame", maximumTurn, maximumZoomStep * 100))
        print("held FOVs \(heldFieldsOfView.sorted()), close bearing sectors \(closeBearings.sorted())")
        guard minimumClearance >= 15, minimumTownSightline >= 0, maximumTurn <= 0.4,
              maximumZoomStep <= 0.02, heldFieldsOfView.count >= 4,
              closeBearings.count >= 3 else { throw AutomaticFailure.acceptance }
        print("PASS automatic camera clearance, continuity and variety")
    }

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
