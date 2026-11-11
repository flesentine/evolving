import Cocoa
import ScreenSaver
import ImageIO

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
    private var config: WorldConfig?
    private var simulation: Simulation?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = ScreenSaverDefaults(forModuleWithName: moduleName) ?? .standard
        buildMenu()
        buildWindow()
        reloadWorld()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NSApp.activate(ignoringOtherApps: true)

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
        let size = NSSize(width: 420, height: 600)
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
        paceLabel.frame = NSRect(x: 24, y: 150, width: 50, height: 20)
        content.addSubview(paceLabel)

        pacePopup = NSPopUpButton(frame: NSRect(x: 78, y: 146, width: 180, height: 26),
                                  pullsDown: false)
        pacePopup.addItems(withTitles: Pace.all.map { $0.name })
        content.addSubview(pacePopup)

        let cameraLabel = label("Camera", size: 13, weight: .regular, colour: .labelColor)
        cameraLabel.frame = NSRect(x: 24, y: 112, width: 54, height: 20)
        content.addSubview(cameraLabel)

        cameraPopup = NSPopUpButton(frame: NSRect(x: 78, y: 108, width: 180, height: 26),
                                    pullsDown: false)
        cameraPopup.addItems(withTitles: CameraMode.allCases.map { $0.rawValue })
        content.addSubview(cameraPopup)

        let apply = NSButton(title: "Apply", target: self, action: #selector(applyPace))
        apply.frame = NSRect(x: 266, y: 108, width: 70, height: 26)
        apply.bezelStyle = .rounded
        content.addSubview(apply)

        let settings = NSButton(title: "Screen Saver Settings…",
                                target: self, action: #selector(openSettings))
        settings.frame = NSRect(x: 24, y: 60, width: 190, height: 30)
        settings.bezelStyle = .rounded
        content.addSubview(settings)

        let preview = NSButton(title: "Preview", target: self, action: #selector(previewSaver))
        preview.frame = NSRect(x: 222, y: 60, width: 84, height: 30)
        preview.bezelStyle = .rounded
        content.addSubview(preview)

        let newWorld = NSButton(title: "New World", target: self, action: #selector(newWorld))
        newWorld.frame = NSRect(x: 314, y: 60, width: 82, height: 30)
        newWorld.bezelStyle = .rounded
        content.addSubview(newWorld)

        statusLabel = label("", size: 11, weight: .regular, colour: .secondaryLabelColor)
        statusLabel.frame = NSRect(x: 24, y: 30, width: 372, height: 18)
        content.addSubview(statusLabel)

        let hint = label("Choose Evolving in System Settings → Screen Saver.",
                         size: 11, weight: .regular, colour: .tertiaryLabelColor)
        hint.frame = NSRect(x: 24, y: 8, width: 372, height: 16)
        content.addSubview(hint)

        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - World state

    private func reloadWorld() {
        guard let store else { return }

        let config = WorldStore.load(from: store)
        self.config = config

        let terrain = WorldGen.generate(seed: config.seed, size: 256)
        var sim = Simulation(seed: config.seed, terrain: terrain)
        sim.advance(to: config.simYear(at: Date()))
        simulation = sim

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

    @objc private func applyPace() {
        guard let store, var config else { return }
        config.paceName = pacePopup.titleOfSelectedItem ?? config.paceName
        WorldStore.save(config, to: store)
        let mode = CameraMode(rawValue: cameraPopup.titleOfSelectedItem ?? "") ?? .auto
        WorldStore.setCameraMode(mode, in: store)
        self.config = config
        statusLabel.stringValue = "Pace \(config.paceName) · camera \(mode.rawValue)."
    }

    @objc private func newWorld() {
        guard let store else { return }
        _ = WorldStore.reset(in: store)
        reloadWorld()
        statusLabel.stringValue = "Started a new world."
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
