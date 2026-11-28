import simd

/// Domestic roundhouses used by Bronze Age residential and farm plots.
enum BronzeHome: String, CaseIterable {
    case timberDaub = "timber-daub"
    case porched
    case uplandStone = "upland-stone"

    var path: String { "variants/bronze-" + rawValue }
    var asset: BuildingAsset { BuildingAsset(path: path, scale: 1 / 0.88) }

    static let skirtDepth: Float = 1.85 // Authored metres below the doorstep.
    static let uplandElevation: Float = 28 / RiverGraph.metresPerUnit

    static func candidates(cell: SIMD2<Int>, elevation: Float) -> [BronzeHome] {
        let alternate = (cell.x + cell.y).isMultiple(of: 2)
        let timber: [BronzeHome] = alternate ? [.timberDaub, .porched] : [.porched, .timberDaub]
        return elevation >= uplandElevation && alternate ? [.uplandStone] + timber : timber
    }

    /// Sample the rotated rectangle, including its interior, on the same
    /// triangulated terrain that the player sees. The skirt and porch posts
    /// extend below this entire grade envelope.
    static func foundationSamples(_ footprint: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let across = footprint[1] - footprint[0]
        let depth = footprint[3] - footprint[0]
        return (0...4).flatMap { z -> [SIMD2<Float>] in
            let row = footprint[0] + depth * (Float(z) / 4)
            return (0...4).map { x in row + across * (Float(x) / 4) }
        }
    }
}
