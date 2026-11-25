import Foundation

enum WorldTransferCheck {
    private final class Defaults: KeyValueStore {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values.removeValue(forKey: key) }
        func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
        func string(forKey key: String) -> String? { values[key] as? String }
        func synchronize() -> Bool { true }
    }

    static func run(output: URL?) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let from = Defaults()
        let to = Defaults()
        let source = TimelineBookmarkStore(directory: folder.appendingPathComponent("source"))
        let destination = TimelineBookmarkStore(directory: folder.appendingPathComponent("destination"))
        let date = Date(timeIntervalSince1970: 1_700_000_000.25)
        let config = WorldConfig(seed: .max, epoch: date, paceName: "Time-lapse", clockAnchor:
            WorldClockAnchor(seed: .max, epoch: date, restoredAt: date, year: 4400.25))
        try WorldStore.save(config, to: from)
        WorldStore.setCameraMode(.coast, in: from)
        WorldStore.setSouthernHemisphere(true, in: from)

        var view = RiverReviewView(seed: .max, year: 4400.25, hour: 11, season: 0.4,
            precipitation: 0, snow: false, animationTime: 42, eye: [0.2, 0.17, 0.31],
            target: [0.1, 0.035, 0.22], fov: 42, width: 1280, height: 800)
        let historical = TimelineBookmark(name: "A Market Bend", mode: .historical, view: view)
        let live = TimelineBookmark(name: "B Coast Live", mode: .live, view: view)
        try source.save(historical)
        try source.save(live)
        view.seed = 1
        let unrelated = TimelineBookmark(name: "Other island", mode: .live, view: view)
        try source.save(unrelated)
        try destination.save(unrelated)
        try WorldStore.save(WorldConfig(seed: 1, epoch: date, paceName: "Standard"), to: to)

        let archive = try WorldArchive.capture(from: from, bookmarks: source, at: date)
        let file = folder.appendingPathComponent("Transfer.evolvingworld.json")
        try archive.write(to: file)
        let decoded = try WorldArchive.read(from: file)
        guard archive == decoded, decoded.seed == .max, decoded.bookmarks == [historical, live] else {
            fail("world file did not preserve the full seed and only the current world's bookmarks")
        }
        if let output { try archive.write(to: output) }

        let restoredAt = date.addingTimeInterval(90 * 86_400)
        try decoded.restore(to: to, bookmarks: destination, at: restoredAt)
        try decoded.restore(to: to, bookmarks: destination, at: restoredAt)
        let restored = try WorldStore.load(from: to)
        let loaded = try destination.load()
        guard restored.seed == config.seed, restored.epoch == config.epoch,
              restored.paceName == config.paceName, restored.historyVersion == config.historyVersion,
              restored.simYear(at: restoredAt) == archive.year,
              restored.simYear(at: restoredAt.addingTimeInterval(86_400)) > archive.year,
              WorldStore.cameraMode(in: to) == .coast, WorldStore.southernHemisphere(in: to) == true,
              Set(loaded.map(\.id)) == Set([historical.id, live.id, unrelated.id]),
              loaded.contains(historical), loaded.contains(live), loaded.contains(unrelated) else {
            fail("destination did not retain clock, preferences, and both worlds' bookmarks")
        }
        var before = config.startReplay(on: config.replayTerrain())
        before.advance(to: archive.year)
        var after = restored.startReplay(on: restored.replayTerrain())
        after.advance(to: restored.simYear(at: restoredAt))
        guard before.era == after.era, before.settlements == after.settlements,
              before.chronicle == after.chronicle else { fail("world history changed during transfer") }
        print("PASS file transfer preserved UInt64 seed, exact fractional year and era, chronology, preferences and bookmarks")

        let blockedDefaults = Defaults()
        blockedDefaults.values["worldHistoryVersion"] = 99
        let blocked = TimelineBookmarkStore(directory: folder.appendingPathComponent("blocked"))
        do {
            try decoded.restore(to: blockedDefaults, bookmarks: blocked, at: restoredAt)
            fail("an unsupported active world was overwritten")
        } catch WorldStore.LoadError.unsupportedHistory(99) {}
        guard try blocked.load().isEmpty, blockedDefaults.values.count == 1 else {
            fail("failed world import left partial data")
        }

        let conflict = TimelineBookmarkStore(directory: folder.appendingPathComponent("conflict"))
        let data = try live.encoded()
        let changedData = Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "B Coast Live", with: "Pre-existing version").utf8)
        let conflicting = try JSONDecoder().decode(TimelineBookmark.self, from: changedData)
        try conflict.save(conflicting)
        do {
            try decoded.restore(to: to, bookmarks: conflict, at: restoredAt)
            fail("conflicting bookmark was overwritten")
        } catch CocoaError.fileWriteFileExists {}
        guard try conflict.load() == [conflicting] else { fail("bookmark rollback did not preserve the original") }

        var altered = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        altered["version"] = 99
        let invalid = folder.appendingPathComponent("Invalid.json")
        try JSONSerialization.data(withJSONObject: altered).write(to: invalid)
        do {
            _ = try WorldArchive.read(from: invalid)
            fail("unsupported archive version was accepted")
        } catch WorldArchive.TransferError.unsupportedFormat {}
        altered["version"] = 1
        altered["bookmarks"] = [altered["bookmarks"] as? [[String: Any]] ?? []].flatMap { $0 + $0 }
        try JSONSerialization.data(withJSONObject: altered).write(to: invalid)
        do {
            _ = try WorldArchive.read(from: invalid)
            fail("duplicate bookmark identifiers were accepted")
        } catch WorldArchive.TransferError.invalidArchive {}
        print("PASS conflicting bookmarks, unsupported revisions and invalid archives preserved the destination")
    }
}
