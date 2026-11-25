import simd

/// The market-street alignment and churchyard of a living medieval town
/// are derived from its founding site. Growing or revisiting the town does
/// not move either, so Timeline replay needs no additional saved state.
struct HistoricQuarter {
    static let mesh = "__church"
    private static let metres = RiverGraph.metresPerUnit

    let church: Landmark
    let ground: Float
    let yardRadius: Float

    static func streetRandom(for settlement: Settlement, seed: UInt64) -> SplitMix64 {
        SplitMix64(seed: seed ^ (UInt64(bitPattern: Int64(settlement.id)) &* 0x2545_F491_4F6C_DD1D))
    }

    static func streetAxis(for settlement: Settlement, seed: UInt64) -> Float? {
        guard settlement.founded < Era.renaissance.startYear else { return nil }
        var rng = streetRandom(for: settlement, seed: seed)
        return rng.nextFloat(in: 0...Float.pi)
    }

    init?(settlement: Settlement, era: Era, terrain: Terrain,
          axis: Float, river: RiverChannel.Field?) {
        guard era.rawValue >= Era.medieval.rawValue,
              settlement.founded < Era.renaissance.startYear else { return nil }

        let town = SIMD2(settlement.x, settlement.z)
        let along = SIMD2(cos(axis), sin(axis))
        let across = SIMD2(-along.y, along.x)
        let isRegionalCentre = settlement.prominence > 2
        let scale = (isRegionalCentre ? 18 : 13) / Self.metres
        let facing = -axis
        let bounds = RiverPlacement.authoredBounds(Self.mesh)
        guard let extent = bounds.map({ simd_length($0) }).max() else { return nil }
        let radius = extent * scale + 1.5 / Self.metres

        // The churchyard faces the old high street. Test both ends and both
        // sides in fixed order so the next viable site is reproducible.
        var offsets: [SIMD2<Float>] = [SIMD2(21, 21), SIMD2(14, 23), SIMD2(26, 24)]
        if isRegionalCentre {
            // In a larger town the first buildable terrace can be beyond the
            // immediate market blocks, especially where the river hugs a hill.
            offsets += [SIMD2(30, 30), SIMD2(30, 40), SIMD2(40, 48)]
        }
        let quadrants: [SIMD2<Float>] = [
            SIMD2(1, 1), SIMD2(-1, 1), SIMD2(1, -1), SIMD2(-1, -1)
        ]
        let candidates = offsets.flatMap { offset in quadrants.map { $0 * offset } }
        for offset in candidates {
            let site = town + (along * offset.x + across * offset.y) / Self.metres
            let model = translation(SIMD3(site.x, 0, site.y))
                * rotationY(facing) * scaleMatrix(SIMD3(repeating: scale))
            let footprint = RiverPlacement.transformed(bounds, by: model)
            if let river {
                guard river.wetIntervals(from: town, to: site).isEmpty,
                      !river.intersectsFootprint(footprint, margin: 2 / Self.metres) else { continue }
            }
            let heights = (footprint + [site]).map { terrain.interpolatedHeight(x: $0.x, z: $0.y) }
            guard let low = heights.min(), let high = heights.max(),
                  low > 6 / Self.metres, high - low <= 2.5 / Self.metres else { continue }

            church = Landmark(kind: .church, center: site, facing: facing, scale: scale)
            ground = low
            yardRadius = radius
            return
        }
        return nil
    }

    func overlaps(_ point: SIMD2<Float>, radius: Float) -> Bool {
        simd_distance_squared(point, church.center) < square(yardRadius + radius)
    }

    /// Keep the same yard clear as new streets are drawn. Clip each run
    /// against the yard expanded by the carriageway and kerb width.
    func streets(in line: CityBuilder.StreetLine) -> [CityBuilder.StreetLine] {
        let radius = yardRadius + line.width * 0.66
        let centre = church.center
        guard zip(line.points, line.points.dropFirst()).contains(where: {
            RiverPolygon.segmentDistance(centre, $0.0, $0.1) < radius
        }) else { return [line] }

        var runs: [CityBuilder.StreetLine] = []
        var points: [SIMD2<Float>] = []
        func finish() {
            if points.count >= 2 {
                runs.append(CityBuilder.StreetLine(points: points, width: line.width))
            }
            points.removeAll(keepingCapacity: true)
        }

        for (a, b) in zip(line.points, line.points.dropFirst()) {
            let delta = b - a
            let length = simd_length(delta)
            guard length > 0 else { continue }
            let direction = delta / length
            let fraction = simd_dot(centre - a, direction) / length
            let closest = a + delta * fraction
            let penetration = square(radius) - simd_distance_squared(closest, centre)
            let half = sqrt(max(penetration, 0)) / length
            let start = clamp01(fraction - half)
            let end = clamp01(fraction + half)

            if start < end {
                if start > 0 {
                    if points.isEmpty { points.append(a) }
                    points.append(a + delta * start)
                }
                finish()
                if end < 1 { points = [a + delta * end, b] }
            } else {
                if points.isEmpty { points.append(a) }
                points.append(b)
            }
        }
        finish()
        return runs
    }

    private func square(_ x: Float) -> Float { x * x }
}
