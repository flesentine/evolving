import Cocoa
import ScreenSaver

/// Captures drags over the saver view and turns them into camera moves.
final class InputView: NSView {
    weak var app: TimelineApp?
    private var last: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            app?.endFreeCamera()
            return
        }
        app?.beginFreeCamera()
        last = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = event.locationInWindow.x - last.x
        let dy = event.locationInWindow.y - last.y
        last = event.locationInWindow
        app?.orbit(dx: dx, dy: dy)
    }

    override func rightMouseDown(with event: NSEvent) {
        app?.beginFreeCamera()
        last = event.locationInWindow
    }

    override func rightMouseDragged(with event: NSEvent) {
        let dx = event.locationInWindow.x - last.x
        let dy = event.locationInWindow.y - last.y
        last = event.locationInWindow
        app?.pan(dx: dx, dy: dy)
    }

    override func scrollWheel(with event: NSEvent) {
        app?.zoom(Double(event.scrollingDeltaY))
    }

    override func magnify(with event: NSEvent) {
        app?.zoom(Double(event.magnification) * 80.0)
    }
}

/// A standalone viewer with a year slider, so the whole arc can be scrubbed
/// without going through Screen Saver settings.
final class TimelineApp: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var saver: ScreenSaverView!
    private var slider: NSSlider!
    private var yearLabel: NSTextField!
    private var eraPopup: NSPopUpButton!
    private var speedPopup: NSPopUpButton!
    private var playbackSpeed: Float = 1.0
    private var playButton: NSButton!
    private var timer: Timer?
    private var playing = false
    private var currentYear: Float = 0
    private let maxYear: Float = 12000

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: min(1500, screen.frame.width * 0.92),
                          height: min(940, screen.frame.height * 0.92))
        let rect = NSRect(origin: .zero, size: size)

        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered,
                          defer: false)
        window.title = "Evolving Timeline"
        window.center()
        window.isReleasedWhenClosed = false

        let content = NSView(frame: rect)
        content.wantsLayer = true
        window.contentView = content

        guard let resources = Bundle.main.resourceURL else {
            fail("The app bundle is missing its resources.")
            return
        }
        let saverURL = resources.appendingPathComponent("Evolving.saver")
        guard let bundle = Bundle(url: saverURL), bundle.load(),
              let principal = bundle.principalClass as? ScreenSaverView.Type,
              let view = principal.init(frame: content.bounds, isPreview: false) else {
            fail("Could not load Evolving.saver from the app bundle.")
            return
        }
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        saver = view
        view.startAnimation()

        let input = InputView(frame: content.bounds)
        input.autoresizingMask = [.width, .height]
        input.app = self
        input.toolTip = "Drag to orbit · scroll to zoom · right-drag to pan · double-click for auto camera"
        content.addSubview(input)

        buildControls(in: content, width: size.width)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let value = readYear() { currentYear = value }
        slider.doubleValue = Double(currentYear)
        updateLabels()

        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 123:
                self.setYear(self.currentYear - (event.modifierFlags.contains(.shift) ? 100 : 10))
                return nil
            case 124:
                self.setYear(self.currentYear + (event.modifierFlags.contains(.shift) ? 100 : 10))
                return nil
            case 49:
                self.togglePlay()
                return nil
            case 53:
                NSApp.terminate(nil)
                return nil
            default:
                return event
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildControls(in content: NSView, width: CGFloat) {
        let barHeight: CGFloat = 62
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: barHeight))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 0.82).cgColor
        bar.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(bar)

        playButton = NSButton(title: "Play", target: self, action: #selector(togglePlay))
        playButton.bezelStyle = .rounded
        playButton.frame = NSRect(x: 14, y: 16, width: 70, height: 30)
        bar.addSubview(playButton)

        let live = NSButton(title: "Live", target: self, action: #selector(goLive))
        live.bezelStyle = .rounded
        live.frame = NSRect(x: 90, y: 16, width: 60, height: 30)
        bar.addSubview(live)

        let auto = NSButton(title: "Auto", target: self, action: #selector(autoCamera))
        auto.bezelStyle = .rounded
        auto.frame = NSRect(x: 154, y: 16, width: 60, height: 30)
        bar.addSubview(auto)

        speedPopup = NSPopUpButton(frame: NSRect(x: 222, y: 14, width: 86, height: 32),
                                   pullsDown: false)
        speedPopup.addItems(withTitles: ["0.5x", "1x", "2x", "5x", "10x", "25x"])
        speedPopup.selectItem(at: 1)
        speedPopup.target = self
        speedPopup.action = #selector(speedChanged)
        bar.addSubview(speedPopup)

        eraPopup = NSPopUpButton(frame: NSRect(x: 314, y: 14, width: 170, height: 32),
                                 pullsDown: false)
        eraPopup.addItems(withTitles: Era.allCases.map { $0.name })
        eraPopup.target = self
        eraPopup.action = #selector(eraChanged)
        bar.addSubview(eraPopup)

        slider = NSSlider(value: 0, minValue: 0, maxValue: Double(maxYear),
                          target: self, action: #selector(sliderChanged))
        slider.isContinuous = true
        slider.frame = NSRect(x: 494, y: 16, width: width - 794, height: 30)
        slider.autoresizingMask = [.width]
        bar.addSubview(slider)

        yearLabel = NSTextField(labelWithString: "")
        yearLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        yearLabel.textColor = .white
        yearLabel.alignment = .right
        yearLabel.frame = NSRect(x: width - 290, y: 19, width: 274, height: 24)
        yearLabel.autoresizingMask = [.minXMargin]
        bar.addSubview(yearLabel)
    }

    @objc private func sliderChanged() {
        setYear(Float(slider.doubleValue))
    }

    @objc private func speedChanged() {
        let speeds: [Float] = [0.5, 1, 2, 5, 10, 25]
        let index = min(max(speedPopup.indexOfSelectedItem, 0), speeds.count - 1)
        playbackSpeed = speeds[index]
        updateLabels()
    }

    @objc private func eraChanged() {
        let index = eraPopup.indexOfSelectedItem
        guard index >= 0, index < Era.allCases.count else { return }
        setYear(Era.allCases[index].startYear + 60)
    }

    @objc private func togglePlay() {
        playing.toggle()
        playButton.title = playing ? "Pause" : "Play"
    }

    @objc private func autoCamera() {
        _ = saver.perform(Selector(("endFreeCamera")))
    }

    func beginFreeCamera() {
        _ = saver.perform(Selector(("beginFreeCamera")))
    }

    func endFreeCamera() {
        _ = saver.perform(Selector(("endFreeCamera")))
    }

    func orbit(dx: CGFloat, dy: CGFloat) {
        let width = max(saver.bounds.width, 1)
        let height = max(saver.bounds.height, 1)
        _ = saver.perform(Selector(("orbitCameraX:")),
                          with: NSNumber(value: Float(dx / width) * 4.0))
        _ = saver.perform(Selector(("orbitCameraY:")),
                          with: NSNumber(value: Float(dy / height) * 2.4))
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        let width = max(saver.bounds.width, 1)
        let height = max(saver.bounds.height, 1)
        _ = saver.perform(Selector(("panCameraX:")),
                          with: NSNumber(value: Float(dx / width) * 1.6))
        _ = saver.perform(Selector(("panCameraY:")),
                          with: NSNumber(value: Float(dy / height) * 1.6))
    }

    func zoom(_ delta: Double) {
        let factor = exp(-Float(delta) * 0.08)
        _ = saver.perform(Selector(("zoomCamera:")),
                          with: NSNumber(value: factor))
    }

    @objc private func goLive() {
        playing = false
        playButton.title = "Play"
        _ = saver.perform(Selector(("clearTimelineOverride")))
        if let value = readYear() {
            currentYear = value
            slider.doubleValue = Double(value)
            updateLabels()
        }
    }

    private func tick() {
        guard playing else { return }
        setYear(currentYear + 4 * playbackSpeed)
    }

    private func setYear(_ year: Float) {
        let value = min(max(year, 0), maxYear)
        currentYear = value
        _ = saver.perform(Selector(("setTimelineYear:")),
                          with: NSNumber(value: value))
        slider.doubleValue = Double(value)
        updateLabels()
    }

    private func readYear() -> Float? {
        guard let result = saver.perform(Selector(("currentTimelineYear"))),
              let number = result.takeUnretainedValue() as? NSNumber else { return nil }
        return number.floatValue
    }

    private func updateLabels() {
        let era = Era.at(currentYear)
        yearLabel.stringValue = String(format: "Year %.0f · %@ · %.1fx",
                                       currentYear, era.name, playbackSpeed)
        if let index = Era.allCases.firstIndex(of: era) {
            eraPopup.selectItem(at: index)
        }
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Evolving Timeline"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = TimelineApp()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
