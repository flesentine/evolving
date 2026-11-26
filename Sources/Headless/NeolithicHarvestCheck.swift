import Foundation
import simd

enum NeolithicHarvestCheck {
    private static let metres = RiverGraph.metresPerUnit

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }

    static func run(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let terrain = WorldGen.generate(seed: 1)
        var sim = Simulation(seed: 1, terrain: terrain)
        sim.advance(to: 450)
        let renderer = try Renderer(context: MetalContext(), terrain: terrain,
                                    colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
        renderer.updateScene(sim)
        let scene = renderer.scene
        guard let mesh = scene.cerealMesh, let indexBuffer = mesh.indexBuffer else {
            throw Failure("Missing submitted seedbed soil")
        }
        let soil = FieldSurface.Mask(mesh: mesh)
        let roads = scene.activityRoads
        let paths = scene.activityStreets
        let banks = scene.riverBankFootprint
        let field = scene.riverField
        let ground = mesh.vertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
        let indices = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        for i in stride(from: 0, to: mesh.indexCount, by: 3) {
            let a = ground[Int(indices[i])].position
            let b = ground[Int(indices[i + 1])].position
            let c = ground[Int(indices[i + 2])].position
            let triangle = [a, b, c].map { SIMD2($0.x, $0.z) }
            let centre = (a + b + c) / 3
            guard abs(centre.y - scene.renderedTerrainHeight(at: SIMD2(centre.x, centre.z))
                      - FieldSurface.cropLift) <= 0.003 / metres,
                  !field.intersectsFootprint(triangle), !paths.intersectsFootprint(triangle),
                  !roads.intersectsFootprint(triangle), !banks.intersectsFootprint(triangle)
            else { throw Failure("Submitted seedbed gets wet, crosses a path, or lifts off terrain") }
        }
        let parts = NeolithicHarvest.Part.allCases
        let first = parts.map { renderer.submittedHarvest($0).map(\.model) }
        for (part, models) in zip(parts, first) {
            guard !models.isEmpty else { throw Failure("No submitted \(part.rawValue) assets") }
            let bounds = RiverPlacement.authoredBounds(part.path)
            for model in models {
                let location = model.columns.3
                let point = SIMD2(location.x, location.z)
                let outline = RiverPlacement.transformed(bounds, by: model)
                guard !field.intersectsFootprint(outline), !paths.intersectsFootprint(outline),
                      !roads.intersectsFootprint(outline), !banks.intersectsFootprint(outline)
                else { throw Failure("\(part.rawValue) crosses water, bank or work path") }
                if part == .wheat || part == .barley {
                    guard soil.height(at: point) == location.y, outline.allSatisfy({ soil.covers($0) })
                    else { throw Failure("\(part.rawValue) is not on its submitted bed") }
                } else {
                    guard !soil.intersectsFootprint(outline),
                          abs(location.y - scene.renderedTerrainHeight(at: point)) <= 0.003 / metres,
                          outline.allSatisfy({ abs(location.y - scene.renderedTerrainHeight(at: $0)) <= 0.086 / metres })
                    else { throw Failure("Harvest prop disagrees with ground or bed") }
                }
            }
            print("PASS \(part.rawValue): \(models.count) submitted instances")
        }
        let plots = renderer.neolithicHarvest.plots
        print("PASS \(plots.count) cereal beds; \(mesh.indexCount / 3) supported soil triangles clear of water, banks and paths")

        func capture(_ label: String, _ view: RiverReviewView) throws {
            NeolithicReference.apply(view, to: renderer)
            try view.write(to: directory.appendingPathComponent(label + ".json"))
            _ = try Snapshot.write(renderer: renderer, width: view.width, height: view.height,
                                   time: view.animationTime, to: directory.appendingPathComponent(label + ".png"))
        }

        let wheat = plots.filter { $0.crop == .wheat }
        let barley = plots.filter { $0.crop == .barley }
        let pairs = wheat.flatMap { a in barley.map { b in (a, b) } }
        guard let pair = pairs.min(by: {
            simd_distance_squared($0.0.centre, $0.1.centre) < simd_distance_squared($1.0.centre, $1.1.centre)
        }) else { throw Failure("No wheat and barley views") }
        let middle = (pair.0.centre + pair.1.centre) * 0.5
        let lookAt = SIMD3(middle.x, scene.renderedTerrainHeight(at: middle), middle.y)
        let viewAxis = simd_normalize(pair.0.centre - pair.1.centre)
        let side = SIMD2(-viewAxis.y, viewAxis.x)
        let room = max(simd_distance(pair.0.centre, pair.1.centre) * metres, 9)
        let offset = side * (room * 0.85 / metres)
        let eye = lookAt + SIMD3(offset.x, room * 1.4 / metres, offset.y)
        var fieldView = RiverReviewView(seed: 1, year: 450, hour: 14, season: 0.68,
            precipitation: 0, snow: false, animationTime: 22, eye: [eye.x, eye.y, eye.z],
            target: [lookAt.x, lookAt.y, lookAt.z], fov: 49, width: 1440, height: 900,
            provenance: "NEO-08 matched wheat and barley beds")
        try capture("fields-day", fieldView)
        fieldView.hour = 18.4
        try capture("fields-dusk", fieldView)

        let bundle = first[2][0].columns.3
        let tray = first[3][0].columns.3
        let harvestFocus = (bundle + tray) * 0.5
        let local = SIMD3(harvestFocus.x, harvestFocus.y + 0.28 / metres, harvestFocus.z)
        let harvestEye = local + SIMD3<Float>(-4.2, 2.6, 3.2) / metres
        var harvestView = fieldView
        harvestView.eye = [harvestEye.x, harvestEye.y, harvestEye.z]
        harvestView.target = [local.x, local.y, local.z]
        harvestView.hour = 15
        harvestView.fov = 26
        harvestView.provenance = "NEO-08 harvest corner"
        try capture("harvest", harvestView)

        var hearth = try RiverReviewView.read(URL(fileURLWithPath: "review/neolithic/neo-07/tending-a.json"))
        hearth.provenance = "NEO-08 matched work hearth and tender"
        hearth.hour = 14
        try capture("hearth-day", hearth)
        guard renderer.submittedHearthLights.isEmpty else { throw Failure("Hearth spills light in daylight") }
        hearth.hour = 18.5
        try capture("hearth-dusk", hearth)
        let lights = renderer.submittedHearthLights
        let smoke = renderer.submittedHearthSmoke()
        let actualHearths = renderer.submittedNeolithicPeople(.hearth).map { $0.model.columns.3 }
        guard !lights.isEmpty, lights.count <= 4, !smoke.isEmpty,
              lights.allSatisfy({ light in
                  light.w > 0 && actualHearths.contains { origin in
                      light.x == origin.x && light.z == origin.z
                          && abs(light.y - origin.y - 0.23 / metres) < 0.001 / metres
                  }
              }), smoke.allSatisfy({ puff in
                  let p = puff.model.columns.3
                  return puff.color.w >= 0 && puff.color.w <= 0.19 && actualHearths.contains { origin in
                      p.y > origin.y && p.y < origin.y + 3.3 / metres
                          && simd_distance(SIMD2(p.x, p.z), SIMD2(origin.x, origin.z)) < 2 / metres
                  }
              }) else { throw Failure("Submitted light or plume disagrees with the actual hearth meshes") }
        try capture("hearth-replay", hearth)
        guard renderer.submittedHearthLights == lights,
              renderer.submittedHearthSmoke().map(\.model) == smoke.map(\.model),
              renderer.submittedHearthSmoke().map(\.color) == smoke.map(\.color)
        else { throw Failure("Frame replay changes the lights or plume") }
        hearth.animationTime += 0.87
        try capture("hearth-dusk-later", hearth)
        guard renderer.submittedHearthLights != lights, renderer.submittedHearthSmoke().map(\.model) != smoke.map(\.model)
        else { throw Failure("The hearth is not animated") }
        hearth.animationTime -= 0.87
        hearth.precipitation = 0.70
        try capture("hearth-rain", hearth)
        guard renderer.submittedHearthLights.count == lights.count,
              zip(renderer.submittedHearthLights, lights).allSatisfy({ $0.w < $1.w })
        else { throw Failure("Rain does not dampen the hearth") }
        print("PASS \(actualHearths.count) submitted hearths; \(lights.count) local lights and \(smoke.count) timed puffs at the dusk camera")

        renderer.updateScene(sim)
        guard parts.map({ renderer.submittedHarvest($0).map(\.model) }) == first
        else { throw Failure("Cereal plot or prop placement changes on replay") }
        sim.advance(to: 810)
        renderer.updateScene(sim)
        hearth.year = 810
        _ = try Snapshot.write(renderer: renderer, width: 640, height: 400,
                               time: hearth.animationTime, to: directory.appendingPathComponent("bronze.png"))
        guard scene.cerealMesh == nil, parts.allSatisfy({ renderer.submittedHarvest($0).isEmpty }),
              renderer.submittedHearthLights.isEmpty, renderer.submittedHearthSmoke().isEmpty
        else { throw Failure("Neolithic beds or hearth effects survive into Bronze Age") }
        print("PASS exact deterministic rebuild, exact hearth replay and Bronze Age transition")
    }
}
