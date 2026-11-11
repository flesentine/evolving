import Foundation
import simd

/// Builds the road network between settlements with A* over the terrain.
/// Roads are derived data: nothing about them is stored in the save file.
/// How a road crosses a river in a given era.
enum BridgeStyle {
    case ford
    case stone
    case iron
    case concrete

    static func forEra(_ era: Era) -> BridgeStyle {
        switch era {
        case .neolithic, .bronze: return .ford
        case .classical, .medieval, .renaissance: return .stone
        case .industrial: return .iron
        case .modern, .information, .future: return .concrete
        }
    }

    var hasParapets: Bool { self != .ford }
    var isRaised: Bool { self != .ford }
}

/// Surface families, matched by the road shader. Raw values are written into
/// the vertex alpha channel of the road mesh.
enum RoadSurface: Int, CaseIterable {
    case dirt = 0
    case gravel = 1
    case romanStone = 2
    case cobble = 3
    case sett = 4
    case macadam = 5
    case asphalt = 6
    case brick = 7
    case paint = 8

    /// Rural road surface for an era.
    static func forRoad(_ era: Era) -> RoadSurface {
        switch era {
        case .neolithic, .bronze: return .dirt
        case .classical: return .romanStone
        case .medieval, .renaissance: return .gravel
        case .industrial: return .macadam
        case .modern, .information, .future: return .asphalt
        }
    }

    /// Street surface inside a town.
    static func forStreet(_ era: Era) -> RoadSurface {
        switch era {
        case .neolithic, .bronze: return .dirt
        case .classical: return .romanStone
        case .medieval: return .cobble
        case .renaissance: return .brick
        case .industrial: return .sett
        case .modern, .information, .future: return .asphalt
        }
    }
}

enum RoadBuilder {

    struct Segment {
        var from: Int32
        var to: Int32
        var points: [SIMD2<Float>]
        var built: Float
        var surface: RoadSurface = .dirt
        /// 1.0 = normal lane; >1 arterial/backbone; <1 local track.
        var widthScale: Float = 1.0
    }

    /// Connects settlements with an era-specific network: braided tracks,
    /// surveyed Roman backbones, market-focused medieval roads, turnpike
    /// spines and modern arterial hierarchies.
    static func segments(for simulation: Simulation, terrain: Terrain) -> [Segment] {
        let settlements = simulation.settlements.filter { $0.isAlive }
        guard settlements.count > 1 else { return [] }

        let era = simulation.era
        let profile = CostProfile.forEra(era)
        let n = terrain.size
        var used = [Bool](repeating: false, count: n * n)

        var result: [Segment] = []
        result.reserveCapacity(settlements.count - 1)
        var visited = [Bool](repeating: false, count: settlements.count)

        let hubs = hubIndices(settlements, era: era)
        let hubSet = Set(hubs)

        func parentIndex(for index: Int, hubsOnly: Bool) -> Int? {
            let s = settlements[index]
            let origin = SIMD2(s.x, s.z)
            var nearest: Int?
            var nearestDistance = Float.greatestFiniteMagnitude
            var preferred: Int?
            var preferredDistance = Float.greatestFiniteMagnitude

            for j in settlements.indices where visited[j] && j != index {
                if hubsOnly && !hubSet.contains(j) { continue }
                let other = settlements[j]
                let d = simd_distance(SIMD2(other.x, other.z), origin)
                if d < nearestDistance { nearestDistance = d; nearest = j }

                let preferredHere: Bool
                switch era {
                case .medieval:
                    preferredHere = other.population > s.population
                case .industrial, .modern, .information, .future:
                    preferredHere = other.population >= s.population
                case .classical, .renaissance:
                    preferredHere = hubSet.contains(j)
                default:
                    preferredHere = false
                }
                if preferredHere && d < preferredDistance {
                    preferredDistance = d
                    preferred = j
                }
            }

            guard let nearest else { return nil }
            guard let preferred else { return nearest }
            // Prefer a hub or larger market when it is not a huge detour.
            if preferredDistance <= nearestDistance * 1.75 { return preferred }
            return nearest
        }

        func connect(_ index: Int, hubsOnly: Bool) {
            guard !visited[index] else { return }
            guard let parent = parentIndex(for: index, hubsOnly: hubsOnly) else {
                visited[index] = true
                return
            }
            let a = settlements[parent]
            let b = settlements[index]
            guard var path = aStar(terrain: terrain,
                                   from: SIMD2(a.x, a.z),
                                   to: SIMD2(b.x, b.z),
                                   profile: profile,
                                   used: used) else {
                visited[index] = true
                return
            }

            // Stop the road at the edge of each town: the town's own street
            // grid takes over from there.
            let aRadius = SettlementMetrics.cityRadius(a.population) * 1.02
            let bRadius = SettlementMetrics.cityRadius(b.population) * 1.02
            let near = trim(path, around: SIMD2(a.x, a.z), radius: aRadius)
            let far = trim(near.reversed(), around: SIMD2(b.x, b.z), radius: bRadius).reversed()
            if far.count >= 2 { path = Array(far) }
            guard path.count >= 2 else { visited[index] = true; return }

            let hubBackbone = hubsOnly || (hubSet.contains(parent) && hubSet.contains(index))
            let attachedHub = hubSet.contains(parent) || hubSet.contains(index)
            let widthScale: Float = hubBackbone ? 1.30 : (attachedHub ? 1.10 : 0.82)
            result.append(Segment(from: a.id, to: b.id, points: path,
                                  built: b.founded,
                                  surface: RoadSurface.forRoad(era),
                                  widthScale: widthScale))
            for p in path {
                let idx = min(max(terrain.cellZ(p.y), 0), n - 1) * n
                    + min(max(terrain.cellX(p.x), 0), n - 1)
                used[idx] = true
            }
            visited[index] = true
        }

        // Backbone first: hubs chain to each other, then everything else
        // attaches to the network.
        if let first = hubs.first {
            visited[first] = true
            for hub in hubs.dropFirst() {
                connect(hub, hubsOnly: true)
            }
        }
        for index in settlements.indices where !visited[index] {
            connect(index, hubsOnly: false)
        }
        return result
    }

    /// Settlements that act as the era's network hubs.
    private static func hubIndices(_ settlements: [Settlement], era: Era) -> [Int] {
        let count: Int
        switch era {
        case .neolithic, .bronze: count = 0
        case .medieval: count = 1
        case .classical, .renaissance: count = 2
        case .industrial: count = 3
        case .modern, .information: count = 4
        case .future: count = 3
        }
        guard count > 0 else { return [] }
        return settlements.indices
            .sorted {
                if settlements[$0].population != settlements[$1].population {
                    return settlements[$0].population > settlements[$1].population
                }
                return settlements[$0].id < settlements[$1].id
            }
            .prefix(count)
            .map { $0 }
    }

    /// Terrain weighting for a given era.
    private struct CostProfile {
        var ascent: Float
        var descent: Float
        var water: Float
        var river: Float
        var wet: Float
        var forest: Float
        var straightness: Float
        var reuse: Float

        static func forEra(_ era: Era) -> CostProfile {
            switch era {
            case .neolithic:
                return CostProfile(ascent: 7, descent: 4, water: 320, river: 22,
                                   wet: 5, forest: 1.4, straightness: 0, reuse: 0)
            case .bronze:
                return CostProfile(ascent: 6, descent: 3.5, water: 300, river: 14,
                                   wet: 4, forest: 1.0, straightness: 0, reuse: 0)
            case .classical:
                return CostProfile(ascent: 3.5, descent: 2, water: 300, river: 5,
                                   wet: 1.6, forest: 0.5, straightness: 2.4, reuse: 0.1)
            case .medieval:
                return CostProfile(ascent: 4, descent: 2.5, water: 300, river: 4,
                                   wet: 2.4, forest: 0.7, straightness: 0.4, reuse: 0.30)
            case .renaissance:
                return CostProfile(ascent: 3.5, descent: 2, water: 300, river: 4,
                                   wet: 1.4, forest: 0.4, straightness: 2.0, reuse: 0.30)
            case .industrial:
                return CostProfile(ascent: 6, descent: 3, water: 300, river: 3,
                                   wet: 1.4, forest: 0.3, straightness: 1.2, reuse: 0.40)
            case .modern, .information, .future:
                return CostProfile(ascent: 2, descent: 1.5, water: 300, river: 1,
                                   wet: 0.6, forest: 0.2, straightness: 2.8, reuse: 0.45)
            }
        }
    }

    /// Drops the leading points that fall inside a settlement.
    private static func trim(_ path: [SIMD2<Float>],
                             around centre: SIMD2<Float>,
                             radius: Float) -> [SIMD2<Float>] {
        guard !path.isEmpty else { return path }
        var start = 0
        while start < path.count, simd_distance(path[start], centre) < radius {
            start += 1
        }
        guard start < path.count else { return [] }
        return Array(path[start...])
    }

    // MARK: - Pathfinding

    private struct HeapItem {
        var index: Int32
        var cost: Float
    }

    /// Simple binary heap keyed by cost.
    private struct MinHeap {
        private var items: [HeapItem] = []

        var isEmpty: Bool { items.isEmpty }

        mutating func push(_ item: HeapItem) {
            items.append(item)
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                if items[parent].cost <= items[i].cost { break }
                items.swapAt(parent, i)
                i = parent
            }
        }

        mutating func pop() -> HeapItem? {
            guard !items.isEmpty else { return nil }
            let top = items[0]
            items[0] = items[items.count - 1]
            items.removeLast()
            var i = 0
            while true {
                let l = i * 2 + 1, r = i * 2 + 2
                var smallest = i
                if l < items.count && items[l].cost < items[smallest].cost { smallest = l }
                if r < items.count && items[r].cost < items[smallest].cost { smallest = r }
                if smallest == i { break }
                items.swapAt(i, smallest)
                i = smallest
            }
            return top
        }
    }

    private static func aStar(terrain: Terrain,
                              from start: SIMD2<Float>,
                              to goal: SIMD2<Float>,
                              profile: CostProfile,
                              used: [Bool]) -> [SIMD2<Float>]? {
        let n = terrain.size
        let startI = min(max(terrain.cellX(start.x), 0), n - 1)
        let startJ = min(max(terrain.cellZ(start.y), 0), n - 1)
        let goalI = min(max(terrain.cellX(goal.x), 0), n - 1)
        let goalJ = min(max(terrain.cellZ(goal.y), 0), n - 1)

        let count = n * n
        var gScore = [Float](repeating: .greatestFiniteMagnitude, count: count)
        var cameFrom = [Int32](repeating: -1, count: count)
        var closed = [Bool](repeating: false, count: count)

        let startIdx = startJ * n + startI
        let goalIdx = goalJ * n + goalI

        let line = goal - start
        let lineLength = max(simd_length(line), 1e-5)
        let lineDir = line / lineLength

        gScore[startIdx] = 0
        var heap = MinHeap()
        heap.push(HeapItem(index: Int32(startIdx), cost: 0))

        let neighbours: [(Int, Int, Float)] = [
            (1, 0, 1), (-1, 0, 1), (0, 1, 1), (0, -1, 1),
            (1, 1, 1.4142), (1, -1, 1.4142), (-1, 1, 1.4142), (-1, -1, 1.4142)
        ]

        var iterations = 0
        while let current = heap.pop() {
            let idx = Int(current.index)
            if closed[idx] { continue }
            if idx == goalIdx { break }
            closed[idx] = true

            iterations += 1
            if iterations > 120_000 { return nil }

            let ci = idx % n, cj = idx / n
            let ch = terrain.height[idx]

            for (di, dj, stepCost) in neighbours {
                let ni = ci + di, nj = cj + dj
                guard ni >= 0, ni < n, nj >= 0, nj < n else { continue }
                let nIdx = nj * n + ni
                if closed[nIdx] { continue }

                let nh = terrain.height[nIdx]
                let dh = nh - ch
                var cost = stepCost
                if dh > 0 {
                    cost += (dh / terrain.cellSize) * profile.ascent
                } else {
                    cost += (-dh / terrain.cellSize) * profile.descent
                }
                if nh <= 0 { cost += profile.water }
                if terrain.river[nIdx] > 0 { cost += profile.river }

                let wetDistance = terrain.waterDistance[nIdx]
                if wetDistance < 12 {
                    cost += profile.wet * (1 - wetDistance / 12)
                }
                if terrain.biome[nIdx] == Terrain.Biome.forest.rawValue {
                    cost += profile.forest
                }
                if profile.straightness > 0 {
                    let p = SIMD2(terrain.worldX(ni), terrain.worldZ(nj))
                    let d = p - start
                    let deviation = abs(d.x * lineDir.y - d.y * lineDir.x)
                    cost += deviation * profile.straightness
                }
                if used[nIdx] {
                    cost *= (1 - profile.reuse)
                }
                cost = max(cost, stepCost * 0.35)

                let tentative = gScore[idx] + cost
                if tentative < gScore[nIdx] {
                    gScore[nIdx] = tentative
                    cameFrom[nIdx] = Int32(idx)
                    let dx = Float(goalI - ni), djf = Float(goalJ - nj)
                    let h = sqrt(dx * dx + djf * djf)
                    heap.push(HeapItem(index: Int32(nIdx), cost: tentative + h * 1.15))
                }
            }
        }

        guard cameFrom[goalIdx] >= 0 || goalIdx == startIdx else { return nil }

        var cells: [Int] = []
        var cursor = goalIdx
        while cursor != startIdx {
            cells.append(cursor)
            let prev = Int(cameFrom[cursor])
            if prev < 0 { return nil }
            cursor = prev
        }
        cells.append(startIdx)
        cells.reverse()

        var points = cells.map { idx -> SIMD2<Float> in
            SIMD2(terrain.worldX(idx % n), terrain.worldZ(idx / n))
        }

        // Light smoothing so roads curve instead of stair-stepping.
        if points.count > 4 {
            var smoothed = points
            for _ in 0..<2 {
                for i in 1..<(smoothed.count - 1) {
                    smoothed[i] = (smoothed[i - 1] + smoothed[i] * 2 + smoothed[i + 1]) * 0.25
                }
            }
            points = smoothed
        }
        return points
    }
}
