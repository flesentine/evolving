import Foundation
import simd

struct RiverSample {
    var position: SIMD2<Float>
    var bed: Float
    var width: Float
    var tangent: SIMD2<Float>
    /// Shared cross-section orientation at a junction. The routing tangent
    /// remains the centreline direction used by drainage/curvature diagnostics.
    var junctionTangent: SIMD2<Float>? = nil
    /// Width used by the rendered channel. Equal to `width` on gentle ground,
    /// narrowed where the cross-slope is steep so a wide river never has to
    /// hang a water plane off a hillside.
    var channelWidth: Float = 0
    /// Multiplier of the effective ribbon half-width at a retained spring.
    /// Applied after the normal channel-width floor, so taper reaches the GPU.
    var sourceWidthFactor: Float = 1
    /// Longest bank offset that stays outside the local bend radius. A strip
    /// offset further than the radius folds through the centreline and shows
    /// up as a triangular wedge of land inside the water.
    var bendLimit: Float = .greatestFiniteMagnitude
    /// Maximum half-width approaching a receiving-channel bottleneck.
    var junctionLimit: Float = .greatestFiniteMagnitude
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

enum RiverEndpoint: Equatable {
    case linked, coastalMouth, basinLake(Int)
}
enum RiverOrigin: Equatable { case spring, junction, basinLake(Int) }

struct RiverReach {
    var id: Int
    var samples: [RiverSample]
    var upstream: [Int] = []
    var downstream: Int?
    var isSource = false
    var isMouth = false
    var firstCell = 0
    var lastCell = 0
    var endpoint: RiverEndpoint = .linked
    var origin: RiverOrigin = .junction
    var junctionsPrepared = false
    /// Contributing land cells immediately before the shared downstream node.
    var incomingArea: Float = 0
}

struct RiverDiagnostics {
    var reaches = 0
    var sources = 0
    var junctions = 0
    var mouths = 0
    var minWidth: Float = 0
    var maxWidth: Float = 0
    var maxGroundRiseMetres: Float = 0 // original terrain, before the rendered carve
    var minCurvatureRadius: Float = .greatestFiniteMagnitude
    var maxTurnDegrees: Float = 0
    var selfIntersections = 0
    var maxJunctionAngle: Float = 0
    var maxSampleSpacing: Float = 0
    var linkedReaches = 0
    var maxLinkGap: Float = 0
    var inlandTerminalEnds = 0
    var maxJunctionWaterStep: Float = 0
    var routingRowRuns = 0
    var maxWaterRise: Float = 0
    var graphIdentityOk = true
    var unsupportedSources = 0
    var minSourceArea: Float = 0 // contributing grid cells, not world distance
    var absorbedSourceStarts = 0

    var failures: [String] {
        var result: [String] = []
        if minWidth < 3 || maxWidth > 45 {
            result.append("width outside 3–45 m")
        }
        // Preserve the old effective bound (0.01 world units = 10 m), but
        // report its real unit. This is original ground, not drawn water;
        // downstream water rise has its own metre-valued gate below.
        let maxGroundRiseLimitMetres: Float = 10
        if maxGroundRiseMetres > maxGroundRiseLimitMetres {
            result.append("original ground rise > 10 m per sample")
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
        if unsupportedSources > 0 { result.append("channel start has no retained catchment source") }
        if minSourceArea < 1200 { result.append("source below 1200-cell catchment threshold") }
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
        original ground rise: \(String(format: "%.3f m", maxGroundRiseMetres))
        min curvature radius: \(String(format: "%.1f m", minCurvatureRadius))
        max adjacent routing-tangent turn: \(String(format: "%.1f°", maxTurnDegrees))
        self-intersections: \(selfIntersections)
        max junction angle: \(String(format: "%.1f°", maxJunctionAngle))
        max sample spacing: \(String(format: "%.2f m", maxSampleSpacing))
        linked reaches: \(linkedReaches)  max link gap: \(String(format: "%.2f m", maxLinkGap))
        inland terminal ends: \(inlandTerminalEnds)  junction water step: \(String(format: "%.3f m", maxJunctionWaterStep))
        routing-cell runs in a row (not mesh): \(routingRowRuns)
        unsupported source starts: \(unsupportedSources); minimum source area: \(Int(minSourceArea)) cells
        covered/short source starts: \(absorbedSourceStarts) thinned, catchment area retained
        water surface rise: \(String(format: "%.3f m", maxWaterRise))  graph identity: \(graphIdentityOk ? "OK" : "BROKEN")
        \(passes ? "PASS" : "FAIL: " + failures.joined(separator: ", "))
        """
    }
}

/// Phase 2 channel geometry, shared by the water mesh, the bank mesh and the
/// headless diagnostics. Keeping one definition of the waterline and the bank
/// profile is what stops the three from disagreeing by a few centimetres.
struct RiverGraph {
    let reaches: [RiverReach]
    let diagnostics: RiverDiagnostics
    let lakes: [RiverLake]
    let contributingArea: [Float]
    let receivers: [Int]
    let absorbedSourceCells: [Int]
    init(reaches: [RiverReach], diagnostics: RiverDiagnostics, lakes: [RiverLake] = [],
         contributingArea: [Float] = [], receivers: [Int] = [], absorbedSourceCells: [Int] = []) {
        self.reaches = reaches; self.diagnostics = diagnostics; self.lakes = lakes
        self.contributingArea = contributingArea; self.receivers = receivers
        self.absorbedSourceCells = absorbedSourceCells
    }
    /// Metres per world unit (the island is about 2 km across in 2 units).
    static let metresPerUnit: Float = 1_000
    static let seaLevel: Float = 0 // world units; shared by ocean, mouths and marine placement
    static let waterLift: Float = 0.60 / metresPerUnit
    static let sourceFreeboard: Float = 0.15 / metresPerUnit // water begins 15 cm below original ground
    static let minimumHalfWidth: Float = 1.4 / metresPerUnit
    static func waterLevel(_ sample: RiverSample) -> Float {
        sample.waterOverride.isFinite ? sample.waterOverride : sample.bed + waterLift
    }
    static func profileHash(_ p: SIMD2<Float>, _ side: Float) -> Float {
        let raw = sin(p.x * 97 + p.y * 53 + side * 31.7) * 43_758.547
        return raw - floor(raw)
    }


    static func build(_ terrain: Terrain) -> RiverGraph {
        let n = terrain.size
        let count = n * n
        let outletHeight: Float = 0 // actual sea level, world units
        let floodSeedHeight: Float = 0 // ocean surface, world units
        let routingIncision = 0.12 / metresPerUnit // 12 cm per routing pass
        let neighbourIncision = 0.03 / metresPerUnit // 3 cm per pass
        let slopeTie = 0.0001 / metresPerUnit // 0.1 mm vertical tie predicate
        let dirs: [(Int, Int)] = [
            (1, 0), (-1, 0), (0, 1), (0, -1),
            (1, 1), (1, -1), (-1, 1), (-1, -1)
        ]

        // Routing surface. Each pass uses true slope (gradient, not raw
        // elevation) and a topological accumulation, so diagonal neighbours
        // are not penalised and the contributing area belongs to the final
        // receiver graph rather than a stale sorting order.
        let land = (0..<count).filter { terrain.height[$0] > outletHeight }
        var route = terrain.height
        var routeDown = [Int](repeating: -1, count: count)
        var routeArea = [Float](repeating: 0, count: count)

        func steepestDown(on surface: [Float],
                          into receivers: inout [Int]) {
            for j in 0..<n {
                for i in 0..<n {
                    let idx = terrain.index(i, j)
                    guard terrain.height[idx] > outletHeight else {
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
                        if slope > bestSlope + slopeTie {
                            bestSlope = slope
                            best = nIdx
                        }
                    }
                    receivers[idx] = best
                }
            }
        }

        func topologicalArea(receivers: [Int]) -> (area: [Float], order: [Int]) {
            let result = RiverRouting.accumulate(receivers: receivers, land: land)
            precondition(result.unprocessed == 0, "River routing cycle: unprocessed land cells")
            return (result.area, result.order)
        }

        for _ in 0..<3 {
            steepestDown(on: route, into: &routeDown)
            (routeArea, _) = topologicalArea(receivers: routeDown)
            for idx in land where routeArea[idx] > 250 {
                route[idx] -= routingIncision
                let i = idx % n, j = idx / n
                for (di, dj) in dirs {
                    let ni = i + di, nj = j + dj
                    guard ni >= 0, ni < n, nj >= 0, nj < n else { continue }
                    route[nj * n + ni] -= neighbourIncision
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
            filled[idx] = max(route[idx], level)
            heap.push(FloodNode(level: filled[idx], order: insertion,
                                index: idx))
            insertion += 1
        }

        for idx in 0..<count where terrain.height[idx] <= outletHeight {
            seed(idx, floodSeedHeight)
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
                filled[nIdx] = max(route[nIdx], node.level)
                heap.push(FloodNode(level: filled[nIdx], order: insertion,
                                    index: nIdx))
                insertion += 1
            }
        }

        let basinCandidates = RiverLake.detect(terrain, filled: filled)
        var down = [Int](repeating: -1, count: count)
        steepestDown(on: route, into: &down)

        // Mark every cell whose steepest path already reaches the sea, then
        // give each true sink one spill along the priority-flood parent tree.
        // One spill per sink keeps the network connected without a fan of
        // parallel channels.
        var settled = [Bool](repeating: false, count: count)
        // Receivers strictly descend on route, which has already been
        // deepened. Original terrain order can visit a cell before its outlet
        // and spuriously send a second parallel spill through the same valley.
        let byRoute = (0..<count).sorted {
            route[$0] == route[$1] ? $0 < $1 : route[$0] < route[$1]
        }
        for idx in byRoute {
            if terrain.height[idx] <= outletHeight {
                settled[idx] = true
            } else if down[idx] >= 0 {
                settled[idx] = settled[down[idx]]
            }
        }
        for idx in 0..<count where down[idx] < 0
            && terrain.height[idx] > outletHeight {
            var cursor = idx
            while cursor >= 0 && !settled[cursor] && parent[cursor] >= 0 {
                down[cursor] = parent[cursor]
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
        // Spills route contributing area; they are not independent rivers.
        // Only paths with the same catchment threshold as natural channels
        // become visible. Accumulation is nondecreasing downstream.
        let selection = RiverRouting.select(channel: isRiver, receivers: down,
                                            area: finalArea, size: n, cellSize: terrain.cellSize)
        let channel = selection.channel
        let keptSources = Set(selection.sources)

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

        let thinned = RiverRouting.pruneCoveredSources(reaches, area: finalArea)
        reaches = prepareJunctions(mergeContinuations(thinned.reaches))
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
        precondition(upstreamFirst.count == reaches.count, "River reach graph contains a cycle")

        // Centreline bed. A cross-section low depends on the sample's
        // tangent, so the two reaches at a shared junction cell could differ
        // by tens of metres on a steep hillside. The shared cell must have
        // one bed, so use the terrain at the centreline point. This is a
        // carved bed reference, not the original surface: adding waterLift to
        // unincised ground left every spring floating 60 cm above the land.
        for r in reaches.indices {
            for i in reaches[r].samples.indices {
                let p = reaches[r].samples[i].position
                reaches[r].samples[i].bed =
                    terrain.interpolatedHeight(x: p.x, z: p.y) - waterLift - sourceFreeboard
            }
        }

        // One connected water profile. Start with a local running minimum
        // per reach, then repeatedly lower each junction to the lowest
        // incident end and re-solve the stem. Levels only fall, so this
        // converges and is independent of reach ordering.
        for r in reaches.indices {
            guard !reaches[r].samples.isEmpty else { continue }
            var level = reaches[r].samples[0].bed + RiverGraph.waterLift
            for i in reaches[r].samples.indices {
                level = min(level,
                            reaches[r].samples[i].bed + RiverGraph.waterLift)
                reaches[r].samples[i].waterOverride = max(level, 0)
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
                                    + RiverGraph.waterLift)
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

        // Lakes are hydraulic controls. Stamp their bounded flooded cells,
        // then propagate required upstream levels in reverse topological order;
        // downstream levels remain a running minimum from each shared node.
        // Only an inland terminal reach creates a basin lake. Priority-flood
        // depressions on continuing source-to-sea paths remain carved river
        // corridors; inundating every such depression floods whole valleys.
        let inlandTerminals = Set(reaches.filter { $0.downstream == nil && terrain.height[$0.lastCell] > 0 }.map { $0.lastCell })
        let lakes = basinCandidates.filter { !$0.cells.allSatisfy { !inlandTerminals.contains($0) } }
            .enumerated().map { RiverLake(id: $0.offset, level: $0.element.level, cells: $0.element.cells) }
        var lakeAt: [Int: Int] = [:]
        for lake in lakes { for cell in lake.cells { lakeAt[cell] = lake.id } }
        func lakeContaining(_ p: SIMD2<Float>) -> Int? {
            let i = min(max(Int(floor((p.x + 1) / terrain.cellSize)), 0), n - 2)
            let j = min(max(Int(floor((p.y + 1) / terrain.cellSize)), 0), n - 2)
            let ids = Set([j * n + i, j * n + i + 1, (j + 1) * n + i, (j + 1) * n + i + 1].compactMap { lakeAt[$0] }).sorted()
            return ids.first { terrain.originalTriangleHeight(at: p) < lakes[$0].level }
        }
        for r in reaches.indices {
            if reaches[r].upstream.isEmpty {
                reaches[r].origin = lakeContaining(reaches[r].samples[0].position).map { .basinLake($0) } ?? .spring
            }
            for i in reaches[r].samples.indices {
                let p = reaches[r].samples[i].position
                let cell = terrain.index(min(max(terrain.cellX(p.x), 0), n - 1),
                                         min(max(terrain.cellZ(p.y), 0), n - 1))
                let sample = reaches[r].samples[i]
                let half = channelHalfWidth(sample)
                let support = half + terrain.cellSize * sqrt(Float(2)) * 0.5
                let radius = Int(ceil(support / terrain.cellSize))
                var nearest: (Float, Int)?
                for dz in -radius...radius { for dx in -radius...radius {
                    let x = cell % n + dx, z = cell / n + dz
                    guard x >= 0 && x < n && z >= 0 && z < n, let id = lakeAt[z * n + x] else { continue }
                    let distance = simd_distance(p, SIMD2(terrain.worldX(x), terrain.worldZ(z)))
                    if distance <= support && distance < (nearest?.0 ?? .greatestFiniteMagnitude) { nearest = (distance, id) }
                }}
                if let id = nearest?.1 { reaches[r].samples[i].waterOverride = lakes[id].level }
            }
        }
        // Terminal levels are boundary conditions, applied before solving the
        // profile. Stamping them afterwards can create an uphill final segment.
        for r in reaches.indices where reaches[r].downstream == nil {
            let last = reaches[r].samples.count - 1, cell = reaches[r].lastCell
            if terrain.height[cell] <= 0 {
                reaches[r].endpoint = .coastalMouth
                reaches[r].samples[last].waterOverride = 0
            } else if let id = lakeAt[cell] {
                reaches[r].endpoint = .basinLake(id)
                reaches[r].samples[last].waterOverride = lakes[id].level
            }
        }
        for r in upstreamFirst.reversed() {
            if let d = reaches[r].downstream, let first = reaches[d].samples.first {
                let last = reaches[r].samples.count - 1
                reaches[r].samples[last].waterOverride = max(reaches[r].samples[last].waterOverride, first.waterOverride)
            }
            for i in reaches[r].samples.indices.reversed() where i + 1 < reaches[r].samples.count {
                reaches[r].samples[i].waterOverride = max(reaches[r].samples[i].waterOverride,
                                                         reaches[r].samples[i + 1].waterOverride)
            }
        }
        for r in upstreamFirst {
            if !reaches[r].upstream.isEmpty {
                let level = reaches[r].upstream.map { reaches[$0].samples.last!.waterOverride }.min()!
                reaches[r].samples[0].waterOverride = level
            }
            var level = reaches[r].samples[0].waterOverride
            for i in reaches[r].samples.indices {
                level = min(level, reaches[r].samples[i].waterOverride)
                reaches[r].samples[i].waterOverride = level
            }
        }

        coastalWaterControls(&reaches,terrain:terrain)
        let fixedWaterControls: [Set<Int>] = reaches.map { reach in
            var controls = Set<Int>()
            if reach.upstream.isEmpty { controls.insert(0) }
            for i in reach.samples.indices where lakeContaining(reach.samples[i].position) != nil { controls.insert(i) }
            return controls
        }
        smoothWaterGrades(&reaches,upstreamFirst:upstreamFirst,fixed:fixedWaterControls)

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
        diagnostics.absorbedSourceStarts = thinned.cells.count
        diagnostics.reaches = reaches.count
        diagnostics.routingRowRuns = maxParallel
        let drawnSources = reaches.filter { $0.upstream.isEmpty }
        diagnostics.sources = drawnSources.count
        diagnostics.unsupportedSources = drawnSources.filter { !keptSources.contains($0.firstCell) || !$0.isSource }.count
        diagnostics.minSourceArea = drawnSources.map { finalArea[$0.firstCell] }.min() ?? 0
        diagnostics.mouths = reaches.filter { $0.isMouth }.count
        diagnostics.junctions = reaches.filter { $0.upstream.count >= 2 }.count
        for a in reaches.indices {
            guard let end = reaches[a].samples.last else { continue }
            if reaches[a].downstream == nil,
               terrain.interpolatedHeight(x: end.position.x,
                                          z: end.position.y) > outletHeight {
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
            let step = abs(RiverGraph.waterLevel(end)
                           - RiverGraph.waterLevel(start))
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
                let rise = RiverGraph.waterLevel(reach.samples[i])
                    - RiverGraph.waterLevel(reach.samples[i - 1])
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
                diagnostics.maxGroundRiseMetres = max(diagnostics.maxGroundRiseMetres, (b.bed - a.bed) * metresPerUnit)
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
                    let radius = simd_distance(reach.samples[i - 1].position, reach.samples[i + 1].position)
                        / max(2 * sin(angle), 1e-5)
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
        return RiverGraph(reaches: reaches, diagnostics: diagnostics, lakes: lakes,
                          contributingArea: finalArea, receivers: down, absorbedSourceCells: thinned.cells)
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
                let grain = RiverGraph.profileHash(first, 1)
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
                                   RiverGraph.minimumHalfWidth)
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

        let corridor = terrain.cellSize * sqrt(Float(2)) * 0.5 // one drainage-cell half diagonal, world units
        func constrain(_ p: SIMD2<Float>) -> SIMD2<Float> {
            var nearest = raw[0], best = Float.greatestFiniteMagnitude
            for i in 1..<raw.count {
                let edge = raw[i] - raw[i - 1]
                let t = min(max(simd_dot(p - raw[i - 1], edge) / max(simd_length_squared(edge), 1e-20), 0), 1)
                let q = raw[i - 1] + edge * t, d = simd_distance(p, q)
                if d < best { best = d; nearest = q }
            }
            return best > corridor ? nearest + (p - nearest) * (corridor / best) : p
        }
        if points.count > 2 {
            for _ in 0..<32 {
                var next = points
                for i in 1..<(points.count - 1) {
                    next[i] = constrain((points[i - 1] + 2 * points[i] + points[i + 1]) * 0.25)
                }
                points = next
            }
            // Projection can change the distance between neighbouring samples.
            // Re-space the constrained polyline before estimating tangents and
            // bend limits; retaining the old spacing left 11 m jumps.
            points = resample(points, spacing: 2 / metresPerUnit)
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
                // Circumradius of these three centreline points. The old
                // half-angle expression was twice the real radius, allowing
                // an inside ribbon edge past the bend centre and inverting
                // submitted triangles.
                radii[i] = simd_distance(a, c) / max(2 * sin(angle), 1e-5)
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
                let cap = max(radius * 1.80, minChannel) // half-width <= 0.90 × true radius
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
        // canal. Ramp the submitted width from 30 cm at the first sample to
        // the full channel over the first 55 m.
        if isSource, let first = samples.first?.along {
            let taperLengthMetres: Float = 55
            for i in samples.indices {
                let d = samples[i].along - first
                let t = min(max(d / taperLengthMetres, 0), 1)
                let f = t * t * (3 - 2 * t)
                let fullHalf = max(samples[i].channelWidth * 0.5, RiverGraph.minimumHalfWidth)
                let springHalf = 0.15 / metresPerUnit // 30 cm spring, widening over 55 m
                samples[i].sourceWidthFactor = (springHalf + (fullHalf - springHalf) * f) / fullHalf
            }
        }

        return RiverReach(id: id, samples: samples,
                          isSource: isSource, isMouth: isMouth,
                          firstCell: cells.first ?? 0,
                          lastCell: cells.last ?? 0,
                          incomingArea: flow[cells[max(cells.count - 2, 0)]])
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
