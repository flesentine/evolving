import Foundation
import simd

enum NeolithicHerdCheck {
    private static let metres = RiverGraph.metresPerUnit
    private typealias Herd = NeolithicHerds.Herd
    private typealias Clearance = NeolithicHerds.Clearance

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func checkRoutes(_ herds: [Herd], clearance: Clearance, scene: WorldScene) throws -> Int {
        var used = FieldSurface.Mask()
        var probes = 0
        for herd in herds {
            let route = herd.route
            let habitat = NeolithicHerds.Habitat.forSpecies(herd.species)
            let reach = simd_distance(route.centre, herd.anchor) * metres
            guard habitat.search.contains(reach), herd.members.count == habitat.members,
                  clearance.allows(route.envelope, in: scene),
                  !used.intersectsFootprint(route.envelope),
                  route.arc.count == route.points.count + 1,
                  zip(route.arc, route.arc.dropFirst()).allSatisfy({ $0 < $1 }),
                  simd_distance(route.position(at: 0).point, route.position(at: route.length).point) < 0.001 / metres
            else { throw Failure("Invalid range or footprint for \(herd.species.name)") }
            used.insertFootprint(route.envelope)

            var fed = false
            var walked = false
            let radius = NeolithicLivestock.sweptRadii[herd.species.rawValue]
            let traversal = Int(ceil(route.length / (herd.species.speedMetres * 8))) + 1
            for sample in 0...(traversal * 30) {
                let time = Float(sample) * 0.5
                let placements = herd.placements(at: time, in: scene)
                let next = herd.placements(at: time + 0.06, in: scene)
                guard placements.count == herd.members.count else { throw Failure("A herd member vanished") }
                for (index, item) in placements.enumerated() {
                    let model = item.instance.model
                    let origin = model.columns.3
                    let point = SIMD2(origin.x, origin.z)
                    let ahead = NeolithicPeople.xz(next[index].instance.model.columns.3)
                    let corners = RiverPlacement.authoredBounds(item.pose.path)
                    let footprint = RiverPlacement.transformed(corners, by: model)
                    guard simd_distance(point, ahead) * metres <= herd.species.speedMetres * 0.06 + 0.005,
                          footprint.allSatisfy({ !scene.terrain.isWater(x: $0.x, z: $0.y) }),
                          clearance.allows(footprint, in: scene),
                          NeolithicLivestock.hoovesSupported(item.pose, by: model, in: scene)
                    else { throw Failure("Unsupported, obstructed, or discontinuous \(herd.species.name) pose at \(time)s") }
                    for j in placements.indices where j > index {
                        let neighbour = NeolithicPeople.xz(placements[j].instance.model.columns.3)
                        let margin = radius * (herd.members[index].scale + herd.members[j].scale)
                        guard simd_distance(point, neighbour) > margin else {
                            throw Failure("Herd members cross on \(herd.species.name) route")
                        }
                    }
                    if item.pose.isFeeding {
                        fed = true
                        guard !next[index].pose.isFeeding || simd_distance(point, ahead) < 0.001 / metres else {
                            throw Failure("Feeding herd member slides")
                        }
                    } else if simd_distance(point, ahead) > 0.01 / metres { walked = true }
                    probes += 1
                }
            }
            guard fed, walked else { throw Failure("Missing walk or feed phase on route") }
        }
        return probes
    }

    private static func rejectedCases(_ herd: Herd, clearance: Clearance, scene: WorldScene) throws {
        let point = herd.route.centre
        let pad = 0.25 / metres
        var intrusion = FieldSurface.Mask()
        intrusion.insertFootprint([point + SIMD2(-pad, -pad), point + SIMD2(pad, -pad),
                                   point + SIMD2(pad, pad), point + SIMD2(-pad, pad)])
        let tests = [
            Clearance(buildingsAndActors: intrusion, fields: clearance.fields, cereal: clearance.cereal,
                      roads: clearance.roads, paths: clearance.paths, banks: clearance.banks),
            Clearance(buildingsAndActors: clearance.buildingsAndActors, fields: intrusion, cereal: clearance.cereal,
                      roads: clearance.roads, paths: clearance.paths, banks: clearance.banks),
            Clearance(buildingsAndActors: clearance.buildingsAndActors, fields: clearance.fields, cereal: intrusion,
                      roads: clearance.roads, paths: clearance.paths, banks: clearance.banks)
        ]
        guard tests.allSatisfy({ !$0.allows(herd.route.envelope, in: scene) }) else {
            throw Failure("An interior building or crop intrusion was accepted")
        }
        // This seed-1 bank apron hid cattle hooves before NEO-09.
        let bank = SIMD2<Float>(-0.00191556, 0.2529707)
        let former = herd.route.envelope.map { $0 - herd.route.centre + bank }
        guard !clearance.allows(former, in: scene) else { throw Failure("Bank intrusion regression") }
        let water = scene.riverField.mesh
        guard water.indices.count >= 3 else { throw Failure("Missing submitted water for intrusion fixture") }
        let wet = water.indices.prefix(3).map { water.vertices[Int($0)].position }
        let centre = (wet[0] + wet[1] + wet[2]) / 3
        let wetEnvelope = herd.route.envelope.map { $0 - herd.route.centre + SIMD2(centre.x, centre.z) }
        let empty = FieldSurface.Mask()
        let riverOnly = Clearance(buildingsAndActors: empty, fields: empty, cereal: empty,
                                  roads: empty, paths: empty, banks: empty)
        guard !riverOnly.allows(wetEnvelope, in: scene) else { throw Failure("Submitted water intrusion was accepted") }
        print("PASS interior building and both crop intrusions, submitted water, and river-bank regression")
    }

    static func run(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (seed, year): (UInt64, Float) in [(1,450), (8,790), (10,280)] {
            let terrain = WorldGen.generate(seed: seed)
            var sim = Simulation(seed: seed, terrain: terrain)
            sim.advance(to: year)
            let renderer = try Renderer(context: MetalContext(), terrain: terrain,
                                        colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
            renderer.updateScene(sim)
            let herds = renderer.neolithicHerds
            guard let clearance = renderer.neolithicHerdClearance, let first = herds.first else {
                throw Failure("No accepted herds for seed \(seed), year \(year)")
            }
            let checks = try checkRoutes(herds, clearance: clearance, scene: renderer.scene)
            renderer.updateScene(sim)
            guard renderer.neolithicHerds == herds else { throw Failure("Herd layout or phase changes on rebuild") }
            let species = NeolithicLivestock.Species.allCases.map { species in
                "\(species.name) \(herds.filter { $0.species == species }.count)"
            }.joined(separator: ", ")
            print("PASS seed \(seed) year \(Int(year)): \(herds.count) non-overlapping ranges (\(species)), \(checks) swept pose probes and exact rebuild")
            if seed == 1 {
                try rejectedCases(first, clearance: clearance, scene: renderer.scene)
                try render(directory: directory, renderer: renderer, herds: herds, seed: seed, year: year)
                sim.advance(to: 810)
                renderer.updateScene(sim)
                guard renderer.neolithicHerds.isEmpty, renderer.submittedNeolithicLivestockCounts().allSatisfy({ $0 == 0 })
                else { throw Failure("Neolithic herds leak into the Bronze Age") }
                print("PASS Bronze Age batch isolation")
            }
        }
    }

    private static func render(directory: URL, renderer: Renderer, herds: [Herd],
                               seed: UInt64, year: Float) throws {
        let scene = renderer.scene
        func frame(_ name: String, _ view: RiverReviewView) throws {
            try view.write(to: directory.appendingPathComponent(name + ".json"))
            NeolithicReference.apply(view, to: renderer)
            _ = try Snapshot.write(renderer: renderer, width: view.width, height: view.height, time: view.animationTime,
                                   to: directory.appendingPathComponent(name + ".png"))
            let expected = herds.flatMap { $0.placements(at: view.animationTime, in: scene) }
            for pose in NeolithicLivestock.poses {
                let models = renderer.submittedLivestock(pose).map(\.model)
                let replay = expected.filter { $0.pose == pose }.map { $0.instance.model }
                guard models == replay else { throw Failure("Submitted Metal batch disagrees with replay for \(pose.path)") }
            }
        }

        for species in NeolithicLivestock.Species.allCases {
            let matches = herds.filter { $0.species == species }
            guard let herd = matches.first else { throw Failure("Missing \(species.name) reference herd") }
            let centre = herd.route.centre
            let height = scene.renderedTerrainHeight(at: centre)
            let target = SIMD3(centre.x, height + 0.50 / metres, centre.y)
            let eye = target + SIMD3<Float>(-9, 5.4, 7.9) / metres
            let fov: Float = species == .cattle ? 47 : 40
            var view = RiverReviewView(seed: seed, year: year, hour: 14, season: 0.68,
                precipitation: 0, snow: false, animationTime: 19.3 - herd.phase, eye: [eye.x, eye.y, eye.z],
                target: [target.x, target.y, target.z], fov: fov, width: 1440, height: 900,
                provenance: "NEO-10 \(species.name) production herd")
            try frame(species.name + "-walk", view)
            view.animationTime = 26.1 - herd.phase
            try frame(species.name + "-feed", view)
            if species == .pig {
                let middle = (centre + herd.anchor) * 0.5
                let y = scene.renderedTerrainHeight(at: middle)
                view.eye = [middle.x - 15 / metres, y + 22 / metres, middle.y + 12 / metres]
                view.target = [middle.x, y, middle.y]
                view.fov = 47
                view.provenance = "NEO-10 pigs at the hamlet edge"
                try frame("hamlet-edge", view)
            }
        }
        print("PASS all seven review frames agree with the actual submitted Metal instance buffers")
    }
}
