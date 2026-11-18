import Foundation
import simd

extension Terrain {
    /// Simulation water proximity is derived from the selected canonical graph,
    /// never from a separately thresholded D8 river mask. The grid is a distance
    /// seed raster, not a replacement for continuous renderer wet classification.
    mutating func applyRiverGraph() {
        guard let graph = riverGraph else { return }
        river = [UInt8](repeating: 0, count: height.count)
        flow = graph.contributingArea.isEmpty ? [Float](repeating: 0, count: height.count) : graph.contributingArea
        let padding = cellSize * sqrt(Float(2)) * 0.5 // one grid-vertex support radius, world units
        for reach in graph.reaches {
            for k in 1..<reach.samples.count {
                let a = reach.samples[k - 1], b = reach.samples[k]
                func half(_ s: RiverSample) -> Float {
                    RiverGraph.channelHalfWidth(s)
                }
                let radius = max(half(a), half(b)) + padding
                let low = simd_min(a.position, b.position) - SIMD2(repeating: radius)
                let high = simd_max(a.position, b.position) + SIMD2(repeating: radius)
                let i0 = max(cellX(low.x) - 1, 0), i1 = min(cellX(high.x) + 1, size - 1)
                let j0 = max(cellZ(low.y) - 1, 0), j1 = min(cellZ(high.y) + 1, size - 1)
                guard i0 <= i1 && j0 <= j1 else { continue }
                let ab = b.position - a.position, length = max(simd_length_squared(ab), 1e-20) // world-unit² predicate
                for j in j0...j1 { for i in i0...i1 {
                    let point = SIMD2(worldX(i), worldZ(j))
                    let t = min(max(simd_dot(point - a.position, ab) / length, 0), 1)
                    if simd_distance(point, a.position + ab * t) <= half(a) + (half(b) - half(a)) * t + padding {
                        let idx = index(i, j)
                        river[idx] = max(river[idx], a.width * RiverGraph.metresPerUnit > 15 ? 3 : 1)
                    }
                }}
            }
        }
        lakeWater = [Float](repeating: 0, count: height.count)
        for lake in graph.lakes { for idx in lake.cells {
            lakeWater[idx] = lake.level; river[idx] = max(river[idx], 1)
        }}
        waterDistance = [Float](repeating: .greatestFiniteMagnitude, count: height.count)
        var queue: [Int] = []
        for idx in height.indices where height[idx] <= 0 || river[idx] > 0 {
            waterDistance[idx] = 0; queue.append(idx)
        }
        var head = 0
        while head < queue.count {
            let idx = queue[head]; head += 1
            let i = idx % size, j = idx / size, distance = waterDistance[idx] + 1
            for (di, dj) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let ni = i + di, nj = j + dj
                guard ni >= 0 && ni < size && nj >= 0 && nj < size else { continue }
                let n = index(ni, nj)
                if distance < waterDistance[n] { waterDistance[n] = distance; queue.append(n) }
            }
        }
        for idx in height.indices {
            let flat = smoothstep(0.9, 0.15, slope[idx])
            let low = smoothstep(0.20, 0.03, height[idx])
            let wet: Float = 1 / (1 + waterDistance[idx] * 0.22)
            let soil: Float = biome[idx] == Biome.beach.rawValue ? 0.35 : 1
            fertility[idx] = lakeWater[idx] > height[idx] ? 0 : clamp01(flat * low * wet * soil * (0.55 + moisture[idx] * 0.65))
        }
    }
}
