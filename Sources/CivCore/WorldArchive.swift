import Foundation

/// A snapshot carries the original identity and an exact replay position. The
/// destination resumes from that year when the user confirms the import.
struct WorldArchive: Codable, Equatable {
    static let maximumYear: Float = 5_000_000
    private static let maximumBytes = 16 * 1024 * 1024

    private(set) var format = "evolving-world"
    private(set) var version = 1
    let seed: UInt64
    let epoch: Date
    let paceName: String
    let historyVersion: Int
    let year: Float
    let camera: CameraMode
    let southernHemisphere: Bool?
    let bookmarks: [TimelineBookmark]

    enum TransferError: LocalizedError {
        case invalidArchive, unsupportedFormat, tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidArchive: return "The file contains an invalid world, clock, or bookmark."
            case .unsupportedFormat: return "This world file uses a format or history revision this version cannot open."
            case .tooLarge: return "The world file is larger than 16 MB."
            }
        }
    }

    static func capture(from defaults: KeyValueStore, bookmarks: TimelineBookmarkStore,
                        at date: Date) throws -> Self {
        let config = try WorldStore.load(from: defaults)
        return try Self(seed: config.seed, epoch: config.epoch, paceName: config.pace.name,
                        historyVersion: config.historyVersion.rawValue, year: config.simYear(at: date),
                        camera: WorldStore.cameraMode(in: defaults),
                        southernHemisphere: WorldStore.southernHemisphere(in: defaults),
                        bookmarks: bookmarks.load().filter { $0.view.seed == config.seed }).validated()
    }

    func validated() throws -> Self {
        guard format == "evolving-world", version == 1,
              let history = WorldHistoryVersion(rawValue: historyVersion) else {
            throw TransferError.unsupportedFormat
        }
        guard seed != 0, year.isFinite, year >= 0, year <= Self.maximumYear,
              epoch.timeIntervalSince1970.isFinite, epoch.timeIntervalSince1970 > 0,
              Date(timeIntervalSince1970: epoch.timeIntervalSince1970) == epoch,
              history.pace(named: paceName).name == paceName else { throw TransferError.invalidArchive }
        var identifiers = Set<UUID>()
        for bookmark in bookmarks {
            guard bookmark.view.seed == seed, identifiers.insert(bookmark.id).inserted,
                  (try? bookmark.validated()) != nil else { throw TransferError.invalidArchive }
        }
        return self
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(validated())
        guard data.count <= Self.maximumBytes else { throw TransferError.tooLarge }
        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> Self {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard bytes.count <= maximumBytes else { throw TransferError.tooLarge }
        guard let archive = try? JSONDecoder().decode(Self.self, from: bytes) else {
            throw TransferError.invalidArchive
        }
        return try archive.validated()
    }

    func restore(to defaults: KeyValueStore, bookmarks store: TimelineBookmarkStore,
                 at date: Date) throws {
        _ = try validated()
        guard let history = WorldHistoryVersion(rawValue: historyVersion) else {
            throw TransferError.unsupportedFormat
        }
        let config = WorldConfig(seed: seed, epoch: epoch, paceName: paceName,
            historyVersion: history, clockAnchor: WorldClockAnchor(seed: seed, epoch: epoch,
                                                                   restoredAt: date, year: year))
        let added = try store.importBookmarks(bookmarks)
        do {
            try WorldStore.save(config, to: defaults)
        } catch {
            for bookmark in added { try? store.remove(bookmark) }
            throw error
        }
        WorldStore.setCameraMode(camera, in: defaults)
        WorldStore.setSouthernHemisphere(southernHemisphere, in: defaults)
        WorldStore.markSeen(date, in: defaults)
    }
}
