import simd

enum NeolithicYards {
    private static let metres = RiverGraph.metresPerUnit

    struct Entrance {
        let settlement: Int32
        let cluster: Int
        let yard: SIMD2<Float>
        let door: SIMD3<Float>
        let forward: SIMD2<Float>
        let footprint: [SIMD2<Float>]
        let stone: Bool
    }

    struct Connection {
        let entrance: Entrance
        let points: [SIMD2<Float>]
    }

    struct Yard {
        let centre: SIMD2<Float>
        let connections: [Connection]
        let fenceSections: [[SIMD2<Float>]]
    }

    struct Layout {
        var surfaces: [FieldSurface.GroundPatch] = []
        var fences: [InstanceData] = []
        var steps: [InstanceData] = []
        var yards: [Yard] = []
    }

    struct Cluster: Hashable, Comparable {
        let settlement: Int32
        let ring: Int

        static func < (a: Self, b: Self) -> Bool {
            (a.settlement, a.ring) < (b.settlement, b.ring)
        }
    }

    private static func vertex(_ point: SIMD2<Float>) -> Vertex {
        Vertex(position: SIMD3(point.x, 0, point.y), normal: SIMD3(0, 1, 0), rgb: .zero)
    }

    private static func corridor(_ a: SIMD2<Float>, _ b: SIMD2<Float>, width: Float,
                                 overlap: Float = 0) -> [SIMD2<Float>] {
        let forward = simd_normalize(b - a)
        let side = SIMD2(-forward.y, forward.x) * (width * 0.5)
        let extend = forward * overlap
        return [a - extend - side, b + extend - side, b + extend + side, a - extend + side]
    }

    private static func samples(_ a: SIMD2<Float>, _ b: SIMD2<Float>, step: Float) -> [SIMD2<Float>] {
        let count = max(1, Int(ceil(simd_distance(a, b) / step)))
        return (0...count).map { a + (b - a) * (Float($0) / Float(count)) }
    }

    static func build(_ entrances: [Entrance], boxes: [InstanceData], scene: WorldScene) -> Layout {
        guard !entrances.isEmpty else { return Layout() }
        let roads = scene.activityRoads
        let groups = Dictionary(grouping: entrances.indices) {
            Cluster(settlement: entrances[$0].settlement, ring: entrances[$0].cluster)
        }
        let cube = RiverPlacement.bounds(Geometry.cube())
        var props = FieldSurface.Mask()
        for box in boxes { props.insertFootprint(RiverPlacement.transformed(cube, by: box.model)) }
        let housePolygons = entrances.map { $0.footprint.map(vertex) }

        func ground(_ point: SIMD2<Float>) -> Float { scene.renderedTerrainHeight(at: point) }
        func dry(_ point: SIMD2<Float>) -> Bool {
            ground(point) > 0.35 / metres && !scene.terrain.isWater(x: point.x, z: point.y)
        }
        func crosses(_ a: [Vertex], _ b: [Vertex]) -> Bool {
            RiverPolygon.overlaps(a, b)
                && abs(RiverPolygon.area(RiverGeometryChecks.intersection(a, b))) > RiverPolygon.areaEpsilon
        }
        func usable(_ polygon: [SIMD2<Float>], excluding house: Int? = nil, margin: Float = 0) -> Bool {
            guard !scene.riverField.intersectsFootprint(polygon, margin: margin),
                  !roads.intersectsFootprint(polygon), !props.intersectsFootprint(polygon),
                  polygon.allSatisfy(dry) else { return false }
            let projected = polygon.map(vertex)
            return !housePolygons.indices.contains { $0 != house && crosses(projected, housePolygons[$0]) }
        }
        func walkable(_ a: SIMD2<Float>, _ b: SIMD2<Float>, width: Float) -> Bool {
            let direction = simd_normalize(b - a)
            let side = SIMD2(-direction.y, direction.x) * (width * 0.5)
            let points = samples(a, b, step: 0.65 / metres)
            for offset in [SIMD2<Float>.zero, side, -side] {
                let line = points.map { $0 + offset }
                guard line.allSatisfy(dry), zip(line, line.dropFirst()).allSatisfy({
                    abs(ground($1) - ground($0)) <= simd_distance($0, $1) * 0.58
                }) else { return false }
            }
            return true
        }

        let yardShape: [SIMD2<Float>] = [SIMD2(-2.5, -0.7), SIMD2(-1.3, -2.1), SIMD2(0.7, -2),
            SIMD2(2.25, -0.85), SIMD2(2.42, 0.73), SIMD2(1.15, 2.02),
            SIMD2(-0.86, 1.92), SIMD2(-2.2, 1.15)]
        let pathWidth: Float = 1.06 / metres
        let soil = SIMD4<Float>(0.36, 0.29, 0.19, 0)
        let yardSoil = SIMD4<Float>(0.38, 0.31, 0.22, 0)
        var layout = Layout()
        for key in groups.keys.sorted() {
            guard let members = groups[key], members.count >= 2 else { continue }
            let original = entrances[members[0]].yard
            var chosen: (SIMD2<Float>, [SIMD2<Float>], [Connection], [FieldSurface.GroundPatch])?
            let offsets: [SIMD2<Float>] = [.zero, SIMD2(1.7, 0), SIMD2(0, 1.7),
                SIMD2(-1.7, 0), SIMD2(0, -1.7), SIMD2(1.9, 1.9), SIMD2(-1.9, 1.9),
                SIMD2(1.9, -1.9), SIMD2(-1.9, -1.9)]
            for offset in offsets {
                let centre = original + offset / metres
                let rim = yardShape.map { centre + $0 / metres }
                let heights = (rim + [centre]).map(ground)
                guard usable(rim), dry(centre), heights.max()! - heights.min()! < 1.25 / metres,
                      rim.indices.allSatisfy({
                          walkable(rim[$0], rim[($0 + 1) % rim.count], width: 0)
                      }) else { continue }

                var links: [Connection] = []
                var patches: [FieldSurface.GroundPatch] = []
                for id in members {
                    let entry = entrances[id]
                    let door = SIMD2(entry.door.x, entry.door.z)
                    let reveal = entry.door.y - ground(door)
                    guard reveal >= -0.10 / metres, reveal <= 0.90 / metres else { continue }
                    let run: Float = reveal > 0.48 / metres ? 1.27 : 0.75
                    let outside = door + entry.forward * (run / metres)
                    guard simd_distance(outside, centre) > 1 / metres else { continue }
                    let throat = corridor(door, outside, width: pathWidth, overlap: 0.10 / metres)
                    guard usable(throat, excluding: id), walkable(door, outside, width: pathWidth) else { continue }

                    let midpoint = (outside + centre) * 0.5
                    let direction = simd_normalize(centre - outside)
                    let detour = SIMD2(-direction.y, direction.x) * (1.5 / metres)
                    let alternatives = [[outside, centre], [outside, midpoint + detour, centre],
                                        [outside, midpoint - detour, centre]]
                    for route in alternatives {
                        let segments = Array(zip(route, route.dropFirst()))
                        let trails = segments.map { corridor($0, $1, width: pathWidth, overlap: 0.17 / metres) }
                        guard trails.allSatisfy({ usable($0) }),
                              segments.allSatisfy({ walkable($0, $1, width: pathWidth) }) else { continue }
                        links.append(Connection(entrance: entry, points: [door] + route))
                        for strip in [throat] + trails {
                            patches.append(FieldSurface.GroundPatch(outline: strip, colour: soil,
                                centre: door, across: SIMD2(-entry.forward.y, entry.forward.x)))
                        }
                        break
                    }
                }
                if links.count >= 2, links.count > (chosen?.2.count ?? 0) {
                    chosen = (centre, rim, links, patches)
                    if links.count == members.count { break }
                }
            }
            guard let (centre, rim, links, paths) = chosen else { continue }
            for link in links { appendSteps(link.entrance, ground: ground, into: &layout.steps) }
            let previousPaths = layout.surfaces
            layout.surfaces.append(FieldSurface.GroundPatch(outline: rim, colour: yardSoil,
                                   centre: centre, across: SIMD2(1, 0)))
            layout.surfaces.append(contentsOf: paths)

            var sections: [[SIMD2<Float>]] = []
            let pathPolygons = (paths + previousPaths).map { $0.outline.map(vertex) }
            for index in rim.indices where sections.count < 2 {
                let a = centre + (rim[index] - centre) * 1.22
                let b = centre + (rim[(index + 1) % rim.count] - centre) * 1.22
                let pad = corridor(a, b, width: 0.24 / metres, overlap: 0.13 / metres)
                guard usable(pad, margin: 1.6 / metres), walkable(a, b, width: 0.24 / metres),
                      !pathPolygons.contains(where: { crosses(pad.map(vertex), $0) }) else { continue }
                sections.append(pad)
                props.insertFootprint(pad)
                appendFence(from: a, to: b, ground: ground, into: &layout.fences)
            }
            layout.yards.append(Yard(centre: centre, connections: links, fenceSections: sections))
        }
        return layout
    }

    private static func appendSteps(_ entrance: Entrance, ground: (SIMD2<Float>) -> Float,
                                    into steps: inout [InstanceData]) {
        let door = SIMD2(entrance.door.x, entrance.door.z)
        let reveal = entrance.door.y - ground(door)
        guard reveal > 0.30 / metres else { return }
        let count = Int(ceil(reveal * metres / 0.25)) - 1
        let drop = reveal / Float(count + 1)
        let heading = atan2(entrance.forward.x, entrance.forward.y)
        for i in 1...count {
            let point = door + entrance.forward * ((0.30 * Float(i)) / metres)
            let side = SIMD2(-entrance.forward.y, entrance.forward.x) * (0.39 / metres)
            let half = entrance.forward * (0.16 / metres)
            let support = [point - half - side, point - half + side,
                           point + half - side, point + half + side].map(ground).min()!
            let low = support - 0.06 / metres
            let high = entrance.door.y - drop * Float(i)
            guard high - low > 0.08 / metres else { continue }
            let model = translation(SIMD3(point.x, (high + low) * 0.5, point.y))
                * rotationY(heading) * scaleMatrix(SIMD3(0.78 / metres, high - low, 0.32 / metres))
            steps.append(InstanceData(model: model, color: SIMD4(0.48, 0.42, 0.32, 0),
                                      material: SIMD4(2, 0, 0, 0)))
        }
    }

    private static func appendFence(from a: SIMD2<Float>, to b: SIMD2<Float>,
                                    ground: (SIMD2<Float>) -> Float, into fence: inout [InstanceData]) {
        let poles = [a, (a + b) * 0.5, b]
        let wood = SIMD4<Float>(0.33, 0.23, 0.13, 0)
        let material = SIMD4<Float>(14, 0, 0, 0)
        for pole in poles {
            let base = ground(pole)
            let model = translation(SIMD3(pole.x, base + 0.30 / metres, pole.y))
                * scaleMatrix(SIMD3(0.14, 0.76, 0.14) / metres)
            fence.append(InstanceData(model: model, color: wood, material: material))
        }
        for (start, end) in zip(poles, poles.dropFirst()) {
            for lift in [Float(0.23), 0.49] {
                let p = SIMD3(start.x, ground(start) + lift / metres, start.y)
                let q = SIMD3(end.x, ground(end) + lift / metres, end.y)
                let forward = simd_normalize(q - p)
                let side = simd_normalize(simd_cross(SIMD3(0, 1, 0), forward))
                let up = simd_cross(forward, side)
                let middle = (p + q) * 0.5
                let model = simd_float4x4(columns: (
                    SIMD4(side * (0.058 / metres), 0), SIMD4(up * (0.075 / metres), 0),
                    SIMD4(q - p, 0), SIMD4(middle, 1)))
                fence.append(InstanceData(model: model, color: wood, material: material))
            }
        }
    }
}
