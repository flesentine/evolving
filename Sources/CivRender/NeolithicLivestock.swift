import Foundation
import simd

enum NeolithicLivestock {
    enum Species: Int, CaseIterable {
        case sheep, cattle, pig

        var name: String {
            switch self {
            case .sheep: return "sheep"
            case .cattle: return "cattle"
            case .pig: return "pig"
            }
        }

        var speedMetres: Float {
            switch self {
            case .sheep: return 0.56
            case .cattle: return 0.66
            case .pig: return 0.48
            }
        }
    }

    struct Pose: Equatable {
        let species: Species
        /// Four gait frames, followed by a lowered-head feeding model.
        let frame: Int

        var isFeeding: Bool { frame == 4 }
        var index: Int { species.rawValue * 5 + frame }
        var path: String {
            "variants/neolithic-livestock-\(species.name)-" + (isFeeding ? "feed" : "walk-\(frame)")
        }
    }

    struct Placement {
        let pose: Pose
        let instance: InstanceData
    }

    static let poses = Species.allCases.flatMap { species in
        (0..<5).map { Pose(species: species, frame: $0) }
    }
    private static let footprints = Species.allCases.map { species -> [SIMD2<Float>] in
        let corners = poses.filter { $0.species == species }.flatMap { RiverPlacement.authoredBounds($0.path) }
        guard let first = corners.first else { return [] }
        let low = corners.reduce(first, simd_min)
        let high = corners.reduce(first, simd_max)
        return [low, SIMD2(high.x, low.y), high, SIMD2(low.x, high.y)]
    }
    private static let supportingHooves = poses.map { pose -> [SIMD3<Float>] in
        guard let mesh = try? CivMesh.load(named: pose.path + ".civmesh") else { return [] }
        var seen = Set<SIMD3<Float>>()
        // Authored positions are in metres. Only the sole vertices of
        // planted hooves contact the ground in a walking pose.
        return mesh.vertices.map(\.position).filter { $0.y <= 0.006 && seen.insert($0).inserted }
    }
    private static let metres = RiverGraph.metresPerUnit
    // NEO-09 keeps the legacy grazing ranges. This cycle drives the
    // pose and short stretches of motion around those ranges.
    static func gait(_ species: Species, at time: Float) -> (pose: Pose, distance: Float) {
        let cycle: Float = 15
        let walk: Float = 8
        let completed = floor(time / cycle)
        let partial = time - completed * cycle
        let frame = partial >= walk ? 4 : Int(partial * 4.8) % 4
        let distance = (completed * walk + min(walk, partial)) * species.speedMetres
        return (Pose(species: species, frame: frame), distance)
    }

    static func roadOrCrop(_ footprint: [SIMD2<Float>], in scene: WorldScene, roads: FieldSurface.Mask) -> Bool {
        roads.intersectsFootprint(footprint)
            || scene.activityStreets.intersectsFootprint(footprint)
            || scene.activityFields.intersectsFootprint(footprint)
    }

    static func hoovesSupported(_ pose: Pose, by model: simd_float4x4, in scene: WorldScene) -> Bool {
        let points = supportingHooves[pose.index]
        return points.count >= 2 && points.allSatisfy { point in
            let sole = model * SIMD4(point, 1)
            let ground = scene.renderedTerrainHeight(at: SIMD2(sole.x, sole.z))
            return abs(sole.y - ground) <= 0.10 / metres
        }
    }

    static func placements(in scene: WorldScene, settlements: [Settlement], seed: UInt64,
                           time: Float, reference: NeolithicReference.Stage? = nil) -> [Placement] {
        guard time.isFinite, time >= 0 else { return [] }
        let roads = scene.activityRoads
        let banks = scene.riverBankFootprint
        var result: [Placement] = []
        for settlement in settlements {
            let radius = max(CityBuilder.cityRadius(settlement.population) * 1.65 + 12 / metres, 28 / metres)
            let centre = SIMD2(settlement.x, settlement.z)
            let identity = UInt64(bitPattern: Int64(settlement.id))
            var rng = SplitMix64(seed: seed ^ (identity &* 0xDA94_2042_E4DD_58B5))
            let startingSpecies = Int(rng.next() % UInt64(Species.allCases.count))
            for slot in 0..<5 {
                let species = Species.allCases[(startingSpecies + slot) % Species.allCases.count]
                let range = radius * (0.8 + rng.nextFloat() * 0.5)
                let anchor = rng.nextFloat() * 2 * .pi
                let offset = rng.nextFloat() * 15
                let scale = (0.94 + rng.nextFloat() * 0.13) / metres
                let step = gait(species, at: time + offset)
                let initial = Self.gait(species, at: offset).distance
                let angle = anchor + (step.distance - initial) / (range * metres)
                let point = centre + SIMD2(cos(angle), sin(angle)) * range
                guard reference?.containsStagedYard(point) != true else { continue }
                let local = footprints[species.rawValue]
                guard local.count == 4 else { continue }
                let ground = scene.renderedTerrainHeight(at: point)
                guard ground > 4 / metres else { continue }

                let heading = -angle
                let horizontalRight = SIMD2(cos(heading), -sin(heading))
                let horizontalForward = SIMD2(sin(heading), cos(heading))
                func slope(along axis: SIMD2<Float>, distance: Float) -> Float {
                    let step = axis * distance
                    return (scene.renderedTerrainHeight(at: point + step)
                         - scene.renderedTerrainHeight(at: point - step)) / (2 * distance)
                }
                let crossSlope = slope(along: horizontalRight, distance: 0.35 / metres)
                let foreSlope = slope(along: horizontalForward, distance: 0.55 / metres)
                guard hypot(crossSlope, foreSlope) < 0.33 else { continue }
                let right = simd_normalize(SIMD3(horizontalRight.x, crossSlope, horizontalRight.y))
                let rawForward = SIMD3(horizontalForward.x, foreSlope, horizontalForward.y)
                let up = simd_normalize(simd_cross(rawForward, right))
                let forward = simd_cross(right, up)
                let model = simd_float4x4(columns: (SIMD4(right * scale, 0), SIMD4(up * scale, 0),
                    SIMD4(forward * scale, 0), SIMD4(point.x, ground, point.y, 1)))
                let footprint = RiverPlacement.transformed(local, by: model)
                guard footprint.allSatisfy({ !scene.terrain.isWater(x: $0.x, z: $0.y) }),
                      !scene.riverField.intersectsFootprint(footprint, margin: 0.40 / metres),
                      !banks.intersectsFootprint(footprint),
                      !roadOrCrop(footprint, in: scene, roads: roads),
                      hoovesSupported(step.pose, by: model, in: scene) else { continue }
                result.append(Placement(pose: step.pose, instance: InstanceData(model: model,
                    color: SIMD4(1, 1, 1, 0), material: SIMD4(9, 0, 0, 0))))
            }
        }
        return result
    }
}
