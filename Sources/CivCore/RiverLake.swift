import Foundation

/// A priority-flood depression bounded by original terrain at one spill level.
/// Cells are water-covered grid vertices; rendering clips their adjacent terrain
/// triangles at level rather than drawing a radius-based terminal disc.
struct RiverLake {
    let id: Int
    let level: Float
    let cells: [Int]

    static func detect(_ terrain: Terrain, filled: [Float]) -> [RiverLake] {
        let n = terrain.size, minimumDepth = 0.5 / RiverGraph.metresPerUnit // 50 cm real depression
        var assigned = [Bool](repeating: false, count: filled.count), lakes: [RiverLake] = []
        let seeds = filled.indices.filter { filled[$0] - terrain.height[$0] > minimumDepth }
            .sorted { filled[$0] == filled[$1] ? $0 < $1 : filled[$0] < filled[$1] }
        for seed in seeds where !assigned[seed] {
            let level = filled[seed]
            guard level > 0 else { continue }
            var queue = [seed], head = 0, openToSea = false
            var visited: Set<Int> = [seed]
            while head < queue.count {
                let i = queue[head]; head += 1
                if terrain.height[i] <= 0 { openToSea = true }
                // Adjacency follows the actual a-c terrain triangulation,
                // including its diagonal; a square-grid flood splits real
                // water connections at diagonally adjacent low vertices.
                for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1)] {
                    let x = i % n + dx, z = i / n + dz
                    guard x >= 0 && x < n && z >= 0 && z < n else { openToSea = true; continue }
                    let next = z * n + x
                    if !visited.contains(next) && terrain.height[next] < level {
                        visited.insert(next); queue.append(next)
                    }
                }
            }
            for cell in queue { assigned[cell] = true }
            if !openToSea { lakes.append(RiverLake(id: lakes.count, level: level, cells: queue.sorted())) }
        }
        return lakes
    }
}
