import simd

/// Bronze households gather around small clearings on one bank. Building
/// envelopes, courts and walking lanes are reserved as each cluster is fitted.
enum BronzeLayout: SettlementLayout {
    private static let metres = RiverGraph.metresPerUnit
    private static let laneWidth: Float = 1.5 / metres
    private static let courtColour = SIMD4<Float>(0.41, 0.34, 0.24, 0)
    private static let pathColour = SIMD4<Float>(0.36, 0.29, 0.19, 0)

    struct Walk {
        let a: SIMD2<Float>
        let b: SIMD2<Float>

        func samples(step: Float = 0.45 / BronzeLayout.metres) -> [SIMD2<Float>] {
            let count = max(1, Int(ceil(simd_distance(a, b) / step)))
            return (0...count).map { a + (b - a) * (Float($0) / Float(count)) }
        }

        var outline: [SIMD2<Float>] {
            let direction = simd_normalize(b - a)
            let side = SIMD2(-direction.y, direction.x) * laneWidth * 0.5
            let join = direction * (0.12 / metres)
            return [a - join - side, b + join - side, b + join + side, a - join + side]
        }
    }

    struct Layout {
        var patches: [FieldSurface.GroundPatch] = []
        var walks: [Int32: [Walk]] = [:]
        var courts: [SIMD2<Float>] = []
    }

    struct Site {
        let terrain: Terrain
        let river: RiverChannel.Field?
        let renderedGround: ((SIMD2<Float>) -> Float)?
        let roads: FieldSurface.Mask
        let banks: FieldSurface.Mask
        var solid = FieldSurface.Mask()
        var communal = FieldSurface.Mask()

        func ground(_ p: SIMD2<Float>) -> Float {
            renderedGround?(p) ?? terrain.originalTriangleHeight(at: p)
        }

        func dry(_ p: SIMD2<Float>) -> Bool {
            ground(p) > 0.35 / metres && !terrain.isWater(x: p.x, z: p.y)
        }

        func clear(_ footprint: [SIMD2<Float>], margin: Float) -> Bool {
            footprint.allSatisfy(dry) && !solid.intersectsFootprint(footprint)
                && !roads.intersectsFootprint(footprint) && !banks.intersectsFootprint(footprint)
                && river?.intersectsFootprint(footprint, margin: margin) != true
        }

        func walkable(_ walk: Walk) -> Bool {
            guard simd_distance(walk.a, walk.b) > 0.45 / metres,
                  clear(walk.outline, margin: 0.25 / metres) else { return false }
            let side = (walk.outline[3] - walk.outline[0]) * 0.5
            let samples = walk.samples()
            for offset in [SIMD2<Float>.zero, side, -side] {
                let row = samples.map { $0 + offset }
                guard row.allSatisfy(dry), zip(row, row.dropFirst()).allSatisfy({
                    abs(ground($0) - ground($1)) <= simd_distance($0, $1) * 0.40
                }) else { return false }
            }
            return true
        }
    }

    private struct House {
        let form: BronzeHome
        let instance: InstanceData
        let footprint: [SIMD2<Float>]
        let approach: Walk
    }

    static func plan(settlement town: Settlement, resources: ResourceMap, terrain: Terrain,
                     seed: UInt64, style: CityBuilder.Style) -> SettlementPlan {
        let centre = SIMD2(town.x, town.z)
        let radius = CityBuilder.cityRadius(town.population)
        let spacing: Float = 20 / metres
        let rings = Int(floor(radius / spacing))
        let townSeed = seed ^ (UInt64(bitPattern: Int64(town.id)) &* 0xB20F_1E5A)
        var rng = SplitMix64(seed: townSeed)
        let axis = rng.nextFloat(in: 0...(2 * .pi))
        let along = SIMD2(cos(axis), sin(axis))
        let across = SIMD2(-along.y, along.x)
        var centres = [centre]
        for ring in 1...max(1, rings) {
            let count = ring * 6
            for i in 0..<count {
                let angle = axis + 2 * .pi * Float(i) / Float(count)
                let distance = spacing * Float(ring) + rng.nextFloat(in: -2...2) / metres
                centres.append(centre + SIMD2(cos(angle), sin(angle)) * distance)
            }
        }
        // Short shifts let the first court skirt a road or an inherited plot.
        for direction in [along, across, -along, -across] {
            centres.append(centre + direction * (11 / metres))
        }

        var plots: [Plot] = []
        for (id, court) in centres.enumerated() {
            var rng = SplitMix64(seed: townSeed ^ (UInt64(id) &* 0x9E37_79B9_7F4A_7C15))
            let heading = axis + rng.nextFloat(in: -0.55...0.55)
            guard resources.sample(court).buildability > 0.10 else { continue }
            for slot in 0..<4 {
                let angle = heading + Float(slot) * .pi / 2 + rng.nextFloat(in: -0.14...0.14)
                let out = SIMD2(cos(angle), sin(angle))
                let distance = rng.nextFloat(in: 7.4...8.4) / metres
                let point = court + out * distance
                guard simd_distance(point, centre) <= radius + 4 / metres,
                      resources.sample(point).buildability > 0.10 else { continue }
                plots.append(Plot(center: point, frontage: -out, width: 7 / metres, depth: 8 / metres,
                    district: .residential, roadID: 0, frontageRank: 2, ring: id,
                    cellIndex: SIMD2(slot + id, id), axis: heading, yard: court))
            }
        }
        return SettlementPlan(center: centre, axis: axis, plots: plots, cell: spacing, radius: radius)
    }

    static func append(_ plan: SettlementPlan, town: Settlement,
                       inherited: [NeolithicInheritance.Home], site: inout Site,
                       geometry: inout CityBuilder.Geometry) {
        let groups = Dictionary(grouping: plan.plots, by: \.ring)
        let limit = CityBuilder.buildingCount(town.population)
        var placed = 0
        var courts: [SIMD2<Float>] = []

        for id in groups.keys.sorted() {
            guard placed + 2 <= limit, let plots = groups[id], let centre = plots.first?.yard,
                  site.dry(centre),
                  site.river?.wetIntervals(from: plan.center, to: centre).isEmpty != false else { continue }
            let outline = clearing(centre, heading: plots[0].axis)
            let heights = (outline + [centre]).map(site.ground)
            guard site.clear(outline, margin: 0.25 / metres), !site.communal.intersectsFootprint(outline),
                  heights.max()! - heights.min()! < 1.35 / metres else { continue }

            var prospect = site
            prospect.communal.insertFootprint(outline)
            var houses: [House] = []
            for plot in plots.prefix(limit - placed) {
                guard let house = fit(plot, centre: centre, site: prospect) else { continue }
                houses.append(house)
                prospect.solid.insertFootprint(house.footprint)
                prospect.communal.insertFootprint(house.approach.outline)
            }
            guard houses.count >= 2 else { continue }
            site = prospect
            geometry.bronzeLayout.patches.append(patch(outline, centre: centre, colour: courtColour))
            geometry.bronzeLayout.courts.append(centre)
            courts.append(centre)
            for house in houses {
                geometry.buildings[house.form.path, default: []].append(house.instance)
                append(house.approach, town: town.id, to: &geometry.bronzeLayout)
            }
            placed += houses.count
        }

        // Link each new clearing to the closest earlier one with a viable
        // direct or dogleg route. The settlement's existing roads stay intact.
        for index in courts.indices.dropFirst() {
            let point = courts[index]
            let earlier = courts[..<index].enumerated().sorted {
                let a = simd_distance_squared($0.element, point)
                let b = simd_distance_squared($1.element, point)
                return a == b ? $0.offset < $1.offset : a < b
            }
            for (_, destination) in earlier where simd_distance(point, destination) <= 32 / metres {
                if let walks = connection(from: point, to: destination, site: site) {
                    for walk in walks {
                        append(walk, town: town.id, to: &geometry.bronzeLayout)
                        site.communal.insertFootprint(walk.outline)
                    }
                    break
                }
            }
        }

        for home in inherited {
            let bounds = RiverPlacement.authoredBounds(home.path)
            guard let front = bounds.map(\.y).max() else { continue }
            let model = home.instance.model
            let forwardScale = simd_length(NeolithicPeople.xz(model.columns.2))
            let threshold = model * SIMD4(0, 0, front + (0.40 / metres) / forwardScale, 1)
            let start = NeolithicPeople.xz(threshold)
            guard let closest = courts.min(by: {
                simd_distance_squared($0, start) < simd_distance_squared($1, start)
            }), simd_distance(closest, start) <= 22 / metres,
                let walks = connection(from: start, to: closest, site: site) else { continue }
            for walk in walks {
                append(walk, town: town.id, to: &geometry.bronzeLayout)
                site.communal.insertFootprint(walk.outline)
            }
        }
    }

    private static func fit(_ plot: Plot, centre: SIMD2<Float>, site: Site) -> House? {
        let ground = site.ground(plot.center)
        let rotation = rotationY(plot.facing)
        for form in BronzeHome.candidates(cell: plot.cellIndex, elevation: ground) {
            var model = translation(SIMD3(plot.center.x, ground, plot.center.y))
                * rotation * scaleMatrix(SIMD3(repeating: 1 / metres))
            let bounds = RiverPlacement.authoredBounds(form.path)
            let footprint = RiverPlacement.transformed(bounds, by: model)
            guard footprint.count == 4, site.clear(footprint, margin: 2 / metres),
                  !site.communal.intersectsFootprint(footprint) else { continue }
            let samples = BronzeHome.foundationSamples(footprint)
            guard samples.allSatisfy(site.dry) else { continue }
            let heights = samples.map(site.ground)
            guard let lowest = heights.min(), let highest = heights.max(),
                  highest - lowest <= (BronzeHome.skirtDepth - 0.12) / metres else { continue }
            model.columns.3.y = highest
            let front = bounds.map(\.y).max()! / metres
            let approach = Walk(a: plot.center + plot.frontage * (front + 0.40 / metres), b: centre)
            guard site.walkable(approach) else { continue }
            return House(form: form,
                instance: InstanceData(model: model, color: SIMD4(1, 1, 1, 0), material: SIMD4(9, 0, 0, 0)),
                footprint: footprint, approach: approach)
        }
        return nil
    }

    private static func clearing(_ centre: SIMD2<Float>, heading: Float) -> [SIMD2<Float>] {
        let shape: [SIMD2<Float>] = [SIMD2(-3.65, -1.35), SIMD2(-2.6, -2.7), SIMD2(0.8, -3.1),
            SIMD2(3.45, -1.6), SIMD2(3.8, 0.55), SIMD2(2.0, 2.6), SIMD2(-1.2, 2.85), SIMD2(-3.35, 1.3)]
        let along = SIMD2(cos(heading), sin(heading))
        let across = SIMD2(-along.y, along.x)
        return shape.map { centre + (along * $0.x + across * $0.y) / metres }
    }

    private static func connection(from a: SIMD2<Float>, to b: SIMD2<Float>, site: Site) -> [Walk]? {
        let delta = b - a
        guard simd_length(delta) > 0.45 / metres else { return nil }
        let normal = simd_normalize(SIMD2(-delta.y, delta.x))
        let middle = (a + b) * 0.5
        for route in [[a, b], [a, middle + normal * (4 / metres), b], [a, middle - normal * (4 / metres), b]] {
            let walks = zip(route, route.dropFirst()).map { Walk(a: $0.0, b: $0.1) }
            if walks.allSatisfy(site.walkable) { return walks }
        }
        return nil
    }

    private static func patch(_ outline: [SIMD2<Float>], centre: SIMD2<Float>,
                              colour: SIMD4<Float>) -> FieldSurface.GroundPatch {
        FieldSurface.GroundPatch(outline: outline, colour: colour, centre: centre, across: SIMD2(1, 0))
    }

    private static func append(_ walk: Walk, town: Int32, to layout: inout Layout) {
        layout.walks[town, default: []].append(walk)
        layout.patches.append(patch(walk.outline, centre: walk.a, colour: pathColour))
    }
}
