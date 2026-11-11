import Foundation
import simd

/// Bronze Age towns grow around a raised temple. Larger settlements are
/// walled and served by a canal; villages stay open and keep a small shrine.
/// Workshops cluster by the gate and fields follow the water outward.
enum BronzeLayout: SettlementLayout {

    static func plan(settlement s: Settlement,
                     resources: ResourceMap,
                     terrain: Terrain,
                     seed: UInt64,
                     style: CityBuilder.Style) -> SettlementPlan {
        let population = max(s.population, 1)
        let radius = CityBuilder.cityRadius(population)
        let count = CityBuilder.buildingCount(population)

        var rng = SplitMix64(seed: seed
                             ^ (UInt64(bitPattern: Int64(s.id)) &* 0x9E37_79B9_7F4A_7C15)
                             ^ 0xB20F_1E5A)

        let walled = population > 240
        let templePlot = Plot(center: SIMD2(s.x, s.z),
                              frontage: SIMD2(0, 1),
                              width: radius * 0.44,
                              depth: radius * 0.44,
                              district: .civic,
                              roadID: 0,
                              frontageRank: 0,
                              ring: 0,
                              cellIndex: .zero,
                              scaleMultiplier: walled ? 2.15 : 1.35,
                              podium: walled ? 0.0018 : 0.0007)

        // The processional axis points at the nearest water, so gate, canal
        // and temple line up.
        let canal = canalRoute(from: SIMD2(s.x, s.z), radius: radius,
                               terrain: terrain)
        let axis = atan2(canal.last!.y - s.z, canal.last!.x - s.x)
        let dir = SIMD2<Float>(cos(axis), sin(axis))
        let perp = SIMD2<Float>(-sin(axis), cos(axis))

        let cell = max(0.0095, radius * 0.13)
        let half = max(Int(ceil(radius / cell)), 3)
        let target = Int(Float(count) * 1.35)

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

        // Walled towns get a dedicated temple mesh on the central platform;
        // villages keep a small shrine building.
        var plots: [Plot] = walled ? [] : [templePlot]
        var landmarks: [Landmark] = []
        if walled {
            landmarks.append(Landmark(kind: .temple,
                                      center: SIMD2(s.x, s.z),
                                      facing: axis,
                                      scale: radius * 0.88))
        }
        plots.reserveCapacity(target + 8)

        for gi in (-half)...half {
            for gj in (-half)...half {
                if gi == 0 && gj == 0 { continue }
                let lx = Float(gi) * cell
                let lz = Float(gj) * cell
                if lx * lx + lz * lz > radius * radius { continue }
                let center = world(Float(gi), Float(gj))
                // Keep a forecourt around the temple clear.
                if simd_distance(center, SIMD2(s.x, s.z)) < radius * 0.24 { continue }
                guard buildable(center) else { continue }

                let ring = max(abs(gi), abs(gj))
                let towardGate = (Float(gi) * dir.x + Float(gj) * dir.y) > Float(half) * 0.35
                let district: District
                if abs(gi) + abs(gj) <= 1 {
                    district = .civic
                } else if ring == 1 && (gi + gj) % 3 == 0 {
                    district = .civic
                } else if ring >= half - 1 {
                    district = .agricultural
                } else if towardGate && abs(gi) + abs(gj) > 2 {
                    district = .industrial
                } else {
                    district = .residential
                }

                // Face the nearest street: grid rows front the processional
                // axis or the ring road around it.
                let facing = gj > 0 ? atan2(-perp.x, -perp.y)
                                    : atan2(perp.x, perp.y)

                plots.append(Plot(center: center,
                                  frontage: SIMD2(sin(facing), cos(facing)),
                                  width: cell * 0.94,
                                  depth: cell * 0.94,
                                  district: district,
                                  roadID: 1,
                                  frontageRank: ring <= 1 ? 0 : 1,
                                  ring: ring,
                                  cellIndex: SIMD2(gi, gj),
                                  axis: axis))
            }
        }

        // Temple first, then the inner rings.
        plots.sort {
            if $0.ring != $1.ring { return $0.ring < $1.ring }
            return abs($0.cellIndex.x) + abs($0.cellIndex.y)
                < abs($1.cellIndex.x) + abs($1.cellIndex.y)
        }
        if plots.count > target {
            plots.removeSubrange(target..<plots.count)
        }

        // Radial streets from the temple to the wall, plus one ring road.
        var roads: [RoadSegment] = []
        roads += RoadPlanning.run(from: SIMD2(s.x, s.z),
                                  to: world(Float(half) * 1.02, 0),
                                  roadClass: 0, width: cell * 0.52,
                                  terrain: terrain, chunks: 4)
        for k in 1..<4 {
            let a = axis + Float(k) / 4 * 2 * Float.pi
            let end = SIMD2(s.x + cos(a) * radius * 1.02,
                            s.z + sin(a) * radius * 1.02)
            roads += RoadPlanning.run(from: SIMD2(s.x, s.z), to: end,
                                      roadClass: 2, width: cell * 0.24,
                                      terrain: terrain, chunks: 3)
        }
        let ringRadius = radius * 0.72
        for k in 0..<16 {
            let a0 = Float(k) / 16 * 2 * Float.pi
            let a1 = Float(k + 1) / 16 * 2 * Float.pi
            roads += RoadPlanning.run(
                from: SIMD2(s.x + cos(a0) * ringRadius, s.z + sin(a0) * ringRadius),
                to: SIMD2(s.x + cos(a1) * ringRadius, s.z + sin(a1) * ringRadius),
                roadClass: 2, width: cell * 0.22,
                terrain: terrain, chunks: 1)
        }

        var wall: [SIMD2<Float>]?
        var water: [SIMD2<Float>]?
        if walled {
            let wallRadius = radius * 1.04
            wall = (0..<20).map { k in
                let a = Float(k) / 20 * 2 * Float.pi
                return SIMD2(s.x + cos(a) * wallRadius, s.z + sin(a) * wallRadius)
            }
            water = canal
        }

        _ = rng
        return SettlementPlan(center: SIMD2(s.x, s.z),
                              axis: axis,
                              roads: roads,
                              plots: plots,
                              cell: cell,
                              radius: radius,
                              half: half,
                              wall: wall,
                              water: water,
                              landmarks: landmarks,
                              gates: [axis, axis + .pi / 2, axis + .pi, axis + 3 * .pi / 2])
    }

    /// Nearest water direction, walked outward from the town centre.
    private static func canalRoute(from centre: SIMD2<Float>,
                                   radius: Float,
                                   terrain: Terrain) -> [SIMD2<Float>] {
        var best = SIMD2<Float>(centre.x + radius * 2, centre.y)
        var bestDistance = Float.greatestFiniteMagnitude

        for k in 0..<24 {
            let a = Float(k) / 24 * 2 * Float.pi
            for step in 1...6 {
                let d = radius * (1.2 + Float(step) * 0.40)
                let p = SIMD2(centre.x + cos(a) * d, centre.y + sin(a) * d)
                if terrain.heightAt(x: p.x, z: p.y) <= 0 || terrain.riverAt(x: p.x, z: p.y) > 0 {
                    if d < bestDistance {
                        bestDistance = d
                        best = p
                    }
                    break
                }
                let water = terrain.waterDistanceAt(x: p.x, z: p.y)
                if water < bestDistance {
                    bestDistance = water
                    best = p
                }
            }
        }

        let heading = atan2(best.y - centre.y, best.x - centre.x)
        let start = SIMD2(centre.x + cos(heading) * radius * 1.04,
                          centre.y + sin(heading) * radius * 1.04)
        var route: [SIMD2<Float>] = []
        let steps = 6
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            var p = start + (best - start) * t
            if i > 0 && i < steps {
                let g = terrain.gradientAt(x: p.x, z: p.y)
                let gl = simd_length(g)
                if gl > 0.001 {
                    p -= g / gl * min(radius * 0.10, gl * 0.02)
                }
            }
            route.append(p)
        }
        return route
    }
}
