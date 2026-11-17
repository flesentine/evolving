import Foundation
import simd

/// Regression for the reported cutoff curtains: metre-scale flat water below
/// a high original surface, shifted relative to the old 20 m bucket lattice.
enum RiverTerrainFixtures {
    static func run() -> Bool {
        // A synthetic river climbs away from one sea row. Estuary excavation
        // may reach only the original two-cell coastal halo plus its lip.
        // Rotate the input to expose the old row-order propagation.
        let size = 16
        for orientation in 0..<4 {
            func index(_ i: Int, _ j: Int) -> Int {
                switch orientation {
                case 1: return i * size + (size - 1 - j)
                case 2: return (size - 1 - j) * size + (size - 1 - i)
                case 3: return (size - 1 - i) * size + j
                default: return j * size + i
                }
            }
            var heights = [Float](repeating: 100 / RiverChannel.metresPerUnit, count: size * size)
            var river = [UInt8](repeating: 0, count: heights.count)
            for i in 0..<size { heights[index(i, 0)] = -1 / RiverChannel.metresPerUnit }
            for j in 1..<size { river[index(size / 2, j)] = 1 }
            WorldGen.carveEstuaries(&heights, river: river, size: size)
            for j in 1..<size {
                let expected: Float = j <= 2 ? -6 : (j == 3 ? 2 : 100)
                if abs(heights[index(size / 2, j)] * RiverChannel.metresPerUnit - expected) > 0.001 {
                    print("FAIL estuary coastal halo: orientation \(orientation), row \(j)")
                    return false
                }
            }
        }
        print("estuary fixtures: 4 orientations; original coastal halo preserved")
        let terrain = WorldGen.generate(seed: 1)
        var probes = 0, failures = 0
        var maxJump: Float = 0, maxReferenceError: Float = 0
        let metres = RiverChannel.metresPerUnit
        for width: Float in [3, 5, 10, 20] {
            for shift: Float in [0, 0.25, 0.5, 0.75] {
                let centre = SIMD2<Float>(19 / metres + shift * terrain.cellSize, 0)
                let samples = [-1, 1].map { sign in
                    RiverSample(position: centre + SIMD2(0, Float(sign) * 15 / metres),
                                bed: 9.4 / metres, width: width / metres, tangent: SIMD2(0, 1),
                                channelWidth: width / metres, along: Float(sign + 1) * 15,
                                waterOverride: 10 / metres)
                }
                let reach = RiverReach(id: 0, samples: samples, isSource: true, isMouth: true)
                let field = RiverChannel.Field(terrain: terrain, network: [reach])
                for radius in [Float(0), RiverChannel.terrainSupportRadius(terrain)] {
                    for boundary in -5...7 {
                        let x = Float(boundary) * 20 / metres
                        let delta: Float = 0.0001 / metres // 0.1 mm either side
                        let a = SIMD2(x - delta, 0), b = SIMD2(x + delta, 0)
                        let ha = field.carvedHeight(100 / metres, at: a, supportRadius: radius)
                        let hb = field.carvedHeight(100 / metres, at: b, supportRadius: radius)
                        let reference = field.carvedHeight(100 / metres, at: a, supportRadius: radius, exhaustive: true)
                        let jump = abs(ha - hb) * metres, error = abs(ha - reference) * metres
                        maxJump = max(maxJump, jump); maxReferenceError = max(maxReferenceError, error)
                        if jump > 0.001 || error > 0.0001 || ha > 100 / metres { failures += 1 }
                        probes += 1
                    }
                }
            }
        }
        print("terrain cutoff fixtures: \(probes) bucket-boundary pairs; failures \(failures)")
        print(String(format: "max 0.2 mm probe step %.6f m; exhaustive reference error %.6f m", maxJump, maxReferenceError))
        print(failures == 0 ? "PASS continuous terrain fixtures" : "FAIL continuous terrain fixtures")
        return failures == 0
    }
}
