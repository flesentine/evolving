import Foundation
import simd

struct RiverSample {
    var position: SIMD2<Float>
    var bed: Float
    var width: Float
    var tangent: SIMD2<Float>
    /// Width used by the rendered channel. Equal to `width` on gentle ground,
    /// narrowed where the cross-slope is steep so a wide river never has to
    /// hang a water plane off a hillside.
    var channelWidth: Float = 0
    /// Longest bank offset that stays outside the local bend radius. A strip
    /// offset further than the radius folds through the centreline and shows
    /// up as a triangular wedge of land inside the water.
    var bendLimit: Float = .greatestFiniteMagnitude
    /// +1 where the bend turns left, -1 right. The inside of the bend is the
    /// side whose offsets have to be compressed.
    var bendInside: Float = 0
    /// Metres along the reach from its first sample, and a per-reach phase.
    /// Bank detail is driven by a smooth wave along this instead of a hash of
    /// the world position, which jittered every 3 m sample and left a sawtooth
    /// along the outer bank edge.
    var along: Float = 0
    var phase: Float = 0
    /// Shared water surface for a junction sample. NaN means "computed".
    var waterOverride: Float = .nan
    /// Terrain cell this sample came from, or -1 for a smoothing artefact.
    var cell: Int = -1
}

struct RiverReach {
    var id: Int
    var samples: [RiverSample]
    var upstream: [Int] = []
    var downstream: Int?
    var isSource = false
    var isMouth = false
    var firstCell = 0
    var lastCell = 0
}

struct RiverDiagnostics {
    var reaches = 0
    var sources = 0
    var junctions = 0
    var mouths = 0
    var minWidth: Float = 0
    var maxWidth: Float = 0
    var maxUphill: Float = 0
    var minCurvatureRadius: Float = .greatestFiniteMagnitude
    var maxTurnDegrees: Float = 0
    var selfIntersections = 0
    var maxJunctionAngle: Float = 0
    var maxSampleSpacing: Float = 0
    var linkedReaches = 0
    var maxLinkGap: Float = 0
    var inlandTerminalEnds = 0
    var maxJunctionWaterStep: Float = 0
    var maxParallelChannels = 0
    var maxWaterRise: Float = 0
    var graphIdentityOk = true

    var failures: [String] {
        var result: [String] = []
        if minWidth < 3 || maxWidth > 45 {
            result.append("width outside 3–45 m")
        }
        if maxUphill > 0.01 {
            result.append("uphill segment > 0.01 m")
        }
        if minCurvatureRadius < 0.5 {
            result.append("curvature radius < 0.5 m")
        }
        if maxTurnDegrees > 40 {
            result.append("adjacent turn > 40°")
        }
        if selfIntersections > 0 {
            result.append("reach self-intersection")
        }
        if maxParallelChannels > 14 {
            result.append("parallel channel runs (canal look)")
        }
        if !graphIdentityOk {
            result.append("drainage forest identity broken")
        }
        if maxWaterRise > 0.05 {
            result.append("water surface rises downstream")
        }
        if linkedReaches == 0 {
            result.append("no reach links to a downstream stem")
        }
        if maxLinkGap > 5 {
            result.append("reach end misses its downstream stem")
        }
        if inlandTerminalEnds * 10 > max(reaches, 1) * 3 {
            result.append("too many inland terminal tarns")
        }
        if maxJunctionWaterStep > 0.05 {
            result.append("water steps at a junction")
        }
        if maxJunctionAngle > 90 {
            result.append("junction angle > 90°")
        }
        if maxSampleSpacing > 5 {
            result.append("sample spacing > 5 m")
        }
        return result
    }

    var passes: Bool { failures.isEmpty }

    var summary: String {
        """
        reaches: \(reaches)  sources: \(sources)  junctions: \(junctions)  mouths: \(mouths)
        width: \(String(format: "%.1f–%.1f m", minWidth, maxWidth))
        max uphill: \(String(format: "%.3f m", maxUphill))
        min curvature radius: \(String(format: "%.1f m", minCurvatureRadius))
        max adjacent turn: \(String(format: "%.1f°", maxTurnDegrees))
        self-intersections: \(selfIntersections)
        max junction angle: \(String(format: "%.1f°", maxJunctionAngle))
        max sample spacing: \(String(format: "%.2f m", maxSampleSpacing))
        linked reaches: \(linkedReaches)  max link gap: \(String(format: "%.2f m", maxLinkGap))
        inland terminal ends: \(inlandTerminalEnds)  junction water step: \(String(format: "%.3f m", maxJunctionWaterStep))
        max parallel channels in a row: \(maxParallelChannels)
        water surface rise: \(String(format: "%.3f m", maxWaterRise))  graph identity: \(graphIdentityOk ? "OK" : "BROKEN")
        \(passes ? "PASS" : "FAIL: " + failures.joined(separator: ", "))
        """
    }
}

/// Phase 2 channel geometry, shared by the water mesh, the bank mesh and the
/// headless diagnostics. Keeping one definition of the waterline and the bank
/// profile is what stops the three from disagreeing by a few centimetres.
enum RiverChannel {
    /// Metres per world unit, mirrored for convenience.
    static let metresPerUnit: Float = RiverNetwork.metresPerUnit

    /// Nominal water depth above the centreline bed. The bed is monotonic
    /// downstream, so this gives a continuous, non-oscillating water surface.
    static let waterLift: Float = 0.60 / metresPerUnit     // 0.60 m

    /// Nominal crest height above the waterline.
    static let bankHeight: Float = 0.35 / metresPerUnit    // 0.35 m

    /// Minimum half-width so the narrowest source still has a visible channel.
    /// Sources taper down to this, so a headwater reads as a spring rather
    /// than a sawn-off canal.
    static let minHalfWidth: Float = 1.4 / metresPerUnit   // 2.8 m channel

    /// A hair of clearance used to keep coplanar surfaces apart.
    static let seam: Float = 0.015 / metresPerUnit         // 1.5 cm

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
        let width = sample.channelWidth > 0 ? sample.channelWidth : sample.width
        return max(width * 0.5, minHalfWidth)
    }

    static func sideVector(_ sample: RiverSample) -> SIMD2<Float> {
        SIMD2<Float>(-sample.tangent.y, sample.tangent.x)
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

    static func carvedHeight(_ h: Float, field: Field, x: Float, z: Float) -> Float {
        guard let s = field.carveWater(at: SIMD2(x, z)) else { return h }
        let d = s.distance
        if d <= 0 { return s.water - bedClearance }
        let allowed: Float
        if d <= wetShelf {
            allowed = s.water - bedClearance
                + (d / wetShelf) * shelfRise
        } else {
            allowed = s.water - (bedClearance - shelfRise)
                + (d - wetShelf) * valleySlope
        }
        return min(h, allowed)
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

    /// A swept-capsule query used for carving and object clipping. Each entry
    /// is the segment between two consecutive samples, with width and water
    /// level interpolated along it. Segment distance is smooth, so the carve
    /// no longer follows a chain of scalloped circles.
    struct Field {
        struct Entry {
            var a: SIMD2<Float>
            var b: SIMD2<Float>
            var halfA: Float
            var halfB: Float
            var waterA: Float
            var waterB: Float
        }

        private let entries: [Entry]
        private let buckets: [Int64: [Int]]
        private let bucketSize: Float = 0.02

        init(terrain: Terrain, network: [RiverReach]) {
            var list: [Entry] = []
            for reach in network {
                let samples = reach.samples
                if samples.count == 1 {
                    let s = samples[0]
                    let h = halfWidth(s)
                    let w = waterLine(terrain, s).y
                    list.append(Entry(a: s.position, b: s.position,
                                      halfA: h, halfB: h,
                                      waterA: w, waterB: w))
                }
                if samples.count >= 2 {
                    for i in 0..<(samples.count - 1) {
                        let a = samples[i], b = samples[i + 1]
                        list.append(Entry(a: a.position, b: b.position,
                                          halfA: halfWidth(a),
                                          halfB: halfWidth(b),
                                          waterA: waterLine(terrain, a).y,
                                          waterB: waterLine(terrain, b).y))
                    }
                }
            }
            for reach in network where !reach.upstream.isEmpty {
                guard let first = reach.samples.first else { continue }
                var radius = halfWidth(first)
                var level = waterLine(terrain, first).y
                for a in reach.upstream where a < network.count {
                    if let end = network[a].samples.last {
                        radius = max(radius, halfWidth(end))
                        level = max(level, waterLine(terrain, end).y)
                    }
                }
                list.append(Entry(a: first.position, b: first.position,
                                  halfA: radius * 1.30, halfB: radius * 1.30,
                                  waterA: level, waterB: level))
            }
            // Closed-basin ends get a small lake disc rather than a
            // rounded ribbon cap.
            for reach in network where reach.downstream == nil
                && !reach.isMouth {
                guard let last = reach.samples.last else { continue }
                let radius = halfWidth(last) * 2.5
                let level = waterLine(terrain, last).y
                list.append(Entry(a: last.position, b: last.position,
                                  halfA: radius, halfB: radius,
                                  waterA: level, waterB: level))
            }
            entries = list
            var map: [Int64: [Int]] = [:]
            for (i, entry) in list.enumerated() {
                map[Field.key(entry.a), default: []].append(i)
                map[Field.key(entry.b), default: []].append(i)
            }
            buckets = map
        }

        private static func key(_ p: SIMD2<Float>) -> Int64 {
            let x = Int64(floor(p.x / 0.02))
            let y = Int64(floor(p.y / 0.02))
            return x &* 73_856_093 &+ y
        }

        private func closest(_ e: Entry, _ p: SIMD2<Float>)
            -> (distance: Float, half: Float, water: Float) {
            let ab = e.b - e.a
            let length2 = simd_dot(ab, ab)
            var t: Float = 0
            if length2 > 1e-12 {
                t = min(max(simd_dot(p - e.a, ab) / length2, 0), 1)
            }
            let q = e.a + ab * t
            let half = e.halfA + (e.halfB - e.halfA) * t
            let water = e.waterA + (e.waterB - e.waterA) * t
            return (simd_distance(q, p) - half, half, water)
        }

        private func nearby(_ p: SIMD2<Float>, _ body: (Entry) -> Void) {
            let baseX = Int64(floor(p.x / bucketSize))
            let baseY = Int64(floor(p.y / bucketSize))
            for dx in -1...1 {
                for dy in -1...1 {
                    let key = (baseX + Int64(dx)) &* 73_856_093
                        &+ (baseY + Int64(dy))
                    guard let list = buckets[key] else { continue }
                    for i in list { body(entries[i]) }
                }
            }
        }

        func surface(at p: SIMD2<Float>) -> (water: Float?, distance: Float)? {
            var water: Float?
            var best = Float.greatestFiniteMagnitude
            nearby(p) { entry in
                let c = closest(entry, p)
                best = min(best, c.distance)
                if c.distance <= 0 {
                    water = max(water ?? -Float.greatestFiniteMagnitude,
                                c.water)
                }
            }
            guard best < .greatestFiniteMagnitude else { return nil }
            return (water, best)
        }

        func carveWater(at p: SIMD2<Float>) -> (water: Float, distance: Float)? {
            var best = Float.greatestFiniteMagnitude
            var bestWater: Float = 0
            nearby(p) { entry in
                let c = closest(entry, p)
                if c.distance < best {
                    best = c.distance
                    bestWater = c.water
                } else if c.distance <= 0 {
                    bestWater = max(bestWater, c.water)
                }
            }
            guard best < .greatestFiniteMagnitude else { return nil }
            return (bestWater, best)
        }

        func waterLevel(at p: SIMD2<Float>) -> Float? {
            var best: Float?
            nearby(p) { entry in
                let c = closest(entry, p)
                if c.distance <= 0 {
                    best = max(best ?? -Float.greatestFiniteMagnitude, c.water)
                }
            }
            return best
        }

        func signedDistance(at p: SIMD2<Float>) -> Float? {
            var best = Float.greatestFiniteMagnitude
            nearby(p) { entry in
                best = min(best, closest(entry, p).distance)
            }
            return best == .greatestFiniteMagnitude ? nil : best
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
        if minWaterDepth < 0.10 || meanWaterDepth > 3.0 {
            result.append("water depth outside 0.1–3 m")
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
        waterline welds: \(crossSections * 2 - waterlineMismatches)/\(crossSections * 2)
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
                            network: [RiverReach]) -> RiverChannelDiagnostics {
        var d = RiverChannelDiagnostics()
        var bankSum: Float = 0
        var channelSum: Float = 0
        var waterSum: Float = 0
        var bankCount = 0
        let field = Field(terrain: t, network: network)

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

                let waterDepth = (line.y - line.bed) * metresPerUnit
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
    /// Metres per world unit (the island is about 20 km across in 2 units).
    static let metresPerUnit: Float = 1_000

    static func build(_ terrain: Terrain) -> (reaches: [RiverReach],
                                             diagnostics: RiverDiagnostics) {
        let n = terrain.size
        let count = n * n
        let dirs: [(Int, Int)] = [
            (1, 0), (-1, 0), (0, 1), (0, -1),
            (1, 1), (1, -1), (-1, 1), (-1, -1)
        ]

        // Routing surface. Each pass uses true slope (gradient, not raw
        // elevation) and a topological accumulation, so diagonal neighbours
        // are not penalised and the contributing area belongs to the final
        // receiver graph rather than a stale sorting order.
        let land = (0..<count).filter { terrain.height[$0] > 0.004 }
        var route = terrain.height
        var routeDown = [Int](repeating: -1, count: count)
        var routeArea = [Float](repeating: 0, count: count)

        func steepestDown(on surface: [Float],
                          into receivers: inout [Int]) {
            for j in 0..<n {
                for i in 0..<n {
                    let idx = terrain.index(i, j)
                    guard surface[idx] > 0.004 else {
                        receivers[idx] = -1
                        continue
                    }
                    var best = -1
                    var bestSlope: Float = 0
                    for (di, dj) in dirs {
                        let ni = i + di, nj = j + dj
                        guard ni >= 0, ni < n, nj >= 0, nj < n else { continue }
                        let nIdx = nj * n + ni
                        let distance: Float = (di != 0 && dj != 0)
                            ? 1.41421356 : 1
                        let slope = (surface[idx] - surface[nIdx]) / distance
                        if slope > bestSlope + 1e-7 {
                            bestSlope = slope
                            best = nIdx
                        }
                    }
                    receivers[idx] = best
                }
            }
        }

        func topologicalArea(receivers: [Int]) -> (area: [Float], order: [Int]) {
            var pending = [Int](repeating: 0, count: count)
            for idx in land where receivers[idx] >= 0 {
                pending[receivers[idx]] += 1
            }
            var area = [Float](repeating: 0, count: count)
            for idx in land { area[idx] = 1 }
            var queue: [Int] = []
            queue.reserveCapacity(land.count)
            for idx in land where pending[idx] == 0 { queue.append(idx) }
            var order: [Int] = []
            order.reserveCapacity(land.count)
            var head = 0
            while head < queue.count {
                let idx = queue[head]
                head += 1
                order.append(idx)
                let down = receivers[idx]
                if down >= 0 {
                    area[down] += area[idx]
                    pending[down] -= 1
                    if pending[down] == 0 { queue.append(down) }
                }
            }
            return (area, order)
        }

        for _ in 0..<3 {
            steepestDown(on: route, into: &routeDown)
            (routeArea, _) = topologicalArea(receivers: routeDown)
            for idx in land where routeArea[idx] > 250 {
                route[idx] -= 0.00012
                let i = idx % n, j = idx / n
                for (di, dj) in dirs {
                    let ni = i + di, nj = j + dj
                    guard ni >= 0, ni < n, nj >= 0, nj < n else { continue }
                    route[nj * n + ni] -= 0.00003
                }
            }
        }

        // Drainage routing on a depressionless fill. The D8 mask alone leaves
        // many short channels stranded in local basins: a river cell with no
        // lower *river* neighbour simply ends. A priority flood from the sea
        // gives every cell a spill level and a pop order; D8 on (filled, order)
        // is acyclic and always reaches the sea, so traces never stop inland.
        var filled = route
        var popOrder = [Int](repeating: -1, count: count)
        var parent = [Int](repeating: -1, count: count)
        var seen = [Bool](repeating: false, count: count)
        var heap = FloodHeap()
        heap.reserve(count)
        var insertion = 0

        func seed(_ idx: Int, _ level: Float) {
            guard !seen[idx] else { return }
            seen[idx] = true
            filled[idx] = max(terrain.height[idx], level)
            heap.push(FloodNode(level: filled[idx], order: insertion,
                                index: idx))
            insertion += 1
        }

        for idx in 0..<count where route[idx] <= 0.004 {
            seed(idx, 0.002)
        }
        for i in 0..<n {
            seed(terrain.index(i, 0), route[terrain.index(i, 0)])
            seed(terrain.index(i, n - 1), route[terrain.index(i, n - 1)])
            seed(terrain.index(0, i), route[terrain.index(0, i)])
            seed(terrain.index(n - 1, i), route[terrain.index(n - 1, i)])
        }

        var popped = 0
        while let node = heap.pop() {
            popOrder[node.index] = popped
            popped += 1
            let i = node.index % n
            let j = node.index / n
            for (di, dj) in dirs {
                let ni = i + di, nj = j + dj
                guard ni >= 0, ni < n, nj >= 0, nj < n else { continue }
                let nIdx = nj * n + ni
                guard !seen[nIdx] else { continue }
                seen[nIdx] = true
                parent[nIdx] = node.index
                filled[nIdx] = max(route[nIdx], node.level + 1e-6)
                heap.push(FloodNode(level: filled[nIdx], order: insertion,
                                    index: nIdx))
                insertion += 1
            }
        }

        var down = [Int](repeating: -1, count: count)
        steepestDown(on: route, into: &down)

        // Mark every cell whose steepest path already reaches the sea, then
        // give each true sink one spill along the priority-flood parent tree.
        // One spill per sink keeps the network connected without a fan of
        // parallel channels.
        var settled = [Bool](repeating: false, count: count)
        let byHeight = (0..<count).sorted {
            terrain.height[$0] < terrain.height[$1]
        }
        for idx in byHeight {
            if route[idx] <= 0.004 {
                settled[idx] = true
            } else if down[idx] >= 0 {
                settled[idx] = settled[down[idx]]
            }
        }
        var spillCell = [Bool](repeating: false, count: count)
        for idx in 0..<count where down[idx] < 0
            && route[idx] > 0.004 {
            var cursor = idx
            while cursor >= 0 && !settled[cursor] && parent[cursor] >= 0 {
                down[cursor] = parent[cursor]
                spillCell[cursor] = true
                settled[cursor] = true
                cursor = parent[cursor]
            }
            if cursor >= 0 && parent[cursor] < 0 {
                settled[cursor] = true
            }
        }

        // One authority: accumulate area on the final receiver graph, then
        // derive the channel mask and widths from that area.
        let (finalArea, _) = topologicalArea(receivers: down)
        var isRiver = [Bool](repeating: false, count: count)
        var flow = [Float](repeating: 0, count: count)
        for idx in land where finalArea[idx] > 1200 {
            isRiver[idx] = true
            flow[idx] = finalArea[idx]
        }
        var channel = isRiver
        for idx in 0..<count where spillCell[idx] {
            channel[idx] = true
        }

        var channelIndegree = [Int](repeating: 0, count: count)
        for idx in 0..<count where down[idx] >= 0 && channel[idx] {
            channelIndegree[down[idx]] += 1
        }

        func isMajorJunction(_ idx: Int) -> Bool {
            var first: Float = 0
            var second: Float = 0
            let i = idx % n
            let j = idx / n
            for (di, dj) in dirs {
                let ni = i + di, nj = j + dj
                guard ni >= 0, ni < n, nj >= 0, nj < n else { continue }
                let nIdx = nj * n + ni
                guard channel[nIdx] && down[nIdx] == idx else { continue }
                let f = finalArea[nIdx]
                if f > first { second = first; first = f }
                else if f > second { second = f }
            }
            return second >= 30
        }

        func widthForFlow(_ value: Float) -> Float {
            // The render mask starts at flow 900, much higher than the
            // simulation's river threshold. A navigable-river width formula
            // gave every first-order stream 30–45 m, so neighbouring ribbons
            // merged into a lake. Scale with the actual discharge.
            let metres = 1.5 + 0.12 * sqrt(max(value, 1))
            return min(max(metres, 3), 45) / metresPerUnit
        }

        var reaches: [RiverReach] = []
        var nextID = 0

        // Split the drainage tree into reaches between graph nodes: a reach
        // starts at a source or junction and stops at the next junction or the
        // sea. Tributaries therefore meet the stem at a shared cell instead of
        // running along its interior, so their water polygons do not overlap.
        func trace(from start: Int) -> [Int]? {
            var cells: [Int] = [start]
            var cursor = down[start]
            while cursor >= 0 && cells.count < 1200 {
                cells.append(cursor)
                if channelIndegree[cursor] != 1 { break }
                cursor = down[cursor]
            }
            return cells.count >= 2 ? cells : nil
        }

        var starts: [Int] = []
        for idx in 0..<count where channel[idx] && down[idx] >= 0
            && channelIndegree[idx] != 1 {
            starts.append(idx)
        }
        // Thin first-order sources: on a smooth slope the D8 tree makes
        // many near-parallel headwaters. Keep the strongest source in each
        // 80 m neighbourhood so the rendered network has a few trunks
        // instead of a sheet of channels.
        let sourceStarts = starts.filter { channelIndegree[$0] == 0 }
        let junctionStarts = starts.filter { channelIndegree[$0] != 0 }
        var keptSources: [Int] = []
        for s in sourceStarts.sorted(by: { flow[$0] > flow[$1] }) {
            let p = SIMD2<Float>(terrain.worldX(s % n), terrain.worldZ(s / n))
            let clear = keptSources.allSatisfy {
                let q = SIMD2<Float>(terrain.worldX($0 % n),
                                     terrain.worldZ($0 / n))
                return simd_distance(p, q) > 180 / metresPerUnit
            }
            if clear { keptSources.append(s) }
        }
        starts = keptSources + junctionStarts
        for start in starts {
            guard let cells = trace(from: start) else { continue }
            reaches.append(makeReach(id: nextID, cells: cells, n: n,
                                     terrain: terrain, flow: flow,
                                     widthForFlow: widthForFlow,
                                     isSource: channelIndegree[cells.first!] == 0,
                                     isMouth: down[cells.last!] < 0))
            nextID += 1
        }

        // A reach ends at the next junction's cell, which is the first cell
        // of exactly one downstream reach. Link by the start point.
        for a in reaches.indices {
            guard !reaches[a].isMouth, let end = reaches[a].samples.last else {
                continue
            }
            // The downstream reach starts on the same cell; use the cell id
            // first, then fall back to the nearest start position.
            var best = reaches.firstIndex {
                $0.id != reaches[a].id && $0.firstCell == reaches[a].lastCell
            }
            if best == nil {
                var bestDistance = 5 / metresPerUnit
                for b in reaches.indices where b != a {
                    guard let start = reaches[b].samples.first else { continue }
                    let d = simd_distance(end.position, start.position)
                    if d < bestDistance {
                        bestDistance = d
                        best = b
                    }
                }
            }
            if let best {
                reaches[a].downstream = best
                reaches[best].upstream.append(a)
            }
        }

        // Upstream-first reach order for the connected water profile.
        var pendingUp = [Int](repeating: 0, count: reaches.count)
        for i in reaches.indices {
            if let d = reaches[i].downstream { pendingUp[d] += 1 }
        }
        var reachQueue = reaches.indices.filter { pendingUp[$0] == 0 }
        var upstreamFirst: [Int] = []
        upstreamFirst.reserveCapacity(reaches.count)
        var reachHead = 0
        while reachHead < reachQueue.count {
            let i = reachQueue[reachHead]
            reachHead += 1
            upstreamFirst.append(i)
            if let d = reaches[i].downstream {
                pendingUp[d] -= 1
                if pendingUp[d] == 0 { reachQueue.append(d) }
            }
        }
        if upstreamFirst.count < reaches.count {
            var seenReach = [Bool](repeating: false, count: reaches.count)
            for i in upstreamFirst { seenReach[i] = true }
            for i in reaches.indices where !seenReach[i] {
                upstreamFirst.append(i)
            }
        }

        // Centreline bed. A cross-section low depends on the sample's
        // tangent, so the two reaches at a shared junction cell could differ
        // by tens of metres on a steep hillside. The shared cell must have
        // one bed, so use the terrain at the centreline point.
        for r in reaches.indices {
            for i in reaches[r].samples.indices {
                let p = reaches[r].samples[i].position
                reaches[r].samples[i].bed =
                    terrain.interpolatedHeight(x: p.x, z: p.y)
            }
        }

        // One connected water profile. Start with a local running minimum
        // per reach, then repeatedly lower each junction to the lowest
        // incident end and re-solve the stem. Levels only fall, so this
        // converges and is independent of reach ordering.
        for r in reaches.indices {
            guard !reaches[r].samples.isEmpty else { continue }
            var level = reaches[r].samples[0].bed + RiverChannel.waterLift
            for i in reaches[r].samples.indices {
                level = min(level,
                            reaches[r].samples[i].bed + RiverChannel.waterLift)
                reaches[r].samples[i].waterOverride = level
            }
        }
        for _ in 0..<64 {
            var changed = false
            for d in reaches.indices where !reaches[d].upstream.isEmpty {
                guard let first = reaches[d].samples.first else { continue }
                var level = first.waterOverride
                for a in reaches[d].upstream {
                    if let end = reaches[a].samples.last {
                        level = min(level, end.waterOverride)
                    }
                }
                if first.waterOverride > level + 1e-7 {
                    reaches[d].samples[0].waterOverride = level
                    changed = true
                }
                var running = level
                for i in reaches[d].samples.indices {
                    running = min(running,
                                  reaches[d].samples[i].bed
                                    + RiverChannel.waterLift)
                    if reaches[d].samples[i].waterOverride
                        > running + 1e-7 {
                        reaches[d].samples[i].waterOverride = running
                        changed = true
                    } else {
                        running = reaches[d].samples[i].waterOverride
                    }
                }
                for a in reaches[d].upstream where !reaches[a].samples.isEmpty {
                    let i = reaches[a].samples.count - 1
                    if reaches[a].samples[i].waterOverride
                        > level + 1e-7 {
                        reaches[a].samples[i].waterOverride = level
                        changed = true
                    }
                }
            }
            if !changed { break }
        }

        // Canal artefact metric: the greatest number of separate channel
        // runs inside a 64-cell (~250 m) span of one row. Counting a whole
        // row includes unrelated tributaries; the window measures adjacent
        // parallel lines, which is what reads as irrigation canals.
        var drawn = [Bool](repeating: false, count: count)
        for reach in reaches {
            for sample in reach.samples where sample.cell >= 0 {
                drawn[sample.cell] = true
            }
        }
        var maxParallel = 0
        let window = 64
        for j in 0..<n {
            var starts: [Int] = []
            var inRun = false
            for i in 0..<n {
                let wet = drawn[j * n + i]
                if wet && !inRun { starts.append(i) }
                inRun = wet
            }
            var right = 0
            for left in starts.indices {
                if right < left { right = left }
                while right < starts.count
                    && starts[right] < starts[left] + window {
                    right += 1
                }
                maxParallel = max(maxParallel, right - left)
            }
        }

        var diagnostics = RiverDiagnostics()
        diagnostics.reaches = reaches.count
        diagnostics.maxParallelChannels = maxParallel
        diagnostics.sources = reaches.filter { $0.upstream.isEmpty }.count
        diagnostics.mouths = reaches.filter { $0.isMouth }.count
        diagnostics.junctions = reaches.filter { $0.upstream.count >= 2 }.count
        for a in reaches.indices {
            guard let end = reaches[a].samples.last else { continue }
            if reaches[a].downstream == nil,
               terrain.interpolatedHeight(x: end.position.x,
                                          z: end.position.y) > 0.004 {
                let i = terrain.cellX(end.position.x)
                let j = terrain.cellZ(end.position.y)
                let onEdge = i <= 0 || i >= n - 1 || j <= 0 || j >= n - 1
                if !onEdge { diagnostics.inlandTerminalEnds += 1 }
            }
            guard let downstream = reaches[a].downstream,
                  let start = reaches[downstream].samples.first else { continue }
            var gap = Float.greatestFiniteMagnitude
            for sample in reaches[downstream].samples {
                gap = min(gap, simd_distance(end.position, sample.position))
            }
            diagnostics.linkedReaches += 1
            diagnostics.maxLinkGap = max(diagnostics.maxLinkGap,
                                         gap * metresPerUnit)
            let step = abs(RiverChannel.waterLine(terrain, end).y
                           - RiverChannel.waterLine(terrain, start).y)
                * metresPerUnit
            diagnostics.maxJunctionWaterStep = max(
                diagnostics.maxJunctionWaterStep, step)
        }
        let incomingEdges = reaches.reduce(0) { $0 + $1.upstream.count }
        let outlets = reaches.filter { $0.downstream == nil }.count
        let graphSources = reaches.filter { $0.upstream.isEmpty }.count
        let junctionExcess = reaches.filter { !$0.upstream.isEmpty }
            .reduce(0) { $0 + $1.upstream.count - 1 }
        // Directed-forest identity: sources = outlets + sum(indegree - 1).
        diagnostics.graphIdentityOk =
            graphSources == outlets + junctionExcess
            && incomingEdges == reaches.count - outlets


        for reach in reaches {
            for i in 1..<reach.samples.count {
                let rise = RiverChannel.waterLine(terrain, reach.samples[i]).y
                    - RiverChannel.waterLine(terrain, reach.samples[i - 1]).y
                if rise * metresPerUnit > diagnostics.maxWaterRise {
                    diagnostics.maxWaterRise = rise * metresPerUnit
                }
            }
        }

        diagnostics.minWidth = (reaches.flatMap { $0.samples }.map(\.width).min() ?? 0)
            * metresPerUnit
        diagnostics.maxWidth = (reaches.flatMap { $0.samples }.map(\.width).max() ?? 0)
            * metresPerUnit

        for reach in reaches {
            for i in 1..<reach.samples.count {
                let a = reach.samples[i - 1]
                let b = reach.samples[i]
                diagnostics.maxUphill = max(diagnostics.maxUphill, b.bed - a.bed)
                diagnostics.maxSampleSpacing = max(
                    diagnostics.maxSampleSpacing,
                    simd_distance(a.position, b.position) * metresPerUnit)
            }
            for i in 1..<(reach.samples.count - 1) {
                let a = reach.samples[i - 1].position
                let b = reach.samples[i].position
                let c = reach.samples[i + 1].position
                let v0 = b - a
                let v1 = c - b
                let ab = simd_length(v0)
                let bc = simd_length(v1)
                if ab > 1e-6 && bc > 1e-6 {
                    let dot = min(max(simd_dot(simd_normalize(v0),
                                               simd_normalize(v1)), -1), 1)
                    let angle = acos(dot)
                    let radius = (0.5 * (ab + bc)) / max(sin(angle * 0.5), 1e-5)
                    diagnostics.minCurvatureRadius = min(
                        diagnostics.minCurvatureRadius,
                        radius * metresPerUnit)
                }
                let t0 = reach.samples[i - 1].tangent
                let t1 = reach.samples[i].tangent
                let dot = min(max(simd_dot(t0, t1), -1), 1)
                diagnostics.maxTurnDegrees = max(
                    diagnostics.maxTurnDegrees,
                    acos(dot) * 180 / .pi)
            }
            diagnostics.selfIntersections += selfIntersections(reach.samples)
            // Junction angle is measured on the D8 cells below; a reach
            // merges into the interior of a longer stem, so comparing its end
            // tangent with the stem's first tangent would report nonsense.
        }
        for idx in 0..<count where channel[idx] && isMajorJunction(idx) {
            let i = idx % n, j = idx / n
            var incoming = SIMD2<Float>(repeating: 0)
            for (di, dj) in dirs {
                let ni = i + di, nj = j + dj
                guard ni >= 0, ni < n, nj >= 0, nj < n else { continue }
                let nIdx = nj * n + ni
                if channel[nIdx] && down[nIdx] == idx {
                    incoming += SIMD2<Float>(Float(i - ni), Float(j - nj))
                }
            }
            let outIdx = down[idx]
            if outIdx >= 0, simd_length(incoming) > 1e-6 {
                let outgoing = SIMD2<Float>(Float(outIdx % n - i),
                                            Float(outIdx / n - j))
                let a = simd_normalize(incoming)
                let b = simd_normalize(outgoing)
                let dot = min(max(simd_dot(a, b), -1), 1)
                diagnostics.maxJunctionAngle = max(
                    diagnostics.maxJunctionAngle,
                    acos(dot) * 180 / .pi)
            }
        }
        if diagnostics.minCurvatureRadius == .greatestFiniteMagnitude {
            diagnostics.minCurvatureRadius = 10_000
        }
        return (reaches, diagnostics)
    }

    private static func makeReach(id: Int,
                                  cells: [Int],
                                  n: Int,
                                  terrain: Terrain,
                                  flow: [Float],
                                  widthForFlow: (Float) -> Float,
                                  isSource: Bool,
                                  isMouth: Bool) -> RiverReach {
        let raw = cells.map { SIMD2<Float>(terrain.worldX($0 % n), terrain.worldZ($0 / n)) }
        let rawFlow = cells.map { flow[$0] }
        let rawWidth = rawFlow.map(widthForFlow)

        // Corner-cutting only. A Catmull-Rom through D8 stair-steps can
        // overshoot a sharp reversal, and a long reach then loops back over
        // itself. Chaikin stays inside the convex hull of the polyline, so a
        // simple cell path can never become self-intersecting.
        var points = chaikin(raw, passes: 4)
        // Relax the D8 stair-steps into bends a wide channel can follow.
        if points.count > 3 {
            for _ in 0..<16 {
                var relaxed = points
                for i in 1..<(points.count - 1) {
                    relaxed[i] = (points[i - 1] + points[i] * 2 + points[i + 1]) * 0.25
                }
                points = relaxed
            }
        }
        // Uniform resample removes the tiny endpoint edges that otherwise
        // produce meaningless curvature values.
        points = resample(points, spacing: 3 / metresPerUnit)
        // Smooth at the final 3 m spacing. The earlier Laplacian passes run
        // on a much finer subdivision, so they cannot open up a 3–5 m D8
        // kink into a bend a 20–45 m channel can actually follow.
        if points.count > 4 {
            for _ in 0..<80 {
                var relaxed = points
                for i in 1..<(points.count - 1) {
                    relaxed[i] = (points[i - 1] + points[i] * 2
                                  + points[i + 1]) * 0.25
                }
                points = relaxed
            }
        }
        // Meander. A D8 path is a chain of eight-direction segments; even
        // after smoothing it reads as a straight canal. Displace the
        // centreline sideways with a width-scaled, per-reach wave, tapered to
        // zero at both ends so junctions keep their shared cells.
        if points.count > 8, let first = points.first {
            var total: Float = 0
            for i in 1..<points.count {
                total += simd_distance(points[i - 1], points[i])
            }
            var baseMinRadius = Float.greatestFiniteMagnitude
            for i in 1..<(points.count - 1) {
                let v0 = points[i] - points[i - 1]
                let v1 = points[i + 1] - points[i]
                let a0 = simd_length(v0)
                let a1 = simd_length(v1)
                guard a0 > 1e-6, a1 > 1e-6 else { continue }
                let dot = min(max(simd_dot(v0 / a0, v1 / a1), -1), 1)
                let angle = acos(dot)
                let radius = (0.5 * (a0 + a1)) / max(sin(angle * 0.5), 1e-5)
                baseMinRadius = min(baseMinRadius, radius)
            }
            if total > 1e-5 {
                let phase = Float(id) * 2.3999632
                let grain = RiverChannel.hash(first, 1)
                var travelled: Float = 0
                var meandered = points
                for i in points.indices {
                    if i > 0 {
                        travelled += simd_distance(points[i - 1], points[i])
                    }
                    let prev = points[max(i - 1, 0)]
                    let next = points[min(i + 1, points.count - 1)]
                    var tangent = next - prev
                    let len = simd_length(tangent)
                    if len > 1e-6 { tangent /= len } else { continue }
                    let normal = SIMD2<Float>(-tangent.y, tangent.x)
                    let sourceIndex = min(
                        Int(Float(i) / Float(points.count - 1)
                            * Float(raw.count - 1)), raw.count - 1)
                    let half = max(rawWidth[sourceIndex] * 0.5,
                                   RiverChannel.minHalfWidth)
                    let wavelength = half * (14 + 6 * grain)
                    let ramp = min(total * 0.30,
                                   max(half * 10, 30 / metresPerUnit))
                    let taper = max(min(min(travelled / ramp,
                                            (total - travelled) / ramp), 1), 0)
                    // Four incommensurate harmonics plus a slow amplitude
                    // envelope: a clean two-sine meander still looks drawn.
                    let ratios: [Float] = [1, 1.73, 2.41, 3.77]
                    let weights: [Float] = [1.0, 0.55, 0.34, 0.20]
                    var wave: Float = 0
                    for k in ratios.indices {
                        wave += weights[k] * sin(
                            2 * Float.pi * travelled
                                / (wavelength * ratios[k])
                                + phase * (1 + Float(k) * 0.618))
                    }
                    let envelope = 0.72 + 0.42 * sin(
                        2 * Float.pi * travelled / (wavelength * 4.7)
                            + phase * 0.73)
                    wave *= envelope
                    // Do not swing wider than the local bend can carry.
                    let v0 = points[i] - prev
                    let v1 = next - points[i]
                    let a0 = simd_length(v0)
                    let a1 = simd_length(v1)
                    var localCap = Float.greatestFiniteMagnitude
                    if a0 > 1e-6 && a1 > 1e-6 {
                        let dot = min(max(simd_dot(v0 / a0, v1 / a1), -1), 1)
                        let angle = acos(dot)
                        let radius = (0.5 * (a0 + a1))
                            / max(sin(angle * 0.5), 1e-5)
                        localCap = radius * 0.35
                    }
                    let amplitude = min(half * 1.15, localCap) * taper
                    meandered[i] = points[i] + normal * (wave * amplitude)
                }
                points = meandered
                // Re-space and lightly relax so the offset cannot stretch a
                // segment to 15 m or leave a kink at a former D8 corner.
                points = resample(points, spacing: 3 / metresPerUnit)
                if points.count > 4 {
                    for _ in 0..<30 {
                        var relaxed = points
                        for i in 1..<(points.count - 1) {
                            relaxed[i] = (points[i - 1] + points[i] * 2
                                          + points[i + 1]) * 0.25
                        }
                        points = relaxed
                    }
                }
            }
        }

        var samples: [RiverSample] = []
        samples.reserveCapacity(points.count)
        var previousBed: Float = .greatestFiniteMagnitude
        var previousWidth: Float = 0
        var travelled: Float = 0

        for (i, p) in points.enumerated() {
            let t = Float(i) / Float(max(points.count - 1, 1))
            let sourceIndex = min(Int(t * Float(raw.count - 1)), raw.count - 1)
            let width = max(rawWidth[sourceIndex], previousWidth * 0.98)
            previousWidth = width

            if i > 0 {
                travelled += simd_distance(p, points[i - 1]) * metresPerUnit
            }

            let bed = terrain.interpolatedHeight(x: p.x, z: p.y)

            let prev = points[max(i - 1, 0)]
            let next = points[min(i + 1, points.count - 1)]
            var tangent = next - prev
            let len = simd_length(tangent)
            if len < 1e-6 { tangent = SIMD2(1, 0) } else { tangent /= len }

            samples.append(RiverSample(position: p, bed: bed,
                                       width: width, tangent: tangent,
                                       along: travelled,
                                       cell: cells[sourceIndex]))
        }

        // One phase per reach keeps the two banks and neighbouring reaches
        // from sharing the same detail wave. Golden-angle steps decorrelate
        // consecutive reach ids without another hash table.
        let phase = Float(id) * 2.3999632
        for i in samples.indices { samples[i].phase = phase }

        // Smooth the tangent field so per-bend flow is continuous.
        if samples.count > 2 {
            for i in 1..<(samples.count - 1) {
                var t = samples[i - 1].tangent + samples[i].tangent * 2
                    + samples[i + 1].tangent
                let len = simd_length(t)
                samples[i].tangent = len > 1e-6 ? t / len : samples[i].tangent
            }
        }

        // The rendered channel narrows where the cross-slope is steep. A
        // 45 m water plane laid across a hillside would float tens of metres
        // above the downhill bank; a real river cuts a gorge instead.
        let minChannel = 4.0 / metresPerUnit
        let reliefLimit = 1.5 / metresPerUnit

        func relief(_ sample: RiverSample, _ width: Float) -> Float {
            let side = SIMD2<Float>(-sample.tangent.y, sample.tangent.x)
            var low = Float.greatestFiniteMagnitude
            var high = -Float.greatestFiniteMagnitude
            for f in [-1, -0.5, 0, 0.5, 1] as [Float] {
                let p = sample.position + side * (width * 0.5 * f)
                let h = terrain.interpolatedHeight(x: p.x, z: p.y)
                low = min(low, h)
                high = max(high, h)
            }
            return high - low
        }

        // Local bend radius. A strip offset further than the radius folds
        // through the centreline, so the width and bank profile are both
        // capped against it below.
        var radii = [Float](repeating: .greatestFiniteMagnitude,
                            count: samples.count)
        var inside = [Float](repeating: 0, count: samples.count)
        if samples.count > 4 {
            for i in 1..<(samples.count - 1) {
                let a = samples[i - 1].position
                let b = samples[i].position
                let c = samples[i + 1].position
                let v0 = b - a
                let v1 = c - b
                let ab = simd_length(v0)
                let bc = simd_length(v1)
                guard ab > 1e-6, bc > 1e-6 else { continue }
                let dot = min(max(simd_dot(simd_normalize(v0),
                                           simd_normalize(v1)), -1), 1)
                let angle = acos(dot)
                radii[i] = (0.5 * (ab + bc)) / max(sin(angle * 0.5), 1e-5)
                // sideVector points left of the tangent, so a left turn puts
                // the centre of curvature on the +1 side.
                let cross = v0.x * v1.y - v0.y * v1.x
                inside[i] = cross >= 0 ? 1 : -1
            }
        }

        for i in samples.indices {
            var width = max(samples[i].width, minChannel)
            for _ in 0..<10 {
                if relief(samples[i], width) <= reliefLimit { break }
                width = max(width * 0.85, minChannel)
                if width == minChannel { break }
            }
            // Keep the half-width inside the bend so the water polygon cannot
            // cross itself, and leave room for the wet margin behind it.
            let radius = radii[i]
            if radius < .greatestFiniteMagnitude {
                let cap = max(radius * 1.20, minChannel)
                width = min(width, cap)
            }
            samples[i].channelWidth = width
            samples[i].bendLimit = radius < .greatestFiniteMagnitude
                ? radius * 0.92 : .greatestFiniteMagnitude
            samples[i].bendInside = inside[i]
        }
        // Smooth the width field so the banks do not step in and out. The
        // smooth may only narrow a sample, never widen it back into a slope.
        if samples.count > 4 {
            for _ in 0..<6 {
                let widths = samples.map(\.channelWidth)
                for i in 1..<(samples.count - 1) {
                    let average = (widths[i - 1] + widths[i] * 2
                                   + widths[i + 1]) * 0.25
                    samples[i].channelWidth = min(average, widths[i])
                }
            }
        }
        // Headwater taper: a source should begin as a spring, not a sawn-off
        // canal. Ramp the rendered width from a couple of metres at the first
        // sample to the full channel over the first 55 m.
        if isSource, let first = samples.first?.along {
            for i in samples.indices {
                let d = samples[i].along - first
                let t = min(max(d / (55 / metresPerUnit), 0), 1)
                let f = t * t * (3 - 2 * t)
                samples[i].channelWidth *= max(f, 0.16)
            }
        }

        return RiverReach(id: id, samples: samples,
                          isSource: isSource, isMouth: isMouth,
                          firstCell: cells.first ?? 0,
                          lastCell: cells.last ?? 0)
    }

    private static func resample(_ points: [SIMD2<Float>],
                                 spacing: Float) -> [SIMD2<Float>] {
        guard points.count >= 2 else { return points }
        var cumulative: [Float] = [0]
        var total: Float = 0
        for i in 1..<points.count {
            total += simd_distance(points[i - 1], points[i])
            cumulative.append(total)
        }
        guard total > spacing else { return points }

        let steps = max(Int(total / spacing), 1)
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(steps + 1)
        var segment = 1
        for step in 0...steps {
            let target = min(Float(step) * spacing, total)
            while segment < points.count - 1 && cumulative[segment] < target {
                segment += 1
            }
            let d0 = cumulative[segment - 1]
            let d1 = cumulative[segment]
            let t = d1 > d0 ? (target - d0) / (d1 - d0) : 0
            result.append(points[segment - 1]
                          + (points[segment] - points[segment - 1]) * t)
        }
        // Keep the exact final control point. `steps` rounds down, so the
        // loop above can stop up to one spacing short and leave a reach end
        // stranded a few metres from the stem it merges into.
        if let last = result.last, let target = points.last,
           simd_distance(last, target) > 1e-6 {
            result.append(target)
        }
        return result
    }

    /// Corner-cutting subdivision. Every pass replaces each segment with two
    /// points at 1/4 and 3/4, keeping the first and last control points.
    private static func chaikin(_ points: [SIMD2<Float>],
                                passes: Int) -> [SIMD2<Float>] {
        guard points.count >= 2 else { return points }
        var p = points
        for _ in 0..<passes {
            var q: [SIMD2<Float>] = [p[0]]
            q.reserveCapacity(p.count * 2)
            for i in 0..<(p.count - 1) {
                let a = p[i], b = p[i + 1]
                q.append(a * 0.75 + b * 0.25)
                q.append(a * 0.25 + b * 0.75)
            }
            q.append(p[p.count - 1])
            p = q
        }
        return p
    }

    /// Centripetal Catmull-Rom with endpoint duplication.
    private static func catmullRomCentripetal(_ points: [SIMD2<Float>],
                                              spacing: Float) -> [SIMD2<Float>] {
        guard points.count >= 2 else { return points }
        var result: [SIMD2<Float>] = []
        let pts = [points[0]] + points + [points[points.count - 1]]

        for i in 0..<(pts.count - 3) {
            let p0 = pts[i], p1 = pts[i + 1], p2 = pts[i + 2], p3 = pts[i + 3]
            let d01 = pow(simd_distance(p0, p1), 0.5)
            let d12 = pow(simd_distance(p1, p2), 0.5)
            let d23 = pow(simd_distance(p2, p3), 0.5)
            let t0: Float = 0
            let t1 = t0 + max(d01, 1e-4)
            let t2 = t1 + max(d12, 1e-4)
            let t3 = t2 + max(d23, 1e-4)

            let steps = max(Int(simd_distance(p1, p2) / max(spacing, 1e-5)), 2)
            for s in 0..<steps {
                let t = t1 + (t2 - t1) * Float(s) / Float(steps)
                let a1 = (t1 - t) / (t1 - t0) * p0 + (t - t0) / (t1 - t0) * p1
                let a2 = (t2 - t) / (t2 - t1) * p1 + (t - t1) / (t2 - t1) * p2
                let a3 = (t3 - t) / (t3 - t2) * p2 + (t - t2) / (t3 - t2) * p3
                let b1 = (t2 - t) / (t2 - t0) * a1 + (t - t0) / (t2 - t0) * a2
                let b2 = (t3 - t) / (t3 - t1) * a2 + (t - t1) / (t3 - t1) * a3
                result.append((t2 - t) / (t2 - t1) * b1 + (t - t1) / (t2 - t1) * b2)
            }
        }
        result.append(points.last!)
        return result
    }

    private static func selfIntersections(_ samples: [RiverSample]) -> Int {
        guard samples.count > 8 else { return 0 }
        let stride = max(samples.count / 40, 1)
        let pts = samples.enumerated()
            .filter { $0.offset % stride == 0 }
            .map(\.element.position)
        var count = 0
        for i in 0..<(pts.count - 1) {
            let first = i + 2
            guard first < pts.count - 1 else { continue }
            for j in first..<(pts.count - 1) {
                if segmentsIntersect(pts[i], pts[i + 1], pts[j], pts[j + 1]) {
                    count += 1
                }
            }
        }
        return count
    }

    private static func segmentsIntersect(_ a: SIMD2<Float>, _ b: SIMD2<Float>,
                                          _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> Bool {
        func cross(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ r: SIMD2<Float>) -> Float {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        let d1 = cross(c, d, a)
        let d2 = cross(c, d, b)
        let d3 = cross(a, b, c)
        let d4 = cross(a, b, d)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
            && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }
}

/// Binary min-heap for the priority flood. `order` breaks ties on flat filled
/// ground so the flood, and therefore the drainage tree, is deterministic.
private struct FloodNode {
    var level: Float
    var order: Int
    var index: Int
}

private struct FloodHeap {
    private var items: [FloodNode] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func reserve(_ capacity: Int) {
        items.reserveCapacity(capacity)
    }

    private func before(_ a: FloodNode, _ b: FloodNode) -> Bool {
        a.level < b.level || (a.level == b.level && a.order < b.order)
    }

    mutating func push(_ node: FloodNode) {
        items.append(node)
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            if before(items[child], items[parent]) {
                items.swapAt(child, parent)
                child = parent
            } else {
                break
            }
        }
    }

    mutating func pop() -> FloodNode? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        items[0] = items[items.count - 1]
        items.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var best = parent
            if left < items.count && before(items[left], items[best]) {
                best = left
            }
            if right < items.count && before(items[right], items[best]) {
                best = right
            }
            if best == parent { break }
            items.swapAt(parent, best)
            parent = best
        }
        return top
    }
}
