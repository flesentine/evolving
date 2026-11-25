import Foundation

/// Small abstraction so the saver and the companion can share one world even
/// though the saver runs inside the legacyScreenSaver sandbox container.
protocol KeyValueStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
    func bool(forKey defaultName: String) -> Bool
    func double(forKey defaultName: String) -> Double
    func string(forKey defaultName: String) -> String?
    @discardableResult func synchronize() -> Bool
}

extension UserDefaults: KeyValueStore {}

/// Which camera the saver should use. `auto` cycles through the shots.
enum CameraMode: String, CaseIterable {
    case auto = "Auto"
    case wide = "Wide"
    case coast = "Coast"
    case city = "City"
    case street = "Street"
    case square = "Square"
}

/// Keep the terrain, simulation and pace curves for published revisions
/// available to existing worlds. A new default needs a new revision.
enum WorldHistoryVersion: Int {
    case original = 1

    static let current: Self = .original

    func terrain(seed: UInt64) -> Terrain {
        switch self {
        case .original: return WorldGen.generate(seed: seed, size: 384)
        }
    }

    func simulation(seed: UInt64, terrain: Terrain) -> Simulation {
        switch self {
        case .original: return Simulation(seed: seed, terrain: terrain)
        }
    }

    func pace(named name: String) -> Pace {
        switch self {
        case .original: return Pace.named(name)
        }
    }
}

struct WorldConfig: Equatable {
    var seed: UInt64
    var epoch: Date
    var paceName: String

    var historyVersion: WorldHistoryVersion = .current

    var pace: Pace { historyVersion.pace(named: paceName) }

    func replayTerrain() -> Terrain {
        historyVersion.terrain(seed: seed)
    }

    func startReplay(on terrain: Terrain) -> Simulation {
        historyVersion.simulation(seed: seed, terrain: terrain)
    }

    /// Simulated year for the given moment.
    func simYear(at date: Date) -> Float {
        let days = Float(date.timeIntervalSince(epoch) / 86_400)
        return pace.simYear(atRealDays: max(days, 0))
    }
}

/// Persistent identity and clock for deterministic replay. Keep the legacy
/// keys readable by earlier builds and stamp their history rules once.
enum WorldStore {

    private enum Key {
        static let seed = "worldSeed"
        static let epoch = "worldEpoch"
        static let pace = "paceName"
        static let initialised = "worldInitialised"
        static let lastSeen = "lastSeen"
        static let hemisphere = "southernHemisphere"
        static let camera = "cameraMode"
        static let historyVersion = "worldHistoryVersion"
    }

    enum LoadError: LocalizedError {
        case unreadableWorld
        case unsupportedHistory(Int)

        var errorDescription: String? {
            switch self {
            case .unreadableWorld:
                return "Evolving could not read this world's saved seed or clock. Its saved data is still in place."
            case .unsupportedHistory(let version):
                return "This world uses history version \(version). Open it in a newer compatible version of Evolving."
            }
        }
    }

    static func load(from defaults: KeyValueStore) throws -> WorldConfig {
        let version = try readHistoryVersion(defaults)
        let savedSeed = defaults.object(forKey: Key.seed)
        let savedEpoch = defaults.object(forKey: Key.epoch)
        let hasWorld = version != nil || defaults.bool(forKey: Key.initialised)
            || savedSeed != nil || savedEpoch != nil

        if !hasWorld {
            let fresh = WorldConfig(seed: makeSeed(), epoch: Date(), paceName: Pace.standard.name)
            try save(fresh, to: defaults)
            return fresh
        }

        guard let rawSeed = savedSeed as? Int64, rawSeed != 0,
              let seconds = savedEpoch as? Double, seconds.isFinite, seconds > 0 else {
            throw LoadError.unreadableWorld
        }

        let historyVersion = version ?? .original
        let config = WorldConfig(seed: UInt64(bitPattern: rawSeed),
                                 epoch: Date(timeIntervalSince1970: seconds),
                                 paceName: defaults.string(forKey: Key.pace) ?? Pace.standard.name,
                                 historyVersion: historyVersion)
        if version == nil {
            // Adopt unversioned worlds under the rules they were created with.
            // Their original seed, epoch, pace and preferences stay byte-for-byte.
            defaults.set(historyVersion.rawValue, forKey: Key.historyVersion)
            defaults.synchronize()
        }
        return config
    }

    private static func readHistoryVersion(_ defaults: KeyValueStore) throws -> WorldHistoryVersion? {
        guard let stored = defaults.object(forKey: Key.historyVersion) else { return nil }
        guard let number = stored as? Int else { throw LoadError.unreadableWorld }
        guard let version = WorldHistoryVersion(rawValue: number) else {
            throw LoadError.unsupportedHistory(number)
        }
        return version
    }

    static func save(_ config: WorldConfig, to defaults: KeyValueStore) throws {
        _ = try readHistoryVersion(defaults)
        defaults.set(Int64(bitPattern: config.seed), forKey: Key.seed)
        defaults.set(config.epoch.timeIntervalSince1970, forKey: Key.epoch)
        defaults.set(config.paceName, forKey: Key.pace)
        defaults.set(config.historyVersion.rawValue, forKey: Key.historyVersion)
        defaults.set(true, forKey: Key.initialised)
        defaults.synchronize()
    }

    /// Replaces the world with a fresh one, starting now.
    static func reset(in defaults: KeyValueStore) throws -> WorldConfig {
        let config = WorldConfig(seed: makeSeed(), epoch: Date(), paceName: Pace.standard.name)
        try save(config, to: defaults)
        return config
    }

    static func makeSeed() -> UInt64 {
        var generator = SplitMix64(seed: UInt64(Date().timeIntervalSince1970 * 1000))
        let value = generator.next()
        return max(value >> 1, 1)
    }

    /// `nil` means "follow the region"; true/false is an explicit choice.
    static func southernHemisphere(in defaults: KeyValueStore) -> Bool? {
        defaults.object(forKey: Key.hemisphere) as? Bool
    }

    static func setSouthernHemisphere(_ value: Bool?, in defaults: KeyValueStore) {
        if let value {
            defaults.set(value, forKey: Key.hemisphere)
        } else {
            defaults.removeObject(forKey: Key.hemisphere)
        }
        defaults.synchronize()
    }

    static func cameraMode(in defaults: KeyValueStore) -> CameraMode {
        CameraMode(rawValue: defaults.string(forKey: Key.camera) ?? "") ?? .auto
    }

    static func setCameraMode(_ mode: CameraMode, in defaults: KeyValueStore) {
        defaults.set(mode.rawValue, forKey: Key.camera)
        defaults.synchronize()
    }

    /// When the world was last on screen. Used for the "while you were away"
    /// recap; it never affects the simulation itself.
    static func lastSeen(in defaults: KeyValueStore) -> Date? {
        let interval = defaults.double(forKey: Key.lastSeen)
        return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

    static func markSeen(_ date: Date, in defaults: KeyValueStore) {
        defaults.set(date.timeIntervalSince1970, forKey: Key.lastSeen)
        defaults.synchronize()
    }
}
