import Foundation
import simd

/// Each herd has a small, walkable range reserved at scene build. The frame
/// sampler follows that accepted route and never drops members on collision.
enum NeolithicHerds {
    typealias Species = NeolithicLivestock.Species
    private static let metres = RiverGraph.metresPerUnit

    struct Habitat {
        let major: Float
        let minor: Float
        let search: ClosedRange<Float>
        let slope: Float
        let members: Int

        static func forSpecies(_ species: Species) -> Self {
            switch species {
            case .sheep: return Self(major: 4.7, minor: 3.6, search: 27...73, slope: 0.24, members: 3)
            case .cattle: return Self(major: 6.5, minor: 4.6, search: 42...103, slope: 0.16, members: 2)
            case .pig: return Self(major: 3.7, minor: 2.8, search: 7.5...23, slope: 0.21, members: 3)
            }
        }
    }

    struct Route: Equatable {
        let centre: SIMD2<Float>
        let envelope: [SIMD2<Float>]
        let points: [SIMD2<Float>]
        let tangents: [SIMD2<Float>]
        let arc: [Float]

        var length: Float { arc[arc.count - 1] }

        init(centre: SIMD2<Float>, direction: Float, habitat: Habitat, radiusMetres: Float) {
            self.centre = centre
            let long = SIMD2(cos(direction), sin(direction))
            let short = SIMD2(-long.y, long.x)
            let margin = radiusMetres + 0.18
            let x = long * ((habitat.major + margin) / metres)
            let z = short * ((habitat.minor + margin) / metres)
            envelope = [centre - x - z, centre + x - z, centre + x + z, centre - x + z]

            // Consecutive chords stay inside the cleared envelope. The arc
            // table keeps the walk speed even on the narrow ends of the loop.
            let count = max(64, Int(ceil(2 * .pi * habitat.major / 0.27)))
            var samples: [SIMD2<Float>] = []
            var axes: [SIMD2<Float>] = []
            var accumulated: [Float] = [0]
            for i in 0..<count {
                let a = Float(i) * (2 * .pi) / Float(count)
                let point = centre + (long * (cos(a) * habitat.major)
                                    + short * (sin(a) * habitat.minor)) / metres
                let axis = short * (cos(a) * habitat.minor) - long * (sin(a) * habitat.major)
                if let previous = samples.last {
                    accumulated.append(accumulated.last! + simd_distance(previous, point) * metres)
                }
                samples.append(point)
                axes.append(simd_normalize(axis))
            }
            accumulated.append(accumulated.last! + simd_distance(samples.last!, samples[0]) * metres)
            points = samples
            tangents = axes
            arc = accumulated
        }

        func position(at distance: Float) -> (point: SIMD2<Float>, heading: Float) {
            let raw = distance.truncatingRemainder(dividingBy: length)
            let offset = raw < 0 ? raw + length : raw
            var lo = 0
            var hi = points.count
            while hi - lo > 1 {
                let mid = (hi + lo) / 2
                if arc[mid] <= offset { lo = mid } else { hi = mid }
            }
            let next = (lo + 1) % points.count
            let blend = (offset - arc[lo]) / (arc[lo + 1] - arc[lo])
            let point = points[lo] + (points[next] - points[lo]) * blend
            let axis = tangents[lo] + (tangents[next] - tangents[lo]) * blend
            return (point, atan2(axis.x, axis.y))
        }
    }

    struct Member: Equatable {
        let start: Float
        let scale: Float
        let phase: Float
    }

    struct Herd: Equatable {
        let species: Species
        let settlement: Int32
        let anchor: SIMD2<Float>
        let route: Route
        let phase: Float
        let members: [Member]

        func placements(at time: Float, in scene: WorldScene) -> [NeolithicLivestock.Placement] {
            let clock = time + phase
            let beat = clock.truncatingRemainder(dividingBy: 15)
            let step = NeolithicLivestock.gait(species, at: clock)
            return members.enumerated().map { slot, member in
                let facing = route.position(at: step.distance + member.start)
                // Walking stays in formation; heads lower at individually
                // seeded times during the stationary part of the cycle.
                let feeding = beat >= 8 + member.phase && beat < 15 - (1 - member.phase) * 0.7
                let frame = feeding ? 4 : step.pose.isFeeding ? 0 : (step.pose.frame + slot) % 4
                let pose = NeolithicLivestock.Pose(species: species, frame: frame)
                let rooting = species == .pig && feeding ? sin(beat * 4.6 + member.phase * 6) * 0.13 : 0
                let model = NeolithicLivestock.model(at: facing.point, heading: facing.heading + rooting,
                                                     scale: member.scale, in: scene)
                return NeolithicLivestock.Placement(pose: pose, instance: InstanceData(
                    model: model, color: SIMD4(1, 1, 1, 0), material: SIMD4(9, 0, 0, 0)))
            }
        }
    }

    struct Clearance {
        let buildingsAndActors: FieldSurface.Mask
        let fields: FieldSurface.Mask
        let cereal: FieldSurface.Mask
        let roads: FieldSurface.Mask
        let paths: FieldSurface.Mask
        let banks: FieldSurface.Mask

        func allows(_ area: [SIMD2<Float>], in scene: WorldScene) -> Bool {
            !scene.riverField.intersectsFootprint(area, margin: 0.4 / metres)
                && !banks.intersectsFootprint(area) && !fields.intersectsFootprint(area)
                && !cereal.intersectsFootprint(area) && !roads.intersectsFootprint(area)
                && !paths.intersectsFootprint(area) && !buildingsAndActors.intersectsFootprint(area)
        }
    }

    static func clearance(in scene: WorldScene, geometry: CityBuilder.Geometry,
                          routines: [NeolithicPeople.Routine], harvest: NeolithicHarvest.Layout,
                          trees: [InstanceData]) -> Clearance {
        var solids = FieldSurface.Mask()
        for path in geometry.buildings.keys.sorted() {
            let bounds = RiverPlacement.authoredBounds(path)
            for instance in geometry.buildings[path, default: []] {
                solids.insertFootprint(RiverPlacement.transformed(bounds, by: instance.model))
            }
        }
        let cube = RiverPlacement.bounds(Geometry.cube())
        for box in geometry.boxes {
            solids.insertFootprint(RiverPlacement.transformed(cube, by: box.model))
        }
        for part in [NeolithicHarvest.Part.sheaves, .tray] {
            let bounds = RiverPlacement.authoredBounds(part.path)
            for prop in harvest.props[part, default: []] {
                solids.insertFootprint(RiverPlacement.transformed(bounds, by: prop.model))
            }
        }
        for routine in routines { solids.insertFootprint(routine.clearance) }
        for tree in trees {
            let point = NeolithicPeople.xz(tree.model.columns.3)
            let pad = 0.55 / metres
            solids.insertFootprint([point + SIMD2(-pad, -pad), point + SIMD2(pad, -pad),
                                    point + SIMD2(pad, pad), point + SIMD2(-pad, pad)])
        }
        return Clearance(buildingsAndActors: solids, fields: scene.activityFields,
                         cereal: FieldSurface.Mask(mesh: scene.cerealMesh),
                         roads: scene.activityRoads, paths: scene.activityStreets, banks: scene.riverBankFootprint)
    }

    static func plan(in scene: WorldScene, settlements: [Settlement], seed: UInt64,
                     clearance: Clearance, reference: NeolithicReference.Stage?) -> [Herd] {
        var result: [Herd] = []
        var reserved = FieldSurface.Mask()
        // A stable seed order spreads the six sites per species over the inhabited island.
        let ordered = settlements.sorted {
            let a = UInt64(bitPattern: Int64($0.id)) ^ seed
            let b = UInt64(bitPattern: Int64($1.id)) ^ seed
            return (a, $0.id) < (b, $1.id)
        }
        for species in Species.allCases {
            let habitat = Habitat.forSpecies(species)
            let radius = NeolithicLivestock.sweptRadii[species.rawValue] * 1.08
            guard radius > 0 else { continue }
            var count = 0
            let poses = NeolithicLivestock.poses.filter { $0.species == species }
            for settlement in ordered where count < 6 {
                let town = SIMD2(settlement.x, settlement.z)
                let yard = scene.neolithicYards.yards.first {
                    $0.connections.first?.entrance.settlement == settlement.id
                }
                let anchor = species == .pig ? yard?.centre ?? town : town
                let identity = UInt64(bitPattern: Int64(settlement.id)) &* 0xD875_F02C_A2CB_45DF
                var rng = SplitMix64(seed: seed ^ identity ^ (UInt64(species.rawValue) &* 0x91E1_0DA5_C79E_7B1D))
                let base = rng.nextFloat(in: 0...(2 * .pi))
                for attempt in 0..<32 {
                    let angle = base + Float(attempt % 8) * .pi / 4
                    let fraction = (Float(attempt / 8) + rng.nextFloat()) / 4
                    let offset = habitat.search.lowerBound + (habitat.search.upperBound - habitat.search.lowerBound) * fraction
                    let centre = anchor + SIMD2(cos(angle), sin(angle)) * (offset / metres)
                    let route = Route(centre: centre, direction: angle + rng.nextFloat(in: -1.2...1.2),
                                      habitat: habitat, radiusMetres: radius)
                    let test = route.envelope + [centre]
                    guard test.allSatisfy({ reference?.containsStagedYard($0) != true
                        && !scene.terrain.isWater(x: $0.x, z: $0.y)
                        && scene.renderedTerrainHeight(at: $0) > 4 / metres }),
                          !reserved.intersectsFootprint(route.envelope),
                          clearance.allows(route.envelope, in: scene),
                          supported(route, poses: poses, grade: habitat.slope, in: scene)
                    else { continue }
                    let phase = rng.nextFloat(in: 0...14.99)
                    let spacing = route.length / Float(habitat.members)
                    let members = (0..<habitat.members).map { slot in
                        Member(start: (Float(slot) + rng.nextFloat(in: 0...0.11)) * spacing,
                               scale: rng.nextFloat(in: 0.94...1.08) / metres,
                               phase: rng.nextFloat())
                    }
                    result.append(Herd(species: species, settlement: settlement.id, anchor: anchor,
                                       route: route, phase: phase, members: members))
                    reserved.insertFootprint(route.envelope)
                    count += 1
                    break
                }
            }
        }
        return result
    }

    private static func supported(_ route: Route, poses: [NeolithicLivestock.Pose],
                                  grade: Float, in scene: WorldScene) -> Bool {
        for i in route.points.indices {
            let point = route.points[i]
            let tangent = route.tangents[i]
            let midpoint = route.position(at: (route.arc[i] + route.arc[i + 1]) * 0.5)
            for (position, heading) in [(point, atan2(tangent.x, tangent.y)), midpoint] {
                let scale = 1.08 / metres
                let model = NeolithicLivestock.model(at: position, heading: heading, scale: scale, in: scene)
                let up = model.columns.1
                guard model.columns.3.y > 4 / metres,
                      hypot(up.x, up.z) / scale <= grade,
                      poses.allSatisfy({ NeolithicLivestock.hoovesSupported($0, by: model, in: scene) })
                else { return false }
                if let feed = poses.last, feed.species == .pig {
                    for turn: Float in [-0.13, 0.13] {
                        let root = NeolithicLivestock.model(at: position, heading: heading + turn, scale: scale, in: scene)
                        guard NeolithicLivestock.hoovesSupported(feed, by: root, in: scene) else { return false }
                    }
                }
            }
        }
        return true
    }
}
