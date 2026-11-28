import simd

/// Small cereal beds and an outdoor cooking spot near a submitted court.
enum BronzeHarvest {
    private static let metres = RiverGraph.metresPerUnit
    static let hearthPath = NeolithicPeople.Part.hearth.path
    static let potPath = "variants/bronze-prop-cookpot"

    struct Station {
        let court: BronzeLayout.Court
        let plots: [NeolithicHarvest.Plot]
        let hearth: InstanceData
        let pot: InstanceData
        let bundles: InstanceData
        let smoke: HearthEffects.Source
    }

    static func plan(in scene: WorldScene, geometry: CityBuilder.Geometry, site: BronzeLayout.Site,
                     routines: [BronzePeople.Routine], seed: UInt64) -> [Station] {
        guard !geometry.bronzeLayout.courts.isEmpty else { return [] }
        var site = site
        for path in geometry.buildings.keys.sorted() {
            let bounds = RiverPlacement.authoredBounds(path)
            for instance in geometry.buildings[path, default: []] {
                site.solid.insertFootprint(RiverPlacement.transformed(bounds, by: instance.model))
            }
        }
        for box in geometry.boxes {
            site.solid.insertFootprint(RiverPlacement.transformed(RiverPlacement.unitBoxBounds, by: box.model))
        }
        for routine in routines { site.solid.insertFootprint(routine.clearance) }
        for pen in scene.bronzePens {
            for footprint in BronzeEnclosures.footprints(pen) { site.solid.insertFootprint(footprint) }
        }
        let paths = scene.activityStreets
        let approaches = FieldSurface.Mask(mesh: scene.bronzeAccessMesh)
        let fields = FieldSurface.Mask(mesh: scene.fieldMesh)
        let plotShape: [SIMD2<Float>] = [
            SIMD2(-2.3, -1.85), SIMD2(2.3, -1.85), SIMD2(2.65, -1.5), SIMD2(2.65, 1.5),
            SIMD2(2.3, 1.85), SIMD2(-2.3, 1.85), SIMD2(-2.65, 1.5), SIMD2(-2.65, -1.5)
        ]
        let items: [(path: String, across: Float, toward: Float, relief: Float, material: Float)] = [
            (hearthPath, 0, -3.06, 0.048, 20),
            (potPath, 0.72, -3.05, 0.080, 9),
            (NeolithicHarvest.Part.sheaves.path, -1.05, -2.62, 0.074, 9)
        ]
        let itemBounds = items.map { RiverPlacement.authoredBounds($0.path) }
        guard itemBounds.allSatisfy({ $0.count == 4 }) else { return [] }

        func clear(_ footprint: [SIMD2<Float>], probes: [SIMD2<Float>], relief: Float) -> Bool {
            guard site.clear(footprint, margin: 0.45 / metres),
                  !paths.intersectsFootprint(footprint), !approaches.intersectsFootprint(footprint),
                  !fields.intersectsFootprint(footprint), probes.allSatisfy(site.dry)
            else { return false }
            let heights = probes.map(site.ground)
            return heights.max()! - heights.min()! <= relief / metres
        }

        var stations: [Station] = []
        var completed: Set<Int32> = []
        for court in geometry.bronzeLayout.courts where !completed.contains(court.town) && stations.count < 12 {
            guard paths.covers(court.centre) else { continue }
            var rng = SplitMix64(seed: seed ^ (UInt64(bitPattern: Int64(court.town)) &* 0x79CC_035D))
            let heading = rng.nextFloat(in: 0...(2 * .pi))
            let wheat = rng.next()
            let barley = rng.next()
            let phase = rng.nextFloat()
            for option in 0..<96 {
                let angle = heading + Float(option % 24) * .pi / 12
                let outward = SIMD2(sin(angle), cos(angle))
                let across = SIMD2(outward.y, -outward.x)
                let radius = 9.4 + Float(option / 24) * 2.5
                let centre = court.centre + outward * (radius / metres)
                let pair: [(NeolithicHarvest.Part, Float, UInt64)] = [(.wheat, -2.96, wheat), (.barley, 2.96, barley)]
                let plots = pair.map { crop, offset, seed in
                    let point = centre + across * (offset / metres)
                    let outline = plotShape.map { point + (across * $0.x + outward * $0.y) / metres }
                    return NeolithicHarvest.Plot(crop: crop, settlement: court.town, centre: point,
                        across: across, outline: outline, seed: seed)
                }
                guard plots.allSatisfy({ plot in
                    clear(plot.outline, probes: plot.outline + [plot.centre]
                        + plot.outline.map { ($0 + plot.centre) * 0.5 }, relief: 0.94)
                }) else { continue }

                let rotation = rotationY(angle)
                let scale = scaleMatrix(SIMD3(repeating: 1 / metres))
                var fixtures: [InstanceData] = []
                var reserved = FieldSurface.Mask()
                for plot in plots { reserved.insertFootprint(plot.outline) }
                for (item, bounds) in zip(items, itemBounds) {
                    let p = centre + (across * item.across + outward * item.toward) / metres
                    var model = translation(SIMD3(p.x, 0, p.y)) * rotation * scale
                    let footprint = RiverPlacement.transformed(bounds, by: model)
                    let probes = BronzeHome.foundationSamples(footprint)
                    guard !reserved.intersectsFootprint(footprint),
                          clear(footprint, probes: probes, relief: item.relief) else { break }
                    model.columns.3.y = site.ground(p)
                    fixtures.append(InstanceData(model: model, color: SIMD4(1, 1, 1, 0),
                                                material: SIMD4(item.material, 0, 0, 0)))
                    reserved.insertFootprint(footprint)
                }
                guard fixtures.count == items.count else { continue }
                let source = HearthEffects.Source(position: NeolithicPeople.xyz(fixtures[0].model.columns.3),
                                                  phase: phase, index: stations.count)
                stations.append(Station(court: court, plots: plots, hearth: fixtures[0], pot: fixtures[1],
                                        bundles: fixtures[2], smoke: source))
                for plot in plots { site.solid.insertFootprint(plot.outline) }
                for (fixture, bounds) in zip(fixtures, itemBounds) {
                    site.solid.insertFootprint(RiverPlacement.transformed(bounds, by: fixture.model))
                }
                completed.insert(court.town)
                break
            }
        }
        return stations
    }
}
