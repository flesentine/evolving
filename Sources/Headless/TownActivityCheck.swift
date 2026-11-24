import Foundation
import simd

enum TownActivityCheck {
    static func run(directory: URL, seed: UInt64) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let terrain = WorldGen.generate(seed: seed)
        let renderer = try Renderer(context: MetalContext(), terrain: terrain,
                                    colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
        renderer.hourOverride = 11
        renderer.weatherOverride = 0
        renderer.seasonOverride = 0.4
        renderer.snowOverride = false

        let cases: [(Float, TownActivity.Kind, Float)] = [
            (500, .fieldwork, 11), (4400, .market, 9), (6700, .freight, 12)
        ]
        var simulation = Simulation(seed: seed, terrain: terrain)
        var expected: [[TownActivity]] = []
        var times: [Float] = []

        for (year, kind, period) in cases {
            simulation.advance(to: year)
            renderer.updateScene(simulation)
            let routes = renderer.townActivities
            guard let route = routes.first, routes.allSatisfy({ $0.kind == kind }),
                  Set(routes.map(\.townID)).count == routes.count else {
                fail("Missing or repeated \(kind.rawValue) activity at year \(year)")
            }
            let travel = (1.16 - route.offset) * period
            let action = (1.45 - route.offset) * period
            let walkPose = route.sample(time: travel)
            let workPose = route.sample(time: action)
            guard simd_distance(walkPose.position, workPose.position) > 1 / TownActivity.metres,
                  walkPose.reach == 0, workPose.reach > 0.2 else {
                fail("\(kind.rawValue) failed to move and perform its activity")
            }
            expected.append(routes)
            times.append(action)
            let focus = (route.start + route.end) * 0.5
            let direction = simd_normalize(route.end - route.start)
            let right = SIMD2(direction.y, -direction.x)
            let eye = focus + (right * 22 + direction * 7) / TownActivity.metres
            let height = renderer.scene.renderedTerrainHeight(at: focus)
            renderer.cameraOverride = Renderer.Camera(
                eye: SIMD3(eye.x, height + 18 / TownActivity.metres, eye.y),
                target: SIMD3(focus.x, height + 1.9 / TownActivity.metres, focus.y), fov: 38)
            for (name, time) in [("travel", travel), ("action", action)] {
                let label = "\(kind.rawValue)-\(name)"
                try Snapshot.write(renderer: renderer, width: 1080, height: 720, time: time,
                                   to: directory.appendingPathComponent(label + ".png"))
                try renderer.lastReviewView?.write(to: directory.appendingPathComponent(label + ".json"))
            }
            print("\(simulation.era.name): \(routes.count) active \(kind.rawValue) sites; captured town #\(route.townID)")
        }

        for index in cases.indices.reversed() {
            let (year, kind, _) = cases[index]
            var rewind = Simulation(seed: seed, terrain: terrain)
            rewind.advance(to: year)
            renderer.updateScene(rewind)
            let actual = renderer.townActivities
            let time = times[index]
            guard actual == expected[index],
                  actual.map({ $0.sample(time: time) }) == expected[index].map({ $0.sample(time: time) }) else {
                fail("\(kind.rawValue) routes or poses changed after rewind")
            }
        }
        print("PASS three distinct era activities, visible movement, and exact routes and poses on rewind")
    }
}
