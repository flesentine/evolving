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
    /// Bounding radius in authored metres includes height because a sloped
    /// pose projects some of the model's height into its horizontal footprint.
    static let sweptRadii = Species.allCases.map { species in
        poses.filter { $0.species == species }.compactMap { pose -> Float? in
            guard let asset = try? CivMesh.load(named: pose.path + ".civmesh") else { return nil }
            return asset.vertices.map { simd_length($0.position) }.max()
        }.max() ?? 0
    }

    private static let supportingHooves = poses.map { pose -> [SIMD3<Float>] in
        guard let mesh = try? CivMesh.load(named: pose.path + ".civmesh") else { return [] }
        var seen = Set<SIMD3<Float>>()
        // Authored positions are in metres. Only the sole vertices of
        // planted hooves contact the ground in a walking pose.
        return mesh.vertices.map(\.position).filter { $0.y <= 0.006 && seen.insert($0).inserted }
    }
    private static let metres = RiverGraph.metresPerUnit
    // The cycle integrates walking speed and holds distance during feeding.
    static func gait(_ species: Species, at time: Float) -> (pose: Pose, distance: Float) {
        let cycle: Float = 15
        let walk: Float = 8
        let completed = floor(time / cycle)
        let partial = time.truncatingRemainder(dividingBy: cycle)
        let frame = partial >= walk ? 4 : Int(partial * 4.8) % 4
        let distance = (completed * walk + min(walk, partial)) * species.speedMetres
        return (Pose(species: species, frame: frame), distance)
    }

    static func hoovesSupported(_ pose: Pose, by model: simd_float4x4, in scene: WorldScene) -> Bool {
        let points = supportingHooves[pose.index]
        return points.count >= 2 && points.allSatisfy { point in
            let sole = model * SIMD4(point, 1)
            let ground = scene.renderedTerrainHeight(at: SIMD2(sole.x, sole.z))
            return abs(sole.y - ground) <= 0.10 / metres
        }
    }

    static func model(at point: SIMD2<Float>, heading: Float, scale: Float,
                      in scene: WorldScene) -> simd_float4x4 {
        let horizontalRight = SIMD2(cos(heading), -sin(heading))
        let horizontalForward = SIMD2(sin(heading), cos(heading))
        func slope(along axis: SIMD2<Float>, distance: Float) -> Float {
            let step = axis * distance
            return (scene.renderedTerrainHeight(at: point + step)
                 - scene.renderedTerrainHeight(at: point - step)) / (2 * distance)
        }
        let crossSlope = slope(along: horizontalRight, distance: 0.35 / metres)
        let foreSlope = slope(along: horizontalForward, distance: 0.55 / metres)
        let right = simd_normalize(SIMD3(horizontalRight.x, crossSlope, horizontalRight.y))
        let rawForward = SIMD3(horizontalForward.x, foreSlope, horizontalForward.y)
        let up = simd_normalize(simd_cross(rawForward, right))
        let forward = simd_cross(right, up)
        let ground = scene.renderedTerrainHeight(at: point)
        return simd_float4x4(columns: (SIMD4(right * scale, 0), SIMD4(up * scale, 0),
            SIMD4(forward * scale, 0), SIMD4(point.x, ground, point.y, 1)))
    }
}
