import simd

/// Metric character parts and deterministic work around the submitted workshops.
enum BronzePeople {
    static let metres = RiverGraph.metresPerUnit

    enum Part: Int, CaseIterable {
        case flax, umber, head, sleeve, forearm, legging, shoe, shuttle, basket

        var path: String {
            switch self {
            case .head: return NeolithicPeople.Part.head.path
            case .forearm: return NeolithicPeople.Part.forearm.path
            case .shoe: return NeolithicPeople.Part.shoe.path
            case .basket: return BronzeCraft.basket.path
            case .flax: return "variants/bronze-person-tunic-flax"
            case .umber: return "variants/bronze-person-tunic-umber"
            case .sleeve: return "variants/bronze-person-sleeve"
            case .legging: return "variants/bronze-person-legging"
            case .shuttle: return "variants/bronze-person-shuttle"
            }
        }
    }

    enum Kind: String, CaseIterable {
        case weaving, shaping, carrying

        var period: Float {
            switch self {
            case .weaving: return 2.8
            case .shaping: return 3.6
            case .carrying: return 9
            }
        }
    }

    struct Routine {
        let kind: Kind
        let start: SIMD2<Float>
        let end: SIMD2<Float>
        let fixture: simd_float4x4?
        let phase: Float
        let umber: Bool
        let clearance: [SIMD2<Float>]

        func fraction(at time: Float) -> Float {
            let clock = time / kind.period + phase
            return clock - floor(clock)
        }

        func motion(at time: Float) -> (point: SIMD2<Float>, heading: Float, stride: Float) {
            let delta = end - start
            let heading = atan2(delta.x, delta.y)
            guard kind == .carrying else { return (start, heading, 0) }
            let phase = fraction(at: time)
            let travel = smoothstep(0.02, 0.42, phase) - smoothstep(0.53, 0.92, phase)
            let turn = smoothstep(0.42, 0.53, phase) + smoothstep(0.92, 1.0, phase)
            let walking = smoothstep(0.02, 0.08, phase) - smoothstep(0.35, 0.42, phase)
                + smoothstep(0.53, 0.59, phase) - smoothstep(0.86, 0.92, phase)
            return (start + delta * travel, heading + .pi * turn, sin(phase * 12 * .pi) * walking)
        }
    }

    private static func pad(_ a: SIMD2<Float>, _ b: SIMD2<Float>, width: Float, reach: Float) -> [SIMD2<Float>] {
        let axis = simd_normalize(b - a)
        let side = SIMD2(-axis.y, axis.x) * (width * 0.5 / metres)
        let inset = axis * (reach / metres)
        return [a - inset - side, b + inset - side, b + inset + side, a - inset + side]
    }

    static func plan(in scene: WorldScene, geometry: CityBuilder.Geometry, workshops: [BronzeCraft.Workshop],
                     seed: UInt64, site: BronzeLayout.Site) -> [Routine] {
        guard !workshops.isEmpty else { return [] }
        var site = site
        for path in geometry.buildings.keys.sorted() {
            let bounds = RiverPlacement.authoredBounds(path)
            for body in geometry.buildings[path, default: []] {
                site.solid.insertFootprint(RiverPlacement.transformed(bounds, by: body.model))
            }
        }
        for box in geometry.boxes {
            site.solid.insertFootprint(RiverPlacement.transformed(RiverPlacement.unitBoxBounds, by: box.model))
        }
        for pen in scene.bronzePens {
            for area in BronzeEnclosures.footprints(pen) { site.solid.insertFootprint(area) }
        }
        let lanes = scene.activityStreets
        let approaches = FieldSurface.Mask(mesh: scene.bronzeAccessMesh)
        let fields = FieldSurface.Mask(mesh: scene.fieldMesh)
        var routines: [Routine] = []

        func usable(_ area: [SIMD2<Float>]) -> Bool {
            let points = BronzeHome.foundationSamples(area)
            let heights = points.map(site.ground)
            return heights.max()! - heights.min()! <= 0.26 / metres
                && points.allSatisfy(site.dry) && site.clear(area, margin: 0.35 / metres)
                && !approaches.intersectsFootprint(area) && !fields.intersectsFootprint(area)
        }

        func claim(_ kind: Kind, start: SIMD2<Float>, end: SIMD2<Float>, fixture: simd_float4x4? = nil,
                   area: [SIMD2<Float>], rng: inout SplitMix64) {
            routines.append(Routine(kind: kind, start: start, end: end, fixture: fixture,
                phase: rng.nextFloat(), umber: kind == .shaping || (kind == .carrying && rng.nextFloat() > 0.55),
                clearance: area))
            site.solid.insertFootprint(area)
        }

        for workshop in workshops {
            var rng = SplitMix64(seed: seed ^ (UInt64(bitPattern: Int64(workshop.court.town)) &* 0xC973_9B71))
            let loom = workshop.loom
            let front = simd_normalize(NeolithicPeople.xz(loom.columns.2))
            let side = SIMD2(front.y, -front.x)
            let loomOrigin = NeolithicPeople.xz(loom.columns.3)
            for shift: Float in [0, -0.14, 0.14] {
                let stance = loomOrigin + (front * 0.58 + side * shift) / metres
                let facing = stance - front / metres
                let area = pad(stance + front * (0.10 / metres), stance - front * (0.09 / metres),
                               width: 0.55, reach: 0.17)
                guard usable(area) else { continue }
                claim(.weaving, start: stance, end: facing, fixture: loom, area: area, rng: &rng)
                break
            }

            // The taller jar in the authored BRZ-06 pair, measured in metres
            // relative to the pottery origin.
            let jar = workshop.pottery * translation(SIMD3(-0.13, 0.515, -0.06))
            let rim = NeolithicPeople.xz(jar.columns.3)
            for axis in [side, -side, -front, front] {
                let stance = rim + axis * (0.63 / metres)
                let area = pad(stance + axis * (0.31 / metres), stance - axis * (0.16 / metres),
                               width: 0.60, reach: 0.13)
                guard usable(area), abs(site.ground(stance) - (jar.columns.3.y - 0.515 / metres)) < 0.16 / metres
                else { continue }
                claim(.shaping, start: stance, end: rim, fixture: jar, area: area, rng: &rng)
                break
            }

            for axis in [side, front, simd_normalize(front + side), simd_normalize(front - side)] {
                let centre = workshop.court.centre
                let start = centre - axis * (1.29 / metres)
                let end = centre + axis * (1.29 / metres)
                let walk = BronzeLayout.Walk(a: start, b: end)
                let area = pad(start, end, width: 0.85, reach: 0.55)
                guard usable(area), walk.samples().allSatisfy(lanes.covers) else { continue }
                claim(.carrying, start: start, end: end, area: area, rng: &rng)
                break
            }
        }
        return routines
    }

    static func sample(_ routine: Routine, time: Float, scene: WorldScene,
                       append: (Part, simd_float4x4) -> Void) {
        let motion = routine.motion(at: time)
        let p = motion.point
        let heading = motion.heading
        let right = SIMD3<Float>(cos(heading), 0, -sin(heading))
        let forward = SIMD3<Float>(sin(heading), 0, cos(heading))
        let phase = routine.fraction(at: time)
        let beat = phase * 2 * .pi
        let kneeling = routine.kind == .shaping
        func ground(_ p: SIMD2<Float>) -> Float {
            max(scene.renderedTerrainHeight(at: p), scene.activityStreets.height(at: p) ?? 0)
        }

        let root = SIMD3(p.x, ground(p), p.y)
        let scale = scaleMatrix(SIMD3(repeating: 1 / metres))
        let facing = rotationY(heading)
        let basis = translation(root) * facing * scale
        let height: Float = kneeling ? 0.38 : 0.83 + abs(motion.stride) * 0.018
        let lean: Float = kneeling ? 0.67 + sin(beat) * 0.07 : routine.kind == .weaving ? 0.13 : 0.06
        let torso = basis * translation(SIMD3(0, height, kneeling ? -0.028 : 0)) * rotationX(lean)
        append(routine.umber ? .umber : .flax, torso)
        append(.head, torso * translation(SIMD3(0, 0.474, 0.014)) * rotationX(kneeling ? 0.18 : 0.08))

        let held = basis * translation(SIMD3(motion.stride * 0.024, 0.75, 0.34))
            * rotationZ(motion.stride * 0.045) * scaleMatrix(SIMD3(repeating: 0.75))
        if routine.kind == .carrying { append(.basket, held) }

        for sign: Float in [-1, 1] {
            let hip = NeolithicPeople.xyz(torso * SIMD4(sign * 0.104, -0.018, 0, 1))
            let step = sign * motion.stride
            let stride = kneeling ? -0.31 : step * 0.25 + sign * (routine.kind == .weaving ? 0.07 : 0)
            let flat = root + (right * (sign * 0.118) + forward * stride) / metres
            let lift = max(0, step) * 0.105 / metres
            let foot = SIMD3(flat.x, ground(SIMD2(flat.x, flat.z)) + lift, flat.z)
            let ankle = foot + SIMD3(0, 0.084 / metres, 0)
            let knee: SIMD3<Float>
            if kneeling {
                let point = root + (right * (sign * 0.115) + forward * 0.21) / metres
                knee = SIMD3(point.x, ground(SIMD2(point.x, point.z)) + 0.078 / metres, point.z)
            } else {
                knee = NeolithicPeople.joint(from: hip, to: ankle, upper: 0.393, lower: 0.388, bend: forward)
            }
            append(.legging, NeolithicPeople.segment(hip, knee, side: right))
            append(.legging, NeolithicPeople.segment(knee, ankle, side: right))
            append(.shoe, translation(foot) * facing * scale)

            let shoulder = NeolithicPeople.xyz(torso * SIMD4(sign * 0.209, 0.421, 0.02, 1))
            let hand: SIMD3<Float>
            switch routine.kind {
            case .weaving:
                guard let loom = routine.fixture else { continue }
                let sweep: Float = sign > 0 ? 0.052 + sin(beat) * 0.168 : -0.20 + sin(beat + 0.8) * 0.052
                let y: Float = sign > 0 ? 1.044 + (1 + cos(beat)) * 0.047 : 1.16 + cos(beat) * 0.032
                hand = NeolithicPeople.xyz(loom * SIMD4(sweep, y, 0.096 + 0.033 * sin(beat * 2), 1))
                if sign > 0 {
                    append(.shuttle, translation(hand + right * (0.026 / metres))
                        * facing * rotationZ(.pi / 2) * scale)
                }
            case .shaping:
                guard let rim = routine.fixture else { continue }
                let centre = NeolithicPeople.xyz(rim.columns.3)
                let arc = sign * (0.87 + sin(beat) * 0.36)
                hand = centre + (right * (sin(arc) * 0.142)
                    - forward * (cos(arc) * 0.142)
                    + SIMD3<Float>(0, 0.018 + cos(beat + sign) * 0.019, 0)) / metres
            case .carrying:
                hand = NeolithicPeople.xyz(held * SIMD4(sign * 0.282, 0.345, 0, 1))
            }
            let bend = right * sign * 0.68 + SIMD3<Float>(0, -0.78, 0)
            let elbow = NeolithicPeople.joint(from: shoulder, to: hand, upper: 0.326, lower: 0.29, bend: bend)
            append(.sleeve, NeolithicPeople.segment(shoulder, elbow, side: forward))
            append(.forearm, NeolithicPeople.segment(elbow, hand, side: forward))
        }
    }
}
