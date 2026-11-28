import Foundation
import simd

enum NeolithicHarvest {
    static let metres = RiverGraph.metresPerUnit

    enum Part: String, CaseIterable {
        case wheat, barley, sheaves, tray
        var path: String { "variants/neolithic-harvest-" + rawValue }
    }

    struct Plot {
        let crop: Part
        let settlement: Int32
        let centre: SIMD2<Float>
        let across: SIMD2<Float>
        let outline: [SIMD2<Float>]
        let seed: UInt64

        var along: SIMD2<Float> { SIMD2(-across.y, across.x) }
        var soil: FieldSurface.GroundPatch {
            let colour = crop == .wheat ? SIMD4<Float>(0.33, 0.235, 0.137, 0)
                                        : SIMD4<Float>(0.29, 0.237, 0.137, 0)
            return FieldSurface.GroundPatch(outline: outline, colour: colour, centre: centre, across: across)
        }
    }

    struct Layout {
        var plots: [Plot] = []
        var props: [Part: [InstanceData]] = [:]
    }

    static func plan(in scene: WorldScene, geometry: CityBuilder.Geometry,
                     routines: [NeolithicPeople.Routine], trees: [InstanceData],
                     seed: UInt64, reference: NeolithicReference.Stage?) -> Layout {
        let yards = scene.neolithicYards.yards
        guard !yards.isEmpty else { return Layout() }
        let crops = FieldSurface.Mask(mesh: scene.fieldMesh)
        let roads = scene.activityRoads
        let yardsAndPaths = scene.activityStreets
        let banks = scene.riverBankFootprint
        var occupied = FieldSurface.Mask()
        for path in geometry.buildings.keys.sorted() {
            let bounds = RiverPlacement.authoredBounds(path)
            for instance in geometry.buildings[path, default: []] {
                occupied.insertFootprint(RiverPlacement.transformed(bounds, by: instance.model))
            }
        }
        let cube = RiverPlacement.bounds(Geometry.cube())
        for box in geometry.boxes {
            occupied.insertFootprint(RiverPlacement.transformed(cube, by: box.model))
        }
        for routine in routines { occupied.insertFootprint(routine.clearance) }
        for tree in trees {
            let point = NeolithicPeople.xz(tree.model.columns.3)
            if yards.contains(where: { simd_distance_squared(point, $0.centre) < pow(19 / metres, 2) }) {
                let pad = 0.42 / metres
                occupied.insertFootprint([point + SIMD2(-pad, -pad), point + SIMD2(pad, -pad),
                                          point + SIMD2(pad, pad), point + SIMD2(-pad, pad)])
            }
        }

        func accepts(_ area: [SIMD2<Float>], maxRiseMetres: Float) -> Bool {
            let centre = area.reduce(SIMD2<Float>.zero, +) / Float(area.count)
            let probes = area + [centre] + area.map { ($0 + centre) * 0.5 }
            let heights = probes.map { scene.renderedTerrainHeight(at: $0) }
            guard let low = heights.min(), let high = heights.max(),
                  low > 0.6 / metres, high - low <= maxRiseMetres / metres,
                  probes.allSatisfy({ reference?.containsStagedYard($0) != true
                      && !scene.terrain.isWater(x: $0.x, z: $0.y) }) else { return false }
            return !scene.riverField.intersectsFootprint(area, margin: 0.45 / metres)
                && !banks.intersectsFootprint(area) && !crops.intersectsFootprint(area)
                && !roads.intersectsFootprint(area) && !yardsAndPaths.intersectsFootprint(area)
                && !occupied.intersectsFootprint(area)
        }

        var layout = Layout()
        for yard in yards {
            guard let entrance = yard.connections.first?.entrance else { continue }
            let identity = UInt64(bitPattern: Int64(entrance.settlement)) &* 0xBBE0_56A3_59D4_58C5
            var rng = SplitMix64(seed: seed ^ identity ^ UInt64(entrance.cluster))
            let start = rng.nextInt(8)
            let base = atan2(entrance.forward.x, entrance.forward.y)
            let species: [Part] = rng.nextInt(2) == 0 ? [.wheat, .barley] : [.barley, .wheat]

            for crop in species where layout.plots.count < 18 {
                for option in 0..<24 {
                    let angle = base + Float((start + option) % 8) * .pi / 4
                    let outward = SIMD2(sin(angle), cos(angle))
                    let across = SIMD2(outward.y, -outward.x)
                    let distance = 6.9 + Float(option / 8) * 2.8
                    let centre = yard.centre + outward * (distance / metres)
                    // A small chamfered bed follows the actual terrain faces.
                    let corners: [SIMD2<Float>] = [SIMD2(-2.3,-1.85), SIMD2(2.3,-1.85),
                        SIMD2(2.65,-1.5), SIMD2(2.65,1.5), SIMD2(2.3,1.85), SIMD2(-2.3,1.85),
                        SIMD2(-2.65,1.5), SIMD2(-2.65,-1.5)]
                    let outline = corners.map { centre + (across * $0.x + outward * $0.y) / metres }
                    guard accepts(outline, maxRiseMetres: 1.05) else { continue }
                    let plot = Plot(crop: crop, settlement: entrance.settlement, centre: centre,
                                    across: across, outline: outline, seed: rng.next())
                    layout.plots.append(plot)
                    occupied.insertFootprint(outline)
                    break
                }
            }
        }

        // Keep handling and stored bundles beside a harvested bed and off
        // the work paths. One station per hamlet is enough to read.
        var stations = Set<Int32>()
        for plot in layout.plots where !stations.contains(plot.settlement) {
            for side in [Float(-1), 1] {
                let station = plot.centre + plot.along * (side * 2.72 / metres)
                let direction = atan2(plot.across.x, plot.across.y)
                let parts: [Part] = [.sheaves, .tray]
                let centres = [station - plot.across * (0.43 / metres),
                               station + plot.across * (0.48 / metres)]
                var candidate: [(Part, InstanceData, [SIMD2<Float>])] = []
                for (part, point) in zip(parts, centres) {
                    var model = translation(SIMD3(point.x, 0, point.y)) * rotationY(direction)
                        * scaleMatrix(SIMD3(repeating: 1 / metres))
                    let bounds = RiverPlacement.authoredBounds(part.path)
                    guard bounds.count == 4 else { break }
                    let area = RiverPlacement.transformed(bounds, by: model)
                    guard accepts(area, maxRiseMetres: 0.085) else { break }
                    model.columns.3.y = scene.renderedTerrainHeight(at: point)
                    candidate.append((part, instance(model), area))
                }
                guard candidate.count == 2 else { continue }
                for (part, prop, area) in candidate {
                    layout.props[part, default: []].append(prop)
                    occupied.insertFootprint(area)
                }
                stations.insert(plot.settlement)
                break
            }
        }
        return layout
    }

    static func plant(_ plots: [Plot], on soil: FieldSurface.Mask, into layout: inout Layout) {
        for plot in plots {
            var rng = SplitMix64(seed: plot.seed)
            let beds = RiverPlacement.authoredBounds(plot.crop.path)
            guard beds.count == 4 else { continue }
            for row in 0..<8 {
                for column in 0..<6 {
                    if rng.nextFloat() < 0.08 { continue }
                    let x = (Float(row) - 3.5) * 0.615 + rng.nextFloat(in: -0.09...0.09)
                    let z = (Float(column) - 2.5) * 0.50 + rng.nextFloat(in: -0.085...0.085)
                    let point = plot.centre + (plot.across * x + plot.along * z) / metres
                    let scale = rng.nextFloat(in: 0.82...1.12) / metres
                    guard let height = soil.height(at: point) else { continue }
                    let model = translation(SIMD3(point.x, height, point.y))
                        * rotationY(rng.nextFloat(in: 0...(2 * .pi))) * scaleMatrix(SIMD3(repeating: scale))
                    let area = RiverPlacement.transformed(beds, by: model)
                    guard area.allSatisfy({ soil.covers($0) }) else { continue }
                    layout.props[plot.crop, default: []].append(instance(model))
                }
            }
        }
    }

    private static func instance(_ model: simd_float4x4) -> InstanceData {
        InstanceData(model: model, color: SIMD4(1, 1, 1, 0), material: SIMD4(9, 0, 0, 0))
    }
}

enum HearthEffects {
    private static let metres = RiverGraph.metresPerUnit

    struct Source {
        let position: SIMD3<Float>
        let phase: Float
        let index: Int
    }

    static func sources(_ routines: [NeolithicPeople.Routine]) -> [Source] {
        routines.enumerated().compactMap { index, routine in
            guard routine.kind == .tending, let base = routine.fixture?.columns.3 else { return nil }
            return Source(position: SIMD3(base.x, base.y, base.z), phase: routine.phase, index: index)
        }
    }

    /// Four local lights at most. The tie break preserves the original site order.
    static func lights(_ sources: [Source], eye: SIMD3<Float>, time: Float,
                       dusk: Float, rain: Float) -> [SIMD4<Float>] {
        guard dusk > 0 else { return [] }
        return sources.compactMap { source -> (Source, Float)? in
            let distance = simd_distance_squared(source.position, eye)
            return distance < pow(36 / metres, 2) ? (source, distance) : nil
        }.sorted { ($0.1, $0.0.index) < ($1.1, $1.0.index) }.prefix(4).map { source, _ in
            let turn = source.phase * 6.283185
            let pulse = 0.84 + 0.09 * sin(time * 5.1 + turn) + 0.07 * sin(time * 8.7 + turn)
            let power = pulse * dusk * (1 - rain * 0.72)
            return SIMD4(source.position.x, source.position.y + 0.23 / metres, source.position.z, power)
        }
    }

    static func smoke(_ sources: [Source], eye: SIMD3<Float>, time: Float, rain: Float) -> [InstanceData] {
        var puffs: [(InstanceData, Float, Int)] = []
        for source in sources where simd_distance_squared(source.position, eye) < pow(120 / metres, 2) {
            for layer in 0..<7 {
                let clock = time / 6.5 + source.phase + Float(layer) / 7
                let age = clock - floor(clock)
                let sway = sin(age * 4.1 + source.phase * 6.283185) * age * 0.26
                let drift = SIMD3(age * age * 1.7, 0.16 + age * 3.1, sway + age * 0.26) / metres
                let point = source.position + drift
                let width = (0.24 + age * 0.86) / metres
                let fade = smoothstep(0, 0.12, age) * (1 - smoothstep(0.45, 1, age))
                let alpha = (0.19 - rain * 0.085) * fade
                let model = translation(point) * scaleMatrix(SIMD3(width, width * 1.6, width))
                puffs.append((InstanceData(model: model, color: SIMD4(0.69, 0.68, 0.66, alpha)),
                              simd_distance_squared(eye, point), source.index * 7 + layer))
            }
        }
        return puffs.sorted { a, b in
            a.1 == b.1 ? a.2 < b.2 : a.1 > b.1
        }.map { $0.0 }
    }
}
