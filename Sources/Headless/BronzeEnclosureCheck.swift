import Foundation
import simd

enum BronzeEnclosureCheck {
    private static let metres = RiverGraph.metresPerUnit

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func run(directory: URL) throws {
        try fixture()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = try MetalContext()
        var savedViews = false
        var total = 0
        for seed: UInt64 in [8, 1, 10] {
            let terrain = WorldGen.generate(seed: seed)
            let renderer = try Renderer(context: context, terrain: terrain,
                colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
            var simulation = Simulation(seed: seed, terrain: terrain)
            for year in (seed == 8 ? [810, 1450, 1990, 2010] : [1450]) {
                simulation.advance(to: Float(year))
                renderer.updateScene(simulation)
                let scene = renderer.scene
                if year == 2010 {
                    guard scene.bronzePens.isEmpty, scene.bronzeEnclosureMesh == nil, scene.bronzeAccessMesh == nil
                    else { throw Failure("Enclosures leaked into the Classical era") }
                    continue
                }
                let label = "seed \(seed) year \(year)"
                try inspect(renderer, label: label)
                total += scene.bronzePens.count
                if !savedViews, year == 1450, let pen = scene.bronzePens.first(where: { $0.banks.count > 1 }) {
                    try views(pen, scene: scene, simulation: simulation, directory: directory)
                    let firstBanks = meshBits(scene.bronzeEnclosureMesh)
                    let firstApproaches = meshBits(scene.bronzeAccessMesh)
                    renderer.updateScene(simulation, refreshRoads: true)
                    guard firstBanks == meshBits(scene.bronzeEnclosureMesh),
                          firstApproaches == meshBits(scene.bronzeAccessMesh) else {
                        throw Failure("\(label) changed bank or approach vertices on replay")
                    }
                    print("PASS \(label) enclosure and approach vertices match on replay")
                    savedViews = true
                }
            }
        }
        guard total > 0, savedViews else { throw Failure("Expected an occupied court with both a paddock and a reave") }
        print("PASS \(total) submitted paddocks across the review matrix")
    }

    private static func fixture() throws {
        var dry = WorldGen.generate(seed: 8, size: 65)
        dry.height = Array(repeating: 26 / metres, count: dry.height.count)
        dry.lakeWater = []
        var lake = dry
        lake.lakeWater = Array(repeating: 28 / metres, count: lake.height.count)
        let court = BronzeLayout.Court(town: 3, centre: .zero)
        var path = FieldSurface.Mask()
        path.insertFootprint(square(half: 3 / metres))
        var crops = FieldSurface.Mask()
        crops.insertFootprint(square(half: 50 / metres))
        func count(_ terrain: Terrain, height: ((SIMD2<Float>) -> Float)? = nil,
                   blocked: FieldSurface.Mask = FieldSurface.Mask()) -> Int {
            let ground = BronzeLayout.Site(terrain: terrain, river: nil, renderedGround: height,
                roads: FieldSurface.Mask(), banks: FieldSurface.Mask())
            let site = BronzeEnclosures.Site(ground: ground, crops: blocked, paths: path)
            return BronzeEnclosures.plan(courts: [court], seed: 8, site: site).count
        }
        guard count(dry) == 1, count(lake) == 0,
              count(dry, height: { 26 / metres + $0.x * 0.68 }) == 0,
              count(dry, blocked: crops) == 0 else {
            throw Failure("Flat, inundated, steep or cropped enclosure fixture gave the wrong result")
        }
        print("PASS flat upland produces one paddock; lake, steep ground and crop fixtures suppress it")
    }

    private static func square(half: Float) -> [SIMD2<Float>] {
        [SIMD2(-half, -half), SIMD2(half, -half), SIMD2(half, half), SIMD2(-half, half)]
    }

    private static func meshBits(_ mesh: Mesh?) -> [UInt32] {
        guard let mesh else { return [] }
        let raw = mesh.vertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
        var bits: [UInt32] = [UInt32(mesh.vertexCount), UInt32(mesh.indexCount)]
        for i in 0..<mesh.vertexCount {
            let v = raw[i]
            bits.append(contentsOf: [v.position.x, v.position.y, v.position.z, v.normal.x, v.normal.y,
                v.normal.z, v.uv.x, v.uv.y, v.color.x, v.color.y, v.color.z, v.color.w].map(\.bitPattern))
        }
        if let indexBuffer = mesh.indexBuffer {
            let indices = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
            bits.append(contentsOf: UnsafeBufferPointer(start: indices, count: mesh.indexCount))
        }
        return bits
    }

    private static func inspect(_ renderer: Renderer, label: String) throws {
        let scene = renderer.scene
        guard !scene.bronzePens.isEmpty else {
            guard scene.bronzeEnclosureMesh == nil, scene.bronzeAccessMesh == nil else {
                throw Failure("\(label) submitted geometry for a suppressed site")
            }
            print("PASS \(label): no eligible enclosure sites")
            return
        }
        guard let banks = scene.bronzeEnclosureMesh, let access = scene.bronzeAccessMesh,
              let indexBuffer = access.indexBuffer else { throw Failure("\(label) missing submitted bank or path mesh") }
        let crops = FieldSurface.Mask(mesh: scene.fieldMesh)
        let paths = scene.activityStreets
        let approaches = FieldSurface.Mask(mesh: access)
        let roads = scene.activityRoads
        let riverBanks = scene.riverBankFootprint
        var houses = FieldSurface.Mask()
        for entry in renderer.submittedBuildings() {
            houses.insertFootprint(RiverPlacement.transformed(RiverPlacement.authoredBounds(entry.path),
                                                              by: entry.instance.model))
        }
        func dryAndClear(_ polygon: [SIMD2<Float>]) -> Bool {
            !houses.intersectsFootprint(polygon) && !crops.intersectsFootprint(polygon)
                && !roads.intersectsFootprint(polygon) && !riverBanks.intersectsFootprint(polygon)
                && !scene.riverField.intersectsFootprint(polygon)
        }
        func surface(_ v: SIMD3<Float>) -> Float {
            v.y - scene.renderedTerrainHeight(at: SIMD2(v.x, v.z))
        }
        var walls = FieldSurface.Mask()
        let vb = banks.vertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
        var buried = 0
        var crown = 0
        for start in stride(from: 0, to: banks.vertexCount, by: 3) {
            let face = (0..<3).map { vb[start + $0].position }
            let polygon = face.map { SIMD2($0.x, $0.z) }
            for v in face {
                let height = surface(v)
                guard height >= -0.16 / metres, height <= 0.60 / metres else {
                    throw Failure("\(label) bad bank relief \(height * metres) m")
                }
                if height < -0.12 / metres { buried += 1 }
                if height > 0.32 / metres { crown += 1 }
            }
            for i in face.indices {
                let a = face[i], b = face[(i + 1) % face.count]
                guard surface(a) < -0.12 / metres, surface(b) < -0.12 / metres else { continue }
                for t: Float in [0.25, 0.5, 0.75] {
                    guard surface(a + (b - a) * t) < -0.01 / metres else {
                        throw Failure("\(label) bank toe lifts off the rendered ground")
                    }
                }
            }
            guard dryAndClear(polygon), !paths.intersectsFootprint(polygon) else {
                throw Failure("\(label) bank overlaps an occupied or wet footprint")
            }
            walls.insertFootprint(polygon)
        }
        guard buried > 0, crown > 0 else { throw Failure("\(label) missing buried toes or stone crest") }

        let va = access.vertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
        let indices = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        for start in stride(from: 0, to: access.indexCount, by: 3) {
            let face = (0..<3).map { va[Int(indices[start + $0])].position }
            let footprint = face.map { SIMD2($0.x, $0.z) }
            guard dryAndClear(footprint), !walls.intersectsFootprint(footprint),
                  face.allSatisfy({ abs(surface($0) - FieldSurface.cropLift) <= 0.02 / metres }) else {
                throw Failure("\(label) approach has bad ground contact or crosses an obstruction")
            }
        }

        for pen in scene.bronzePens {
            let side = SIMD2(-pen.inward.y, pen.inward.x)
            let halfGate = BronzeEnclosures.clearGateWidth * 0.5
            guard paths.covers(pen.court),
                  !walls.covers(pen.gate + side * (halfGate - 0.10 / metres)),
                  !walls.covers(pen.gate - side * (halfGate - 0.10 / metres)),
                  walls.covers(pen.gate + side * (halfGate + 0.18 / metres)),
                  walls.covers(pen.gate - side * (halfGate + 0.18 / metres)),
                  pen.access.flatMap({ $0.samples(step: 0.20 / metres) }).allSatisfy({
                      approaches.covers($0) || paths.covers($0)
                  }) else { throw Failure("\(label) gate is blocked, missing a side or disconnected from its court") }
            for (a,b) in zip(pen.banks[0], pen.banks[0].dropFirst()) {
                guard walls.covers((a + b) * 0.5) else { throw Failure("\(label) broken enclosure boundary") }
            }
        }
        let divisions = scene.bronzePens.filter { $0.banks.count > 1 }.count
        print("PASS \(label): \(scene.bronzePens.count) paddocks, \(divisions) companion reaves, \(banks.vertexCount / 3) bank triangles, \(access.indexCount / 3) approach triangles")
    }

    private static func views(_ pen: BronzeEnclosures.Pen, scene: WorldScene, simulation: Simulation,
                              directory: URL) throws {
        let side = SIMD2(-pen.inward.y, pen.inward.x)
        let inside = pen.gate + pen.inward * (2.7 / metres)
        let middle = (inside + pen.court) * 0.5
        let views: [(String, SIMD2<Float>, SIMD2<Float>, Float, Float)] = [
            ("gate-close", inside, pen.gate - pen.inward * (10 / metres) + side * (6 / metres), 10, 51),
            ("court-access-overhead", middle, middle - pen.inward * (6 / metres) + side * (4 / metres), 38, 49),
        ]
        for (name, p, eyeXZ, height, fov) in views {
            let ground = scene.renderedTerrainHeight(at: p)
            let eyeGround = scene.renderedTerrainHeight(at: eyeXZ)
            let view = RiverReviewView(seed: simulation.seed, year: simulation.year, hour: 14.5, season: 0.67,
                precipitation: 0, snow: false, animationTime: 24,
                eye: [eyeXZ.x, max(ground, eyeGround) + height / metres, eyeXZ.y],
                target: [p.x, ground + 0.2 / metres, p.y], fov: fov, width: 1440, height: 900,
                provenance: "BRZ-05 connected paddock and reave — \(name)")
            try view.write(to: directory.appendingPathComponent(name + ".json"))
        }
    }
}
