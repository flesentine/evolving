import Foundation
import simd

/// Renaissance towns overlay an ideal plan on the medieval fabric: a central
/// piazza, radial boulevards to the gates, bastioned walls, and one preserved
/// old quarter.
enum RenaissanceLayout: SettlementLayout {

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
                             ^ 0x2E17_A155)
        let axis = rng.nextFloat(in: 0...(Float.pi / 2))
        let dir = SIMD2<Float>(cos(axis), sin(axis))
        let perp = SIMD2<Float>(-sin(axis), cos(axis))

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
                // Piazza: a clear 3 x 3 block at the centre.
                if abs(gi) <= 1 && abs(gj) <= 1 { continue }
                let lx = Float(gi) * cell
                let lz = Float(gj) * cell
                if lx * lx + lz * lz > radius * radius { continue }
                let center = world(Float(gi), Float(gj))
                guard buildable(center) else { continue }

                let ring = max(abs(gi), abs(gj))

                // Keep the eight boulevards clear so the radial plan reads
                // from above.
                if ring > 2 {
                    let theta = atan2(center.y - s.z, center.x - s.x)
                    let step = 2 * Float.pi / 8
                    let nearest = (theta - axis) / step
                    let delta = (nearest - nearest.rounded()) * step
                    let radial = simd_distance(center, SIMD2(s.x, s.z))
                    if abs(sin(delta)) * radial < cell * 1.15 { continue }
                }
                let oldQuarter = gi > 1 && gj > 1
                let district: District
                if ring <= 2 {
                    district = .civic
                } else if ring == 3 || ring == 4 {
                    district = .commercial
                } else if ring >= half - 1 {
                    district = .agricultural
                } else {
                    district = .residential
                }

                // The preserved medieval quarter keeps narrow, irregular
                // plots; the rest of the town is regular.
                let width = oldQuarter ? cell * rng.nextFloat(in: 0.52...0.72)
                                       : cell * 0.94
                let facing = gj > 0 ? atan2(-perp.x, -perp.y)
                                    : atan2(perp.x, perp.y)

                plots.append(Plot(center: center,
                                  frontage: SIMD2(sin(facing), cos(facing)),
                                  width: width,
                                  depth: oldQuarter ? cell * rng.nextFloat(in: 1.4...1.9)
                                                    : cell * 0.94,
                                  district: district,
                                  roadID: 0,
                                  frontageRank: ring <= 2 ? 0 : 1,
                                  ring: ring,
                                  cellIndex: SIMD2(gi, gj),
                                  axis: axis,
                                  scaleMultiplier: ring <= 2 ? 1.18 : 1,
                                  podium: ring <= 2 ? 0.0005 : 0))
            }
        }

        plots.sort {
            if $0.ring != $1.ring { return $0.ring < $1.ring }
            return abs($0.cellIndex.x) + abs($0.cellIndex.y)
                < abs($1.cellIndex.x) + abs($1.cellIndex.y)
        }
        if plots.count > target { plots.removeSubrange(target..<plots.count) }

        // Streets only run as far as the built plots, not across open fields.
        let builtRadius = plots.reduce(Float(0)) {
            max($0, simd_distance($1.center, SIMD2(s.x, s.z)))
        }

        // Radial boulevards from the piazza to eight gates.
        var roads: [RoadSegment] = []
        for k in 0..<8 {
            let a = axis + Float(k) / 8 * 2 * Float.pi
            let end = SIMD2(s.x + cos(a) * radius * 1.06,
                            s.z + sin(a) * radius * 1.06)
            roads += RoadPlanning.run(from: SIMD2(s.x, s.z), to: end,
                                      roadClass: k % 2 == 0 ? 1 : 2,
                                      width: cell * (k % 2 == 0 ? 0.46 : 0.26),
                                      terrain: terrain, chunks: 4)
        }
        // Ring road around the piazza.
        let ringRadius = radius * 0.58
        for k in 0..<20 {
            let a0 = Float(k) / 20 * 2 * Float.pi
            let a1 = Float(k + 1) / 20 * 2 * Float.pi
            roads += RoadPlanning.run(
                from: SIMD2(s.x + cos(a0) * ringRadius, s.z + sin(a0) * ringRadius),
                to: SIMD2(s.x + cos(a1) * ringRadius, s.z + sin(a1) * ringRadius),
                roadClass: 2, width: cell * 0.22,
                terrain: terrain, chunks: 1)
        }

        // Bastioned wall.
        var wall: [SIMD2<Float>]?
        if population > 180 {
            let wallRadius = radius * 1.06
            wall = (0..<24).map { k in
                let a = Float(k) / 24 * 2 * Float.pi
                return SIMD2(s.x + cos(a) * wallRadius, s.z + sin(a) * wallRadius)
            }
        }

        var landmarks: [Landmark] = []
        if population > 220 {
            let domeCenter = SIMD2(s.x + dir.x * cell * 1.15,
                                   s.z + dir.y * cell * 1.15)
            landmarks.append(Landmark(kind: .dome,
                                      center: domeCenter,
                                      facing: axis,
                                      scale: radius * 0.38))
        }

        return SettlementPlan(center: SIMD2(s.x, s.z),
                              axis: axis,
                              roads: roads,
                              plots: plots,
                              cell: cell,
                              radius: max(builtRadius * 1.04, cell * 2),
                              half: half,
                              wall: wall,
                              landmarks: landmarks,
                              gates: (0..<8).map { axis + Float($0) / 8 * 2 * Float.pi })
    }
}
