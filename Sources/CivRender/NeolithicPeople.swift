import Foundation
import simd

/// Yard routines use metric Blender parts and absolute animation time.
enum NeolithicPeople {
    static let metres = RiverGraph.metresPerUnit

    enum Part: Int, CaseIterable {
        case oat, brown, head, sleeve, forearm, legging, shoe, handstone, quernBed, hearth, poker, basket
        var path: String {
            let names = ["tunic-oat", "tunic-brown", "head", "sleeve", "forearm", "legging",
                         "shoe", "handstone", "quern-bed", "hearth", "poker"]
            return self == .basket ? NeolithicProps.paths[1] : "variants/neolithic-person-" + names[rawValue]
        }
    }

    enum Kind: String, CaseIterable { case grinding, carrying, tending }

    struct Routine {
        let kind: Kind
        let start: SIMD2<Float>
        let end: SIMD2<Float>
        let fixture: simd_float4x4?
        let phase: Float
        let brown: Bool
        let clearance: [SIMD2<Float>]

        func motion(at time: Float) -> (point: SIMD2<Float>, heading: Float, stride: Float) {
            let axis = end - start
            let direction = atan2(axis.x, axis.y)
            guard kind == .carrying else { return (start, direction, 0) }
            let clock = time / 8 + phase
            let beat = clock - floor(clock)
            let outward = smoothstep(0, 0.40, beat)
            let returning = smoothstep(0.50, 0.90, beat)
            let travel = outward - returning
            let turn = smoothstep(0.40, 0.50, beat) + smoothstep(0.90, 1, beat)
            let moving = smoothstep(0, 0.07, beat) - smoothstep(0.33, 0.40, beat)
                + smoothstep(0.50, 0.57, beat) - smoothstep(0.83, 0.90, beat)
            let step = sin(time * 8.1 + phase * 6.283185) * moving
            return (start + axis * travel, direction + .pi * turn, step)
        }
    }

    struct Layout {
        var routines: [Routine] = []
        var workedQuerns = Set<Int>()
    }

    private static func pad(_ start: SIMD2<Float>, _ end: SIMD2<Float>,
                            width: Float, extensionMetres: Float) -> [SIMD2<Float>] {
        let axis = simd_normalize(end - start)
        let across = SIMD2(-axis.y, axis.x) * (width * 0.5 / metres)
        let extensionVector = axis * (extensionMetres / metres)
        return [start - extensionVector - across, end + extensionVector - across,
                end + extensionVector + across, start - extensionVector + across]
    }

    static func plan(in scene: WorldScene, geometry: CityBuilder.Geometry,
                     props: [String: [InstanceData]], settlements: [Settlement],
                     seed: UInt64, reference: NeolithicReference.Stage?) -> Layout {
        var solids = FieldSurface.Mask()
        for path in geometry.buildings.keys.sorted() {
            let bounds = RiverPlacement.authoredBounds(path)
            for instance in geometry.buildings[path, default: []] {
                solids.insertFootprint(RiverPlacement.transformed(bounds, by: instance.model))
            }
        }
        for path in NeolithicProps.paths {
            let bounds = RiverPlacement.authoredBounds(path)
            for instance in props[path, default: []] {
                solids.insertFootprint(RiverPlacement.transformed(bounds, by: instance.model))
            }
        }
        let cube = RiverPlacement.bounds(Geometry.cube())
        for box in geometry.boxes {
            solids.insertFootprint(RiverPlacement.transformed(cube, by: box.model))
        }

        let roads = scene.activityRoads
        let banks = scene.riverBankFootprint
        let fields = FieldSurface.Mask(mesh: scene.fieldMesh)
        let querns = props[NeolithicProps.paths[0], default: []]
        var layout = Layout()
        var occupied = FieldSurface.Mask()
        var staffed = Set<Int32>()

        func safe(_ area: [SIMD2<Float>]) -> Bool {
            let centre = area.reduce(SIMD2<Float>.zero, +) / Float(area.count)
            let probes = area + [centre]
            let heights = probes.map { scene.renderedTerrainHeight(at: $0) }
            guard let low = heights.min(), let high = heights.max(),
                  low > 0.35 / metres, high - low < 0.28 / metres,
                  probes.allSatisfy({ reference?.containsStagedYard($0) != true
                      && !scene.terrain.isWater(x: $0.x, z: $0.y) }) else { return false }
            return !scene.riverField.intersectsFootprint(area, margin: 0.3 / metres)
                && !banks.intersectsFootprint(area) && !roads.intersectsFootprint(area)
                && !fields.intersectsFootprint(area) && !solids.intersectsFootprint(area)
                && !occupied.intersectsFootprint(area)
        }

        func add(_ kind: Kind, start: SIMD2<Float>, end: SIMD2<Float>,
                 fixture: simd_float4x4? = nil, area: [SIMD2<Float>], rng: inout SplitMix64) {
            layout.routines.append(Routine(kind: kind, start: start, end: end, fixture: fixture,
                phase: rng.nextFloat(), brown: rng.nextFloat() > 0.52, clearance: area))
            occupied.insertFootprint(area)
        }

        for yard in scene.neolithicYards.yards {
            guard let entrance = yard.connections.first?.entrance else { continue }
            let identity = UInt64(bitPattern: Int64(entrance.settlement)) &* 0xDB4F_0B91_75AE_2165
            var rng = SplitMix64(seed: seed ^ identity ^ UInt64(entrance.cluster))
            let forward = entrance.forward
            let side = SIMD2(forward.y, -forward.x)
            let axes = [forward, side, -forward, -side]

            if let index = querns.indices.filter({ !layout.workedQuerns.contains($0) })
                .min(by: { simd_distance_squared(xz(querns[$0].model.columns.3), yard.centre)
                    < simd_distance_squared(xz(querns[$1].model.columns.3), yard.centre) }) {
                let tool = querns[index].model
                let centre = xz(tool.columns.3)
                if simd_distance(centre, yard.centre) <= 4.4 / metres {
                    for axis in axes {
                        let feet = centre - axis * (0.68 / metres)
                        let area = pad(feet - axis * (0.14 / metres), feet + axis * (0.08 / metres),
                                       width: 0.57, extensionMetres: 0.20)
                        let ground = scene.renderedTerrainHeight(at: feet)
                        guard safe(area), abs(ground - tool.columns.3.y) < 0.10 / metres else { continue }
                        add(.grinding, start: feet, end: centre, fixture: tool, area: area, rng: &rng)
                        layout.workedQuerns.insert(index)
                        staffed.insert(entrance.settlement)
                        break
                    }
                }
            }

            for axis in [forward, side] {
                let across = SIMD2(axis.y, -axis.x)
                let mid = yard.centre - across * (0.37 / metres)
                let start = mid - axis * (1.05 / metres)
                let end = mid + axis * (1.05 / metres)
                let area = pad(start, end, width: 0.86, extensionMetres: 0.38)
                guard safe(area), supportsRoute(start, end, in: scene, onYard: true) else { continue }
                add(.carrying, start: start, end: end, area: area, rng: &rng)
                staffed.insert(entrance.settlement)
                break
            }

            for axis in axes {
                let centre = yard.centre + axis * (3.8 / metres)
                let feet = centre - axis * (0.81 / metres)
                let area = pad(feet - axis * (0.13 / metres), centre + axis * (0.16 / metres),
                               width: 1.02, extensionMetres: 0.30)
                guard safe(area), !scene.activityStreets.intersectsFootprint(area) else { continue }
                let ground = scene.renderedTerrainHeight(at: centre)
                let fixture = translation(SIMD3(centre.x, ground, centre.y)) * scaleMatrix(SIMD3(repeating: 1 / metres))
                add(.tending, start: feet, end: centre, fixture: fixture, area: area, rng: &rng)
                staffed.insert(entrance.settlement)
                break
            }
        }

        // Young camps have no shared yard yet. Look for one short dry route
        // around the buildings so the clothing and basket also appear there.
        for settlement in settlements where !staffed.contains(settlement.id) {
            var rng = SplitMix64(seed: seed ^ UInt64(bitPattern: Int64(settlement.id)))
            let turn = rng.nextFloat() * 2 * .pi
            let centre = SIMD2(settlement.x, settlement.z)
            let radiusMetres = max(4, CityBuilder.cityRadius(settlement.population) * metres * 0.55)
            for attempt in 0..<16 {
                let angle = turn + Float(attempt) * .pi / 4
                let radial = SIMD2(cos(angle), sin(angle))
                let side = SIMD2(-radial.y, radial.x)
                let radius = radiusMetres + Float(attempt / 8) * 3
                let mid = centre + radial * (radius / metres)
                let start = mid - side * (1.05 / metres)
                let end = mid + side * (1.05 / metres)
                let area = pad(start, end, width: 0.86, extensionMetres: 0.38)
                guard safe(area), supportsRoute(start, end, in: scene, onYard: false) else { continue }
                add(.carrying, start: start, end: end, area: area, rng: &rng)
                break
            }
        }
        return layout
    }

    private static func supportsRoute(_ start: SIMD2<Float>, _ end: SIMD2<Float>,
                                      in scene: WorldScene, onYard: Bool) -> Bool {
        (0...12).allSatisfy { step in
            let point = start + (end - start) * (Float(step) / 12)
            return (!onYard || scene.activityStreets.covers(point))
                && scene.terrain.slopeAt(x: point.x, z: point.y) < 0.34
        }
    }

    static func xyz(_ p: SIMD4<Float>) -> SIMD3<Float> { SIMD3(p.x, p.y, p.z) }

    static func xz(_ p: SIMD4<Float>) -> SIMD2<Float> { SIMD2(p.x, p.z) }

    static func segment(_ from: SIMD3<Float>, _ to: SIMD3<Float>, side: SIMD3<Float>,
                                length: Float = 1) -> simd_float4x4 {
        let delta = from - to
        let up = simd_normalize(delta)
        let cross = simd_cross(side, up)
        let alternate = abs(up.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let forward = simd_normalize(simd_length_squared(cross) > 1e-6 ? cross : simd_cross(alternate, up))
        let right = simd_cross(up, forward)
        return simd_float4x4(columns: (SIMD4(right / metres, 0), SIMD4(delta / length, 0),
                                     SIMD4(forward / metres, 0), SIMD4(from, 1)))
    }

    static func joint(from start: SIMD3<Float>, to end: SIMD3<Float>,
                              upper: Float, lower: Float, bend: SIMD3<Float>) -> SIMD3<Float> {
        let line = end - start
        let axis = simd_normalize(line)
        let flat = bend - axis * simd_dot(bend, axis)
        let alternate = abs(axis.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let depth = simd_normalize(simd_length_squared(flat) > 1e-6 ? flat : simd_cross(alternate, axis))
        let distance = min(max(simd_length(line) * metres, 0.03), upper + lower - 0.001)
        let along = (distance * distance + upper * upper - lower * lower) / (2 * distance)
        let offset = sqrt(max(0, upper * upper - along * along))
        return start + (axis * along + depth * offset) / metres
    }

    static func sample(_ routine: Routine, time: Float, scene: WorldScene,
                       append: (Part, simd_float4x4) -> Void) {
        let motion = routine.motion(at: time)
        let p = motion.point
        let angle = motion.heading
        let right = SIMD3<Float>(cos(angle), 0, -sin(angle))
        let forward = SIMD3<Float>(sin(angle), 0, cos(angle))
        let standing = routine.kind == .carrying
        func ground(_ p: SIMD2<Float>) -> Float {
            max(scene.renderedTerrainHeight(at: p), scene.activityStreets.height(at: p) ?? 0)
        }

        let beat = 2 * Float.pi * (time / (routine.kind == .tending ? 3.8 : 1.85) + routine.phase)
        let lean: Float
        let height: Float
        let hipDepth: Float
        switch routine.kind {
        case .carrying:
            lean = 0.045
            height = 0.83 + abs(motion.stride) * 0.018
            hipDepth = 0
        case .grinding:
            lean = 0.95 + sin(beat) * 0.13
            height = 0.39
            hipDepth = -0.025
        case .tending:
            lean = 0.35 + sin(beat) * 0.075
            height = 0.43
            hipDepth = -0.095
        }
        let root = SIMD3(p.x, ground(p), p.y)
        let poseBasis = translation(root) * rotationY(angle) * scaleMatrix(SIMD3(repeating: 1 / metres))
        let torso = poseBasis * translation(SIMD3(0, height, hipDepth)) * rotationX(lean)
        append(routine.brown ? .brown : .oat, torso)
        append(.head, torso * translation(SIMD3(0, 0.468, 0.014)) * rotationX(standing ? 0.05 : 0.23))

        var counter: SIMD3<Float> = .zero
        var activeHand: SIMD3<Float> = .zero
        if let fixture = routine.fixture {
            switch routine.kind {
            case .grinding:
                let sweep: Float = -0.018 + sin(beat) * 0.105
                let load = fixture * translation(SIMD3(0, 0.122, sweep))
                append(.handstone, load)
                counter = xyz(load * SIMD4<Float>(0, 0.067, 0, 1))
            case .tending:
                append(.hearth, fixture)
                counter = xyz(fixture * SIMD4<Float>(sin(beat) * 0.095, 0.08, cos(beat) * 0.095, 1))
                activeHand = xyz(poseBasis * SIMD4<Float>(0.16, 0.60 + cos(beat) * 0.055, 0.36, 1))
                append(.poker, segment(activeHand, counter, side: right, length: 0.70))
            case .carrying: break
            }
        } else {
            let sway = motion.stride * 0.028
            let load = poseBasis * translation(SIMD3(sway, 0.85, 0.32))
            append(.basket, load)
            counter = xyz(load * SIMD4<Float>(0, 0.184, 0, 1))
        }

        for sign in [Float(-1), 1] {
            let hip = xyz(torso * SIMD4<Float>(sign * 0.103, -0.018, 0, 1))
            let step = sign * motion.stride
            let along: Float = standing ? step * 0.27 : -0.31
            let flat = root + (right * (sign * 0.12) + forward * along) / metres
            let lift: Float = standing ? max(0, step) * 0.115 : 0
            let foot = SIMD3(flat.x, ground(SIMD2(flat.x, flat.z)) + lift / metres, flat.z)
            let ankle = foot + SIMD3(0, 0.084 / metres, 0)
            let knee: SIMD3<Float>
            if standing {
                knee = joint(from: hip, to: ankle, upper: 0.393, lower: 0.388, bend: forward)
            } else {
                let kneeFlat = root + (right * (sign * 0.12) + forward * 0.21) / metres
                knee = SIMD3(kneeFlat.x, ground(SIMD2(kneeFlat.x, kneeFlat.z)) + 0.081 / metres, kneeFlat.z)
            }
            append(.legging, segment(hip, knee, side: right))
            append(.legging, segment(knee, ankle, side: right))
            append(.shoe, translation(foot) * rotationY(angle) * scaleMatrix(SIMD3(repeating: 1 / metres)))

            let shoulder = xyz(torso * SIMD4<Float>(sign * 0.205, 0.418, 0.016, 1))
            let hand: SIMD3<Float>
            switch routine.kind {
            case .grinding: hand = counter + right * (sign * 0.061 / metres)
            case .carrying: hand = counter + right * (sign * 0.176 / metres)
            case .tending: hand = sign > 0 ? activeHand : knee + SIMD3(0, 0.108 / metres, 0)
            }
            let bend = right * sign * 0.70 + SIMD3<Float>(0, -0.75, 0)
            let elbow = joint(from: shoulder, to: hand, upper: 0.326, lower: 0.29, bend: bend)
            append(.sleeve, segment(shoulder, elbow, side: forward))
            append(.forearm, segment(elbow, hand, side: forward))
        }
    }
}
