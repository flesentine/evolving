import simd

/// Low stone-and-earth banks laid out on dry ground beside occupied courts.
enum BronzeEnclosures {
    static let metres = RiverGraph.metresPerUnit
    static let clearGateWidth: Float = 2.6 / metres
    private static let bankHalfWidth: Float = 0.48 / metres
    private static let minimumElevation: Float = 22 / metres
    private static let accessColour = SIMD4<Float>(0.36, 0.29, 0.19, 0)

    struct Pen {
        let town: Int32
        let court: SIMD2<Float>
        let outline: [SIMD2<Float>]
        let banks: [[SIMD2<Float>]]
        let gate: SIMD2<Float>
        /// Direction from the opening into the paddock.
        let inward: SIMD2<Float>
        let access: [BronzeLayout.Walk]
    }

    struct Site {
        let ground: BronzeLayout.Site
        let crops: FieldSurface.Mask
        let paths: FieldSurface.Mask
        var reserved = FieldSurface.Mask()

        func clear(_ polygon: [SIMD2<Float>]) -> Bool {
            ground.clear(polygon, margin: 0.5 / metres)
                && !crops.intersectsFootprint(polygon) && !reserved.intersectsFootprint(polygon)
        }
    }

    /// Try several edges around an occupied court. A failed site contributes
    /// neither a wall nor an approach. Accepted plots reserve their full area.
    static func plan(courts: [BronzeLayout.Court], seed: UInt64, site: Site,
                     connects: (Pen) -> Bool = { _ in true }) -> [Pen] {
        var site = site
        var settled: Set<Int32> = []
        var pens: [Pen] = []
        for court in courts where !settled.contains(court.town) {
            var rng = SplitMix64(seed: seed ^ (UInt64(bitPattern: Int64(court.town)) &* 0xC520_35BF))
            let heading = rng.nextFloat(in: 0...(2 * .pi))
            if let pen = find(court: court, heading: heading, site: site, connects: connects) {
                settled.insert(court.town)
                pens.append(pen)
                site.reserved.insertFootprint(pen.outline)
                for bank in pen.banks {
                    for strip in strips(bank) { site.reserved.insertFootprint(strip) }
                }
                for walk in pen.access { site.reserved.insertFootprint(walk.outline) }
            }
        }
        return pens
    }

    private static func find(court: BronzeLayout.Court, heading: Float, site: Site,
                             connects: (Pen) -> Bool) -> Pen? {
        guard site.paths.covers(court.centre) else { return nil }
        for distance: Float in [12.5, 16.5, 21.0, 26.0] {
            for direction in 0..<16 {
                let angle = heading + Float(direction) * .pi / 8
                let inward = SIMD2(cos(angle), sin(angle))
                let gate = court.centre + inward * (distance / metres)
                if let pen = fit(court: court, gate: gate, inward: inward, site: site),
                   connects(pen) { return pen }
            }
        }
        return nil
    }

    private static func fit(court: BronzeLayout.Court, gate: SIMD2<Float>,
                            inward: SIMD2<Float>, site: Site) -> Pen? {
        let across = SIMD2(-inward.y, inward.x)
        func point(_ u: Float, _ v: Float) -> SIMD2<Float> {
            gate + across * (u / metres) + inward * (v / metres)
        }
        let penDepth: Float = 7.4
        let half: Float = 4.65
        let clearPad: Float = 0.78
        let outline = [point(-half - clearPad, -clearPad), point(half + clearPad, -clearPad),
                       point(half + clearPad, penDepth + clearPad), point(-half - clearPad, penDepth + clearPad)]
        guard site.ground.ground(gate) >= minimumElevation, site.clear(outline),
              !site.paths.intersectsFootprint(outline) else { return nil }
        var low = Float.infinity, high = -Float.infinity
        for v in 0...6 {
            for u in -4...4 {
                let p = point(Float(u) * half / 4, Float(v) * penDepth / 6)
                guard site.ground.dry(p) else { return nil }
                let height = site.ground.ground(p)
                low = min(low, height)
                high = max(high, height)
            }
        }
        guard high - low <= 1.65 / metres else { return nil }
        let left = gate - across * (clearGateWidth * 0.5)
        let right = gate + across * (clearGateWidth * 0.5)
        let boundary = [left, point(-half, 0), point(-half, penDepth),
                        point(half, penDepth), point(half, 0), right]
        guard gradeAllows(boundary, site: site) else { return nil }

        let landing = point(0, -2.35), inside = point(0, 1.8)
        let middle = (landing + court.centre) * 0.5
        let bend = across * (3.2 / metres)
        let approaches = [[court.centre, landing, inside], [court.centre, middle + bend, landing, inside],
                          [court.centre, middle - bend, landing, inside]]
        for route in approaches {
            let walks = zip(route, route.dropFirst()).map { BronzeLayout.Walk(a: $0.0, b: $0.1) }
            guard walks.allSatisfy({ site.ground.walkable($0) && site.clear($0.outline) }),
                  walks.dropLast().allSatisfy({ !intersects($0.outline, outline) }) else { continue }

            var banks = [boundary]
            // A short detached field division, with a grass break beside
            // the paddock. Keep the whole bank clear as the hillside turns.
            for side: Float in [1, -1] {
                let reave = [point(side * 6.4, 2.8), point(side * 7.8, 5.4), point(side * 9.25, 8.6)]
                let pads = strips(reave)
                if gradeAllows(reave, site: site), pads.allSatisfy({ pad in
                    site.clear(pad) && !site.paths.intersectsFootprint(pad)
                        && !walks.contains(where: { intersects(pad, $0.outline) })
                }) {
                    banks.append(reave)
                    break
                }
            }
            return Pen(town: court.town, court: court.centre, outline: outline,
                       banks: banks, gate: gate, inward: inward, access: walks)
        }
        return nil
    }

    private static func intersects(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>]) -> Bool {
        func vertices(_ points: [SIMD2<Float>]) -> [Vertex] {
            points.map { Vertex(position: SIMD3($0.x, 0, $0.y), normal: SIMD3(0, 1, 0), rgb: .zero) }
        }
        return abs(RiverPolygon.area(RiverGeometryChecks.intersection(vertices(a), vertices(b)))) > RiverPolygon.areaEpsilon
    }

    private static func gradeAllows(_ line: [SIMD2<Float>], site: Site) -> Bool {
        for (a, b) in zip(line, line.dropFirst()) {
            let samples = BronzeLayout.Walk(a: a, b: b).samples(step: 0.50 / metres)
            guard samples.allSatisfy(site.ground.dry), zip(samples, samples.dropFirst()).allSatisfy({
                abs(site.ground.ground($1) - site.ground.ground($0)) <= simd_distance($0, $1) * 0.32
            }) else { return false }
        }
        return true
    }

    private static func offsets(_ line: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let sides = zip(line, line.dropFirst()).map { a, b in
            let axis = simd_normalize(b - a)
            return SIMD2(-axis.y, axis.x) * bankHalfWidth
        }
        return line.indices.map { i in
            if i == 0 { return sides[0] }
            if i == line.count - 1 { return sides[i - 1] }
            // Keep the two adjoining trapezoids welded at the corner.
            let dot = simd_dot(sides[i - 1], sides[i]) / (bankHalfWidth * bankHalfWidth)
            return (sides[i - 1] + sides[i]) / (1 + dot)
        }
    }

    private static func strips(_ line: [SIMD2<Float>]) -> [[SIMD2<Float>]] {
        let side = offsets(line)
        return line.indices.dropLast().map { i in
            [line[i] - side[i], line[i + 1] - side[i + 1],
             line[i + 1] + side[i + 1], line[i] + side[i]]
        }
    }

    static func accessPatches(_ pen: Pen) -> [FieldSurface.GroundPatch] {
        pen.access.map { walk in
            FieldSurface.GroundPatch(outline: walk.outline, colour: accessColour,
                centre: walk.a, across: SIMD2(1, 0))
        }
    }

    static func mesh(_ pens: [Pen], seed: UInt64, ground: (SIMD2<Float>) -> Float) -> [Vertex] {
        var vertices: [Vertex] = []
        func xz(_ point: SIMD3<Float>) -> SIMD2<Float> { SIMD2(point.x, point.z) }

        func emit(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                  colour: SIMD3<Float>, outward: SIMD3<Float>) {
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            guard length > 0 else { return }
            let flip = simd_dot(cross, outward) < 0
            let normal = cross * (flip ? -1 / length : 1 / length)
            for p in [a, flip ? c : b, flip ? b : c] {
                vertices.append(Vertex(position: p, normal: normal, rgb: colour))
            }
        }
        for pen in pens {
            var rng = SplitMix64(seed: seed ^ (UInt64(bitPattern: Int64(pen.town)) &* 0xE7E2_115D))
            for (bank, line) in pen.banks.enumerated() {
                let side = offsets(line)
                var rows: [[SIMD3<Float>]] = []
                for i in line.indices.dropLast() {
                    let length = simd_distance(line[i], line[i + 1])
                    let count = Int(ceil(length / (0.68 / metres)))
                    for j in 0...count where i == 0 || j > 0 {
                        let t = Float(j) / Float(count)
                        let centre = line[i] + (line[i + 1] - line[i]) * t
                        let across = side[i] + (side[i + 1] - side[i]) * t
                        let crest = rng.nextFloat(in: 0.15...0.23)
                        let profile: [(Float, Float)] = [(-1, -0.14), (-0.76, 0.10), (-0.43, crest),
                            (0.45, crest - 0.025), (0.82, 0.09), (1, -0.14)]
                        let row = profile.map { shift, height -> SIMD3<Float> in
                            let p = centre + across * shift
                            return SIMD3(p.x, ground(p) + height / metres, p.y)
                        }
                        rows.append(row)
                    }
                }
                for (a, b) in zip(rows, rows.dropFirst()) {
                    let tone = rng.nextFloat(in: 0.84...1.12)
                    for j in a.indices.dropLast() {
                        let earth = SIMD3<Float>(0.27, 0.22, 0.15) * tone
                        let top = SIMD3<Float>(0, 1, 0)
                        emit(a[j], a[j + 1], b[j + 1], colour: earth, outward: top)
                        emit(a[j], b[j + 1], b[j], colour: earth, outward: top)
                    }

                    // Set individual, irregular slabs into the earth. Real
                    // joints and uneven crests read from overhead as well as
                    // from the gate. The stones stay inside the bank's toes.
                    let start = (xz(a[0]) + xz(a[5])) * 0.5
                    let end = (xz(b[0]) + xz(b[5])) * 0.5
                    let startSide = (xz(a[5]) - xz(a[0])) * 0.5
                    let endSide = (xz(b[5]) - xz(b[0])) * 0.5
                    let leading = rng.nextFloat(in: 0.04...0.19)
                    let trailing = rng.nextFloat(in: 0.77...0.95)
                    let shift = rng.nextFloat(in: -0.17...0.17)
                    let profile: [SIMD2<Float>] = [
                        SIMD2(leading, -0.32), SIMD2(leading + 0.11, -0.62), SIMD2(trailing - 0.11, -0.66),
                        SIMD2(trailing, -0.11), SIMD2(trailing - 0.13, 0.54), SIMD2(leading + 0.12, 0.52)
                    ]
                    let stoneCentre = (start + end) * 0.5
                    let height = rng.nextFloat(in: 0.30...0.53) * (bank == 0 ? 1 : 0.83)
                    let toneStone = rng.nextFloat(in: 0.76...1.22)
                    let rock = SIMD3<Float>(0.32, 0.31, 0.26) * toneStone
                    let base = profile.map { uv in
                        let side = startSide + (endSide - startSide) * uv.x
                        let p = start + (end - start) * uv.x + side * (uv.y + shift)
                        return SIMD3(p.x, ground(p) + 0.038 / metres, p.y)
                    }
                    let top = base.map { v -> SIMD3<Float> in
                        let p = stoneCentre + (xz(v) - stoneCentre) * 0.79
                        let relief = height + rng.nextFloat(in: -0.045...0.035)
                        return SIMD3(p.x, ground(p) + relief / metres, p.y)
                    }
                    for j in base.indices {
                        let k = (j + 1) % base.count
                        let side = (xz(base[j]) + xz(base[k])) * 0.5 - stoneCentre
                        let outward = SIMD3(side.x, 0, side.y)
                        emit(base[j], base[k], top[k], colour: rock, outward: outward)
                        emit(base[j], top[k], top[j], colour: rock, outward: outward)
                    }
                    for j in 1..<(top.count - 1) {
                        emit(top[0], top[j], top[j + 1], colour: rock, outward: SIMD3(0, 1, 0))
                    }
                }
                for (row, direction) in [(rows[0], line[0] - line[1]),
                    (rows[rows.count - 1], line[line.count - 1] - line[line.count - 2])] {
                    let out = SIMD3(direction.x, 0, direction.y)
                    for j in 1..<(row.count - 1) {
                        emit(row[0], row[j], row[j + 1], colour: SIMD3(0.27, 0.22, 0.15), outward: out)
                    }
                }
            }
        }
        return vertices
    }
}
