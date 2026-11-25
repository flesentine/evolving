import Cocoa
import ScreenSaver
import ImageIO
import UniformTypeIdentifiers

/// A small companion window: the current state of the world, a pace selector,
/// and shortcuts into Screen Saver settings and the live preview. It reads the
/// same `ScreenSaverDefaults` domain as the saver, so it always agrees with it.
final class CompanionApp: NSObject, NSApplicationDelegate {

    private let moduleName = "com.mccullough.evolving"

    private var window: NSWindow!
    private var yearLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var headlineLabel: NSTextField!
    private var pacePopup: NSPopUpButton!
    private var cameraPopup: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var historyView: NSTextView!
    private var historyCount = -1

    private var store: UserDefaults!
    private var fixtureDomain: String?
    private var config: WorldConfig?
    private var simulation: Simulation?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = ScreenSaverDefaults(forModuleWithName: moduleName) ?? .standard
        buildMenu()
        buildWindow()
        if CommandLine.arguments.dropFirst().first == "--check-world-transfer" {
            runTransferFixture()
        } else {
            reloadWorld()
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NSApp.activate(ignoringOtherApps: true)

        if fixtureDomain != nil && ProcessInfo.processInfo.environment["EVOLVING_COMPANION_SHOT"] == nil {
            NSApp.terminate(nil)
            return
        }

        // Screenshot hook for documentation and visual checks.
        if let path = ProcessInfo.processInfo.environment["EVOLVING_COMPANION_SHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                let id = CGWindowID(self.window.windowNumber)
                if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                                       [.boundsIgnoreFraming, .bestResolution]) {
                    let url = URL(fileURLWithPath: path)
                    if let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                                  "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, image, nil)
                        CGImageDestinationFinalize(dest)
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let fixtureDomain { store.removePersistentDomain(forName: fixtureDomain) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Evolving",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Evolving",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Window

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       colour: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = colour
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 2
        return field
    }

    private func buildWindow() {
        let size = NSSize(width: 420, height: 638)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable],
                          backing: .buffered,
                          defer: false)
        window.title = "Evolving"
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content

        let title = label("Evolving", size: 24, weight: .semibold, colour: .labelColor)
        title.frame = NSRect(x: 24, y: size.height - 58, width: 300, height: 30)
        content.addSubview(title)

        yearLabel = label("", size: 19, weight: .medium, colour: .labelColor)
        yearLabel.frame = NSRect(x: 24, y: size.height - 96, width: 372, height: 26)
        content.addSubview(yearLabel)

        detailLabel = label("", size: 13, weight: .regular, colour: .secondaryLabelColor)
        detailLabel.frame = NSRect(x: 24, y: size.height - 120, width: 372, height: 20)
        content.addSubview(detailLabel)

        headlineLabel = label("", size: 11.5, weight: .regular, colour: .tertiaryLabelColor)
        headlineLabel.frame = NSRect(x: 24, y: size.height - 146, width: 372, height: 20)
        content.addSubview(headlineLabel)

        let separator = NSBox(frame: NSRect(x: 24, y: size.height - 166, width: 372, height: 1))
        separator.boxType = .separator
        content.addSubview(separator)

        let historyLabel = label("History", size: 13, weight: .semibold, colour: .labelColor)
        historyLabel.frame = NSRect(x: 24, y: size.height - 196, width: 200, height: 20)
        content.addSubview(historyLabel)

        let scroll = NSScrollView(frame: NSRect(x: 24, y: size.height - 410, width: 372, height: 204))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false

        let history = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        history.isEditable = false
        history.isSelectable = true
        history.drawsBackground = false
        history.font = .systemFont(ofSize: 11)
        history.textColor = .secondaryLabelColor
        history.textContainerInset = NSSize(width: 4, height: 6)
        history.isVerticallyResizable = true
        history.autoresizingMask = [.width]
        history.textContainer?.widthTracksTextView = true
        scroll.documentView = history
        content.addSubview(scroll)
        historyView = history

        let paceLabel = label("Pace", size: 13, weight: .regular, colour: .labelColor)
        paceLabel.frame = NSRect(x: 24, y: 188, width: 50, height: 20)
        content.addSubview(paceLabel)

        pacePopup = NSPopUpButton(frame: NSRect(x: 78, y: 184, width: 180, height: 26),
                                  pullsDown: false)
        pacePopup.addItems(withTitles: Pace.all.map { $0.name })
        content.addSubview(pacePopup)

        let cameraLabel = label("Camera", size: 13, weight: .regular, colour: .labelColor)
        cameraLabel.frame = NSRect(x: 24, y: 150, width: 54, height: 20)
        content.addSubview(cameraLabel)

        cameraPopup = NSPopUpButton(frame: NSRect(x: 78, y: 146, width: 180, height: 26),
                                    pullsDown: false)
        cameraPopup.addItems(withTitles: CameraMode.allCases.map { $0.rawValue })
        content.addSubview(cameraPopup)

        let apply = NSButton(title: "Apply", target: self, action: #selector(applyPace))
        apply.frame = NSRect(x: 266, y: 146, width: 70, height: 26)
        apply.bezelStyle = .rounded
        content.addSubview(apply)

        let settings = NSButton(title: "Screen Saver Settings…",
                                target: self, action: #selector(openSettings))
        settings.frame = NSRect(x: 24, y: 61, width: 190, height: 30)
        settings.bezelStyle = .rounded
        content.addSubview(settings)

        let preview = NSButton(title: "Preview", target: self, action: #selector(previewSaver))
        preview.frame = NSRect(x: 222, y: 61, width: 84, height: 30)
        preview.bezelStyle = .rounded
        content.addSubview(preview)

        let newWorld = NSButton(title: "New World", target: self, action: #selector(newWorld))
        newWorld.frame = NSRect(x: 314, y: 61, width: 82, height: 30)
        newWorld.bezelStyle = .rounded
        content.addSubview(newWorld)

        let exportButton = NSButton(title: "Export World…", target: self, action: #selector(exportWorld))
        exportButton.bezelStyle = .rounded
        exportButton.frame = NSRect(x: 24, y: 23, width: 140, height: 30)
        content.addSubview(exportButton)

        let importButton = NSButton(title: "Import World…", target: self, action: #selector(importWorld))
        importButton.bezelStyle = .rounded
        importButton.frame = NSRect(x: 171, y: 23, width: 140, height: 30)
        content.addSubview(importButton)

        statusLabel = label("", size: 11, weight: .regular, colour: .secondaryLabelColor)
        statusLabel.frame = NSRect(x: 24, y: 3, width: 372, height: 18)
        content.addSubview(statusLabel)


        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - World state

    private func reloadWorld(at date: Date = Date()) {
        guard let store else { return }

        let config: WorldConfig
        do {
            config = try WorldStore.load(from: store)
        } catch {
            self.config = nil
            simulation = nil
            yearLabel.stringValue = "World unavailable"
            statusLabel.stringValue = error.localizedDescription
            let alert = NSAlert()
            alert.messageText = "Evolving could not open this world"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
            return
        }
        self.config = config

        var sim = config.startReplay(on: config.replayTerrain())
        sim.advance(to: config.simYear(at: date))
        simulation = sim
        historyCount = -1

        pacePopup?.selectItem(withTitle: config.paceName)
        cameraPopup?.selectItem(withTitle: WorldStore.cameraMode(in: store).rawValue)
        updateLabels(sim)
    }

    private func tick() {
        guard var sim = simulation, let config else { return }
        let target = config.simYear(at: Date())
        if target > sim.year {
            sim.advance(to: target)
            simulation = sim
        }
        updateLabels(sim)
    }

    private func updateLabels(_ sim: Simulation) {
        yearLabel.stringValue = "Year \(Int(sim.year))  ·  \(sim.era.name)"

        let population = Int(sim.totalPopulation.rounded())
        let alive = sim.settlements.reduce(0) { $1.isAlive ? $0 + 1 : $0 }
        detailLabel.stringValue = "\(population.formatted()) people  ·  \(alive) settlements"

        if let entry = sim.headline() {
            headlineLabel.stringValue = "\(Int(entry.year)) — \(entry.text)"
        } else {
            headlineLabel.stringValue = ""
        }

        if sim.chronicle.count != historyCount, let historyView {
            historyCount = sim.chronicle.count
            let entries = sim.chronicle.suffix(150)
            historyView.string = entries
                .map { "Year \(Int($0.year)) — \($0.text)" }
                .joined(separator: "\n")
            historyView.scrollToEndOfDocument(nil)
        }
    }

    // MARK: - Actions

    @objc private func exportWorld() {
        let panel = NSSavePanel()
        panel.title = "Export Evolving World"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Evolving World.evolvingworld.json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                let archive = try WorldArchive.capture(from: self.store,
                    bookmarks: TimelineBookmarkStore.local(), at: Date())
                try archive.write(to: url)
                self.statusLabel.stringValue = "World exported at year \(Int(archive.year))."
            } catch {
                self.transferError("World could not be exported", error)
            }
        }
    }

    @objc private func importWorld() {
        let panel = NSOpenPanel()
        panel.title = "Import Evolving World"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                self.confirmImport(try WorldArchive.read(from: url))
            } catch {
                self.transferError("World could not be read", error)
            }
        }
    }

    private func confirmImport(_ archive: WorldArchive) {
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Switch to the world in this file?"
        confirm.informativeText = "The imported world resumes at year \(archive.year.formatted()). "
            + "Evolving saves a backup of your current world before switching. "
            + "Reopen Timeline and Player afterward to see the imported world."
        confirm.addButton(withTitle: "Cancel")
        confirm.addButton(withTitle: "Import World")
        confirm.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            do {
                let bookmarks = try TimelineBookmarkStore.local()
                let support = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                let backups = support.appendingPathComponent("Evolving Timeline/World Backups", isDirectory: true)
                let previous = try WorldArchive.capture(from: self.store, bookmarks: bookmarks, at: Date())
                try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                let backup = backups.appendingPathComponent("Previous World " + UUID().uuidString + ".evolvingworld.json")
                try previous.write(to: backup)
                try self.restoreArchive(archive, bookmarks: bookmarks)
            } catch {
                self.transferError("World could not be imported", error)
            }
        }
    }

    private func restoreArchive(_ archive: WorldArchive, bookmarks: TimelineBookmarkStore) throws {
        let now = Date()
        try archive.restore(to: store, bookmarks: bookmarks, at: now)
        reloadWorld(at: now)
        statusLabel.stringValue = "World restored at year \(archive.year.formatted())."
    }

    private func transferError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    private func runTransferFixture() {
        let args = CommandLine.arguments
        guard args.count == 4 else { exit(2) }
        let domain = "com.mccullough.evolving.transfer-test." + UUID().uuidString
        guard let fixture = UserDefaults(suiteName: domain) else { exit(2) }
        fixtureDomain = domain
        store = fixture
        let bookmarks = TimelineBookmarkStore(directory: URL(fileURLWithPath: args[3], isDirectory: true))
        do {
            let archive = try WorldArchive.read(from: URL(fileURLWithPath: args[2]))
            try restoreArchive(archive, bookmarks: bookmarks)
            let restored = try WorldStore.load(from: store)
            let savedBookmarks = try bookmarks.load()
            guard restored.seed == archive.seed, restored.epoch == archive.epoch,
                  simulation?.year == archive.year, simulation?.era == Era.at(archive.year),
                  Set(savedBookmarks.map(\.id)) == Set(archive.bookmarks.map(\.id)),
                  savedBookmarks.allSatisfy(archive.bookmarks.contains) else {
                throw WorldArchive.TransferError.invalidArchive
            }
            print("PASS Companion import restored exact year, era, island and \(savedBookmarks.count) bookmarks")
        } catch {
            FileHandle.standardError.write(Data("FAIL Companion import: \(error)\n".utf8))
            fixture.removePersistentDomain(forName: domain)
            exit(1)
        }
    }

    @objc private func applyPace() {
        guard let store, config != nil else { return }
        do {
            var updated = try WorldStore.load(from: store)
            updated.paceName = pacePopup.titleOfSelectedItem ?? updated.paceName
            try WorldStore.save(updated, to: store)
            let mode = CameraMode(rawValue: cameraPopup.titleOfSelectedItem ?? "") ?? .auto
            WorldStore.setCameraMode(mode, in: store)
            reloadWorld()
            statusLabel.stringValue = "Pace \(updated.paceName) · camera \(mode.rawValue)."
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func newWorld() {
        guard let store, config != nil else { return }
        do {
            _ = try WorldStore.reset(in: store)
            reloadWorld()
            statusLabel.stringValue = "Started a new world."
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func previewSaver() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.open(url)
    }
}

let application = NSApplication.shared
let delegate = CompanionApp()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
