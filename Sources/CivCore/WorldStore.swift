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

struct WorldConfig {
    var seed: UInt64
    var epoch: Date
    var paceName: String

    var pace: Pace { Pace.named(paceName) }

    /// Simulated year for the given moment.
    func simYear(at date: Date) -> Float {
        let days = Float(date.timeIntervalSince(epoch) / 86_400)
        return pace.simYear(atRealDays: max(days, 0))
    }
}

/// The entire persistent state is two numbers: which world, and when it began.
/// Everything else is replayed deterministically from the seed.
enum WorldStore {

    private enum Key {
        static let seed = "worldSeed"
        static let epoch = "worldEpoch"
        static let pace = "paceName"
        static let initialised = "worldInitialised"
        static let lastSeen = "lastSeen"
        static let hemisphere = "southernHemisphere"
        static let camera = "cameraMode"
    }

    static func load(from defaults: KeyValueStore) -> WorldConfig {
        if defaults.bool(forKey: Key.initialised) == false {
            let fresh = WorldConfig(seed: makeSeed(),
                                    epoch: Date(),
                                    paceName: Pace.standard.name)
            save(fresh, to: defaults)

            // Another display or process may have created the world first.
            // Adopt whatever is now on disk so every screen shows the same
            // island rather than two different seeds.
            defaults.synchronize()
            if let stored = read(from: defaults) {
                return stored
            }
            return fresh
        }

        return read(from: defaults) ?? WorldConfig(seed: makeSeed(),
                                                   epoch: Date(),
                                                   paceName: Pace.standard.name)
    }

    private static func read(from defaults: KeyValueStore) -> WorldConfig? {
        guard defaults.bool(forKey: Key.initialised) else { return nil }

        let seed = UInt64(bitPattern: defaults.object(forKey: Key.seed) as? Int64 ?? 1)
        let epochInterval = defaults.double(forKey: Key.epoch)
        let epoch = epochInterval > 0 ? Date(timeIntervalSince1970: epochInterval) : Date()
        let paceName = defaults.string(forKey: Key.pace) ?? Pace.standard.name

        return WorldConfig(seed: seed == 0 ? 1 : seed,
                           epoch: epoch,
                           paceName: paceName)
    }

    static func save(_ config: WorldConfig, to defaults: KeyValueStore) {
        defaults.set(Int64(bitPattern: config.seed), forKey: Key.seed)
        defaults.set(config.epoch.timeIntervalSince1970, forKey: Key.epoch)
        defaults.set(config.paceName, forKey: Key.pace)
        defaults.set(true, forKey: Key.initialised)
        defaults.synchronize()
    }

    /// Replaces the world with a fresh one, starting now.
    static func reset(in defaults: KeyValueStore, seed: UInt64? = nil) -> WorldConfig {
        let config = WorldConfig(seed: seed ?? makeSeed(), epoch: Date(), paceName: Pace.standard.name)
        save(config, to: defaults)
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
