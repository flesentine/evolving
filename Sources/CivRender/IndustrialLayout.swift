import Foundation
import simd

/// Industrial towns are pulled toward power and transport: mills on the water,
/// terraces within walking distance, warehouses at the wharf, a railway
/// corridor, and villas on the clean, high side.
enum IndustrialLayout: SettlementLayout {

    static func plan(settlement s: Settlement,
                     resources: ResourceMap,
                     terrain: Terrain,
                     seed: UInt64,
                     style: CityBuilder.Style) -> SettlementPlan {
        let population = max(s.population, 1)
        let radius = CityBuilder.plannedRadius(population, era: .industrial)
        let count = CityBuilder.buildingCount(population)
        let target = min(Int(Float(count) * 0.92), 80)

        var rng = SplitMix64(seed: seed
                             ^ (UInt64(bitPattern: Int64(s.id)) &* 0x9E37_79B9_7F4A_7C15)
                             ^ 0x1D05_7B1A)
        let axis = rng.nextFloat(in: 0...(Float.pi / 2))
        let dir = SIMD2<Float>(cos(axis), sin(axis))
        let perp = SIMD2<Float>(-sin(axis), cos(axis))

        // The mill side faces the nearest water or ore.
        let powerAngle = resourceDirection(centre: SIMD2(s.x, s.z),
                                           radius: radius,
                                           terrain: terrain,
                                           resources: resources)
        let powerDir = SIMD2<Float>(cos(powerAngle), sin(powerAngle))
        let cleanDir = -powerDir

        let cell = max(0.0108, radius * 0.15)
        let half = max(Int(ceil(radius / cell)), 3)

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
                if gi == 0 && gj == 0 { continue }
                let lx = Float(gi) * cell
                let lz = Float(gj) * cell
                if lx * lx + lz * lz > radius * radius { continue }
                let center = world(Float(gi), Float(gj))
                guard buildable(center) else { continue }

                let ring = max(abs(gi), abs(gj))
                let toPower = simd_dot(center - SIMD2(s.x, s.z), powerDir)
                let district: District
                if toPower > radius * 0.22 && ring >= 1 {
                    district = .industrial
                } else if simd_dot(center - SIMD2(s.x, s.z), cleanDir) > radius * 0.30
                            && ring >= half - 2 {
                    district = .residential   // villa quarter
                } else if ring <= 1 {
                    district = .commercial
                } else if ring >= half - 1 {
                    district = .agricultural
                } else {
                    district = .residential
                }

                // Terraces are narrow; villas keep generous plots.
                let villa = district == .residential
                    && simd_dot(center - SIMD2(s.x, s.z), cleanDir) > radius * 0.30
                // Villas keep generous grounds; skip some plots for gardens.
                if villa && rng.nextFloat() < 0.30 { continue }
                let width = villa ? cell * 1.15 : cell * rng.nextFloat(in: 0.62...0.80)
                let facing = gj > 0 ? atan2(-perp.x, -perp.y)
                                    : atan2(perp.x, perp.y)

                plots.append(Plot(center: center,
                                  frontage: SIMD2(sin(facing), cos(facing)),
                                  width: width,
                                  depth: cell * (villa ? 1.15 : 1.5),
                                  district: district,
                                  roadID: 0,
                                  frontageRank: ring <= 1 ? 0 : 1,
                                  ring: ring,
                                  cellIndex: SIMD2(gi, gj),
                                  axis: axis,
                                  scaleMultiplier: villa ? 1.38 : 1))
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

        // A railway crosses the town beside the mill side.
        let railOffset = radius * 0.72
        let railA = SIMD2(s.x + powerDir.x * railOffset - perp.x * radius * 1.6,
                          s.z + powerDir.y * railOffset - perp.y * radius * 1.6)
        let railB = SIMD2(s.x + powerDir.x * railOffset + perp.x * radius * 1.6,
                          s.z + powerDir.y * railOffset + perp.y * radius * 1.6)

        // Mill road from the centre to the water, plus a wharf lane.
        var roads: [RoadSegment] = []
        let wharf = SIMD2(s.x + powerDir.x * radius * 1.05,
                          s.z + powerDir.y * radius * 1.05)
        roads += RoadPlanning.run(from: SIMD2(s.x, s.z), to: wharf,
                                  roadClass: 1, width: cell * 0.55,
                                  terrain: terrain, chunks: 4)

        return SettlementPlan(center: SIMD2(s.x, s.z),
                              axis: axis,
                              roads: roads,
                              plots: plots,
                              cell: cell,
                              radius: max(builtRadius * 1.04, cell * 2),
                              half: half,
                              rail: [railA, railB])
    }

    /// Direction of the strongest industrial resource around the town.
    private static func resourceDirection(centre: SIMD2<Float>,
                                          radius: Float,
                                          terrain: Terrain,
                                          resources: ResourceMap) -> Float {
        var bestAngle: Float = 0
        var best: Float = -1
        for k in 0..<24 {
            let a = Float(k) / 24 * 2 * Float.pi
            let p = SIMD2(centre.x + cos(a) * radius * 0.9,
                          centre.y + sin(a) * radius * 0.9)
            let r = resources.sample(p)
            let score = r.ore * 0.55 + r.freshWater * 0.30 + r.routeAccess * 0.15
            if score > best { best = score; bestAngle = a }
        }
        return bestAngle
    }
}
