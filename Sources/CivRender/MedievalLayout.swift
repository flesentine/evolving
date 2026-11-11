import Foundation
import simd

/// Medieval towns grow from a market street. Houses are long, narrow burgage
/// plots packed along the frontage, with lanes behind and fields beyond the
/// wall — the layout preserved in most European market towns today.
enum MedievalLayout: SettlementLayout {

    static func plan(settlement s: Settlement,
                     resources: ResourceMap,
                     terrain: Terrain,
                     seed: UInt64,
                     style: CityBuilder.Style) -> SettlementPlan {
        let population = max(s.population, 1)
        let radius = CityBuilder.cityRadius(population)
        let target = Int(Float(CityBuilder.buildingCount(population)) * 1.45)

        var rng = SplitMix64(seed: seed
                             ^ (UInt64(bitPattern: Int64(s.id)) &* 0x2545_F491_4F6C_DD1D))

        // The market street runs across the prevailing slope, which is where
        // historic high streets sit: flat frontage, drainage to the sides.
        let axis = rng.nextFloat(in: 0...(Float.pi))
        let dir = SIMD2<Float>(cos(axis), sin(axis))
        let perp = SIMD2<Float>(-sin(axis), cos(axis))
        let cell = max(style.width.upperBound * 2.2, radius * 0.17)
        let streetHalf = cell * 0.24
        let laneWidth = cell * 0.13
        let plotWidth = cell * 0.46
        let plotDepth = plotWidth * 3.4
        let rowPitch = plotDepth + laneWidth

        func world(_ along: Float, _ across: Float) -> SIMD2<Float> {
            SIMD2(s.x + dir.x * along + perp.x * across,
                  s.z + dir.y * along + perp.y * across)
        }

        func buildable(_ p: SIMD2<Float>) -> Bool {
            terrain.heightAt(x: p.x, z: p.y) > 0.004
                && !terrain.isWater(x: p.x, z: p.y)
                && terrain.riverAt(x: p.x, z: p.y) == 0
                && resources.sample(p).buildability > 0.10
        }

        var plots: [Plot] = []
        plots.reserveCapacity(target + 16)

        let rows = 4
        for row in 0..<rows {
            for side in [Float(-1), Float(1)] {
                let bandStart = streetHalf + cell * 0.05 + Float(row) * rowPitch
                let centerOffset = bandStart + plotDepth * 0.5
                let frontage = perp * -side

                var along = -radius * 1.06
                while along < radius * 1.06 && plots.count < target {
                    let width = plotWidth * rng.nextFloat(in: 0.92...1.08)
                    let depth = plotDepth * rng.nextFloat(in: 0.94...1.08)
                    defer { along += width * 1.02 }
                    if along + width > radius * 1.06 { break }

                    let lx = along + width * 0.5
                    let center = world(lx, side * centerOffset)
                    let dist = sqrt(lx * lx + centerOffset * centerOffset)
                    if dist > radius * 1.10 { continue }
                    guard buildable(center) else { continue }

                    // Leave a proper market square open in the front row.
                    if row == 0 && abs(lx) < radius * 0.26 { continue }

                    let district: District
                    if row == 0 && abs(lx) < radius * 0.70 {
                        district = .commercial
                    } else if row == 0 {
                        district = .residential
                    } else if row == 1 {
                        district = (Int(abs(lx) / plotWidth) % 7 == 3) ? .civic : .residential
                    } else if row == rows - 1 {
                        district = .agricultural
                    } else {
                        district = .residential
                    }

                    plots.append(Plot(center: center,
                                      frontage: frontage,
                                      width: width,
                                      depth: depth,
                                      district: district,
                                      roadID: row,
                                      frontageRank: row == 0 ? 0 : 1,
                                      ring: row,
                                      cellIndex: SIMD2(Int(along / plotWidth), row),
                                      axis: axis))
                }
            }
        }

        // Suburban ribbons outside the wall, strung along the approach roads.
        for side in [Float(-1), Float(1)] {
            var along = radius * 1.32
            while along < radius * 1.72 && plots.count < target {
                let width = plotWidth * rng.nextFloat(in: 0.95...1.12)
                defer { along += width * 1.05 }
                for acrossSide in [Float(-1), Float(1)] {
                    let center = world(along, acrossSide * (streetHalf + plotDepth * 0.55))
                    guard buildable(center) else { continue }
                    plots.append(Plot(center: center,
                                      frontage: perp * -acrossSide,
                                      width: width,
                                      depth: plotDepth,
                                      district: .agricultural,
                                      roadID: 99,
                                      frontageRank: 2,
                                      ring: rows + 1,
                                      cellIndex: SIMD2(Int(along / plotWidth), rows + 1),
                                      axis: axis))
                }
            }
        }

        // Front row first, then each row behind it, centre outward.
        plots.sort {
            if $0.ring != $1.ring { return $0.ring < $1.ring }
            return abs($0.cellIndex.x) < abs($1.cellIndex.x)
        }

        // The nearest civic plot becomes a dedicated church; the next one
        // stays a taller guildhall.
        var landmarks: [Landmark] = []
        if let index = plots.firstIndex(where: { $0.district == .civic }) {
            let plot = plots.remove(at: index)
            let great = s.population > 500
            landmarks.append(Landmark(kind: great ? .cathedral : .church,
                                      center: plot.center,
                                      facing: plot.facing,
                                      scale: great ? max(cell * 1.7, radius * 0.26)
                                                   : max(cell * 1.3, radius * 0.19)))
        }
        var guildhalls = 0
        for i in plots.indices where plots[i].district == .civic && guildhalls < 1 {
            plots[i].scaleMultiplier = 1.30
            guildhalls += 1
        }

        // Market street, back lanes, cross lanes and approach roads.
        var roads: [RoadSegment] = []
        let marketHalf = radius * 1.14
        roads += RoadPlanning.run(from: world(-marketHalf, 0),
                                  to: world(marketHalf, 0),
                                  roadClass: 1, width: streetHalf * 2,
                                  terrain: terrain, chunks: 8)
        // One rear lane per side serves the burgage gardens; deeper rows are
        // reached through gaps rather than a full grid of lanes.
        for side in [Float(-1), Float(1)] {
            let across = side * (streetHalf + cell * 0.05 + rowPitch - laneWidth * 0.5)
            roads += RoadPlanning.run(from: world(-radius * 0.96, across),
                                      to: world(radius * 0.96, across),
                                      roadClass: 2, width: laneWidth,
                                      terrain: terrain, chunks: 6)
        }
        // Three cross lanes: the two ends of the market and the middle.
        let crossCount = 3
        for k in 0..<crossCount {
            let along = (Float(k) / Float(crossCount - 1) * 2 - 1) * radius * 0.68
            let across = streetHalf + rowPitch * 1.5
            roads += RoadPlanning.run(from: world(along, -across),
                                      to: world(along, across),
                                      roadClass: 2, width: laneWidth * 0.9,
                                      terrain: terrain, chunks: 4)
        }
        for side in [Float(-1), Float(1)] {
            roads += RoadPlanning.run(from: world(side * radius * 1.12, 0),
                                      to: world(side * radius * 1.55, 0),
                                      roadClass: 2, width: laneWidth * 1.2,
                                      terrain: terrain, chunks: 3)
        }

        // A closed wall polygon, used by the wall renderer for its gate.
        let wallRadius = radius * 1.16
        let wall = (0..<24).map { k -> SIMD2<Float> in
            let a = Float(k) / 24 * 2 * Float.pi
            return SIMD2(s.x + cos(a) * wallRadius, s.z + sin(a) * wallRadius)
        }

        return SettlementPlan(center: SIMD2(s.x, s.z),
                              axis: axis,
                              roads: roads,
                              plots: plots,
                              cell: cell,
                              radius: radius,
                              half: rows,
                              wall: wall,
                              landmarks: landmarks,
                              gates: [axis, axis + .pi])
    }
}
