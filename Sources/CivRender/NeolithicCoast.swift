import simd

enum NeolithicCoast {
    private static let metres = RiverGraph.metresPerUnit
    private static let headings = (0..<16).map { index in
        let angle = Float(index) * (.pi / 8)
        return SIMD2(cos(angle), sin(angle))
    }

    /// The visual style follows open sea and a low coastal shelf. A single
    /// wet ray (for example down a river mouth) is insufficient. A ridge
    /// rising above the plot screens that direction.
    static func isExposed(_ point: SIMD2<Float>, terrain: Terrain) -> Bool {
        let elevation = terrain.originalTriangleHeight(at: point)
        guard elevation >= 4 / metres, elevation <= 34 / metres,
              !terrain.isWater(x: point.x, z: point.y) else { return false }

        let open = headings.map { direction in
            for distance in [Float(40), 80, 120, 160] {
                let sample = point + direction * (distance / metres)
                let height = terrain.originalTriangleHeight(at: sample)
                if height > elevation + 10 / metres { return false }
                if height < -1 / metres {
                    return [Float(55), 115].allSatisfy { fetch in
                        let offshore = sample + direction * (fetch / metres)
                        return terrain.originalTriangleHeight(at: offshore) < -1 / metres
                    }
                }
            }
            return false
        }
        return open.indices.contains { open[$0] && open[($0 + 1) % open.count] }
    }
}
