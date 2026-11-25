import Foundation

/// Check the chronology, with settlement and event locations rounded to metres.
enum WorldHistoryFingerprint {
    static let seeds: [UInt64] = [1, 6393821808673518700]
    static let years: [Float] = [500, 2336.25, 4400.25, 7900, 10000, 14480]

    static func digest(_ simulation: Simulation) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func append(_ value: String) {
            for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
            hash = (hash ^ 0xFF) &* 0x0000_0100_0000_01B3
        }
        func position(_ x: Float, _ z: Float) {
            append(String(Int((x * RiverGraph.metresPerUnit).rounded())))
            append(String(Int((z * RiverGraph.metresPerUnit).rounded())))
        }

        append(String(simulation.era.rawValue))
        for town in simulation.settlements {
            append(String(town.id))
            append(town.name)
            append(String(town.founded.bitPattern))
            append(String(town.abandoned.bitPattern))
            position(town.x, town.z)
        }
        for event in simulation.chronicle {
            append(String(event.kind.rawValue))
            append(String(event.year.bitPattern))
            append(event.text)
            position(event.x, event.z)
        }
        return String(format: "%016llx", hash)
    }
}
