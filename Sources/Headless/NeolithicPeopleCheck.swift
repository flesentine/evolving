import CoreGraphics
import Foundation
import ImageIO
import simd

enum NeolithicPeopleCheck {
    private typealias Part = NeolithicPeople.Part
    private static let metres = NeolithicPeople.metres

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }

    private static func rgba(_ url: URL, width: Int, height: Int) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { throw Failure("Cannot decode saved review still") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pixels, count: width * height * 4))
    }

    private static func rasterDelta(_ first: URL, _ second: URL, width: Int, height: Int) throws -> (Int, Int) {
        let a = try rgba(first, width: width, height: height)
        let b = try rgba(second, width: width, height: height)
        var count = 0
        var maximum = 0
        for index in stride(from: 0, to: a.count, by: 4) {
            var pixelDelta = 0
            for channel in index..<(index + 4) {
                pixelDelta = max(pixelDelta, abs(Int(a[channel]) - Int(b[channel])))
            }
            if pixelDelta > 0 { count += 1 }
            maximum = max(maximum, pixelDelta)
        }
        return (count, maximum)
    }

    static func run(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let terrain = WorldGen.generate(seed: 1)
        var simulation = Simulation(seed: 1, terrain: terrain)
        simulation.advance(to: 450)
        let renderer = try Renderer(context: MetalContext(), terrain: terrain,
                                    colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
        renderer.updateScene(simulation)
        let routines = renderer.neolithicPeople
        let scene = renderer.scene
        let crops = FieldSurface.Mask(mesh: scene.fieldMesh)
        let roads = scene.activityRoads
        let banks = scene.riverBankFootprint
        var occupied = FieldSurface.Mask()
        for routine in routines {
            let area = routine.clearance
            guard !banks.intersectsFootprint(area), !roads.intersectsFootprint(area),
                  !crops.intersectsFootprint(area), !occupied.intersectsFootprint(area),
                  !scene.riverField.intersectsFootprint(area, margin: 0.3 / metres)
            else { throw Failure("Actor clearance overlaps a bank, road, crop, other routine or river") }
            occupied.insertFootprint(area)
        }
        let quernTransforms = renderer.submittedHouseholdProps(NeolithicProps.paths[0]).map(\.model)
        let parts = Part.allCases.filter { $0 != .quernBed }
        var frames = 0

        func verifySubmitted(time: Float) throws -> [[simd_float4x4]] {
            var expected = Array(repeating: [simd_float4x4](), count: Part.allCases.count)
            for routine in routines {
                NeolithicPeople.sample(routine, time: time, scene: scene) { part, model in
                    expected[part.rawValue].append(model)
                }
            }
            return try parts.map { part in
                let instances = renderer.submittedNeolithicPeople(part).map(\.model)
                guard instances == expected[part.rawValue],
                      instances.allSatisfy({ model in
                          (0..<4).allSatisfy { column in (0..<4).allSatisfy { model[column][$0].isFinite } }
                      }) else { throw Failure("Missing, divergent, or nonfinite submitted part: \(part)") }
                if part == .forearm {
                    for model in instances {
                        let axis = model.columns.1
                        let length = simd_length(SIMD3(axis.x, axis.y, axis.z)) * metres
                        guard length >= 0.275, length <= 0.395 else {
                            throw Failure("Submitted forearm stretched to \(length) m")
                        }
                    }
                }
                if part == .shoe {
                    for model in instances {
                        let sole = model.columns.3
                        let point = SIMD2(sole.x, sole.z)
                        let height = max(scene.renderedTerrainHeight(at: point),
                                         scene.activityStreets.height(at: point) ?? 0)
                        let clearance = (sole.y - height) * metres
                        guard clearance >= -0.001, clearance <= 0.116 else {
                            throw Failure("Shoe clearance \(clearance) m outside the walking lift range")
                        }
                    }
                }
                return instances
            }
        }

        for kind in NeolithicPeople.Kind.allCases {
            let choices = routines.filter { $0.kind == kind }
            guard let routine = choices.first else { throw Failure("No \(kind.rawValue) routine") }
            if kind == .grinding {
                guard let fixture = routine.fixture, quernTransforms.contains(fixture) else {
                    throw Failure("The handstone has no placed quern bed")
                }
            }
            let delta = routine.end - routine.start
            let forward = simd_normalize(delta)
            let side = SIMD2(forward.y, -forward.x)
            let sunlight = SIMD2<Float>(-0.43, 0.38)
            let sign: Float = simd_dot(side, sunlight) > 0 ? 1 : -1
            let midpoint = (routine.start + routine.end) * 0.5
            let height = scene.renderedTerrainHeight(at: midpoint)
            let space = side * (sign * 5.3 / metres) + forward * (3.0 / metres)
            let focus = SIMD3(midpoint.x, height + 0.74 / metres, midpoint.y)
            let eye = focus + SIMD3(space.x, 1.85 / metres, space.y)
            let period: Float = kind == .carrying ? 8 : kind == .grinding ? 1.85 : 3.8
            let steps: [Float] = kind == .carrying ? [0.13, 0.27] : [0.25, 0.75]
            let prop: Part = kind == .carrying ? .basket : kind == .grinding ? .handstone : .poker
            let propIndex = parts.firstIndex(of: prop)!
            var prior: [simd_float4x4]?
            for (index, step) in steps.enumerated() {
                let time = (2 + step - routine.phase) * period
                let name = kind.rawValue + (index == 0 ? "-a" : "-b")
                let view = RiverReviewView(seed: 1, year: 450, hour: 14, season: 0.68,
                    precipitation: 0, snow: false, animationTime: time, eye: [eye.x, eye.y, eye.z],
                    target: [focus.x, focus.y, focus.z], fov: 32, width: 1440, height: 900,
                    provenance: "NEO-07 production \(kind.rawValue) routine")
                try view.write(to: directory.appendingPathComponent(name + ".json"))
                NeolithicReference.apply(view, to: renderer)
                let output = directory.appendingPathComponent(name + ".png")
                _ = try Snapshot.write(renderer: renderer, width: view.width, height: view.height,
                                       time: time, to: output)
                let first = try verifySubmitted(time: time)
                guard !first[propIndex].isEmpty, prior != first[propIndex] else {
                    throw Failure("Missing or unmoving \(kind.rawValue) prop")
                }
                prior = first[propIndex]
                let replay = directory.appendingPathComponent(name + "-replay.png")
                _ = try Snapshot.write(renderer: renderer, width: view.width, height: view.height,
                                       time: time, to: replay)
                guard try verifySubmitted(time: time) == first else {
                    throw Failure("Replay changed submitted \(name) pose or props")
                }
                // Metal can round a sparse set of background pixels differently
                // at triangle edges. Keep that measurement separate from pose
                // and tool transforms, which must repeat exactly.
                let (changed, maximum) = try rasterDelta(output, replay, width: view.width, height: view.height)
                guard changed <= view.width * view.height / 10_000, maximum <= 2 else {
                    throw Failure("\(name) raster replay differs at \(changed) pixels, maximum channel delta \(maximum)")
                }
                print("PASS \(name): exact pose and props, \(changed) raster pixels changed, maximum channel delta \(maximum)")
                frames += 1
            }
            print("PASS \(kind.rawValue): \(choices.count) routines, changing submitted tool poses and checked raster replays")
        }

        renderer.updateScene(simulation)
        let rebuilt = renderer.neolithicPeople
        guard rebuilt.count == routines.count,
              zip(rebuilt, routines).allSatisfy({
                  $0.kind == $1.kind && $0.start == $1.start && $0.end == $1.end
                    && $0.phase == $1.phase && $0.brown == $1.brown && $0.fixture == $1.fixture
              }) else { throw Failure("Routine layout differs on scene rebuild") }
        simulation.advance(to: 810)
        renderer.updateScene(simulation)
        guard renderer.neolithicPeople.isEmpty, parts.allSatisfy({ renderer.submittedNeolithicPeople($0).isEmpty })
        else { throw Failure("Neolithic clothing and routine batches survived into Bronze Age") }
        print("PASS \(routines.count) non-overlapping sites, six saved views, \(frames) exact pose and prop replays, deterministic rebuild and Bronze Age transition")
    }
}
