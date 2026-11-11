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
    private var lastSeenSave: CFTimeInterval = 0
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
    }

    // MARK: - Setup

    private func commonInit(isPreview: Bool) {
        isPreviewPane = isPreview
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        animationTimeInterval = 1.0 / 30.0

        // ScreenSaverDefaults keeps our state separate from the host's.
        let bundleID = Bundle(for: EvolvingSaver.self).bundleIdentifier ?? "com.mccullough.evolving"
        let store = ScreenSaverDefaults(forModuleWithName: bundleID) ?? UserDefaults.standard
        defaults = store


        if let awayText = ProcessInfo.processInfo.environment["EVOLVING_AWAY_HOURS"],
           let hours = Double(awayText), hours > 0 {
            WorldStore.markSeen(Date().addingTimeInterval(-hours * 3600), in: store)
        }

        buildWorld()
    }

    /// Builds (or rebuilds) everything derived from the stored config: terrain,
    /// simulation, renderer and HUD. Called at launch and again after the
    /// options sheet changes the world.
    private func buildWorld() {
        guard let store = defaults else { return }

        teardownWorld()

        let worldConfig = developmentOverride(WorldStore.load(from: store))
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
            let terrain = WorldGen.generate(seed: worldConfig.seed,
                                            size: isPreview ? 256 : 384)
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

            // Replay the world to the present moment. When there is a real gap
            // since the last visit, replay to that moment first so the recap can
            // describe what actually changed.
            let now = Date()
            let targetYear = worldConfig.simYear(at: now)
            let previousSeen = WorldStore.lastSeen(in: store)

            var sim = Simulation(seed: worldConfig.seed, terrain: terrain)
            let replayStart = CACurrentMediaTime()

            var before: WorldSnapshot?
            if !isPreview, let previousSeen {
                let previousYear = worldConfig.simYear(at: previousSeen)
                if targetYear - previousYear > 0.5 {
                    sim.advance(to: previousYear)
                    before = WorldSnapshot(sim)
                }
            }

            sim.advance(to: targetYear)
            let after = WorldSnapshot(sim)
            NSLog("Evolving: replayed \(Int(sim.year)) years in \(Int((CACurrentMediaTime() - replayStart) * 1000)) ms")

            renderer.updateScene(sim)
            renderer.updateTrees(CityBuilder.trees(terrain: terrain,
                                                   settlements: sim.settlements,
                                                   seed: worldConfig.seed,
                                                   riverField: renderer.scene.riverField))

            addSubview(view)
            self.metalView = view
            self.renderer = renderer
            self.simulation = sim
            self.lastSceneYear = sim.year
            self.lastSceneEra = sim.era
            self.lastSeenSave = 0
            self.recapUntil = 0

            buildHUD()
            if !isPreview {
                configureRecap(before: before, after: after, chronicle: sim.chronicle,
                               now: now, previousSeen: previousSeen)
                WorldStore.markSeen(now, in: store)
            }
            updateHUD(force: true, now: CACurrentMediaTime())
            NSLog("Evolving: Metal up on \(context.device.name), preview=\(isPreview), year \(Int(sim.year)), \(sim.settlements.count) settlements")
        } catch {
            NSLog("Evolving: setup failed — \(error)")
            showStatus("Evolving could not start Metal.\n\(error)")
        }
    }

    private func teardownWorld() {
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
        if settingsWindow == nil {
            settingsWindow = makeSettingsSheet()
        }
        syncSettingsControls()
        return settingsWindow
    }

    /// The sheet is built once and reused, so refresh it from the store every
    /// time it is shown (the world may have been reset since last time).
    private func syncSettingsControls() {
        guard let store = defaults else { return }
        let stored = WorldStore.load(from: store)
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

        var updated = WorldStore.load(from: store)
        updated.paceName = pacePopup?.titleOfSelectedItem ?? updated.paceName

        let seedText = seedField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let typedSeed = UInt64(seedText) ?? 0
        let seedChanged = typedSeed > 0 && typedSeed != updated.seed
        if seedChanged { updated.seed = typedSeed }

        let wantsNewWorld = resetCheckbox?.state == .on
        if seedChanged || wantsNewWorld {
            updated.epoch = Date()
            WorldStore.markSeen(Date(), in: store)
        }

        WorldStore.setSouthernHemisphere(hemisphereCheckbox?.state == .on, in: store)
        let mode = CameraMode(rawValue: cameraPopup?.titleOfSelectedItem ?? "") ?? .auto
        WorldStore.setCameraMode(mode, in: store)
        WorldStore.save(updated, to: store)
        closeSettings(.OK)

        // Rebuild against the new config so the preview updates immediately.
        buildWorld()
        if isAnimating {
            startRenderLoop()
        }
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
        }
    }

    override func layout() {
        super.layout()
        metalView?.frame = bounds
        layoutHUD()
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
        tickWorld(now: now)
        metalView?.draw()
        updateHUD(force: false, now: now)
    }

    /// Timeline-scrubbing API used by the standalone Timeline app.
    @objc func setTimelineYear(_ value: NSNumber) {
        let year = min(max(value.floatValue, 0), 12000)
        timelineYearOverride = year
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
        renderer.updateTrees(CityBuilder.trees(terrain: updated.terrain,
                                               settlements: updated.settlements,
                                               seed: updated.seed,
                                               riverField: renderer.scene.riverField))
        updateHUD(force: true, now: CACurrentMediaTime())
    }

    @objc func clearTimelineOverride() {
        timelineYearOverride = nil
    }

    // MARK: - Free camera (Timeline app)

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
        let terrain = renderer.scene.terrain
        var sim = Simulation(seed: config.seed, terrain: terrain)
        sim.advance(to: max(year, 0))
        simulation = sim
        lastSceneYear = sim.year
        lastSceneEra = sim.era
        renderer.updateScene(sim)
        renderer.updateTrees(CityBuilder.trees(terrain: terrain,
                                               settlements: sim.settlements,
                                               seed: sim.seed,
                                               riverField: renderer.scene.riverField))
        updateHUD(force: true, now: CACurrentMediaTime())
    }

    /// Catches the civilisation up to real time. The mapping from wall-clock
    /// time to simulated years lives entirely in `Pace`, so a month asleep is
    /// just a bigger jump here.
    private func tickWorld(now: CFTimeInterval) {
        guard let config, var sim = simulation else { return }

        let target = timelineYearOverride ?? config.simYear(at: Date())
        if target < sim.year - 0.5 {
            rebuildSimulation(to: target)
            return
        }
        if target - sim.year >= 0.25 {
            sim.advance(to: target)
            simulation = sim

            let yearChanged = abs(sim.year - lastSceneYear) >= 0.99
            let eraChanged = sim.era != lastSceneEra
            if yearChanged || eraChanged {
                lastSceneYear = sim.year
                lastSceneEra = sim.era
                renderer?.updateScene(sim)
                renderer?.updateTrees(CityBuilder.trees(terrain: sim.terrain,
                                                        settlements: sim.settlements,
                                                        seed: sim.seed,
                                                        riverField: renderer?.scene.riverField))
            }
        }

        if now - lastSeenSave > 30 {
            lastSeenSave = now
            persistLastSeen()
        }
    }

    private func persistLastSeen() {
        // Viewing the preview in System Settings must not count as spending
        // time with the world, or it would erase the "while you were away" gap.
        guard !isPreviewPane, let store = defaults else { return }
        WorldStore.markSeen(Date(), in: store)
    }
}
