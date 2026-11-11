import Foundation
import simd

/// Neolithic hamlets are clusters of huts around a shared yard, with no
/// streets at all. Movement happens between clusters and across open ground,
/// as at Çatalhöyük.
enum NeolithicLayout: SettlementLayout {

    static func plan(settlement s: Settlement,
                     resources: ResourceMap,
                     terrain: Terrain,
                     seed: UInt64,
                     style: CityBuilder.Style) -> SettlementPlan {
        let population = max(s.population, 1)
        let radius = CityBuilder.cityRadius(population)
        let target = CityBuilder.buildingCount(population)

        var rng = SplitMix64(seed: seed
                             ^ (UInt64(bitPattern: Int64(s.id)) &* 0x9E37_79B9_7F4A_7C15)
                             ^ 0x4E01_711C)

        let axis = rng.nextFloat(in: 0...(Float.pi))
        let cell = max(0.0092, radius * 0.15)
        let clusterCount = max(3, min(7, target / 4))

        func buildable(_ p: SIMD2<Float>) -> Bool {
            terrain.heightAt(x: p.x, z: p.y) > 0.004
                && !terrain.isWater(x: p.x, z: p.y)
                && terrain.riverAt(x: p.x, z: p.y) == 0
                && resources.sample(p).buildability > 0.10
        }

        var plots: [Plot] = []
        plots.reserveCapacity(target + 8)

        for cluster in 0..<clusterCount where plots.count < target {
            let angle = axis + Float(cluster) / Float(clusterCount) * 2 * Float.pi
                + rng.nextFloat(in: -0.4...0.4)
            let distance = radius * rng.nextFloat(in: 0.10...0.66)
            let yard = SIMD2(s.x + cos(angle) * distance,
                             s.z + sin(angle) * distance)
            guard buildable(yard) else { continue }

            let huts = max(4, min(14, target / clusterCount + Int(rng.nextFloat() * 4)))
            let yardRadius = cell * 1.15

            for hut in 0..<huts where plots.count < target {
                let a = Float(hut) / Float(huts) * 2 * Float.pi
                    + rng.nextFloat(in: -0.18...0.18)
                let d = yardRadius * rng.nextFloat(in: 0.95...1.55)
                let p = SIMD2(yard.x + cos(a) * d, yard.y + sin(a) * d)
                guard buildable(p) else { continue }

                let facing = atan2(yard.x - p.x, yard.y - p.y)
                let district: District = distance > radius * 0.55
                    ? .agricultural : .residential

                plots.append(Plot(center: p,
                                  frontage: SIMD2(sin(facing), cos(facing)),
                                  width: cell * rng.nextFloat(in: 0.88...1.06),
                                  depth: cell * rng.nextFloat(in: 0.88...1.06),
                                  district: district,
                                  roadID: 0,
                                  frontageRank: 2,
                                  ring: cluster,
                                  cellIndex: SIMD2(hut, cluster),
                                  axis: axis))
            }
        }

        // No roads: only open ground between clusters.
        return SettlementPlan(center: SIMD2(s.x, s.z),
                              axis: axis,
                              plots: plots,
                              cell: cell,
                              radius: radius,
                              half: clusterCount)
    }
}
