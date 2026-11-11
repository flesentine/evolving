import Foundation

/// Deterministic PRNG used by terrain generation and the simulation.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextFloat() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + nextFloat() * (range.upperBound - range.lowerBound)
    }

    mutating func nextInt(_ bound: Int) -> Int {
        Int(next() % UInt64(max(bound, 1)))
    }
}

extension SplitMix64: RandomNumberGenerator {}
