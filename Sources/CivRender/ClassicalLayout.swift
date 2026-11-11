import Foundation
import simd

/// Classical towns are planned grids with two nuclei: the acropolis on the
/// high ground and the agora at the centre of the grid. Coastal towns add a
/// small harbour grid facing the water.
enum ClassicalLayout: SettlementLayout {

    static func plan(settlement s: Settlement,
                     resources: ResourceMap,
                     terrain: Terrain,
                     seed: UInt64,
                     style: CityBuilder.Style) -> SettlementPlan {
        let population = max(s.population, 1)
        let radius = CityBuilder.cityRadius(population)
        let count = CityBuilder.buildingCount(population)
        let target = Int(Float(count) * 1.30)

        var rng = SplitMix64(seed: seed
                             ^ (UInt64(bitPattern: Int64(s.id)) &* 0x9E37_79B9_7F4A_7C15)
                             ^ 0xC1A5_51CA)

        // Grid aligned with the coast where there is one, so the town faces
        // the sea; otherwise align with the dominant slope.
        let coast = coastDirection(from: SIMD2(s.x, s.z), radius: radius,
                                   terrain: terrain)
        let coastAngle = coast?.angle
        let axis = coastAngle ?? rng.nextFloat(in: 0...(Float.pi / 2))
        let dir = SIMD2<Float>(cos(axis), sin(axis))
        let perp = SIMD2<Float>(-sin(axis), cos(axis))

        // Acropolis sits on the highest ground inside the town radius.
        var acropolis = SIMD2<Float>(s.x, s.z)
        var bestHeight = -Float.greatestFiniteMagnitude
        for k in 0..<16 {
            let a = Float(k) / 16 * 2 * Float.pi
            let p = SIMD2(s.x + cos(a) * radius * 0.62,
                          s.z + sin(a) * radius * 0.62)
            let h = terrain.heightAt(x: p.x, z: p.y)
            if h > bestHeight { bestHeight = h; acropolis = p }
        }

        let cell = max(0.0092, radius * 0.12)
        let half = max(Int(ceil(radius / cell)), 3)

        func world(_ gi: Float, _ gj: Float) -> SIMD2<Float> {
            SIMD2(s.x + dir.x * gi * cell + perp.x * gj * cell,
                  s.z + dir.y * gi * cell + perp.y * gj * cell)
        }
        func buildable(_ p: SIMD2<Float>) -> Bool {
            terrain.heightAt(x: p.x, z: p.y) > 0.004
                && !terrain.isWater(x: p.x, z: p.y)
                && terrain.riverAt(x: p.x, z: p.y) == 0
                && resources.sample(p).buildability > 0.10
        }

        var plots: [Plot] = []
        plots.reserveCapacity(target + 12)

        for gi in (-half)...half {
            for gj in (-half)...half {
                // The agora is a clear rectangle at the centre of the grid.
                if abs(gi) <= 1 && abs(gj) <= 1 { continue }
                let lx = Float(gi) * cell
                let lz = Float(gj) * cell
                if lx * lx + lz * lz > radius * radius { continue }
                let center = world(Float(gi), Float(gj))
                guard buildable(center) else { continue }

                let ring = max(abs(gi), abs(gj))
                let nearAgora = ring <= 2
                let nearAcropolis = simd_distance(center, acropolis) < cell * 1.6
                let district: District
                if nearAcropolis {
                    district = .civic
                } else if nearAgora {
                    district = .commercial
                } else if ring >= half - 1 {
                    district = .agricultural
                } else {
                    district = .residential
                }

                let facing = gj > 0 ? atan2(-perp.x, -perp.y)
                                    : atan2(perp.x, perp.y)

                plots.append(Plot(center: center,
                                  frontage: SIMD2(sin(facing), cos(facing)),
                                  width: cell * 0.92,
                                  depth: cell * 0.92,
                                  district: district,
                                  roadID: 1,
                                  frontageRank: ring <= 2 ? 0 : 1,
                                  ring: ring,
                                  cellIndex: SIMD2(gi, gj),
                                  axis: axis,
                                  scaleMultiplier: nearAcropolis ? 1.35 : 1,
                                  podium: nearAcropolis ? 0.0008 : 0))
            }
        }

        // Harbour: a small rotated grid on the nearest shore, linked by a
        // straight avenue to the town gate.
        var harbourRoads: [RoadSegment] = []
        // Cardo and decumanus: the two broad axes crossing at the forum.
        harbourRoads += RoadPlanning.run(
            from: SIMD2(s.x - dir.x * radius * 1.10, s.z - dir.y * radius * 1.10),
            to: SIMD2(s.x + dir.x * radius * 1.10, s.z + dir.y * radius * 1.10),
            roadClass: 0, width: cell * 0.72, terrain: terrain, chunks: 5)
        harbourRoads += RoadPlanning.run(
            from: SIMD2(s.x - perp.x * radius * 1.10, s.z - perp.y * radius * 1.10),
            to: SIMD2(s.x + perp.x * radius * 1.10, s.z + perp.y * radius * 1.10),
            roadClass: 0, width: cell * 0.72, terrain: terrain, chunks: 5)

        var landmarks: [Landmark] = []
        if let coast {
            let coastAngle = coast.angle
            let shore = SIMD2(s.x + cos(coastAngle) * coast.distance * 0.94,
                              s.z + sin(coastAngle) * coast.distance * 0.94)
            let hDir = SIMD2<Float>(cos(coastAngle), sin(coastAngle))
            let hPerp = SIMD2<Float>(-sin(coastAngle), cos(coastAngle))
            for row in 0..<2 {
                for col in -3...3 {
                    let p = SIMD2(shore.x + hPerp.x * Float(col) * cell * 0.9
                                      + hDir.x * Float(row) * cell * 0.9,
                                  shore.y + hPerp.y * Float(col) * cell * 0.9
                                      + hDir.y * Float(row) * cell * 0.9)
                    guard buildable(p) else { continue }
                    plots.append(Plot(center: p,
                                      frontage: -hDir,
                                      width: cell * 0.9,
                                      depth: cell * 0.9,
                                      district: .port,
                                      roadID: 90,
                                      frontageRank: 2,
                                      ring: half + 1,
                                      cellIndex: SIMD2(col, row),
                                      axis: coastAngle))
                }
            }
            harbourRoads += RoadPlanning.run(from: SIMD2(s.x, s.z),
                                             to: shore,
                                             roadClass: 1, width: cell * 0.6,
                                             terrain: terrain, chunks: 5)
            landmarks.append(Landmark(kind: .dock,
                                      center: shore,
                                      facing: atan2(-hDir.x, -hDir.y),
                                      scale: cell * 2.6))
        }

        plots.sort {
            if $0.ring != $1.ring { return $0.ring < $1.ring }
            return abs($0.cellIndex.x) + abs($0.cellIndex.y)
                < abs($1.cellIndex.x) + abs($1.cellIndex.y)
        }
        if plots.count > target { plots.removeSubrange(target..<plots.count) }

        // The acropolis gets a dedicated temple on its highest plot.
        if let index = plots.indices.min(by: {
            simd_distance(plots[$0].center, acropolis)
                < simd_distance(plots[$1].center, acropolis)
        }) {
            let plot = plots.remove(at: index)
            landmarks.append(Landmark(kind: .temple,
                                      center: plot.center,
                                      facing: plot.facing,
                                      scale: radius * 0.46))
        }

        // Streets only run as far as the built plots, not across open fields.
        let builtRadius = plots.reduce(Float(0)) {
            max($0, simd_distance($1.center, SIMD2(s.x, s.z)))
        }

        // Wall with gates on the two main axes.
        var wall: [SIMD2<Float>]?
        if population > 180 {
            let wallRadius = radius * 1.03
            wall = (0..<24).map { k in
                let a = Float(k) / 24 * 2 * Float.pi
                return SIMD2(s.x + cos(a) * wallRadius, s.z + sin(a) * wallRadius)
            }
        }

        var aqueduct: [SIMD2<Float>]?
        if population > 220 {
            var source = SIMD2(s.x + radius * 2, s.z)
            var high = -Float.greatestFiniteMagnitude
            for k in 0..<24 {
                let a = Float(k) / 24 * 2 * Float.pi
                for step in 1...4 {
                    let d = radius * (1.4 + Float(step) * 0.55)
                    let p = SIMD2(s.x + cos(a) * d, s.z + sin(a) * d)
                    let h = terrain.heightAt(x: p.x, z: p.y)
                    if h > high { high = h; source = p }
                }
            }
            if high > 0.02 {
                var route: [SIMD2<Float>] = []
                let start = SIMD2(s.x + cos(axis) * radius * 1.02,
                                  s.z + sin(axis) * radius * 1.02)
                for i in 0...5 {
                    let t = Float(i) / 5
                    route.append(start + (source - start) * t)
                }
                aqueduct = route
            }
        }

        return SettlementPlan(center: SIMD2(s.x, s.z),
                              axis: axis,
                              roads: harbourRoads,
                              plots: plots,
                              cell: cell,
                              radius: max(builtRadius * 1.04, cell * 2),
                              half: half,
                              wall: wall,
                              landmarks: landmarks,
                              aqueduct: aqueduct,
                              gates: [axis, axis + .pi, axis + .pi / 2, axis + 3 * .pi / 2])
    }

    /// Direction of the nearest shore, or nil when the town is inland.
    private static func coastDirection(from centre: SIMD2<Float>,
                                       radius: Float,
                                       terrain: Terrain) -> (angle: Float, distance: Float)? {
        var best: (angle: Float, distance: Float)?
        for k in 0..<24 {
            let a = Float(k) / 24 * 2 * Float.pi
            for step in 1...8 {
                let d = radius * (1.5 + Float(step) * 1.1)
                let p = SIMD2(centre.x + cos(a) * d, centre.y + sin(a) * d)
                if terrain.heightAt(x: p.x, z: p.y) <= 0 {
                    if best == nil || d < best!.distance {
                        best = (a, d)
                    }
                    break
                }
            }
        }
        return best
    }
}
