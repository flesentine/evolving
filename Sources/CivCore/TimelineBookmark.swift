import Foundation

/// A favorite place belongs to one world. A historical bookmark pins the
/// displayed year; a Live bookmark keeps following that world's clock.
struct TimelineBookmark: Codable, Equatable {
    enum Mode: String, Codable {
        case historical, live
    }

    private(set) var version = 1
    let id: UUID
    let name: String
    let mode: Mode
    let view: RiverReviewView

    init(name: String, mode: Mode, view: RiverReviewView) {
        self.id = UUID()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mode = mode
        self.view = view
    }

    func validated() throws -> Self {
        guard version == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, name.rangeOfCharacter(from: .newlines) == nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Live worlds can continue well beyond the historical slider.
        // The saved Live year is descriptive and never drives a replay.
        _ = try view.validated(maximumYear: mode == .live ? .greatestFiniteMagnitude : 12000)
        // A camera must have a horizontal viewing direction for lookAt's up
        // vector. Normal Timeline views always include a horizontal offset.
        let dx = view.eye[0] - view.target[0]
        let dz = view.eye[2] - view.target[2]
        let dy = view.eye[1] - view.target[1]
        let horizontal = dx * dx + dz * dz
        guard horizontal > 0, (horizontal + dy * dy).isFinite else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return self
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(validated())
    }
}

/// Independent files allow simultaneous saves without replacing other
/// bookmarks. The world configuration and existing review exports stay separate.
struct TimelineBookmarkStore {
    let directory: URL

    static func local() throws -> Self {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true)
        return Self(directory: support.appendingPathComponent("Evolving Timeline/Bookmarks", isDirectory: true))
    }

    func save(_ bookmark: TimelineBookmark) throws {
        let data = try bookmark.encoded()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(for: bookmark.id), options: .atomic)
    }

    func load() throws -> [TimelineBookmark] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }

        return contents.compactMap { url -> TimelineBookmark? in
            guard url.pathExtension == "json",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            do {
                let bookmark = try JSONDecoder().decode(TimelineBookmark.self, from: Data(contentsOf: url)).validated()
                guard bookmark.id == id else { throw CocoaError(.fileReadCorruptFile) }
                return bookmark
            } catch {
                NSLog("Evolving Timeline: could not read bookmark at \(url.lastPathComponent): \(error)")
                return nil
            }
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    /// Keep existing bookmark files intact. A complete temporary file is
    /// linked into place exclusively, so simultaneous imports cannot replace it.
    func importBookmarks(_ bookmarks: [TimelineBookmark]) throws -> [TimelineBookmark] {
        guard !bookmarks.isEmpty else { return [] }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var added: [TimelineBookmark] = []
        do {
            for bookmark in bookmarks {
                let url = file(for: bookmark.id)
                let temporary = directory.appendingPathComponent(".import-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try bookmark.encoded().write(to: temporary, options: .atomic)
                do {
                    try FileManager.default.linkItem(at: temporary, to: url)
                    added.append(bookmark)
                } catch CocoaError.fileWriteFileExists {
                    let existing = try JSONDecoder().decode(TimelineBookmark.self, from: Data(contentsOf: url))
                    guard existing == bookmark else {
                        throw CocoaError(.fileWriteFileExists, userInfo: [
                            NSLocalizedDescriptionKey: "A different bookmark conflicts with “\(bookmark.name)”. Existing bookmarks were kept."
                        ])
                    }
                }
            }
        } catch {
            for bookmark in added { try? remove(bookmark) }
            throw error
        }
        return added
    }

    func remove(_ bookmark: TimelineBookmark) throws {
        try FileManager.default.removeItem(at: file(for: bookmark.id))
    }

    private func file(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}
