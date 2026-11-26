import simd

/// A single late-Neolithic earthwork at the edge of a lived-in landscape.
enum NeolithicBarrow {
    static let path = "variants/neolithic-long-barrow"
    static let years: Range<Float> = 600..<800
    private static let metres = RiverGraph.metresPerUnit

    struct Placement {
        let instance: InstanceData
        let settlement: Settlement
        let footprint: [SIMD2<Float>]
        let shoulderDrops: SIMD2<Float> // metres
    }

    // The survey rectangle includes the entire authored mound and forecourt,
    // with room for the horizontal displacement of the tilted slab tops.
    private static let survey: [SIMD2<Float>] = [
        SIMD2(-6.2, -16.25), SIMD2(6.2, -16.25), SIMD2(6.2, 14.5), SIMD2(-6.2, 14.5)
    ]
    private static let footing = RiverPlacement.authoredVertices(path)
        .map(\.position).filter { $0.y <= -0.58 }

    static func place(year: Float, in scene: WorldScene, settlements: [Settlement],
                      clearance: NeolithicHerds.Clearance, herds: [NeolithicHerds.Herd]) -> Placement? {
        guard years.contains(year), !footing.isEmpty else { return nil }
        let towns = settlements.filter(\.isAlive).sorted { $0.id < $1.id }
        var pasture = FieldSurface.Mask()
        for herd in herds { pasture.insertFootprint(herd.route.envelope) }
        for town in towns {
            let anchor = SIMD2(town.x, town.z)
            for distance in stride(from: Float(72), through: 216, by: 12) {
                for step in 0..<48 {
                    let angle = (2 * Float.pi / 48) * Float(step)
                    let outward = SIMD2(cos(angle), sin(angle))
                    let point = anchor + outward * (distance / metres)
                    // Consider each point only for its nearest hamlet. Stable
                    // ID order also resolves equidistant settlements.
                    guard towns.min(by: {
                        simd_distance_squared(point, SIMD2($0.x, $0.z)) <
                        simd_distance_squared(point, SIMD2($1.x, $1.z))
                    })?.id == town.id else { continue }
                    let height = scene.renderedTerrainHeight(at: point)
                    guard height >= 9 / metres else { continue }
                    for heading in 0..<16 {
                        let angle = Float(heading) * (.pi / 16)
                        var forward = SIMD2(sin(angle), cos(angle))
                        if simd_dot(forward, outward) > 0 { forward = -forward }
                        if let placed = site(point, height: height, forward: forward, town: town, towns: towns,
                                             scene: scene, clearance: clearance, pasture: pasture) { return placed }
                    }
                }
            }
        }
        return nil
    }

    private static func site(_ point: SIMD2<Float>, height: Float, forward: SIMD2<Float>,
                             town: Settlement, towns: [Settlement], scene: WorldScene,
                             clearance: NeolithicHerds.Clearance, pasture: FieldSurface.Mask) -> Placement? {
        let right = SIMD2(forward.y, -forward.x)
        func ground(_ x: Float, _ z: Float) -> Float {
            scene.renderedTerrainHeight(at: point + (right * x + forward * z) / metres)
        }

        // Both shoulders must fall away. This rejects level ground and
        // ordinary hillsides even when they could support the foundation.
        let drops = SIMD2(height - ground(-18, 0), height - ground(18, 0)) * metres
        guard drops.x >= 0.7, drops.y >= 0.7, drops.x + drops.y >= 2 else { return nil }
        let sideGrade = (ground(4, 0) - ground(-4, 0)) * metres / 8
        let longGrade = (ground(0, 10) - ground(0, -10)) * metres / 20
        guard abs(sideGrade) <= 0.15, abs(longGrade) <= 0.17 else { return nil }

        let area = survey.map { point + (right * $0.x + forward * $0.y) / metres }
        guard towns.allSatisfy({ other in
            let setback = max(40 / metres, CityBuilder.cityRadius(other.population) + 12 / metres)
            return simd_distance(point, SIMD2(other.x, other.z)) >= setback + 18 / metres
        }), !scene.riverField.intersectsFootprint(area, margin: 2 / metres),
            clearance.allows(area, in: scene), !pasture.intersectsFootprint(area) else { return nil }

        let xAxis = simd_normalize(SIMD3(right.x, sideGrade, right.y))
        let yAxis = simd_normalize(simd_cross(SIMD3(forward.x, longGrade, forward.y), xAxis))
        let zAxis = simd_cross(xAxis, yAxis)
        let model = simd_float4x4(SIMD4(xAxis / metres, 0), SIMD4(yAxis / metres, 0),
                                  SIMD4(zAxis / metres, 0), SIMD4(point.x, height, point.y, 1))
        func groundRelativeTo(_ p: SIMD3<Float>) -> Float {
            let world = model * SIMD4(p, 1)
            return (scene.renderedTerrainHeight(at: SIMD2(world.x, world.z)) - world.y) * metres
        }
        // Limit both burial and exposure on the actual submitted terrain.
        for x: Float in [-5, -2.5, 0, 2.5, 5] {
            for z: Float in [-15, -12, -9, -6, -3, 0, 3, 6, 9, 12, 14] {
                let offset = groundRelativeTo(SIMD3(x, 0, z))
                guard abs(offset) <= 0.54 else { return nil }
            }
        }
        guard abs(groundRelativeTo(SIMD3(0, 0, 11.3))) <= 0.25,
              footing.allSatisfy({ groundRelativeTo($0) >= 0.025 }) else { return nil }

        let tint = scene.renderedTerrainTint(at: point)
        // Slot 22 uses terrain shading for the turf atlas tile and keeps the
        // slab entrance on the regular building material.
        let instance = InstanceData(model: model, color: SIMD4(tint.x, tint.y, tint.z, 0),
                                    material: SIMD4(22, 0, 0, 0))
        return Placement(instance: instance, settlement: town, footprint: area, shoulderDrops: drops)
    }
}
