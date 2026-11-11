import Foundation
import simd

/// The baseline planner: a regular grid of plots around a central square.
///
/// This reproduces the layout the renderer used before the settlement planner
/// existed, so wiring the planner in does not change any era visually. Each
/// era replaces this with its own planner once its rules are implemented.
enum GridLayout: SettlementLayout {

    static func plan(settlement s: Settlement,
                     resources: ResourceMap,
                     terrain: Terrain,
                     seed: UInt64,
                     style: CityBuilder.Style) -> SettlementPlan {
        let population = max(s.population, 1)
        let radius = CityBuilder.cityRadius(population)

        var rng = SplitMix64(seed: seed
                             ^ (UInt64(bitPattern: Int64(s.id)) &* 0x9E37_79B9_7F4A_7C15))
        let gridAngle = rng.nextFloat(in: 0...(Float.pi / 2))
        let cell = max(style.width.upperBound * 2.2, radius * 0.17)
        let half = max(Int(ceil(radius / cell)), 2)

        var plots: [Plot] = []
        plots.reserveCapacity((half * 2 + 1) * (half * 2 + 1))

        for gi in (-half)...half {
            for gj in (-half)...half {
                // The central plot stays open for the well and market.
                if gi == 0 && gj == 0 { continue }
                let lx = Float(gi) * cell
                let lz = Float(gj) * cell
                if lx * lx + lz * lz > radius * radius { continue }

                let x = s.x + lx * cos(gridAngle) - lz * sin(gridAngle)
                let z = s.z + lx * sin(gridAngle) + lz * cos(gridAngle)

                // Doors face the street: rows front toward the town centre,
                // the central row fronts along the cross street.
                let facing: Float
                if gj > 0 {
                    facing = Float.pi - gridAngle
                } else if gj < 0 {
                    facing = -gridAngle
                } else if gi > 0 {
                    facing = atan2(-cos(gridAngle), -sin(gridAngle))
                } else {
                    facing = atan2(cos(gridAngle), sin(gridAngle))
                }

                // A simple district gradient: commerce next to the square,
                // civic and residential in the middle rings, smallholdings at
                // the fringe. Later planners replace this with resource-led
                // districts.
                let ring = max(abs(gi), abs(gj))
                let district: District
                if ring == 0 {
                    district = .commercial
                } else if ring == 1 && (gi &+ gj) % 5 == 0 {
                    district = .civic
                } else if ring >= half - 1 {
                    district = .agricultural
                } else {
                    district = .residential
                }

                plots.append(Plot(center: SIMD2(x, z),
                                  frontage: SIMD2(sin(facing), cos(facing)),
                                  width: cell,
                                  depth: cell,
                                  district: district,
                                  roadID: 0,
                                  frontageRank: 1,
                                  ring: max(abs(gi), abs(gj)),
                                  cellIndex: SIMD2(gi, gj),
                                  axis: gridAngle))
            }
        }

        // Fill a growing square block row by row: complete terraces along each
        // street before the next row starts, so a town reads as planned rows
        // rather than a scatter of plots.
        plots.sort {
            if $0.ring != $1.ring { return $0.ring < $1.ring }
            if $0.cellIndex.y != $1.cellIndex.y { return $0.cellIndex.y < $1.cellIndex.y }
            return $0.cellIndex.x < $1.cellIndex.x
        }

        // Grid streets, split into short runs so steep cells are skipped
        // instead of drawn as a road up a hillside.
        var roads: [RoadSegment] = []
        let reach = Float(half) * cell
        let roadWidth = cell * 0.34
        let ca = cos(gridAngle), sa = sin(gridAngle)
        func world(_ lx: Float, _ lz: Float) -> SIMD2<Float> {
            SIMD2(s.x + lx * ca - lz * sa,
                  s.z + lx * sa + lz * ca)
        }
        for gj in (-half)...half {
            let lz = Float(gj) * cell
            roads += RoadPlanning.run(from: world(-reach, lz),
                                      to: world(reach, lz),
                                      roadClass: 1, width: roadWidth,
                                      terrain: terrain,
                                      chunks: half * 2 + 1)
        }
        for gi in (-half)...half {
            let lx = Float(gi) * cell
            roads += RoadPlanning.run(from: world(lx, -reach),
                                      to: world(lx, reach),
                                      roadClass: 1, width: roadWidth,
                                      terrain: terrain,
                                      chunks: half * 2 + 1)
        }

        return SettlementPlan(center: SIMD2(s.x, s.z),
                              axis: gridAngle,
                              roads: roads,
                              plots: plots,
                              cell: cell,
                              radius: radius,
                              half: half)
    }
}
