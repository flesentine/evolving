import Foundation
import simd

/// The car-era city: a compact downtown inside a ring road, radial arterials,
/// separated uses, and low-density suburbs outside the ring.
enum ModernLayout: SettlementLayout {

    static func plan(settlement s: Settlement,
                     resources: ResourceMap,
                     terrain: Terrain,
                     seed: UInt64,
                     style: CityBuilder.Style) -> SettlementPlan {
        let population = max(s.population, 1)
        let radius = CityBuilder.plannedRadius(population, era: .modern)
        let count = CityBuilder.buildingCount(population)
        let target = min(Int(Float(count) * 0.90), 80)

        var rng = SplitMix64(seed: seed
                             ^ (UInt64(bitPattern: Int64(s.id)) &* 0x9E37_79B9_7F4A_7C15)
                             ^ 0x30DE_2A11)
        let axis = rng.nextFloat(in: 0...(Float.pi / 2))
        let dir = SIMD2<Float>(cos(axis), sin(axis))
        let perp = SIMD2<Float>(-sin(axis), cos(axis))
        let cell = max(0.0118, radius * 0.16)
        let half = max(Int(ceil(radius / cell)), 3)
        let ringRadius = radius * 0.62

        func world(_ gi: Float, _ gj: Float) -> SIMD2<Float> {
            SIMD2(s.x + dir.x * gi * cell + perp.x * gj * cell,
                  s.z + dir.y * gi * cell + perp.y * gj * cell)
        }
        func buildable(_ p: SIMD2<Float>) -> Bool {
            terrain.heightAt(x: p.x, z: p.y) > 0.004
                && !terrain.isWater(x: p.x, z: p.y)
                && terrain.riverAt(x: p.x, z: p.y) == 0
                && resources.sample(p).buildability > 0.08
        }

        var plots: [Plot] = []
        plots.reserveCapacity(target + 12)

        for gi in (-half)...half {
            for gj in (-half)...half {
                if abs(gi) <= 1 && abs(gj) <= 1 { continue }
                let lx = Float(gi) * cell
                let lz = Float(gj) * cell
                let dist = sqrt(lx * lx + lz * lz)
                guard dist <= radius else { continue }
                let center = world(Float(gi), Float(gj))
                guard buildable(center) else { continue }

                // Suburban fringe: detached houses with gaps between them.
                if dist > ringRadius && rng.nextFloat() < 0.42 { continue }

                let ring = max(abs(gi), abs(gj))
                let district: District
                if dist < ringRadius * 0.55 {
                    district = .commercial
                } else if dist > ringRadius * 1.05 {
                    district = .residential
                } else if abs(Float(gi) - Float(gj)) <= 1 && rng.nextFloat() < 0.35 {
                    district = .industrial
                } else {
                    district = .residential
                }

                let facing = gj > 0 ? atan2(-perp.x, -perp.y)
                                    : atan2(perp.x, perp.y)
                let core = dist < ringRadius * 0.55

                plots.append(Plot(center: center,
                                  frontage: SIMD2(sin(facing), cos(facing)),
                                  width: cell * rng.nextFloat(in: 0.78...1.05),
                                  depth: cell * rng.nextFloat(in: 0.85...1.10),
                                  district: district,
                                  roadID: 0,
                                  frontageRank: ring <= 2 ? 0 : 1,
                                  ring: ring,
                                  cellIndex: SIMD2(gi, gj),
                                  axis: axis,
                                  scaleMultiplier: core ? 1.65 : (dist > ringRadius ? 0.85 : 1.10)))
            }
        }

        plots.sort {
            if $0.ring != $1.ring { return $0.ring < $1.ring }
            return abs($0.cellIndex.x) + abs($0.cellIndex.y)
                < abs($1.cellIndex.x) + abs($1.cellIndex.y)
        }
        if plots.count > target { plots.removeSubrange(target..<plots.count) }
        let builtRadius = plots.reduce(Float(0)) {
            max($0, simd_distance($1.center, SIMD2(s.x, s.z)))
        }

        // Ring road and six radial arterials.
        var roads: [RoadSegment] = []
        for k in 0..<24 {
            let a0 = Float(k) / 24 * 2 * Float.pi
            let a1 = Float(k + 1) / 24 * 2 * Float.pi
            roads += RoadPlanning.run(
                from: SIMD2(s.x + cos(a0) * ringRadius, s.z + sin(a0) * ringRadius),
                to: SIMD2(s.x + cos(a1) * ringRadius, s.z + sin(a1) * ringRadius),
                roadClass: 1, width: cell * 0.62,
                terrain: terrain, chunks: 1)
        }
        for k in 0..<6 {
            let a = axis + Float(k) / 6 * 2 * Float.pi
            let end = SIMD2(s.x + cos(a) * builtRadius * 1.10,
                            s.z + sin(a) * builtRadius * 1.10)
            roads += RoadPlanning.run(from: SIMD2(s.x, s.z), to: end,
                                      roadClass: 1, width: cell * 0.50,
                                      terrain: terrain, chunks: 4)
        }

        return SettlementPlan(center: SIMD2(s.x, s.z),
                              axis: axis,
                              roads: roads,
                              plots: plots,
                              cell: cell,
                              radius: max(builtRadius * 1.05, cell * 2),
                              half: half)
    }
}

/// Transit-oriented density: towers cluster at a few stations and taper
/// outward, with parks filling the gaps.
enum InformationLayout: SettlementLayout {

    static func plan(settlement s: Settlement,
                     resources: ResourceMap,
                     terrain: Terrain,
                     seed: UInt64,
                     style: CityBuilder.Style) -> SettlementPlan {
        let population = max(s.population, 1)
        let radius = CityBuilder.plannedRadius(population, era: .information)
        let count = CityBuilder.buildingCount(population)
        let target = min(Int(Float(count) * 0.62), 70)

        var rng = SplitMix64(seed: seed
                             ^ (UInt64(bitPattern: Int64(s.id)) &* 0x9E37_79B9_7F4A_7C15)
                             ^ 0x1F02_7715)
        let axis = rng.nextFloat(in: 0...(Float.pi / 2))
        let dir = SIMD2<Float>(cos(axis), sin(axis))
        let perp = SIMD2<Float>(-sin(axis), cos(axis))
        let cell = max(0.0118, radius * 0.15)
        let half = max(Int(ceil(radius / cell)), 3)

        // Two to four stations along the transit spine.
        let stationCount = 2 + rng.nextInt(3)
        var stations: [SIMD2<Float>] = []
        for k in 0..<stationCount {
            let t = (Float(k) + 0.5) / Float(stationCount) * 2 - 1
            stations.append(SIMD2(s.x + dir.x * t * radius * 0.72,
                                  s.z + dir.y * t * radius * 0.72))
        }

        func world(_ gi: Float, _ gj: Float) -> SIMD2<Float> {
            SIMD2(s.x + dir.x * gi * cell + perp.x * gj * cell,
                  s.z + dir.y * gi * cell + perp.y * gj * cell)
        }
        func buildable(_ p: SIMD2<Float>) -> Bool {
            terrain.heightAt(x: p.x, z: p.y) > 0.004
                && !terrain.isWater(x: p.x, z: p.y)
                && terrain.riverAt(x: p.x, z: p.y) == 0
                && resources.sample(p).buildability > 0.08
        }

        var plots: [Plot] = []
        plots.reserveCapacity(target + 16)

        for gi in (-half)...half {
            for gj in (-half)...half {
                if abs(gi) <= 1 && abs(gj) <= 1 { continue }
                let lx = Float(gi) * cell
                let lz = Float(gj) * cell
                if lx * lx + lz * lz > radius * radius { continue }
                let center = world(Float(gi), Float(gj))
                guard buildable(center) else { continue }

                let nearest = stations.map { simd_distance($0, center) }.min() ?? radius
                let nodeFactor = max(0, 1 - nearest / (radius * 0.55))

                // Parks break up the tower grid away from stations.
                if nodeFactor < 0.15 && rng.nextFloat() < 0.40 { continue }

                let district: District = nodeFactor > 0.45
                    ? .commercial
                    : (rng.nextFloat() < 0.18 ? .park : .residential)
                let facing = gj > 0 ? atan2(-perp.x, -perp.y)
                                    : atan2(perp.x, perp.y)

                plots.append(Plot(center: center,
                                  frontage: SIMD2(sin(facing), cos(facing)),
                                  width: cell * rng.nextFloat(in: 0.82...1.06),
                                  depth: cell * rng.nextFloat(in: 0.90...1.12),
                                  district: district,
                                  roadID: 0,
                                  frontageRank: nodeFactor > 0.45 ? 0 : 1,
                                  ring: max(abs(gi), abs(gj)),
                                  cellIndex: SIMD2(gi, gj),
                                  axis: axis,
                                  scaleMultiplier: 0.85 + nodeFactor * 1.25))
            }
        }

        // Node towers first: the skyline clusters at the stations and thins
        // outward instead of covering every block.
        plots.sort { $0.scaleMultiplier > $1.scaleMultiplier }
        if plots.count > target { plots.removeSubrange(target..<plots.count) }
        plots.sort {
            if $0.ring != $1.ring { return $0.ring < $1.ring }
            return abs($0.cellIndex.x) + abs($0.cellIndex.y)
                < abs($1.cellIndex.x) + abs($1.cellIndex.y)
        }
        let builtRadius = plots.reduce(Float(0)) {
            max($0, simd_distance($1.center, SIMD2(s.x, s.z)))
        }

        // Transit spine plus feeder arterials.
        var roads: [RoadSegment] = []
        roads += RoadPlanning.run(from: SIMD2(s.x - dir.x * builtRadius,
                                              s.z - dir.y * builtRadius),
                                  to: SIMD2(s.x + dir.x * builtRadius,
                                            s.z + dir.y * builtRadius),
                                  roadClass: 0, width: cell * 0.55,
                                  terrain: terrain, chunks: 6)
        for k in 0..<4 {
            let a = axis + Float(k) / 4 * Float.pi
            let end = SIMD2(s.x + cos(a) * builtRadius * 1.05,
                            s.z + sin(a) * builtRadius * 1.05)
            roads += RoadPlanning.run(from: SIMD2(s.x, s.z), to: end,
                                      roadClass: 2, width: cell * 0.30,
                                      terrain: terrain, chunks: 3)
        }

        return SettlementPlan(center: SIMD2(s.x, s.z),
                              axis: axis,
                              roads: roads,
                              plots: plots,
                              cell: cell,
                              radius: max(builtRadius * 1.05, cell * 2),
                              half: half)
    }
}

/// Near-future: a few arcology clusters on a transit spine, with most of the
/// land returned to green.
enum FutureLayout: SettlementLayout {

    static func plan(settlement s: Settlement,
                     resources: ResourceMap,
                     terrain: Terrain,
                     seed: UInt64,
                     style: CityBuilder.Style) -> SettlementPlan {
        let population = max(s.population, 1)
        let radius = CityBuilder.plannedRadius(population, era: .future)
        let count = CityBuilder.buildingCount(population)

        var rng = SplitMix64(seed: seed
                             ^ (UInt64(bitPattern: Int64(s.id)) &* 0x9E37_79B9_7F4A_7C15)
                             ^ 0xF07D_2E00)
        let axis = rng.nextFloat(in: 0...(Float.pi))
        let dir = SIMD2<Float>(cos(axis), sin(axis))
        let perp = SIMD2<Float>(-sin(axis), cos(axis))
        let cell = max(0.0128, radius * 0.17)

        func buildable(_ p: SIMD2<Float>) -> Bool {
            terrain.heightAt(x: p.x, z: p.y) > 0.004
                && !terrain.isWater(x: p.x, z: p.y)
                && terrain.riverAt(x: p.x, z: p.y) == 0
                && resources.sample(p).buildability > 0.08
        }

        var plots: [Plot] = []
        let clusterCount = 2 + rng.nextInt(2)
        for cluster in 0..<clusterCount {
            let t = clusterCount == 1 ? 0
                : (Float(cluster) / Float(clusterCount - 1) * 2 - 1)
            let hub = SIMD2(s.x + dir.x * t * radius * 0.52,
                            s.z + dir.y * t * radius * 0.52)
            guard buildable(hub) else { continue }

            for k in 0..<6 {
                let a = Float(k) / 8 * 2 * Float.pi
                let d = cell * (k == 0 ? 0 : 1.15)
                let p = SIMD2(hub.x + cos(a) * d, hub.y + sin(a) * d)
                guard buildable(p) else { continue }
                let facing = atan2(hub.x - p.x, hub.y - p.y)
                plots.append(Plot(center: p,
                                  frontage: SIMD2(sin(facing), cos(facing)),
                                  width: cell * 0.95,
                                  depth: cell * 0.95,
                                  district: k == 0 ? .civic : .commercial,
                                  roadID: 0,
                                  frontageRank: 0,
                                  ring: cluster,
                                  cellIndex: SIMD2(k, cluster),
                                  axis: axis,
                                  scaleMultiplier: k == 0 ? 1.90 : 1.30))
            }
        }

        // A ring of mid-rise housing and services between the hubs.
        let housing = 8 + rng.nextInt(4)
        for k in 0..<housing {
            let a = Float(k) / Float(housing) * 2 * Float.pi + 0.2
            let d = radius * rng.nextFloat(in: 0.55...0.88)
            let p = SIMD2(s.x + cos(a) * d, s.z + sin(a) * d)
            guard buildable(p) else { continue }
            plots.append(Plot(center: p,
                              frontage: SIMD2(cos(a + .pi), sin(a + .pi)),
                              width: cell * 0.9,
                              depth: cell * 0.9,
                              district: rng.nextFloat() < 0.2 ? .park : .residential,
                              roadID: 0,
                              frontageRank: 1,
                              ring: 9,
                              cellIndex: SIMD2(k, 9),
                              axis: axis,
                              scaleMultiplier: 0.95))
        }

        plots.sort { $0.ring < $1.ring }
        let builtRadius = plots.reduce(Float(0)) {
            max($0, simd_distance($1.center, SIMD2(s.x, s.z)))
        }

        // Transit spine connecting the arcologies.
        var roads: [RoadSegment] = []
        roads += RoadPlanning.run(from: SIMD2(s.x - dir.x * builtRadius * 1.3,
                                              s.z - dir.y * builtRadius * 1.3),
                                  to: SIMD2(s.x + dir.x * builtRadius * 1.3,
                                            s.z + dir.y * builtRadius * 1.3),
                                  roadClass: 0, width: cell * 0.6,
                                  terrain: terrain, chunks: 6)

        return SettlementPlan(center: SIMD2(s.x, s.z),
                              axis: axis,
                              roads: roads,
                              plots: plots,
                              cell: cell,
                              radius: max(builtRadius * 1.05, cell * 2),
                              half: clusterCount,
                              rail: [SIMD2(s.x - dir.x * builtRadius * 1.3,
                                           s.z - dir.y * builtRadius * 1.3),
                                     SIMD2(s.x + dir.x * builtRadius * 1.3,
                                           s.z + dir.y * builtRadius * 1.3)])
    }
}
