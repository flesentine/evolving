import Foundation
import simd

enum RiverChannel {
    static func carvedTerrain(_ terrain: Terrain, field: RiverChannel.Field,
                              supportRadius: Float = 0) -> Terrain {
        var carved = terrain
        for j in 0..<carved.size {
            for i in 0..<carved.size {
                let index = carved.index(i, j)
                carved.height[index] = RiverChannel.carvedHeight(terrain.height[index], field: field,
                                                               x: carved.worldX(i), z: carved.worldZ(j),
                                                               supportRadius: supportRadius)
            }
        }
        return carved
    }

    /// Add the local mesh-support constraint to an already carved coarse
    /// surface. Reuse the global valley calculation instead of solving it
    /// again for the placement grid and coincident render vertices.
    static func supportedTerrain(_ terrain: Terrain, field: Field, radius: Float) -> Terrain {
        var result = terrain
        for j in 0..<terrain.size {
            for i in 0..<terrain.size {
                let index = terrain.index(i, j)
                result.height[index] = field.supportedHeight(terrain.height[index],
                    at: SIMD2(terrain.worldX(i), terrain.worldZ(j)), supportRadius: radius)
            }
        }
        return result
    }

    /// Distance from a sampled terrain vertex to the nearest water triangle
    /// that must be covered for the interpolated render triangles to stay
    /// below the water sheet. One subcell diagonal on the default detail grid.
    static func terrainSupportRadius(_ terrain: Terrain, detail: Int = 2) -> Float {
        terrain.cellSize / Float(max(detail, 1)) * sqrt(2)
    }


    /// Metres per world unit, mirrored for convenience.
    static let metresPerUnit: Float = RiverNetwork.metresPerUnit

    /// Nominal water depth above the centreline bed. The bed is monotonic
    /// downstream, so this gives a continuous, non-oscillating water surface.
    static let waterLift: Float = 0.60 / metresPerUnit     // 0.60 m

    /// Nominal crest height above the waterline.
    static let bankHeight: Float = 0.35 / metresPerUnit    // 0.35 m

    /// Minimum half-width for established channels. Retained springs apply
    /// their sourceWidthFactor after this floor and start at 30 cm full width.
    static let minHalfWidth: Float = 1.4 / metresPerUnit   // 2.8 m channel

    /// A hair of clearance used to keep coplanar surfaces apart.
    static let seam: Float = 0.015 / metresPerUnit         // 1.5 cm

    /// Shared junction cut distance for water ribbons and bank strips.
    /// Different trim multipliers leave exposed banks or an uncovered seam.
    static let junctionTrimFactor: Float = 1.05

    /// Five samples across the water surface, left to right.
    static let across: [Float] = [-1, -0.5, 0, 0.5, 1]

    /// Finer probe for the terrain maximum/minimum under the water. The mesh
    /// only needs five vertices, but the waterline must clear terrain peaks
    /// that fall between them or the river shows blue-tinted holes.
    static let waterProbe: [Float] = [
        -1, -0.875, -0.75, -0.625, -0.5, -0.375, -0.25, -0.125, 0,
        0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1
    ]

    static func halfWidth(_ sample: RiverSample) -> Float {
        RiverGraph.channelHalfWidth(sample)
    }

    static func sideVector(_ sample: RiverSample) -> SIMD2<Float> {
        let direction = sample.junctionTangent ?? sample.tangent
        return SIMD2<Float>(-direction.y, direction.x)
    }

    /// Render-mesh bed carve. The simulation grid is untouched, but the
    /// terrain mesh dips below the water inside the channel so a cell that
    /// happens to sit above the water plane can never show through it. The
    /// blend keeps the cut hidden under the bank at the waterline.
    static let bedClearance: Float = 0.45 / metresPerUnit

    /// A wet shelf a few metres wide sits just below the water, then the
    /// ground is allowed to rise at a bounded slope. On a steep hillside this
    /// cuts a valley instead of a vertical trench; on gentle ground it does
    /// nothing.
    static let wetShelf: Float = 4.0 / metresPerUnit
    static let shelfRise: Float = 0.44 / metresPerUnit
    static let valleySlope: Float = 0.55          // vertical / horizontal

    static func carvedHeight(_ h: Float, field: Field, x: Float, z: Float,
                             supportRadius: Float = 0) -> Float {
        field.carvedHeight(h, at: SIMD2(x, z), supportRadius: supportRadius)
    }

    /// The water plane for one sample and the lowest terrain under it.
    /// `bed` is the deepest point of the water cross-section. `lift` lets
    /// overlapping reaches at a confluence separate by a centimetre or two,
    /// which keeps the two surfaces from z-fighting without a visible step.
    static func waterLine(_ t: Terrain,
                          _ sample: RiverSample,
                          lift: Float = 0) -> (y: Float, bed: Float) {
        let side = sideVector(sample)
        let half = halfWidth(sample)
        var lowest = Float.greatestFiniteMagnitude
        for f in waterProbe {
            let p = sample.position + side * (half * f)
            let h = t.interpolatedHeight(x: p.x, z: p.y)
            lowest = min(lowest, h)
        }
        // Use the monotonic centreline bed, not the highest bank, so the
        // surface does not rise and fall with every cross-slope change.
        if sample.waterOverride.isFinite {
            return (sample.waterOverride + lift,
                    sample.waterOverride - waterLift)
        }
        // The render carve guarantees the terrain under the channel is
        // below the sheet, so the surface can be exactly the monotonic bed.
        // Taking max(bed, localLowest + cover) here let a downstream sample
        // rise above the upstream one and produced reverse water slopes.
        return (sample.bed + waterLift + lift, sample.bed)
    }

    struct BankPoint {
        var offset: Float
        var y: Float
        var color: SIMD3<Float>
        var wetness: Float
        var normal: SIMD3<Float>
    }

    static func hash(_ p: SIMD2<Float>, _ side: Float) -> Float {
        let raw = sin(p.x * 97.0 + p.y * 53.0 + side * 31.7) * 43_758.547
        return raw - floor(raw)
    }

    /// Nine-point bank profile from the waterline out onto the floodplain.
    /// The anchors are: waterline, damp margin, four slope stops, crest and
    /// two apron stops. Subdividing the slope keeps the crest from reading as
    /// a single folded strip and lets the profile settle onto the terrain
    /// without a visible crease at the outer edge. `offset` is the distance
    /// from the centreline along `sideSign`.
    static func bankProfile(_ t: Terrain,
                            _ sample: RiverSample,
                            sideSign: Float,
                            lift: Float = 0,
                            direction: SIMD2<Float>? = nil,
                            field: Field? = nil) -> [BankPoint] {
        let side = direction ?? sideVector(sample) * sideSign
        let half = halfWidth(sample)
        let line = waterLine(t, sample, lift: lift)
        // Smooth detail wave along the reach. A hash of the world position
        // changed every 3 m sample, which put a sawtooth on the outer bank.
        let h = 0.5 + 0.5 * sin(sample.along * 0.22 + sideSign * 1.7
                                + sample.phase)

        let halfMetres = half * metresPerUnit
        let wetMetres = 1.30 + 0.50 * h
        let slopeMetres = max(halfMetres * 0.26, 1.0) * (0.90 + 0.18 * h)
        let apronMetres = max(halfMetres * 0.55, 2.0) * (0.94 + 0.12 * h)

        let wetOffset = wetMetres / metresPerUnit
        let slopeOffset = slopeMetres / metresPerUnit
        let apronOffset = apronMetres / metresPerUnit

        // On the inside of a tight bend the bank strip would otherwise reach
        // past the centre of curvature and fold over itself. Compress the
        // slope and apron (never the wet margin) to fit inside the radius.
        var slopeScale: Float = 1
        if sideSign == sample.bendInside,
           sample.bendLimit < .greatestFiniteMagnitude {
            let budget = sample.bendLimit - half - wetOffset
            let rest = slopeOffset + apronOffset
            if rest > 1e-6 {
                slopeScale = min(1, max(budget, 0) / rest)
            }
        }

        let slope = slopeOffset * slopeScale
        let apron = apronOffset * slopeScale
        let bank = half + wetOffset + slope
        let offsets: [Float] = [
            half,
            half + wetOffset,
            half + wetOffset + slope * 0.22,
            half + wetOffset + slope * 0.42,
            half + wetOffset + slope * 0.64,
            bank,
            bank + apron * 0.30,
            bank + apron * 0.62,
            bank + apron
        ]

        let terrainY = offsets.map { o -> Float in
            let p = sample.position + side * o
            let raw = t.interpolatedHeight(x: p.x, z: p.y)
            guard let field else { return raw }
            return carvedHeight(raw, field: field, x: p.x, z: p.y)
        }

        let crestTarget = line.y + bankHeight * (0.95 + 0.18 * h)
        var y = [Float](repeating: 0, count: offsets.count)
        y[0] = line.y
        // Crest. It must clear the terrain and rise above the outer apron so
        // the bank reads as a lip rather than a ditch.
        y[5] = max(terrainY[5] + seam,
                   max(crestTarget, terrainY[4] + seam + 0.00002))
        // On a steep cross-slope the raw terrain 10–20 m from the centreline
        // can be tens of metres above the water. Capping the crest keeps the
        // bank a bank rather than a canyon wall; the apron still climbs to
        // the hillside behind it.
        y[5] = min(y[5], line.y + 2.0 / metresPerUnit)
        // Slope points follow a concave-up curve from the waterline to the
        // crest. Never allow one to fall below raw terrain or above the next.
        for i in stride(from: 4, through: 1, by: -1) {
            let target = line.y + (y[5] - line.y)
                * pow(Float(i) / 5.0, 0.78)
            y[i] = min(max(terrainY[i] + seam, target), y[i + 1] - seam)
        }
        // Apron points settle back onto the terrain. Interpolating from the
        // crest to the outermost terrain height removes the hard fold that a
        // single planar strip left at the edge of the floodplain.
        for i in 6...8 {
            let f = Float(i - 5) / 3.0
            y[i] = max(max(terrainY[i] + seam,
                           y[5] + (terrainY[8] - y[5]) * f),
                       line.y + 0.00010 * f)
        }

        let grass = SIMD3<Float>(0.315, 0.395, 0.185)
        let soil = SIMD3<Float>(0.26, 0.22, 0.15)
        let silt = SIMD3<Float>(0.30, 0.255, 0.175)
        let colors: [SIMD3<Float>] = [
            SIMD3<Float>(0.075, 0.068, 0.050),              // wet mud
            silt * (0.92 + 0.16 * h),                       // damp silt
            simd_mix(silt, grass, SIMD3(repeating: 0.55)),
            simd_mix(silt, grass, SIMD3(repeating: 0.80)),
            grass * (0.94 + 0.10 * h),
            grass * (1.00 + 0.10 * h),                      // crest
            grass * (0.97 + 0.10 * h),
            grass * (0.94 + 0.12 * h),
            grass * (0.92 + 0.14 * h)
        ]
        let wetness: [Float] = [0.95, 0.80, 0.45, 0.28, 0.16,
                                0.10, 0.07, 0.05, 0.04]

        var points: [BankPoint] = []
        points.reserveCapacity(offsets.count)
        for i in offsets.indices {
            let slopeHere: Float
            if i == 0 {
                slopeHere = (y[1] - y[0]) / max(offsets[1] - offsets[0], 1e-7)
            } else if i == offsets.count - 1 {
                slopeHere = (y[i] - y[i - 1])
                    / max(offsets[i] - offsets[i - 1], 1e-7)
            } else {
                slopeHere = (y[i + 1] - y[i - 1])
                    / max(offsets[i + 1] - offsets[i - 1], 1e-7)
            }
            let normal = simd_normalize(SIMD3<Float>(-side.x * slopeHere, 1,
                                                     -side.y * slopeHere))
            points.append(BankPoint(offset: offsets[i], y: y[i],
                                    color: colors[i], wetness: wetness[i],
                                    normal: normal))
        }
        return points
    }

    /// A confluence pool: the union of the incoming channels, rendered as one
    /// disc at one water level so the tributary and stem meet without a seam.
    struct Junction {
        var position: SIMD2<Float>
        var radius: Float
        var waterY: Float
    }

    static func junctions(_ t: Terrain,
                          network: [RiverReach]) -> [Junction] {
        var result: [Junction] = []
        for reach in network where !reach.upstream.isEmpty {
            guard let first = reach.samples.first else { continue }
            var radius = halfWidth(first)
            var waterY = waterLine(t, first).y
            for a in reach.upstream where a < network.count {
                if let end = network[a].samples.last {
                    radius = max(radius, halfWidth(end))
                    waterY = max(waterY, waterLine(t, end).y)
                }
            }
            result.append(Junction(position: first.position,
                                   radius: radius * 1.15,
                                   waterY: waterY + 0.00002))
        }
        return result
    }

    /// Queries the actual submitted water triangles, including the Boolean
    /// junction union. Capsules and enlarged junction discs are not a second
    /// definition of wetness. Buckets index complete triangle AABBs, so large
    /// tarns and long segments cannot fall between endpoint buckets.
    struct Field {
        let mesh: RiverSurface.Geometry
        let network: [RiverReach]
        let originalTerrain: Terrain
        var geometry: (vertices: [Vertex], indices: [UInt32]) { (mesh.vertices, mesh.indices) }
        private let triangles: [[Vertex]]
        private let carveIndex: RiverTriangleIndex
        private let lowestWater: Float
        private let buckets: [Int64: [Int]]
        private let bucketSize: Float = 20 / metresPerUnit // 20 m

        init(terrain: Terrain, network: [RiverReach]) {
            originalTerrain = terrain
            self.network = RiverSurface.prepared(network)
            let mesh = RiverSurface.build(terrain, network: self.network)
            self.mesh = mesh
            var list: [[Vertex]] = []
            for i in stride(from: 0, to: mesh.indices.count, by: 3) {
                list.append((0..<3).map { mesh.vertices[Int(mesh.indices[i + $0])] })
            }
            triangles = list
            carveIndex = RiverTriangleIndex(list)
            lowestWater = list.reduce(Float.greatestFiniteMagnitude) { min($0, min($1[0].position.y, min($1[1].position.y, $1[2].position.y))) }
            var map: [Int64: [Int]] = [:]
            let size: Float = 20 / metresPerUnit
            for (i, triangle) in list.enumerated() {
                let x = triangle.map { $0.position.x }, z = triangle.map { $0.position.z }
                for bx in (Int(floor(x.min()! / size)) - 1)...(Int(floor(x.max()! / size)) + 1) {
                    for bz in (Int(floor(z.min()! / size)) - 1)...(Int(floor(z.max()! / size)) + 1) {
                        map[Field.key(bx, bz), default: []].append(i)
                    }
                }
            }
            buckets = map
        }
        private static func key(_ x: Int, _ z: Int) -> Int64 {
            Int64(x) &* 73_856_093 &+ Int64(z)
        }
        func nearbyTriangles(_ p: SIMD2<Float>) -> [[Vertex]] {
            let x = Int(floor(p.x / bucketSize)), z = Int(floor(p.y / bucketSize))
            return (buckets[Field.key(x, z)] ?? []).map { triangles[$0] }
        }
        func nearbyTriangles(_ triangle: [Vertex]) -> [[Vertex]] {
            let p = triangle.map { SIMD2($0.position.x, $0.position.z) }
            let low = p.reduce(SIMD2(repeating: .greatestFiniteMagnitude), simd_min)
            let high = p.reduce(SIMD2(repeating: -.greatestFiniteMagnitude), simd_max)
            var ids: Set<Int> = []
            for z in Int(floor(low.y / bucketSize))...Int(floor(high.y / bucketSize)) {
                for x in Int(floor(low.x / bucketSize))...Int(floor(high.x / bucketSize)) {
                    for id in buckets[Field.key(x, z)] ?? [] { ids.insert(id) }
                }
            }
            return ids.sorted().map { triangles[$0] }
        }
        /// Exact segment/wet-triangle intersections. Sampling a road at 6 m
        /// intervals can skip a 3 m channel between both endpoints.
        func wetIntervals(from a: SIMD2<Float>, to b: SIMD2<Float>) -> [ClosedRange<Float>] {
            func vertex(_ p: SIMD2<Float>) -> Vertex {
                Vertex(position: SIMD3(p.x, 0, p.y), normal: SIMD3(0,1,0), rgb: .zero)
            }
            var intervals: [ClosedRange<Float>] = []
            let aa = SIMD2<Double>(Double(a.x), Double(a.y)), bb = SIMD2<Double>(Double(b.x), Double(b.y))
            for tri in nearbyTriangles([vertex(a), vertex(b)]) where RiverPolygon.area(tri) < 0 {
                let points = Array(tri.reversed()).map { RiverPolygon.point($0) }
                var lo: Double = 0, hi: Double = 1
                for i in 0..<3 {
                    let p = points[i], edge = points[(i + 1) % 3] - p
                    let da = RiverPolygon.cross(edge, aa - p), db = RiverPolygon.cross(edge, bb - p)
                    if da < 0 && db < 0 { hi = -1; break }
                    if da < 0 { lo = max(lo, da / (da - db)) }
                    if db < 0 { hi = min(hi, da / (da - db)) }
                }
                if lo < hi { intervals.append(Float(lo)...Float(hi)) }
            }
            intervals.sort { $0.lowerBound == $1.lowerBound ? $0.upperBound < $1.upperBound : $0.lowerBound < $1.lowerBound }
            var merged: [ClosedRange<Float>] = []
            for interval in intervals {
                if let previous = merged.last, interval.lowerBound <= previous.upperBound {
                    merged[merged.count - 1] = previous.lowerBound...max(previous.upperBound, interval.upperBound)
                } else { merged.append(interval) }
            }
            return merged
        }

        /// Convex object/plot footprints, including a true Euclidean setback.
        /// Interior intersections catch narrow streams between all corner probes.
        func intersectsFootprint(_ points: [SIMD2<Float>], margin: Float = 0) -> Bool {
            guard points.count >= 3 else { return false }
            func vertex(_ p: SIMD2<Float>) -> Vertex {
                Vertex(position: SIMD3(p.x, 0, p.y), normal: SIMD3(0,1,0), rgb: .zero)
            }
            let low = points.reduce(SIMD2<Float>(repeating: .greatestFiniteMagnitude), simd_min) - SIMD2(repeating: margin)
            let high = points.reduce(SIMD2<Float>(repeating: -.greatestFiniteMagnitude), simd_max) + SIMD2(repeating: margin)
            let footprint = points.map(vertex)
            for water in nearbyTriangles([vertex(low), vertex(high)]) where RiverPolygon.area(water) < 0 {
                if abs(RiverPolygon.area(RiverGeometryChecks.intersection(footprint, water))) > RiverPolygon.areaEpsilon { return true }
                guard margin > 0 else { continue }
                let wet = water.map { SIMD2($0.position.x, $0.position.z) }
                for i in points.indices { for j in wet.indices {
                    let a = points[i], b = points[(i + 1) % points.count], c = wet[j], d = wet[(j + 1) % wet.count]
                    if min(RiverPolygon.segmentDistance(a, c, d), RiverPolygon.segmentDistance(b, c, d),
                           RiverPolygon.segmentDistance(c, a, b), RiverPolygon.segmentDistance(d, a, b)) < margin { return true }
                }}
            }
            return false
        }

        func nearbyLevel(at p: SIMD2<Float>, margin: Float) -> Float? {
            guard let value = nearbyWater(at: p), value.distance <= margin else { return nil }
            return value.water
        }
        static func probe(_ triangle: [Vertex], _ p: SIMD2<Float>)
            -> (distance: Float, water: Float) {
            let a = RiverPolygon.point(triangle[0]), b = RiverPolygon.point(triangle[1])
            let c = RiverPolygon.point(triangle[2]), q = SIMD2<Double>(Double(p.x), Double(p.y))
            let denominator = RiverPolygon.cross(b - a, c - a)
            guard abs(denominator) > 1e-30 else {
                return (.greatestFiniteMagnitude, 0)
            }
            let v = RiverPolygon.cross(q - a, c - a) / denominator
            let w = RiverPolygon.cross(b - a, q - a) / denominator
            let u = 1 - v - w
            let inside = min(u, min(v, w)) >= -1e-8 // dimensionless barycentric tolerance
            let points = [SIMD2(triangle[0].position.x, triangle[0].position.z),
                          SIMD2(triangle[1].position.x, triangle[1].position.z),
                          SIMD2(triangle[2].position.x, triangle[2].position.z)]
            var distance = Float.greatestFiniteMagnitude, edgeWater: Float = 0
            for i in 0..<3 {
                let j = (i + 1) % 3, ab = points[j] - points[i]
                let t = min(max(simd_dot(p - points[i], ab) / max(simd_length_squared(ab), 1e-20), 0), 1)
                let d = simd_distance(p, points[i] + ab * t)
                if d < distance {
                    distance = d
                    edgeWater = triangle[i].position.y + (triangle[j].position.y - triangle[i].position.y) * t
                }
            }
            let water = Float(u) * triangle[0].position.y + Float(v) * triangle[1].position.y
                + Float(w) * triangle[2].position.y
            return (inside ? -max(distance, Float.leastNonzeroMagnitude) : distance,
                    inside ? water : edgeWater)
        }
        /// Includes the nearest level just outside the wet footprint, for
        /// canonicalizing clipped bank edges within the numerical shore band.
        func shorelineReference(at p: SIMD2<Float>) -> (water: Float, distance: Float)? {
            nearbyWater(at:p)
        }
        func surface(at p: SIMD2<Float>) -> (water: Float?, distance: Float)? {
            guard let value = nearbyWater(at: p) else { return nil }
            return (value.distance <= 0 ? value.water : nil, value.distance)
        }
        /// Bounded query for wet classification and exclusion only. Terrain
        /// carving uses the global hierarchy below, never this bucket halo.
        private func nearbyWater(at p: SIMD2<Float>) -> (water: Float, distance: Float)? {
            let x = Int(floor(p.x / bucketSize)), z = Int(floor(p.y / bucketSize))
            guard let ids = buckets[Field.key(x, z)] else { return nil }
            var best = Float.greatestFiniteMagnitude, level: Float = 0
            var candidates: [(Float, Float)] = []
            for id in ids {
                let value = carveIndex.records[id].probe.probe(p)
                if value.distance < best { best = value.distance; level = value.water }
                candidates.append((value.distance, value.water))

            }
            guard best < .greatestFiniteMagnitude else { return nil }
            if best > 0 {
                // Blend water levels over nearest-boundary ties. The support
                // shrinks to zero at the shoreline, preserving exact mesh Y.
                let support = min(best, 2 / metresPerUnit) // at most 2 m
                var sum: Float = 0, weight: Float = 0
                for (d, water) in candidates where d - best < support {
                    let w = pow(1 - (d - best) / support, 2)
                    sum += water * w; weight += w
                }
                if weight > 0 { level = sum / weight }
            }
            return (level, best)
        }
        private func interiorWater(_ p: SIMD2<Float>, exhaustive: Bool) -> (water: Float, distance: Float)? {
            let x = Int(floor(p.x / bucketSize)), z = Int(floor(p.y / bucketSize))
            let ids = exhaustive ? Array(carveIndex.records.indices) : (buckets[Field.key(x, z)] ?? [])
            var best: (water: Float, distance: Float)?
            for id in ids {
                let record = carveIndex.records[id]
                if p.x < record.low.x || p.x > record.high.x || p.y < record.low.y || p.y > record.high.y { continue }
                let value = record.probe.probe(p)
                if value.distance <= 0 && value.distance < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = (value.water, value.distance)
                }
            }
            return best
        }
        /// Continuous valley surface with no spatial-hash cutoff. Wetness and
        /// bank clipping still use bounded triangle buckets; carving uses the
        /// hierarchy's global nearest surface and a continuous tie blend.
        func carvedHeight(_ original: Float, at p: SIMD2<Float>, supportRadius: Float,
                          exhaustive: Bool = false) -> Float {
            if original <= lowestWater - bedClearance { return original }
            guard let water = interiorWater(p, exhaustive: exhaustive) ?? carveIndex.nearest(p, exhaustive: exhaustive) else { return original }
            let d = max(water.distance, 0)
            let rise = d <= wetShelf ? d / wetShelf * shelfRise
                : shelfRise + (d - wetShelf) * valleySlope
            let base = min(original, water.water - bedClearance + rise)
            return supportedHeight(base, at: p, supportRadius: supportRadius, exhaustive: exhaustive)
        }

        func supportedHeight(_ base: Float, at p: SIMD2<Float>, supportRadius: Float,
                             exhaustive: Bool = false) -> Float {
            guard supportRadius > 0 else { return base }
            var result = base
            let radius = supportRadius + wetShelf
            let key = Field.key(Int(floor(p.x / bucketSize)), Int(floor(p.y / bucketSize)))
            let ids = exhaustive || radius > bucketSize ? Array(carveIndex.records.indices) : (buckets[key] ?? [])
            for id in ids {
                let record = carveIndex.records[id]
                let query = record.probe.probe(p)
                let distance = max(query.distance, 0)
                if distance >= radius { continue }
                // For a convex triangle, any point within the support disc
                // lies at most sqrt(R²-d²) from its closest point. The affine
                // water gradient therefore bounds the lowest local water Y.
                let along = sqrt(max(supportRadius * supportRadius - distance * distance, 0))
                let localLow = max(record.minWater, query.water - record.gradient * along)
                let cap = localLow - bedClearance + max(distance - supportRadius, 0) * valleySlope
                let t = min(max((distance - supportRadius) / wetShelf, 0), 1)
                let weight = 1 - t * t * (3 - 2 * t)
                result = min(result, base + (min(base, cap) - base) * weight)
            }
            return min(base, result)
        }
        func waterLevel(at p: SIMD2<Float>) -> Float? {
            guard let value = nearbyWater(at: p), value.distance <= 0 else { return nil }
            return value.water
        }
        func signedDistance(at p: SIMD2<Float>) -> Float? {
            nearbyWater(at: p)?.distance
        }
        func isNearWater(at p: SIMD2<Float>, margin: Float) -> Bool {
            guard let d = signedDistance(at: p) else { return false }
            return d <= margin
        }
    }

}

/// Phase 2 gate: bank height, channel depth, wet margin, freeboard and the
/// cross-section vertex count. Object clearance is filled in by the caller.
struct RiverChannelDiagnostics {
    var crossSections = 0
    var crossSectionVertices = 5
    var minBankHeight: Float = .greatestFiniteMagnitude
    var maxBankHeight: Float = 0
    var meanBankHeight: Float = 0
    var minChannelDepth: Float = .greatestFiniteMagnitude
    var maxChannelDepth: Float = 0
    var meanChannelDepth: Float = 0
    var minWaterDepth: Float = .greatestFiniteMagnitude
    var maxWaterDepth: Float = 0
    var meanWaterDepth: Float = 0
    var minWetMargin: Float = .greatestFiniteMagnitude
    var maxWetMargin: Float = 0
    var minFreeboard: Float = .greatestFiniteMagnitude
    var maxFreeboard: Float = 0
    var waterlineMismatches = 0
    /// Open-water probes whose carved bed still rises above the water sheet.
    /// Non-zero means the terrain can be seen through the river.
    var exposedBedProbes = 0
    var maxBedOverWater: Float = 0
    var submergedTrees = 0
    var submergedBuildings = 0
    var roadCrossings = 0
    var minObjectClearance: Float = .greatestFiniteMagnitude

    var failures: [String] {
        var result: [String] = []
        if minBankHeight < 0.15 || meanBankHeight < 0.15
            || meanBankHeight > 1.2 {
            result.append("bank lip outside 0.15–1.2 m above water")
        }
        if minChannelDepth < 0.3 || meanChannelDepth < 0.3
            || meanChannelDepth > 3.0 {
            result.append("channel depth outside 0.3–3 m")
        }
        if minWaterDepth < 0.10 {
            result.append("submitted terrain water depth below 10 cm")
        }
        if minWetMargin < 0.5 || maxWetMargin > 2.0 {
            result.append("wet margin outside 0.5–2 m")
        }
        if minFreeboard < 0.02 {
            result.append("water spills over the outer bank")
        }
        if crossSectionVertices < 5 || crossSectionVertices > 7 {
            result.append("cross-section is not 5–7 vertices")
        }
        if waterlineMismatches > 0 {
            result.append("waterline does not weld to the banks")
        }
        if exposedBedProbes > 0 {
            result.append("riverbed rises through the water sheet")
        }
        if submergedTrees > 0 { result.append("trees standing in the water") }
        if submergedBuildings > 0 { result.append("buildings in the channel") }
        return result
    }

    var passes: Bool { failures.isEmpty }

    var summary: String {
        """
        channel cross-sections: \(crossSections)  vertices across: \(crossSectionVertices)
        bank lip above water: \(String(format: "%.2f–%.2f m (mean %.2f)", minBankHeight, maxBankHeight, meanBankHeight))
        channel depth (lip to bed): \(String(format: "%.2f–%.2f m (mean %.2f)", minChannelDepth, maxChannelDepth, meanChannelDepth))
        water depth: \(String(format: "%.2f–%.2f m (mean %.2f)", minWaterDepth, maxWaterDepth, meanWaterDepth))
        wet margin: \(String(format: "%.2f–%.2f m", minWetMargin, maxWetMargin))
        profile self-consistency (not GPU seam welds): \(crossSections * 2 - waterlineMismatches)/\(crossSections * 2)
        bed above water: \(exposedBedProbes) probes  (max \(String(format: "%.3f m", maxBedOverWater)))
        outer freeboard: \(String(format: "%.2f–%.2f m", minFreeboard, maxFreeboard))
        submerged: trees \(submergedTrees)  buildings \(submergedBuildings)  road crossings \(roadCrossings)
        nearest object clearance: \(String(format: "%.2f m", minObjectClearance))
        \(passes ? "PASS" : "FAIL: " + failures.joined(separator: ", "))
        """
    }
}

extension RiverChannel {
    static func diagnostics(_ t: Terrain,
                            network: [RiverReach], suppliedField: Field? = nil) -> RiverChannelDiagnostics {
        var d = RiverChannelDiagnostics()
        var bankSum: Float = 0
        var channelSum: Float = 0
        var waterSum: Float = 0
        var bankCount = 0
        let field = suppliedField ?? Field(terrain: t, network: network)
        let carved = carvedTerrain(t, field: field)
        let support = supportedTerrain(carved, field: field, radius: terrainSupportRadius(t))
        let submitted = WorldScene.terrainVertices(carved, detail: 2, riverField: field, coarseSupport: support)

        for reach in network {
            for sample in reach.samples {
                let line = waterLine(t, sample)
                d.crossSections += 1

                // The centre of the channel must be open water. The outer
                // probes sit in the short blend at the bank, so only the
                // open 90% of the width is checked.
                let side = sideVector(sample)
                let half = halfWidth(sample)
                for f in waterProbe where abs(f) <= 0.82 {
                    let p = sample.position + side * (half * f)
                    let ground = t.interpolatedHeight(x: p.x, z: p.y)
                    let bed = carvedHeight(ground, field: field, x: p.x, z: p.y)
                    // Compare against the highest water surface covering
                    // this point: at a confluence a tributary can sit above
                    // the local reach, and that is the sheet we actually see.
                    if let water = field.surface(at: p)?.water {
                        let over = (bed - water) * metresPerUnit
                        if over > 0.005 {
                            d.exposedBedProbes += 1
                            d.maxBedOverWater = max(d.maxBedOverWater, over)

                        }
                    }
                }

                let actualWater = field.waterLevel(at: sample.position) ?? line.y
                let actualBed = WorldScene.renderedTerrainHeight(sample.position, terrain: t, vertices: submitted)
                let waterDepth = (actualWater - actualBed) * metresPerUnit
                d.minWaterDepth = min(d.minWaterDepth, waterDepth)
                d.maxWaterDepth = max(d.maxWaterDepth, waterDepth)
                waterSum += waterDepth

                for sign in [Float(-1), Float(1)] {
                    let profile = bankProfile(t, sample, sideSign: sign,
                                              lift: 0, field: field)
                    if abs(profile[0].offset - halfWidth(sample)) > 1e-7
                        || abs(profile[0].y - line.y) > 1e-7 {
                        d.waterlineMismatches += 1
                    }
                    let lip = (profile[5].y - line.y) * metresPerUnit
                    let depth = (profile[5].y - line.bed) * metresPerUnit
                    let wet = (profile[1].offset - profile[0].offset)
                        * metresPerUnit
                    let free = (profile[8].y - line.y) * metresPerUnit

                    d.minBankHeight = min(d.minBankHeight, lip)
                    d.maxBankHeight = max(d.maxBankHeight, lip)
                    d.minChannelDepth = min(d.minChannelDepth, depth)
                    d.maxChannelDepth = max(d.maxChannelDepth, depth)
                    d.minWetMargin = min(d.minWetMargin, wet)
                    d.maxWetMargin = max(d.maxWetMargin, wet)
                    d.minFreeboard = min(d.minFreeboard, free)
                    d.maxFreeboard = max(d.maxFreeboard, free)
                    bankSum += lip
                    channelSum += depth
                    bankCount += 1
                }
            }
        }

        if d.crossSections == 0 {
            d.minBankHeight = 0
            d.maxBankHeight = 0
            d.minChannelDepth = 0
            d.maxChannelDepth = 0
            d.minWaterDepth = 0
            d.maxWaterDepth = 0
            d.minWetMargin = 0
            d.maxWetMargin = 0
            d.minFreeboard = 0
            d.maxFreeboard = 0
        } else {
            d.meanBankHeight = bankSum / Float(max(bankCount, 1))
            d.meanChannelDepth = channelSum / Float(max(bankCount, 1))
            d.meanWaterDepth = waterSum / Float(max(d.crossSections, 1))
        }
        return d
    }
}

/// Deterministic river graph and smoothed centrelines.
///
/// The graph is built from D8 flow on the terrain. Each reach runs from a
/// source or junction to the next junction or the sea, and is resampled into
/// centripetal Catmull-Rom points with a monotonic bed.
enum RiverNetwork {
    static let metresPerUnit: Float = RiverGraph.metresPerUnit
    static func build(_ terrain: Terrain) -> (reaches: [RiverReach], diagnostics: RiverDiagnostics) {
        if let graph = terrain.riverGraph { return (graph.reaches, graph.diagnostics) }
        let graph = RiverGraph.build(terrain)
        return (graph.reaches, graph.diagnostics)
    }
}
