import Foundation

enum WorldUpgradeCheck {
    private final class FixtureDefaults: KeyValueStore {
        var values: [String: Any]
        init(_ values: [String: Any] = [:]) { self.values = values }
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values.removeValue(forKey: key) }
        func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
        func string(forKey key: String) -> String? { values[key] as? String }
        func synchronize() -> Bool { true }
    }

    static func run() throws {
        let epoch = 1_700_000_000.25
        let original: [String: Any] = [
            "worldSeed": Int64(-1), "worldEpoch": epoch, "paceName": "Chronicle",
            "worldInitialised": true, "lastSeen": epoch + 86_400, "cameraMode": "Coast",
            "southernHemisphere": true
        ]
        let legacy = FixtureDefaults(original)
        let migrated = try WorldStore.load(from: legacy)
        guard migrated.seed == UInt64.max, migrated.epoch.timeIntervalSince1970 == epoch,
              migrated.historyVersion == .original, migrated.paceName == "Chronicle" else {
            fail("legacy world identity changed during migration")
        }
        var expected = original
        expected["worldHistoryVersion"] = 1
        let reopened = try WorldStore.load(from: FixtureDefaults(legacy.values))
        guard NSDictionary(dictionary: legacy.values) == NSDictionary(dictionary: expected),
              reopened == migrated else { fail("migration changed existing settings or failed to reopen") }

        let unmarked = FixtureDefaults(original.filter { $0.key != "worldInitialised" })
        guard try WorldStore.load(from: unmarked) == migrated else {
            fail("missing initialization marker replaced a valid legacy world")
        }
        for _ in 0..<64 {
            let firstLaunch = FixtureDefaults()
            let fresh = try WorldStore.load(from: firstLaunch)
            let nextLaunch = try WorldStore.load(from: firstLaunch)
            guard fresh.seed != 0, firstLaunch.values["worldHistoryVersion"] as? Int == 1,
                  fresh == nextLaunch else { fail("fresh world identity was not persisted") }
        }

        let unreadable = FixtureDefaults(original.filter { $0.key != "worldEpoch" })
        let originalUnreadable = NSDictionary(dictionary: unreadable.values)
        do {
            _ = try WorldStore.load(from: unreadable)
            fail("incomplete saved world was silently replaced")
        } catch WorldStore.LoadError.unreadableWorld {
            guard NSDictionary(dictionary: unreadable.values) == originalUnreadable else {
                fail("unreadable world was modified")
            }
        }

        let future = FixtureDefaults(expected)
        future.values["worldHistoryVersion"] = 99
        let originalFuture = NSDictionary(dictionary: future.values)
        do {
            _ = try WorldStore.load(from: future)
            fail("unknown history revision was opened as the current rules")
        } catch WorldStore.LoadError.unsupportedHistory(99) {}
        do {
            try WorldStore.save(migrated, to: future)
            fail("unknown history revision could be downgraded")
        } catch WorldStore.LoadError.unsupportedHistory(99) {}
        guard NSDictionary(dictionary: future.values) == originalFuture else {
            fail("unknown history revision was modified")
        }
        print("PASS legacy adoption, reopen, partial-data protection and unknown-version protection")

        for (name, days) in [("Standard", [0.0, 5, 20, 60, 130, 220, 330, 450, 600, 1080]),
                             ("Chronicle", [0.0, 20, 80, 240, 520, 880, 1320, 1800, 2400, 4320]),
                             ("Time-lapse", [0.0, 0.8, 3, 10, 22, 37, 55, 75, 100, 180])] {
            let config = WorldConfig(seed: 1, epoch: migrated.epoch, paceName: name)
            let expectedYears: [Float] = [0, 800, 2000, 3500, 5000, 6200, 7400, 8600, 10000, 14480]
            for (day, year) in zip(days, expectedYears) {
                let actual = config.simYear(at: config.epoch.addingTimeInterval(day * 86_400))
                guard abs(actual - year) < 0.005 else { fail("\(name) day \(day) moved from year \(year)") }
            }
        }
        print("PASS all three legacy pace curves through year 14,480")

        checkChronology(epoch: migrated.epoch)
    }

    private static func checkChronology(epoch: Date) {
        // Version 1 reference captured from the pre-migration HIST-03 simulator.
        let fingerprints = [
            ["afb3335911f0c765", "39f1d21d6a602eb0", "993364b8842a6003",
             "16a96c362e1a3861", "626e6cabfb077fda", "059af522835879ae"],
            ["6608c2d67bbed1f7", "36036e86118c71ac", "355d059b613959fc",
             "b7cf33beca3f4815", "78a092cb4e6b3e2b", "a0facf6ba8b9b914"]
        ]
        for (index, seed) in WorldHistoryFingerprint.seeds.enumerated() {
            let config = WorldConfig(seed: seed, epoch: epoch, paceName: "Standard")
            let terrain = config.replayTerrain()
            var sim = config.startReplay(on: terrain)
            for (checkpoint, year) in WorldHistoryFingerprint.years.enumerated() {
                sim.advance(to: year)
                let digest = WorldHistoryFingerprint.digest(sim)
                guard digest == fingerprints[index][checkpoint] else {
                    fail("version 1 chronology changed for seed \(seed) at year \(year): \(digest)")
                }
                print("history v1 \(seed) \(year) \(digest)")
            }
        }
        print("PASS 12 legacy chronology checkpoints over two seeds")
    }
}
