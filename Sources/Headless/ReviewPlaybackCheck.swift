import Foundation

/// A saved review view must reconstruct the civilisation that Timeline drew.
enum ReviewPlaybackCheck {
    static func run() -> Bool {
        for seed in [UInt64(1), 6393821808673518700] {
            let terrain = WorldGen.generate(seed: seed)
            var playback = Simulation(seed: seed, terrain: terrain)
            for target: Float in [100, 2336.25, 4594, 5000.5] {
                while playback.year < target {
                    playback.advance(to: min(playback.year + 0.25, target))
                }
                var replay = Simulation(seed: seed, terrain: terrain)
                replay.advance(to: target)
                guard playback.year == replay.year, playback.era == replay.era,
                      playback.settlements == replay.settlements,
                      playback.chronicle == replay.chronicle,
                      playback.totalPopulation == replay.totalPopulation,
                      playback.peakPopulation == replay.peakPopulation,
                      playback.foundedCount == replay.foundedCount else {
                    print("FAIL review playback: seed \(seed), year \(target), incremental settlements \(playback.settlements.count), restored \(replay.settlements.count)")
                    return false
                }
            }
        }
        print("PASS review playback: quarter-year stepping and direct replay match at eight seed/year checkpoints")
        return true
    }
}
