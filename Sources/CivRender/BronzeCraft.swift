import simd

/// A loom and a small household work surface share the dry edge of a court.
enum BronzeCraft: String, CaseIterable {
    case loom, workbench, basket, pottery

    var path: String { "variants/bronze-prop-" + rawValue }
    private var supportDepth: Float { self == .loom || self == .workbench ? 0.10 : 0.073 }
    private var material: Float { self == .workbench ? 23 : 9 }
    private static let metres = RiverGraph.metresPerUnit

    static func place(in scene: WorldScene, geometry: CityBuilder.Geometry,
                      seed: UInt64, site: BronzeLayout.Site) -> [String: [InstanceData]] {
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
        for pen in scene.bronzePens {
            for polygon in BronzeEnclosures.footprints(pen) {
                site.solid.insertFootprint(polygon)
            }
        }
        let paths = scene.activityStreets
        let approaches = FieldSurface.Mask(mesh: scene.bronzeAccessMesh)
        let crops = FieldSurface.Mask(mesh: scene.fieldMesh)
        var completed: Set<Int32> = []
        var placements: [String: [InstanceData]] = [:]
        for court in geometry.bronzeLayout.courts where !completed.contains(court.town) {
            guard paths.covers(court.centre) else { continue }
            var rng = SplitMix64(seed: seed ^ (UInt64(bitPattern: Int64(court.town)) &* 0x3127_7A5D))
            let heading = rng.nextFloat(in: 0...(2 * .pi))
            if let group = fit(court: court.centre, heading: heading, site: site,
                               paths: paths, approaches: approaches, crops: crops) {
                completed.insert(court.town)
                for item in group {
                    site.solid.insertFootprint(item.footprint)
                    placements[item.kind.path, default: []].append(item.instance)
                }
            }
        }
        return placements
    }

    private struct Item {
        let kind: BronzeCraft
        let instance: InstanceData
        let footprint: [SIMD2<Float>]
    }

    private static func fit(court: SIMD2<Float>, heading: Float, site: BronzeLayout.Site,
                            paths: FieldSurface.Mask, approaches: FieldSurface.Mask,
                            crops: FieldSurface.Mask) -> [Item]? {
        let offsets: [(BronzeCraft, SIMD2<Float>)] = [
            (.loom, SIMD2(-0.91, 0)), (.workbench, SIMD2(0.83, -0.10)),
            (.basket, SIMD2(-0.12, 0.76)), (.pottery, SIMD2(0.71, -0.92))
        ]
        for radius: Float in [4.1, 4.7, 5.4, 6.1] {
            for i in 0..<20 {
                let angle = heading + Float(i) * .pi / 10
                let inward = SIMD2(cos(angle), sin(angle))
                let side = SIMD2(inward.y, -inward.x)
                let anchor = court - inward * (radius / metres)
                let rotation = rotationY(atan2(inward.x, inward.y))
                var group: [Item] = []
                for (kind, offset) in offsets {
                    let p = anchor + (side * offset.x + inward * offset.y) / metres
                    var model = translation(SIMD3(p.x, 0, p.y))
                        * rotation * scaleMatrix(SIMD3(repeating: 1 / metres))
                    let footprint = RiverPlacement.transformed(
                        RiverPlacement.authoredBounds(kind.path), by: model)
                    guard footprint.count == 4, site.clear(footprint, margin: 0.30 / metres),
                          !paths.intersectsFootprint(footprint), !approaches.intersectsFootprint(footprint),
                          !crops.intersectsFootprint(footprint),
                          !group.contains(where: {
                              RiverPlacement.rectanglesOverlap(footprint, $0.footprint, clearance: 0.06 / metres)
                          }) else { break }
                    let samples = BronzeHome.foundationSamples(footprint)
                    guard samples.allSatisfy(site.dry) else { break }
                    let heights = samples.map(site.ground)
                    let high = heights.max()!
                    guard high - heights.min()! <= (kind.supportDepth - 0.008) / metres else { break }
                    model.columns.3.y = high - 0.008 / metres
                    let instance = InstanceData(model: model, color: SIMD4(1, 1, 1, 0),
                                                material: SIMD4(kind.material, 0, 0, 0))
                    group.append(Item(kind: kind, instance: instance, footprint: footprint))
                }
                if group.count == offsets.count { return group }
            }
        }
        return nil
    }
}
