import Foundation
import simd

enum BronzeWorkCheck {
    private static let metres = RiverGraph.metresPerUnit

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func run(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = try MetalContext()
        var total = 0
        for seed: UInt64 in [8, 1, 10] {
            let terrain = WorldGen.generate(seed: seed)
            let renderer = try Renderer(context: context, terrain: terrain,
                colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
            var simulation = Simulation(seed: seed, terrain: terrain)
            for year in (seed == 8 ? [790, 810, 1450, 1990, 2010] : [1450]) {
                simulation.advance(to: Float(year))
                renderer.updateScene(simulation)
                guard simulation.era == .bronze else {
                    guard renderer.bronzePeople.isEmpty,
                          BronzePeople.Part.allCases.allSatisfy({ renderer.submittedBronzePeople($0).isEmpty })
                    else { throw Failure("Bronze workers leaked into \(year)") }
                    continue
                }
                let label = "seed \(seed) year \(year)"
                try inspect(renderer, label: label)
                total += renderer.bronzePeople.count
                let counts = BronzePeople.Kind.allCases.map { kind in
                    "\(renderer.bronzePeople.count(where: { $0.kind == kind })) \(kind.rawValue)"
                }
                print("PASS \(label): \(counts.joined(separator: ", "))")
                if seed == 8 && year == 1450 {
                    try renderReview(renderer, simulation: simulation, directory: directory)
                }
            }
        }
        guard total > 0 else { throw Failure("The renderer submitted no craft workers") }
        print("PASS \(total) Bronze work routines across the review matrix")
    }

    private static func inspect(_ renderer: Renderer, label: String) throws {
        let scene = renderer.scene
        let crops = FieldSurface.Mask(mesh: scene.fieldMesh)
        let access = FieldSurface.Mask(mesh: scene.bronzeAccessMesh)
        var solids = FieldSurface.Mask()
        for house in renderer.submittedBuildings() {
            solids.insertFootprint(RiverPlacement.transformed(RiverPlacement.authoredBounds(house.path),
                                                              by: house.instance.model))
        }
        for pen in scene.bronzePens {
            for area in BronzeEnclosures.footprints(pen) { solids.insertFootprint(area) }
        }
        var people = FieldSurface.Mask()
        let roads = scene.activityRoads
        let banks = scene.riverBankFootprint
        for routine in renderer.bronzePeople {
            let area = routine.clearance
            guard !solids.intersectsFootprint(area), !people.intersectsFootprint(area),
                  !roads.intersectsFootprint(area), !banks.intersectsFootprint(area),
                  !access.intersectsFootprint(area), !crops.intersectsFootprint(area),
                  !scene.riverField.intersectsFootprint(area, margin: 0.30 / metres) else {
                throw Failure("\(label) \(routine.kind) overlaps an obstacle")
            }
            people.insertFootprint(area)
            var positions: [SIMD3<Float>] = []
            for step in 0..<20 {
                let time = Float(step) * routine.kind.period / 20
                var hands: [SIMD3<Float>] = []
                BronzePeople.sample(routine, time: time, scene: scene) { part, model in
                    if part == .forearm { hands.append(NeolithicPeople.xyz(model.columns.3 - model.columns.1)) }
                    if (routine.kind == .weaving && part == .shuttle)
                        || (routine.kind == .carrying && part == .basket) {
                        positions.append(NeolithicPeople.xyz(model.columns.3))
                    }
                }
                guard hands.count == 2, hands.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
                    throw Failure("\(label) \(routine.kind) has invalid hand transforms")
                }
                if routine.kind == .shaping, let jar = routine.fixture {
                    let centre = NeolithicPeople.xyz(jar.columns.3)
                    guard hands.allSatisfy({ simd_distance($0, centre) <= 0.154 / metres }) else {
                        throw Failure("\(label) potter loses contact with the rim")
                    }
                    positions.append(hands[1])
                }
                if routine.kind == .carrying {
                    let point = routine.motion(at: time).point
                    guard scene.activityStreets.covers(point), !scene.terrain.isWater(x: point.x, z: point.y) else {
                        throw Failure("\(label) carrier leaves the dry court")
                    }
                }
            }
            let required: Float = routine.kind == .carrying ? 2.0 : routine.kind == .weaving ? 0.22 : 0.06
            // The seeded phase can start anywhere in the stroke. Measure
            // total travel across the cycle rather than from its first sample.
            guard positions.indices.contains(where: { i in
                positions.dropFirst(i + 1).contains { simd_distance($0, positions[i]) >= required / metres }
            }) else {
                throw Failure("\(label) \(routine.kind) does not complete its intended stroke")
            }
        }
    }

    private static func renderReview(_ renderer: Renderer, simulation: Simulation, directory: URL) throws {
        for kind in BronzePeople.Kind.allCases {
            guard let routine = renderer.bronzePeople.first(where: { $0.kind == kind }) else {
                throw Failure("Seed 8 year 1450 is missing \(kind.rawValue)")
            }
            let axis = simd_normalize(routine.end - routine.start)
            let right = SIMD2(axis.y, -axis.x)
            let targetXZ: SIMD2<Float>
            let camera: SIMD2<Float>
            let rise: Float
            let targetHeight: Float
            let fov: Float
            let phase: Float
            switch kind {
            case .weaving:
                let loom = NeolithicPeople.xz(routine.fixture!.columns.3)
                targetXZ = (routine.start + loom) * 0.5
                camera = targetXZ + (right * 4.8 - axis * 2.9) / metres
                rise = 4.4; targetHeight = 0.83; fov = 27; phase = 0.23
            case .shaping:
                targetXZ = (routine.start + routine.end) * 0.5
                camera = targetXZ + (right * 4.3 + axis * 1.7) / metres
                rise = 4.9; targetHeight = 0.47; fov = 22; phase = 0.19
            case .carrying:
                targetXZ = (routine.start + routine.end) * 0.5
                camera = targetXZ + (right * 5.3 + axis * 1.9) / metres
                rise = 5.0; targetHeight = 0.77; fov = 31; phase = 0.22
            }
            let scene = renderer.scene
            let ground = scene.renderedTerrainHeight(at: targetXZ)
            let eyeGround = scene.renderedTerrainHeight(at: camera)
            let time = (12 + phase - routine.phase) * kind.period
            let view = RiverReviewView(seed: simulation.seed, year: simulation.year, hour: 13.25,
                season: 0.68, precipitation: 0, snow: false, animationTime: time,
                eye: [camera.x, max(ground, eyeGround) + rise / metres, camera.y],
                target: [targetXZ.x, ground + targetHeight / metres, targetXZ.y],
                fov: fov, width: 1280, height: 800, provenance: "BRZ-07 production \(kind.rawValue)")
            let name = kind.rawValue
            let record = directory.appendingPathComponent(name + ".json")
            try view.write(to: record)
            let still = directory.appendingPathComponent(name + ".png")
            try capture(view, output: still, renderer: renderer)
            let first = submitted(renderer)
            try expectProductionPose(renderer, time: view.animationTime)
            var later = view
            later.animationTime += kind.period * 0.23
            let moving = directory.appendingPathComponent(name + "-later.png")
            try capture(later, output: moving, renderer: renderer)
            guard first != submitted(renderer), try Data(contentsOf: still) != Data(contentsOf: moving) else {
                throw Failure("\(kind.rawValue) produced the same submitted pose or pixels at different times")
            }

            let saved = try RiverReviewView.read(record)
            renderer.updateScene(simulation, refreshRoads: true)
            let replay = directory.appendingPathComponent(name + "-replay.png")
            try capture(saved, output: replay, renderer: renderer)
            guard first == submitted(renderer), try Data(contentsOf: still) == Data(contentsOf: replay) else {
                throw Failure("\(kind.rawValue) changed at the same saved animation time")
            }
            print("PASS \(kind.rawValue) saved replay matched Metal instances and rendered PNG byte for byte")
        }
    }

    private static func capture(_ view: RiverReviewView, output: URL, renderer: Renderer) throws {
        NeolithicReference.apply(view, to: renderer)
        _ = try Snapshot.write(renderer: renderer, width: view.width, height: view.height,
                               time: view.animationTime, to: output)
    }

    private static func submitted(_ renderer: Renderer) -> [[UInt32]] {
        BronzePeople.Part.allCases.map { part in
            renderer.submittedBronzePeople(part).flatMap { bits($0.model) }
        }
    }

    private static func expectProductionPose(_ renderer: Renderer, time: Float) throws {
        var expected = Array(repeating: [UInt32](), count: BronzePeople.Part.allCases.count)
        for routine in renderer.bronzePeople {
            BronzePeople.sample(routine, time: time, scene: renderer.scene) { part, model in
                expected[part.rawValue].append(contentsOf: bits(model))
            }
        }
        guard expected.allSatisfy({ !$0.isEmpty }), submitted(renderer) == expected else {
            throw Failure("The Metal batches did not submit every expected garment, limb and carried prop")
        }
    }

    private static func bits(_ model: simd_float4x4) -> [UInt32] {
        [model.columns.0, model.columns.1, model.columns.2, model.columns.3].flatMap {
            [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern, $0.w.bitPattern]
        }
    }
}
