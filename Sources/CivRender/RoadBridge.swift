import simd

/// Earthwork and structure for raised crossings. All distances in this file
/// are expressed in metres before conversion to world units.
enum RoadBridge {
    private static let metres = RiverNetwork.metresPerUnit

    struct Row {
        let centre: SIMD2<Float>
        let direction: SIMD2<Float>
        let side: SIMD2<Float>
        let distance: Float

        func edge(_ offset: Float) -> SIMD2<Float> { centre + side * offset }
    }

    struct Span {
        let rows: ClosedRange<Int>
        let waterLevel: Float
        let deck: Float
    }

    struct Plan {
        let rows: [Row]
        let spans: [Span]
        let minimumHeights: [Float]
        let blockedStrips: Set<Int>
        let wetStrips: [Int]
        let needsLeadingApproach: Bool
        let needsTrailingApproach: Bool
    }

    /// Ranges refer to the actual road vertex buffer used for drawing.
    struct Crossing {
        let centre: SIMD2<Float>
        let direction: SIMD2<Float>
        let waterLevel: Float
        let deckRows: Range<Int>
        let foundations: [Range<Int>]
        let piers: [Range<Int>]
    }

    /// Drive lanes sampled from the same ribbon vertices that form the deck.
    struct DrivePath {
        let distances: [Float]
        let outbound: [SIMD3<Float>]
        let inbound: [SIMD3<Float>]

        var length: Float { distances.last! }

        func pose(progress: Float, forward: Bool) -> (position: SIMD3<Float>, direction: SIMD2<Float>) {
            let at = progress * length
            var lo = 0, hi = distances.count - 1
            while hi - lo > 1 {
                let middle = (lo + hi) / 2
                if distances[middle] <= at { lo = middle } else { hi = middle }
            }
            let lane = forward ? outbound : inbound
            let delta = lane[hi] - lane[lo]
            let t = (at - distances[lo]) / max(distances[hi] - distances[lo], 0.0001 / RoadBridge.metres)
            let heading = SIMD2(delta.x, delta.z)
            let direction = simd_length_squared(heading) > 0 ? simd_normalize(heading) : SIMD2(1, 0)
            return (lane[lo] + delta * t, forward ? direction : -direction)
        }
    }

    static func drivePath(_ plan: Plan, roadBase: Int, vertices: [Vertex]) -> DrivePath {
        func lane(_ index: Int) -> [SIMD3<Float>] {
            plan.rows.indices.map { i in
                let start = roadBase + i * 5
                let centre = vertices[start + 2].position
                return centre + (vertices[start + index].position - centre) * 0.42
            }
        }
        return DrivePath(distances: plan.rows.map(\.distance), outbound: lane(1), inbound: lane(3))
    }

    static func row(_ path: [SIMD2<Float>], at i: Int, distance: Float = 0) -> Row {
        let delta = path[min(i + 1, path.count - 1)] - path[max(i - 1, 0)]
        let length = simd_length(delta)
        let direction = length > 0.001 / metres ? delta / length : SIMD2(1, 0)
        return Row(centre: path[i], direction: direction, side: SIMD2(-direction.y, direction.x), distance: distance)
    }

    private static func point(_ p: SIMD2<Float>, y: Float = 0) -> SIMD3<Float> {
        SIMD3(p.x, y, p.y)
    }

    private static func pad(_ row: Row, half: Float, length: Float) -> [SIMD2<Float>] {
        let end = row.direction * (length * 0.5)
        return [row.edge(half) - end, row.edge(-half) - end,
                row.edge(-half) + end, row.edge(half) + end]
    }

    private static func dryFoundation(_ row: Row, half: Float, field: RiverChannel.Field) -> Bool {
        !field.intersectsFootprint(pad(row, half: half * 1.22, length: 2 / metres), margin: 0.25 / metres)
    }

    /// Walk inward along an omitted town approach from the trimmed endpoint.
    /// Carry one extra routed point past the first dry landing for the joint.
    static func retainedApproach(_ points: [SIMD2<Float>], from endpoint: SIMD2<Float>,
                                 half: Float, field: RiverChannel.Field) -> [SIMD2<Float>] {
        let route = [endpoint] + points
        var distance: Float = 0
        for i in 1..<route.count {
            distance += simd_distance(route[i - 1], route[i])
            if distance > 40 / metres { break }
            if dryFoundation(row(route, at: i), half: half, field: field) {
                return Array(points.prefix(i + 1))
            }
        }
        return []
    }

    private static func waterLevel(_ a: Row, _ b: Row, half: Float, field: RiverChannel.Field) -> Float? {
        let corners = [a.edge(half), a.edge(-half), b.edge(-half), b.edge(half)]
            .map { Vertex(position: point($0), normal: SIMD3(0, 1, 0), rgb: .zero) }
        let left = corners.map { $0.position.x }.min()!, right = corners.map { $0.position.x }.max()!
        let near = corners.map { $0.position.z }.min()!, far = corners.map { $0.position.z }.max()!
        let road = [[corners[0], corners[3], corners[1]], [corners[1], corners[3], corners[2]]]
        var highest: Float?
        for water in field.nearbyTriangles(corners) where RiverPolygon.area(water) < 0 {
            if water.allSatisfy({ $0.position.x < left }) || water.allSatisfy({ $0.position.x > right })
                || water.allSatisfy({ $0.position.z < near }) || water.allSatisfy({ $0.position.z > far }) {
                continue
            }
            for triangle in road {
                let overlap = RiverGeometryChecks.intersection(triangle, water)
                guard abs(RiverPolygon.area(overlap)) > RiverPolygon.areaEpsilon else { continue }
                for vertex in overlap {
                    let p = SIMD2(vertex.position.x, vertex.position.z)
                    let level = RiverChannel.Field.probe(water, p).water
                    highest = max(highest ?? level, level)
                }
            }
        }
        return highest
    }

    static func plan(_ path: [SIMD2<Float>], half: Float, scene: WorldScene) -> Plan {
        var distance: Float = 0
        let rows = path.indices.map { i -> Row in
            if i > 0 { distance += simd_distance(path[i - 1], path[i]) }
            return row(path, at: i, distance: distance)
        }
        let field = scene.riverField
        var runs: [(first: Int, last: Int, water: Float)] = []
        var wet: [Int] = []
        for i in 0..<(rows.count - 1) {
            guard let level = waterLevel(rows[i], rows[i + 1], half: half, field: field) else { continue }
            wet.append(i)
            // Brief dry slivers leave too little room for separate abutments.
            if let previous = runs.last, rows[i].distance - rows[previous.last + 1].distance < 7 / metres {
                runs[runs.count - 1] = (previous.first, i, max(previous.water, level))
            } else {
                runs.append((i, i, level))
            }
        }
        var spans: [Span] = []
        var anchored: [(first: Int, last: Int, water: Float)] = []
        var needsLeadingApproach = false, needsTrailingApproach = false
        var heights = [Float](repeating: -.infinity, count: rows.count)
        var blocked: Set<Int> = []
        func ground(_ i: Int) -> Float {
            [-half, -half * 0.62, 0, half * 0.62, half]
                .map {
                    let p = rows[i].edge($0)
                    return max(scene.renderedTerrainHeight(at: p), scene.terrain.interpolatedHeight(x: p.x, z: p.y))
                }.max()!
        }
        func anchor(from wetRow: Int, direction: Int) -> Int? {
            var i = wetRow
            while rows.indices.contains(i), abs(rows[i].distance - rows[wetRow].distance) <= 40 / metres {
                if dryFoundation(rows[i], half: half, field: field) {
                    return i
                }
                i += direction
            }
            return nil
        }

        for run in runs {
            let leading = anchor(from: run.first, direction: -1)
            let trailing = anchor(from: run.last + 1, direction: 1)
            if leading == nil, rows[run.first].distance <= 40 / metres { needsLeadingApproach = true }
            if trailing == nil, rows.last!.distance - rows[run.last + 1].distance <= 40 / metres { needsTrailingApproach = true }
            guard let first = leading, let last = trailing else { continue }
            if let previous = anchored.last, first <= previous.last {
                anchored[anchored.count - 1] = (previous.first, max(previous.last, last), max(previous.water, run.water))
            } else {
                anchored.append((first, last, run.water))
            }
        }
        for run in anchored {
            let first = run.first, last = run.last
            guard rows[last].distance - rows[first].distance <= 120 / metres else { continue }
            let section = first...last
            let deck = max(run.water + 2.6 / metres, section.map(ground).max()! + 1.9 / metres)
            spans.append(Span(rows: section, waterLevel: run.water, deck: deck))
            for i in section { heights[i] = max(heights[i], deck) }

            // Meet the existing road with a graded approach. Leave the road's
            // ordinary profile in charge once it reaches the ramp.
            for end in [first, last] {
                let direction = end == first ? -1 : 1
                var i = end + direction
                while rows.indices.contains(i) {
                    let ramp = deck - abs(rows[i].distance - rows[end].distance) * 0.15
                    if ramp <= ground(i) + 1.9 / metres { break }
                    heights[i] = max(heights[i], ramp)
                    i += direction
                }
            }
        }
        for i in 0..<(rows.count - 1) where heights[i].isFinite || heights[i + 1].isFinite {
            blocked.insert(i)
        }
        return Plan(rows: rows, spans: spans, minimumHeights: heights, blockedStrips: blocked, wetStrips: wet,
                    needsLeadingApproach: needsLeadingApproach, needsTrailingApproach: needsTrailingApproach)
    }

    static func append(_ plan: Plan, roadBase: Int, half: Float, style: BridgeStyle, color: SIMD3<Float>,
                       scene: WorldScene, vertices: inout [Vertex], indices: inout [UInt32]) -> [Crossing] {
        let surface: RoadSurface = style == .stone ? .bridgeStone : (style == .iron ? .bridgeIron : .bridgeConcrete)
        let wall = style == .iron ? SIMD3<Float>(0.22, 0.24, 0.23) : color * 0.84
        let trim = style == .iron ? SIMD3<Float>(0.33, 0.35, 0.32) : color * 1.10

        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                  color: SIMD3<Float>) {
            let cross = simd_cross(b - a, c - a)
            guard simd_length_squared(cross) > 0 else { return }
            let normal = simd_normalize(cross)
            let start = UInt32(vertices.count)
            for p in [a, b, c, d] {
                let uv = abs(normal.y) > 0.8 ? SIMD2(p.x, p.z)
                    : SIMD2(p.x * normal.z - p.z * normal.x, p.y)
                vertices.append(Vertex(position: p, normal: normal,
                                       color: SIMD4(color, Float(surface.rawValue)),
                                       uv: uv * metres))
            }
            indices.append(contentsOf: [start, start + 1, start + 2, start, start + 2, start + 3])
        }

        func support(_ row: Row, half: Float, length: Float, top: Float, color: SIMD3<Float>) -> Range<Int> {
            let footprint = pad(row, half: half, length: length)
            let footing = footprint.map { scene.renderedTerrainHeight(at: $0) }.min()! - 0.45 / metres
            let start = vertices.count
            for i in footprint.indices {
                let j = (i + 1) % 4
                quad(point(footprint[j], y: footing), point(footprint[i], y: footing),
                     point(footprint[i], y: top), point(footprint[j], y: top), color: color)
            }
            quad(point(footprint[0], y: top), point(footprint[3], y: top),
                 point(footprint[2], y: top), point(footprint[1], y: top), color: color)
            return start..<vertices.count
        }

        func top(_ i: Int, right: Bool) -> SIMD3<Float> {
            vertices[roadBase + i * 5 + (right ? 4 : 0)].position
        }

        var result: [Crossing] = []
        var bridgeStrips: Set<Int> = []
        for span in plan.spans {
            let first = span.rows.lowerBound, last = span.rows.upperBound
            let length = plan.rows[last].distance - plan.rows[first].distance
            let bays = max(1, Int(ceil(length * metres / (style == .stone ? 15 : 22))))
            let spanStart = plan.rows[first].distance
            var piers: [Range<Int>] = []

            func underside(_ i: Int, right: Bool) -> SIMD3<Float> {
                let position = top(i, right: right)
                let bay = (plan.rows[i].distance - spanStart) / length * Float(bays)
                let rise = style == .stone ? sin((bay - floor(bay)) * .pi) : 0
                let depth: Float = style == .stone ? 1.35 - 0.78 * rise : (style == .iron ? 0.70 : 0.92)
                return position - SIMD3(0, depth / metres, 0)
            }

            for i in first..<last {
                bridgeStrips.insert(i)
                let a = top(i, right: false), b = top(i + 1, right: false)
                let c = top(i, right: true), d = top(i + 1, right: true)
                let lowA = underside(i, right: false), lowB = underside(i + 1, right: false)
                let lowC = underside(i, right: true), lowD = underside(i + 1, right: true)
                quad(lowA, lowB, b, a, color: wall)
                quad(lowD, lowC, c, d, color: wall)
                quad(lowA, lowC, lowD, lowB, color: wall * 0.78)

                // Watertight cap and two vertical faces for each parapet.
                for right in [false, true] {
                    let sign: Float = right ? -1 : 1
                    let outerA = right ? c : a, outerB = right ? d : b
                    let lift = SIMD3<Float>(0, (style == .iron ? 0.83 : 1.00) / metres, 0)
                    let r0 = plan.rows[i], r1 = plan.rows[i + 1]
                    let width: Float = (style == .iron ? 0.12 : 0.25) / metres
                    let innerA = outerA - point(r0.side * (width * sign))
                    let innerB = outerB - point(r1.side * (width * sign))
                    if right {
                        quad(outerB, outerA, outerA + lift, outerB + lift, color: trim)
                        quad(innerA, innerB, innerB + lift, innerA + lift, color: trim)
                        quad(innerA + lift, innerB + lift, outerB + lift, outerA + lift, color: trim)
                    } else {
                        quad(outerA, outerB, outerB + lift, outerA + lift, color: trim)
                        quad(innerB, innerA, innerA + lift, innerB + lift, color: trim)
                        quad(outerA + lift, outerB + lift, innerB + lift, innerA + lift, color: trim)
                    }
                }
            }
            let foundations = [first, last].map { i in
                support(plan.rows[i], half: half * 1.22, length: 2 / metres,
                        top: top(i, right: false).y - 0.2 / metres, color: wall)
            }
            for i in [first, last] {
                let a = top(i, right: false), b = top(i, right: true)
                let lowA = underside(i, right: false), lowB = underside(i, right: true)
                if i == first { quad(lowB, lowA, a, b, color: wall) }
                else { quad(lowA, lowB, b, a, color: wall) }
            }
            for bay in 1..<bays {
                let desired = spanStart + length * Float(bay) / Float(bays)
                guard let i = span.rows.min(by: { abs(plan.rows[$0].distance - desired) < abs(plan.rows[$1].distance - desired) }),
                      i != first, i != last, scene.riverField.waterLevel(at: plan.rows[i].centre) != nil else { continue }
                piers.append(support(plan.rows[i], half: half * 0.48, length: 1.5 / metres,
                                     top: top(i, right: false).y - 0.20 / metres, color: wall * 0.92))
            }
            let middle = (first + last) / 2
            result.append(Crossing(centre: plan.rows[middle].centre, direction: plan.rows[middle].direction,
                                   waterLevel: span.waterLevel, deckRows: (roadBase + first * 5)..<(roadBase + (last + 1) * 5),
                                   foundations: foundations, piers: piers))
        }
        // Retain earth below the raised approaches. Their top edges are the
        // very same ribbon vertices used for the road and bridge deck.
        for i in plan.blockedStrips.sorted() where !bridgeStrips.contains(i) {
            for right in [false, true] {
                let a = top(i, right: right), b = top(i + 1, right: right)
                let la = point(SIMD2(a.x, a.z), y: scene.renderedTerrainHeight(at: SIMD2(a.x, a.z)) - 0.15 / metres)
                let lb = point(SIMD2(b.x, b.z), y: scene.renderedTerrainHeight(at: SIMD2(b.x, b.z)) - 0.15 / metres)
                if right { quad(lb, la, a, b, color: wall * 0.92) }
                else { quad(la, lb, b, a, color: wall * 0.92) }
            }
        }
        return result
    }
}
