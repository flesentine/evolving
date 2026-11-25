import Foundation
import simd

/// One opt-in art review vignette. The shipping Neolithic catalog is unchanged
/// while the reference house, figure and livestock proportions are evaluated.
enum NeolithicReference {
    static let seed: UInt64 = 1
    static let year: Float = 450
    static let house = "variants/neo01-house"
    static let worker = "variants/neo01-worker"
    static let livestock = "variants/neo01-livestock"
    static let paths = [house, worker, livestock]
    private static let metres = RiverGraph.metresPerUnit

    static func apply(_ view: RiverReviewView, to renderer: Renderer) {
        renderer.restoreTimelineCamera(Renderer.Camera(
            eye: SIMD3(view.eye[0], view.eye[1], view.eye[2]),
            target: SIMD3(view.target[0], view.target[1], view.target[2]), fov: view.fov))
        renderer.hourOverride = view.hour
        renderer.seasonOverride = view.season
        renderer.weatherOverride = view.precipitation
        renderer.snowOverride = view.snow
        renderer.referenceAnimationTime = view.animationTime
    }

    struct Stage {
        let centre: SIMD3<Float>
        let forward: SIMD2<Float>
        let islandCentre: SIMD2<Float>

        func containsStagedYard(_ point: SIMD2<Float>) -> Bool {
            simd_distance(point, SIMD2(centre.x, centre.z)) < 20 / NeolithicReference.metres
        }

        func views(width: Int = 1440, height: Int = 900) -> [(String, RiverReviewView)] {
            let side = SIMD2(forward.y, -forward.x)
            func offset(_ across: Float, _ up: Float, _ front: Float) -> SIMD3<Float> {
                let position = side * across + forward * front
                return SIMD3(position.x, up, position.y) / NeolithicReference.metres
            }
            func view(eye: SIMD3<Float>, target: SIMD3<Float>, fov: Float) -> RiverReviewView {
                RiverReviewView(seed: NeolithicReference.seed, year: NeolithicReference.year, hour: 15,
                    season: 0.68, precipitation: 0, snow: false, animationTime: 24,
                    eye: [eye.x, eye.y, eye.z], target: [target.x, target.y, target.z],
                    fov: fov, width: width, height: height, provenance: "NEO-01 fixed review camera")
            }
            return [
                ("hamlet", view(eye: centre + offset(16, 10, 24),
                                target: centre + offset(0, 1.6, 2.1), fov: 37)),
                ("overhead", view(eye: centre + offset(0, 44, 3),
                                  target: centre + offset(0, 0, 2), fov: 48)),
                ("island", view(eye: SIMD3(0.78, 0.76, 1.16),
                                target: SIMD3(islandCentre.x, 0.07, islandCentre.y), fov: 56))
            ]
        }
    }

    static func stage(_ geometry: inout CityBuilder.Geometry, scene: WorldScene,
                      settlement: Settlement) -> Stage? {
        let centre = SIMD2(settlement.x, settlement.z)
        let houses = geometry.buildings.keys.sorted().flatMap { path in
            let bounds = RiverPlacement.authoredBounds(path)
            return geometry.buildings[path, default: []].map {
                RiverPlacement.transformed(bounds, by: $0.model)
            }
        }
        let boundsByAsset = Dictionary(uniqueKeysWithValues: paths.map { ($0, RiverPlacement.authoredBounds($0)) })
        guard boundsByAsset.values.allSatisfy({ $0.count == 4 }) else {
            NSLog("Evolving: NEO-01 review meshes are missing")
            return nil
        }
        let anchors = [Float(12), 18, 25, 33, 42, 54, 68].flatMap { radius in
            (0..<24).map { index -> SIMD2<Float> in
                let angle = Float(index) * 2 * .pi / 24
                return centre + SIMD2(cos(angle), sin(angle)) * (radius / metres)
            }
        }
        func overlaps(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>]) -> Bool {
            guard a.count == 4, b.count == 4 else { return false }
            for rectangle in [a, b] {
                for index in [1, 3] {
                    let axis = rectangle[index] - rectangle[0]
                    let projectedA = a.map { simd_dot($0, axis) }
                    let projectedB = b.map { simd_dot($0, axis) }
                    if projectedA.max()! < projectedB.min()! || projectedB.max()! < projectedA.min()! {
                        return false
                    }
                }
            }
            return true
        }
        var reliefRejected = 0, waterRejected = 0, collisionRejected = 0

        for base in anchors {
            let forward = simd_normalize(centre - base)
            let side = SIMD2(forward.y, -forward.x)
            let facing = atan2(forward.x, forward.y)
            let placements: [(String, SIMD2<Float>, Float, Float)] = [
                (house, base, facing, 1.10 / metres),
                (worker, base + (forward * 4.35 - side * 0.95) / metres, facing + 0.38, 0.26 / metres),
                (livestock, base + (forward * 5.0 + side * 2.25) / metres, facing - 0.95, 0.26 / metres)
            ]
            var fitted: [(String, InstanceData, [SIMD2<Float>])] = []
            for (asset, p, heading, allowedRelief) in placements {
                let transform = translation(SIMD3(p.x, scene.renderedTerrainHeight(at: p), p.y))
                    * rotationY(heading) * scaleMatrix(SIMD3(repeating: 1 / metres))
                let footprint = RiverPlacement.transformed(boundsByAsset[asset]!, by: transform)
                let heights = ([p] + footprint).map { scene.renderedTerrainHeight(at: $0) }
                let lowest = heights.min()!, highest = heights.max()!
                guard highest - lowest <= allowedRelief else { reliefRejected += 1; break }
                guard footprint.allSatisfy({ !scene.terrain.isWater(x: $0.x, z: $0.y) }),
                      !scene.riverField.intersectsFootprint(footprint, margin: 8 / metres) else {
                    waterRejected += 1
                    break
                }
                guard !houses.contains(where: { overlaps(footprint, $0) }),
                      !fitted.contains(where: { overlaps(footprint, $0.2) }) else {
                    collisionRejected += 1
                    break
                }
                var grounded = transform
                grounded.columns.3.y = asset == house ? highest : (lowest + highest) * 0.5
                fitted.append((asset, InstanceData(model: grounded, color: SIMD4(1, 1, 1, 0),
                                                  material: SIMD4(9, 0, 0, 0)), footprint))
            }
            guard fitted.count == placements.count else { continue }
            for (asset, instance, _) in fitted {
                geometry.buildings[asset] = [instance]
            }
            let y = scene.renderedTerrainHeight(at: base)
            return Stage(centre: SIMD3(base.x, y, base.y), forward: forward, islandCentre: centre * 0.14)
        }
        NSLog("Evolving: NEO-01 found no clear yard (relief %d, water %d, overlap %d)",
              reliefRejected, waterRejected, collisionRejected)
        return nil
    }
}
