import Cocoa
import ScreenSaver
import MetalKit

/// The screen saver's principal class.
///
/// The world is not saved: only the seed and the date the world began are
/// persisted. Everything else — terrain, settlements, roads, buildings — is
/// replayed from those two numbers whenever the saver starts, so closing the
/// lid for a month simply means a longer catch-up at launch.
/// A cheap summary of the world at one moment, used to describe what changed
/// while the screensaver was away.
private struct WorldSnapshot {
    var year: Float
    var era: Era
    var population: Int
    var alive: Set<Int32>

    init(_ sim: Simulation) {
        year = sim.year
        era = sim.era
        population = Int(sim.totalPopulation.rounded())
        alive = Set(sim.settlements.filter { $0.isAlive }.map { $0.id })
    }
}

@objc(EvolvingSaver)
final class EvolvingSaver: ScreenSaverView {

    private var metalView: MTKView?
    private var renderer: Renderer?
    private var renderTimer: Timer?
    private var lastDrawTime: CFTimeInterval = 0

    // Persistence + simulation
    private var defaults: UserDefaults?
    private var config: WorldConfig?
    private var simulation: Simulation?
    private var lastSceneYear: Float = -1
    private var lastSceneEra: Era?
    private var timelineYearOverride: Float?
    private var previousLiveDate: Date?
    private var lastLiveFrame: Date?
    private var lastSeenCheckpoint: Date?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var fixtureDate: Date?

    private var wallDate: Date { fixtureDate ?? Date() }
    private var lastHUDUpdate: CFTimeInterval = 0

    // Overlay
    private var hud: NSView?
    private var yearLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var chronicleLabel: NSTextField?
    private var recapLabel: NSTextField?
    private var recapUntil: CFTimeInterval = 0

    private var isPreviewPane = false

    // Metal is created once and reused across world rebuilds.
    private var metalContext: MetalContext?
    private var statusLabel: NSTextField?

    // Options sheet
    private var settingsWindow: NSWindow?
    private var pacePopup: NSPopUpButton?
    private var seedField: NSTextField?
    private var resetCheckbox: NSButton?
    private var hemisphereCheckbox: NSButton?
    private var cameraPopup: NSPopUpButton?

    /// Frame counter exposed to the verification tool via KVC.
    @objc dynamic var framesDrawn: Int { renderer?.framesDrawn ?? 0 }
    @objc dynamic var presentedFrameCount: Int { renderer?.presentedFrameCount ?? 0 }
    @objc dynamic var firstFramePresentedTime: Double { renderer?.firstFramePresentedTime ?? 0 }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit(isPreview: isPreview)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit(isPreview: false)
    }

    deinit {
        renderTimer?.invalidate()
        persistLastSeen()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Setup

    private func commonInit(isPreview: Bool) {
        isPreviewPane = isPreview
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        animationTimeInterval = 1.0 / 30.0

        // ScreenSaverDefaults keeps our state separate from the host's.
        let bundleID = Bundle(for: EvolvingSaver.self).bundleIdentifier ?? "com.mccullough.evolving"
        let env = ProcessInfo.processInfo.environment
        if env["EVOLVING_DEV"] == "1", let suite = env["EVOLVING_LIFECYCLE_SUITE"],
           suite.hasPrefix("com.mccullough.evolving.lifecycle-test."),
           let seconds = env["EVOLVING_LIFECYCLE_DATE"].flatMap(Double.init),
           seconds.isFinite, seconds > 0, let fixture = UserDefaults(suiteName: suite) {
            fixtureDate = Date(timeIntervalSince1970: seconds)
            defaults = fixture
        } else {
            defaults = ScreenSaverDefaults(forModuleWithName: bundleID) ?? UserDefaults.standard
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
                [weak self] _ in self?.prepareForSleep()
            },
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                [weak self] _ in self?.resumeFromSleep()
            }
        ]
        buildWorld()
    }

    /// Builds (or rebuilds) everything derived from the stored config: terrain,
    /// simulation, renderer and HUD. Called at launch and again after the
    /// options sheet changes the world.
    private func buildWorld() {
        guard let store = defaults else { return }

        teardownWorld()

        config = nil
        let worldConfig: WorldConfig
        do {
            worldConfig = developmentOverride(try WorldStore.load(from: store))
        } catch {
            showStatus(error.localizedDescription)
            return
        }
        config = worldConfig

        do {
            let context: MetalContext
            if let existing = metalContext {
                context = existing
            } else {
                context = try MetalContext()
                metalContext = context
            }

            let view = MTKView(frame: bounds, device: context.device)
            view.colorPixelFormat = .bgra8Unorm_srgb
            // The scene renders into our own offscreen depth target; the view
            // itself only receives the composited post pass.
            view.depthStencilPixelFormat = .invalid
            view.clearColor = MTLClearColor(red: 0.02, green: 0.03, blue: 0.05, alpha: 1)
            view.framebufferOnly = false
            view.isPaused = true
            view.enableSetNeedsDisplay = false
            view.autoresizingMask = [.width, .height]
            view.layer?.isOpaque = true

            let started = CACurrentMediaTime()
            let replayTerrain = worldConfig.replayTerrain()
            let terrain = isPreview
                ? WorldGen.generate(seed: worldConfig.seed, size: 256) : replayTerrain
            NSLog("Evolving: terrain \(terrain.size)² in \(Int((CACurrentMediaTime() - started) * 1000)) ms")

            let renderer = try Renderer(context: context,
                                        terrain: terrain,
                                        colorPixelFormat: view.colorPixelFormat,
                                        depthPixelFormat: .depth32Float)
            view.delegate = renderer

            if let stored = WorldStore.southernHemisphere(in: store) {
                renderer.southernHemisphere = stored
            }
            renderer.cameraMode = WorldStore.cameraMode(in: store)

            // Development-only visual overrides (the headless tool sets its
            // own, unconditionally, because it is already a dev tool).
            let env = ProcessInfo.processInfo.environment
            if env["EVOLVING_DEV"] == "1" {
                if let text = env["EVOLVING_HOUR"], let hour = Float(text) {
                    renderer.hourOverride = hour
                }
                if let text = env["EVOLVING_SEASON"], let season = Float(text) {
                    renderer.seasonOverride = min(max(season, 0), 1)
                }
                if let text = env["EVOLVING_WEATHER"], let weather = Float(text) {
                    renderer.weatherOverride = min(max(weather, 0), 1)
                }
                if let text = env["EVOLVING_SNOW"] {
                    renderer.snowOverride = text == "1"
                }
            }

            let now = wallDate
            let wallYear = worldConfig.simYear(at: now)
            let awayHours = ProcessInfo.processInfo.environment["EVOLVING_AWAY_HOURS"].flatMap(Double.init)
            let recorded = WorldStore.lastSeen(in: store)
            let recordedYear = recorded.map { worldConfig.simYear(at: $0) } ?? wallYear
            let targetYear = recordedYear.isFinite && recordedYear <= WorldArchive.maximumYear
                ? max(wallYear, recordedYear) : wallYear
            let previous = awayHours.flatMap { hours in
                hours.isFinite && hours > 0 ? now.addingTimeInterval(-hours * 3600) : nil
            } ?? recorded
            var sim = worldConfig.startReplay(on: replayTerrain)
            let replayStart = CACurrentMediaTime()
            sim.advance(to: targetYear)
            NSLog("Evolving: replayed \(Int(sim.year)) years in \(Int((CACurrentMediaTime() - replayStart) * 1000)) ms")

            renderer.updateScene(sim)

            addSubview(view)
            self.metalView = view
            self.renderer = renderer
            self.simulation = sim
            self.lastSceneYear = sim.year
            self.lastSceneEra = sim.era
            self.previousLiveDate = previous
            self.lastLiveFrame = nil
            self.lastSeenCheckpoint = nil
            self.recapUntil = 0

            buildHUD()
            updateHUD(force: true, now: CACurrentMediaTime())
            NSLog("Evolving: Metal up on \(context.device.name), preview=\(isPreview), year \(Int(sim.year)), \(sim.settlements.count) settlements")
        } catch {
            NSLog("Evolving: setup failed — \(error)")
            showStatus("Evolving could not start Metal.\n\(error)")
        }
    }

    private func teardownWorld() {
        persistLastSeen()
        renderTimer?.invalidate()
        renderTimer = nil
        metalView?.removeFromSuperview()
        metalView = nil
        renderer = nil
        simulation = nil
        hud?.removeFromSuperview()
        hud = nil
        recapLabel?.removeFromSuperview()
        recapLabel = nil
        statusLabel?.removeFromSuperview()
        statusLabel = nil
        yearLabel = nil
        detailLabel = nil
        chronicleLabel = nil
    }

    private func showStatus(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.textColor = .white
        label.font = .systemFont(ofSize: 13)
        label.alignment = .center
        label.frame = bounds.insetBy(dx: 24, dy: 24)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
        statusLabel = label
    }

    /// Development-only overrides so the headless tool can preview any point in
    /// the arc without waiting twenty months. Production runs ignore them.
    private func developmentOverride(_ config: WorldConfig) -> WorldConfig {
        let env = ProcessInfo.processInfo.environment
        guard env["EVOLVING_DEV"] == "1" else { return config }

        var result = config
        if let text = env["EVOLVING_SEED"], let seed = UInt64(text), seed > 0 {
            result.seed = seed
        }
        if let text = env["EVOLVING_AGE_DAYS"], let days = Double(text) {
            result.epoch = Date().addingTimeInterval(-days * 86_400)
            result.clockAnchor = nil
        }
        if let pace = env["EVOLVING_PACE"], !pace.isEmpty {
            result.paceName = pace
        }
        return result
    }

    // MARK: - HUD

    private func makeLabel(size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = NSColor(white: 1, alpha: alpha)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.drawsBackground = false
        label.isBordered = false
        return label
    }

    private func buildHUD() {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.02, alpha: 0.42).cgColor
        container.layer?.cornerRadius = 10

        yearLabel = makeLabel(size: isPreviewPane ? 15 : 23, weight: .semibold, alpha: 0.96)
        detailLabel = makeLabel(size: isPreviewPane ? 10 : 13, weight: .regular, alpha: 0.82)
        chronicleLabel = makeLabel(size: isPreviewPane ? 9 : 11.5, weight: .regular, alpha: 0.62)

        for label in [yearLabel, detailLabel, chronicleLabel].compactMap({ $0 }) {
            container.addSubview(label)
        }
        addSubview(container)
        hud = container

        let recap = makeLabel(size: isPreviewPane ? 10 : 15, weight: .medium, alpha: 0.92)
        recap.maximumNumberOfLines = 3
        recap.alignment = .center
        recap.isHidden = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.75)
        shadow.shadowBlurRadius = 8
        recap.shadow = shadow
        addSubview(recap)
        recapLabel = recap

        layoutHUD()
    }

    private func layoutHUD() {
        guard let hud else { return }
        let margin: CGFloat = isPreviewPane ? 10 : 30
        let width = min(bounds.width - margin * 2, isPreviewPane ? 340 : 620)

        let yearHeight: CGFloat = isPreviewPane ? 18 : 29
        let detailHeight: CGFloat = isPreviewPane ? 13 : 18
        let chronicleHeight: CGFloat = isPreviewPane ? 12 : 16
        let padding: CGFloat = isPreviewPane ? 7 : 13
        let height = padding * 2 + yearHeight + detailHeight + chronicleHeight + 2

        hud.frame = NSRect(x: margin, y: margin, width: max(width, 120), height: height)

        var y = height - padding - yearHeight
        yearLabel?.frame = NSRect(x: padding, y: y, width: hud.bounds.width - padding * 2, height: yearHeight)
        y -= detailHeight + 1
        detailLabel?.frame = NSRect(x: padding, y: y, width: hud.bounds.width - padding * 2, height: detailHeight)
        y -= chronicleHeight + 1
        chronicleLabel?.frame = NSRect(x: padding, y: y, width: hud.bounds.width - padding * 2, height: chronicleHeight)

        recapLabel?.frame = NSRect(x: margin,
                                   y: bounds.height - margin - (isPreviewPane ? 34 : 78),
                                   width: bounds.width - margin * 2,
                                   height: isPreviewPane ? 34 : 78)
    }

    private func updateHUD(force: Bool, now: CFTimeInterval) {
        guard force || now - lastHUDUpdate > 0.25 else { return }
        lastHUDUpdate = now
        guard let sim = simulation else { return }

        yearLabel?.stringValue = "Year \(Int(sim.year))   ·   \(sim.era.name)"

        let population = Int(sim.totalPopulation.rounded())
        let alive = sim.settlements.reduce(0) { $1.isAlive ? $0 + 1 : $0 }
        detailLabel?.stringValue = "\(population.formatted()) people   ·   \(alive) settlements"

        if let entry = sim.headline() {
            chronicleLabel?.stringValue = "\(Int(entry.year)) — \(entry.text)"
        } else {
            chronicleLabel?.stringValue = ""
        }

        recapLabel?.isHidden = now >= recapUntil
    }

    private func configureRecap(before: WorldSnapshot?,
                                after: WorldSnapshot,
                                chronicle: [ChronicleEntry],
                                now: Date,
                                previousSeen: Date?) {
        guard !isPreviewPane, let previous = previousSeen else { return }

        let away = now.timeIntervalSince(previous)
        guard away > 3600 else { return }

        let passed = max(after.year - (before?.year ?? after.year), 0)
        var lines: [String] = []
        lines.append("While you were away for \(durationText(away)), \(Int(passed.rounded())) years passed.")

        if let before {
            var changes: [String] = []
            let founded = after.alive.subtracting(before.alive).count
            let lost = before.alive.subtracting(after.alive).count
            if founded > 0 {
                changes.append("\(founded) new \(founded == 1 ? "town" : "towns")")
            }
            if lost > 0 {
                changes.append("\(lost) abandoned")
            }

            var line = "Population \(before.population.formatted()) → \(after.population.formatted())"
            if !changes.isEmpty {
                line += " · " + changes.joined(separator: " · ")
            }
            lines.append(line)
        }

        if let before, before.era != after.era {
            lines.append("A new age has begun: \(after.era.name).")
        } else if let before,
                  let event = chronicle.last(where: { entry in
                      entry.year > before.year && entry.year <= after.year &&
                      [.plague, .fire, .war, .drought, .quake, .abandon].contains(entry.kind)
                  }) {
            lines.append("\(Int(event.year)) — \(event.text)")
        }

        recapLabel?.stringValue = lines.joined(separator: "\n")
        recapLabel?.isHidden = false
        recapUntil = CACurrentMediaTime() + 14
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24

        if days >= 60 { return "\(Int(days / 30.4)) months" }
        if days >= 2 { return "\(Int(days)) days" }
        if hours >= 2 { return "\(Int(hours)) hours" }
        return "\(Int(max(minutes, 1))) minutes"
    }

    // MARK: - Options sheet

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        guard config != nil else { return nil }
        if settingsWindow == nil {
            settingsWindow = makeSettingsSheet()
        }
        syncSettingsControls()
        return settingsWindow
    }

    /// The sheet is built once and reused, so refresh it from the store every
    /// time it is shown (the world may have been reset since last time).
    private func syncSettingsControls() {
        guard let store = defaults, let stored = try? WorldStore.load(from: store) else { return }
        pacePopup?.selectItem(withTitle: stored.paceName)
        seedField?.stringValue = String(stored.seed)
        resetCheckbox?.state = .off
        hemisphereCheckbox?.state = (WorldStore.southernHemisphere(in: store)
                                     ?? Renderer.detectSouthernHemisphere()) ? .on : .off
        cameraPopup?.selectItem(withTitle: WorldStore.cameraMode(in: store).rawValue)
    }

    private func makeSettingsSheet() -> NSWindow {
        let size = NSSize(width: 400, height: 300)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.title = "Evolving"

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content

        let heading = NSTextField(labelWithString: "World")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.frame = NSRect(x: 20, y: size.height - 40, width: 200, height: 18)
        content.addSubview(heading)

        let paceLabel = NSTextField(labelWithString: "Pace")
        paceLabel.frame = NSRect(x: 20, y: size.height - 74, width: 60, height: 20)
        content.addSubview(paceLabel)

        let popup = NSPopUpButton(frame: NSRect(x: 92, y: size.height - 78, width: 288, height: 26),
                                  pullsDown: false)
        popup.addItems(withTitles: Pace.all.map { $0.name })
        popup.selectItem(withTitle: config?.paceName ?? Pace.standard.name)
        content.addSubview(popup)
        pacePopup = popup

        let seedLabel = NSTextField(labelWithString: "Seed")
        seedLabel.frame = NSRect(x: 20, y: size.height - 110, width: 60, height: 20)
        content.addSubview(seedLabel)

        let field = NSTextField(frame: NSRect(x: 92, y: size.height - 114, width: 164, height: 24))
        field.stringValue = String(config?.seed ?? 1)
        content.addSubview(field)
        seedField = field

        let randomise = NSButton(title: "Randomise", target: self, action: #selector(randomiseSeed))
        randomise.frame = NSRect(x: 264, y: size.height - 114, width: 116, height: 24)
        randomise.bezelStyle = .rounded
        content.addSubview(randomise)

        let reset = NSButton(checkboxWithTitle: "Start a new world now",
                             target: nil, action: nil)
        reset.frame = NSRect(x: 92, y: size.height - 146, width: 288, height: 20)
        reset.state = .off
        content.addSubview(reset)
        resetCheckbox = reset

        let hemisphere = NSButton(checkboxWithTitle: "Southern hemisphere (flip seasons)",
                                  target: nil, action: nil)
        hemisphere.frame = NSRect(x: 92, y: size.height - 178, width: 288, height: 20)
        hemisphere.state = .off
        content.addSubview(hemisphere)
        hemisphereCheckbox = hemisphere

        let cameraLabel = NSTextField(labelWithString: "Camera")
        cameraLabel.frame = NSRect(x: 20, y: size.height - 206, width: 60, height: 20)
        content.addSubview(cameraLabel)

        let camera = NSPopUpButton(frame: NSRect(x: 92, y: size.height - 210, width: 288, height: 26),
                                   pullsDown: false)
        camera.addItems(withTitles: CameraMode.allCases.map { $0.rawValue })
        content.addSubview(camera)
        cameraPopup = camera

        let note = NSTextField(labelWithString: "Changing the seed or starting over resets the world to year 0.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 20, y: 54, width: size.width - 40, height: 16)
        content.addSubview(note)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSettings))
        cancel.frame = NSRect(x: size.width - 200, y: 16, width: 84, height: 28)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        content.addSubview(cancel)

        let ok = NSButton(title: "OK", target: self, action: #selector(applySettings))
        ok.frame = NSRect(x: size.width - 106, y: 16, width: 84, height: 28)
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        content.addSubview(ok)

        return window
    }

    @objc private func randomiseSeed() {
        seedField?.stringValue = String(WorldStore.makeSeed())
        resetCheckbox?.state = .on
    }

    @objc private func cancelSettings() {
        closeSettings(.cancel)
    }

    @objc private func applySettings() {
        guard let store = defaults else {
            closeSettings(.OK)
            return
        }

        var updated: WorldConfig
        do {
            updated = try WorldStore.load(from: store)
        } catch {
            settingsFailure(error)
            return
        }
        updated.paceName = pacePopup?.titleOfSelectedItem ?? updated.paceName

        let seedText = seedField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let typedSeed = UInt64(seedText) ?? 0
        let seedChanged = typedSeed > 0 && typedSeed != updated.seed
        if seedChanged { updated.seed = typedSeed }

        let wantsNewWorld = resetCheckbox?.state == .on
        if seedChanged || wantsNewWorld {
            updated.epoch = Date()
            updated.clockAnchor = nil
            updated.historyVersion = .current
        }
        do {
            try WorldStore.save(updated, to: store)
        } catch {
            settingsFailure(error)
            return
        }
        if seedChanged || wantsNewWorld {
            WorldStore.markSeen(updated.epoch, in: store)
        }

        WorldStore.setSouthernHemisphere(hemisphereCheckbox?.state == .on, in: store)
        let mode = CameraMode(rawValue: cameraPopup?.titleOfSelectedItem ?? "") ?? .auto
        WorldStore.setCameraMode(mode, in: store)
        closeSettings(.OK)

        // Rebuild against the new config so the preview updates immediately.
        buildWorld()
        if isAnimating {
            startRenderLoop()
        }
    }

    private func settingsFailure(_ error: Error) {
        guard let window = settingsWindow else { return }
        let alert = NSAlert()
        alert.messageText = "World settings could not be saved"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    private func closeSettings(_ response: NSApplication.ModalResponse) {
        guard let window = settingsWindow else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: response)
        } else {
            NSApp.endSheet(window, returnCode: response.rawValue)
        }
    }

    // MARK: - Lifecycle

    override func startAnimation() {
        super.startAnimation()
        startRenderLoop()
    }

    override func stopAnimation() {
        stopRenderLoop()
        persistLastSeen()
        super.stopAnimation()
    }

    override func animateOneFrame() {
        super.animateOneFrame()
        // The host calls this on its own timer; if our own timer is not running
        // (for example in a preview pane) this still keeps frames coming.
        drawIfDue()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && isAnimating {
            startRenderLoop()
        } else if window == nil {
            stopRenderLoop()
            persistLastSeen()
        }
    }

    override func layout() {
        super.layout()
        metalView?.frame = bounds
        layoutHUD()
    }

    private func prepareForSleep() {
        persistLastSeen()
    }

    private func resumeFromSleep() {
        if isAnimating && window != nil { drawIfDue(force: true) }
    }

    // The native verifier drives the same sleep/wake handlers with a fixed
    // clock and a separate preferences suite, without sleeping the host Mac.
    @objc func setLifecycleFixtureDate(_ value: NSDate) {
        guard fixtureDate != nil else { return }
        fixtureDate = value as Date
    }

    @objc func lifecycleFixtureSleep() {
        if fixtureDate != nil { prepareForSleep() }
    }

    @objc func lifecycleFixtureWake() {
        if fixtureDate != nil { resumeFromSleep() }
    }

    @objc func lifecycleFixtureRecap() -> NSString? {
        guard fixtureDate != nil, let label = recapLabel, !label.isHidden else { return nil }
        return label.stringValue as NSString
    }

    // MARK: - Render loop

    private func startRenderLoop() {
        guard renderTimer == nil, metalView != nil else { return }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.drawIfDue()
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer

        // Draw once immediately so the view is not black while the first
        // timer tick arrives.
        drawIfDue(force: true)
    }

    private func stopRenderLoop() {
        renderTimer?.invalidate()
        renderTimer = nil
    }

    private func drawIfDue(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastDrawTime > 1.0 / 120.0 else { return }
        lastDrawTime = now
        let date = wallDate
        let live = !isPreviewPane && timelineYearOverride == nil
        let previous = lastLiveFrame.map { max($0, previousLiveDate ?? $0) } ?? previousLiveDate
        let returning = live && (previous.map { date.timeIntervalSince($0) > 3600 } ?? false)
        tickWorld(at: date, catchUp: force || returning)
        let frames = framesDrawn
        metalView?.draw()
        if live, framesDrawn != frames {
            if returning, let previous, let config, let sim = simulation {
                var before = config.startReplay(on: sim.terrain)
                before.advance(to: min(config.simYear(at: previous), sim.year))
                configureRecap(before: WorldSnapshot(before), after: WorldSnapshot(sim),
                               chronicle: sim.chronicle, now: date, previousSeen: previous)
            }
            if (lastLiveFrame ?? .distantPast) < date {
                lastLiveFrame = date
                if date.timeIntervalSince(lastSeenCheckpoint ?? .distantPast) >= 30 {
                    persistLastSeen()
                }
            }
        }
        updateHUD(force: false, now: now)
    }

    /// Timeline-scrubbing API used by the standalone Timeline app.
    @objc func setTimelineYear(_ value: NSNumber) {
        let year = min(max(value.floatValue, 0), 12000)
        persistLastSeen()
        timelineYearOverride = year
        recapUntil = 0
        recapLabel?.isHidden = true
        guard let config, let renderer, let sim = simulation else { return }
        if year < sim.year - 0.5 || year < 0 {
            rebuildSimulation(to: year)
            return
        }
        var updated = sim
        if year - updated.year >= 0.25 {
            updated.advance(to: year)
        }
        simulation = updated
        lastSceneYear = updated.year
        lastSceneEra = updated.era
        renderer.updateScene(updated)
        updateHUD(force: true, now: CACurrentMediaTime())
    }

    @objc func clearTimelineOverride() {
        guard timelineYearOverride != nil else { return }
        timelineYearOverride = nil
        if let config, let simulation {
            let target = config.simYear(at: wallDate)
            if target < simulation.year { rebuildSimulation(to: target) }
        }
        drawIfDue(force: true)
    }

    @objc func isTimelineLive() -> NSNumber {
        NSNumber(value: timelineYearOverride == nil)
    }

    /// Restore a named camera in the existing world. A historical bookmark
    /// uses its exact frame year; a Live bookmark resolves the current year.
    @objc func restoreTimelineBookmark(_ data: NSData) -> NSNumber {
        guard let config, let renderer, var sim = simulation,
              let bookmark = try? JSONDecoder().decode(TimelineBookmark.self, from: data as Data).validated(),
              bookmark.view.seed == config.seed else { return NSNumber(value: false) }

        let view = bookmark.view
        let year = bookmark.mode == .live ? config.simYear(at: wallDate) : view.year
        persistLastSeen()
        timelineYearOverride = bookmark.mode == .historical ? year : nil
        if timelineYearOverride != nil {
            recapUntil = 0
            recapLabel?.isHidden = true
        }
        if year < sim.year {
            sim = config.startReplay(on: sim.terrain)
        }
        sim.advance(to: year)
        simulation = sim
        lastSceneYear = sim.year
        lastSceneEra = sim.era
        renderer.restoreTimelineCamera(Renderer.Camera(
            eye: SIMD3(view.eye[0], view.eye[1], view.eye[2]),
            target: SIMD3(view.target[0], view.target[1], view.target[2]), fov: view.fov))
        renderer.updateScene(sim, refreshRoads: true)
        updateHUD(force: true, now: CACurrentMediaTime())
        drawIfDue(force: true)
        return NSNumber(value: true)
    }

    // MARK: - Free camera (Timeline app)

    @objc func riverReviewViewData() -> NSData? {
        guard let record = renderer?.lastReviewView else { return nil }
        return try? record.encoded() as NSData
    }

    @objc func timelineBookmarkViewData() -> NSData? {
        guard let record = renderer?.lastReviewView else { return nil }
        return try? record.encoded(maximumYear: .greatestFiniteMagnitude) as NSData
    }

    @objc func beginFreeCamera() {
        renderer?.beginFreeCamera()
    }

    @objc func orbitCameraX(_ value: NSNumber) {
        renderer?.orbitCamera(dx: value.floatValue, dy: 0)
    }

    @objc func orbitCameraY(_ value: NSNumber) {
        renderer?.orbitCamera(dx: 0, dy: value.floatValue)
    }

    @objc func zoomCamera(_ value: NSNumber) {
        renderer?.zoomCamera(value.floatValue)
    }

    @objc func panCameraX(_ value: NSNumber) {
        renderer?.panCamera(dx: value.floatValue, dy: 0)
    }

    @objc func panCameraY(_ value: NSNumber) {
        renderer?.panCamera(dx: 0, dy: value.floatValue)
    }

    @objc func endFreeCamera() {
        renderer?.endFreeCamera()
    }

    @objc func currentTimelineYear() -> NSNumber {
        NSNumber(value: simulation?.year ?? 0)
    }

    /// Rebuilds the deterministic world at an earlier year.
    private func rebuildSimulation(to year: Float) {
        guard let config, let renderer else { return }
        guard let terrain = simulation?.terrain else { return }
        var sim = config.startReplay(on: terrain)
        sim.advance(to: max(year, 0))
        simulation = sim
        lastSceneYear = sim.year
        lastSceneEra = sim.era
        renderer.updateScene(sim)
        updateHUD(force: true, now: CACurrentMediaTime())
    }

    /// Advance Live after a gap. A backward wall-clock correction holds the
    /// active replay until the clock catches up; Timeline still rewinds explicitly.
    private func tickWorld(at date: Date, catchUp: Bool) {
        guard timelineYearOverride == nil, let config, var sim = simulation else { return }
        let target = config.simYear(at: date)
        guard target > sim.year, catchUp || target - sim.year >= 0.25
                || Era.at(target) != sim.era else { return }
        sim.advance(to: target)
        simulation = sim

        let yearChanged = sim.year.rounded(.down) > lastSceneYear.rounded(.down)
        let eraChanged = sim.era != lastSceneEra
        if yearChanged || eraChanged {
            lastSceneYear = sim.year
            lastSceneEra = sim.era
            renderer?.updateScene(sim, refreshRoads: catchUp && yearChanged)
        }
    }

    private func persistLastSeen() {
        guard let store = defaults, let config, let frame = lastLiveFrame,
              frame > (lastSeenCheckpoint ?? .distantPast) else { return }
        WorldStore.recordLiveFrame(frame, for: config, in: store)
        lastSeenCheckpoint = frame
    }
}
