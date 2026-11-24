import simd

/// A short routine tied to a visible town feature. Layout is rebuilt with the
/// settlement; sampling a routine never advances mutable animation state.
struct TownActivity: Equatable {
    enum Kind: String {
        case fieldwork, market, freight

        init(era: Era) {
            switch era {
            case .neolithic, .bronze: self = .fieldwork
            case .classical, .medieval, .renaissance: self = .market
            case .industrial, .modern, .information, .future: self = .freight
            }
        }

        var coat: SIMD3<Float> {
            switch self {
            case .fieldwork: return SIMD3(0.56, 0.44, 0.28)
            case .market: return SIMD3(0.30, 0.53, 0.61)
            case .freight: return SIMD3(0.72, 0.37, 0.18)
            }
        }
    }

    struct Pose: Equatable {
        let position: SIMD2<Float>
        let facing: Float
        let stride: Float
        let reach: Float
    }

    static let metres = RiverGraph.metresPerUnit
    let townID: Int32
    let kind: Kind
    let start: SIMD2<Float>
    let end: SIMD2<Float>
    /// Phase in turns, independent of layout ordering and camera.
    let offset: Float

    func sample(time: Float) -> Pose {
        let period: Float = kind == .fieldwork ? 11 : kind == .market ? 9 : 12
        let clock = time / period + offset
        let phase = clock - floor(clock)
        // Work or exchange at the far end, then walk back and pause briefly.
        let progress = smoothstep(0, 0.33, phase) * (1 - smoothstep(0.62, 0.90, phase))
        let direction = end - start
        let turn = smoothstep(0.54, 0.62, phase) * (1 - smoothstep(0.90, 1, phase))
        let heading = atan2(direction.x, direction.y) + Float.pi * turn
        let outbound = smoothstep(0, 0.05, phase) * (1 - smoothstep(0.28, 0.33, phase))
        let returning = smoothstep(0.62, 0.67, phase) * (1 - smoothstep(0.85, 0.90, phase))
        let gait = (outbound + returning) * sin(time * 8 + offset * 2 * Float.pi)
        let working = smoothstep(0.32, 0.40, phase) * (1 - smoothstep(0.51, 0.58, phase))
        let reach = kind == .fieldwork
            ? working * (0.66 + 0.30 * sin(time * 5))
            : working
        return Pose(position: start + direction * progress,
                    facing: heading,
                    stride: gait, reach: reach)
    }

    static func candidates(townID: Int32, kind: Kind, seed: UInt64,
                           routes: [(SIMD2<Float>, SIMD2<Float>)]) -> [Self] {
        var rng = SplitMix64(seed: seed ^ (UInt64(bitPattern: Int64(townID)) &* 0xAEF3_44C1_B933_8EF7))
        let offset = rng.nextFloat()
        return routes.map { Self(townID: townID, kind: kind, start: $0.0, end: $0.1, offset: offset) }
    }

    var footprint: [SIMD2<Float>] {
        let axis = simd_normalize(end - start)
        // Include the overhang of the load or extended hand at either end.
        let longitudinal = axis * ((kind == .freight ? 2.4 : 1.8) / Self.metres)
        let side = SIMD2(-axis.y, axis.x) * (1.6 / Self.metres)
        return [start - longitudinal - side, end + longitudinal - side,
                end + longitudinal + side, start - longitudinal + side]
    }

    static func choose(_ candidates: [[Self]], geometry: CityBuilder.Geometry, scene: WorldScene) -> [Self] {
        guard !candidates.isEmpty else { return [] }
        let roads = scene.activityRoads
        let streets = scene.activityStreets
        let crops = candidates.first?.first?.kind == .fieldwork
            ? FieldSurface.Mask(mesh: scene.fieldMesh) : FieldSurface.Mask()
        var solids = FieldSurface.Mask()
        for key in geometry.buildings.keys.sorted() {
            let bounds = RiverPlacement.authoredBounds(key)
            for instance in geometry.buildings[key] ?? [] {
                solids.insertFootprint(RiverPlacement.transformed(bounds, by: instance.model))
            }
        }
        // Stalls, walls and other box-built structures share the cube mesh.
        let cube = RiverPlacement.bounds(Geometry.cube())
        for instance in geometry.boxes {
            solids.insertFootprint(RiverPlacement.transformed(cube, by: instance.model))
        }

        var occupied = FieldSurface.Mask()
        return candidates.compactMap { alternatives in
            let selected = alternatives.first { route in
                let area = route.footprint
                guard !scene.riverField.intersectsFootprint(area, margin: 0.5 / metres),
                      !roads.intersectsFootprint(area), !solids.intersectsFootprint(area),
                      !occupied.intersectsFootprint(area),
                      route.kind != .fieldwork || !streets.intersectsFootprint(area) else { return false }
                return (0...4).allSatisfy { step in
                    let point = route.start + (route.end - route.start) * (Float(step) / 4)
                    return scene.renderedTerrainHeight(at: point) > 6 / metres
                        && scene.terrain.slopeAt(x: point.x, z: point.y) < 0.45
                        && (route.kind != .fieldwork || crops.covers(point))
                }
            }
            if let selected { occupied.insertFootprint(selected.footprint) }
            return selected
        }
    }
}
