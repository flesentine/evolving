import Cocoa
import ScreenSaver
import UniformTypeIdentifiers

enum CameraInput: Equatable {
    case begin, automatic, toggleMove
    case orbit(CGFloat, CGFloat), pan(CGFloat, CGFloat), zoom(Double)
}

/// Native pointer/key handling; actions are shared by mouse and trackpad.
final class InputView: NSView {
    var cameraInput: ((CameraInput) -> Void)?
    var movesOnDrag = false
    private var last: NSPoint = .zero
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 { cameraInput?(.automatic); return }
        cameraInput?(.begin)
        last = event.locationInWindow
    }
    private func drag(_ event: NSEvent, move: Bool) {
        let dx = event.locationInWindow.x - last.x
        let dy = event.locationInWindow.y - last.y
        last = event.locationInWindow
        cameraInput?(move ? .pan(dx, dy) : .orbit(dx, dy))
    }
    override func mouseDragged(with event: NSEvent) {
        drag(event, move: movesOnDrag || event.modifierFlags.contains(.shift))
    }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        cameraInput?(.begin); last = event.locationInWindow
    }
    override func rightMouseDragged(with event: NSEvent) { drag(event, move: true) }
    override func otherMouseDown(with event: NSEvent) { rightMouseDown(with: event) }
    override func otherMouseDragged(with event: NSEvent) { drag(event, move: true) }
    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.option) {
            cameraInput?(.pan(event.scrollingDeltaX, event.scrollingDeltaY))
        } else { cameraInput?(.zoom(Double(event.scrollingDeltaY))) }
    }
    override func magnify(with event: NSEvent) { cameraInput?(.zoom(Double(event.magnification) * 80)) }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            super.keyDown(with: event); return
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 120 : 40
        switch event.keyCode {
        case 0: cameraInput?(.pan(step, 0))       // A: move camera left
        case 2: cameraInput?(.pan(-step, 0))      // D: move camera right
        case 13: cameraInput?(.pan(0, -step))     // W: move camera forward
        case 1: cameraInput?(.pan(0, step))       // S: move camera backward
        case 46: cameraInput?(.toggleMove)        // M: toggle normal-drag movement
        default: super.keyDown(with: event)
        }
    }
}

/// Exercise real AppKit input events without depending on accessibility access.
func checkNavigationInput() {
    let input = InputView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
    var actions: [CameraInput] = []
    input.cameraInput = { actions.append($0) }
    func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat,
               _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: flags,
                           timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }
    input.mouseDown(with: mouse(.leftMouseDown, 100, 100))
    input.mouseDragged(with: mouse(.leftMouseDragged, 120, 110))
    precondition(actions.last == .orbit(20, 10), "normal drag must orbit")
    input.mouseDragged(with: mouse(.leftMouseDragged, 140, 125, .shift))
    precondition(actions.last == .pan(20, 15), "Shift-drag must pan")
    input.movesOnDrag = true
    input.mouseDragged(with: mouse(.leftMouseDragged, 150, 130))
    precondition(actions.last == .pan(10, 5), "Move mode must pan")
    input.rightMouseDown(with: mouse(.rightMouseDown, 100, 100))
    input.rightMouseDragged(with: mouse(.rightMouseDragged, 110, 120))
    precondition(actions.last == .pan(10, 20), "right drag must pan")
    for (precise, option) in [(true, false), (true, true), (false, false)] {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                         wheelCount: 2, wheel1: 12, wheel2: 4, wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        if option { cg.flags = .maskAlternate }
        input.scrollWheel(with: NSEvent(cgEvent: cg)!)
        if precise && !option {
            guard case .pan = actions.last! else { preconditionFailure("trackpad scroll must pan") }
        } else {
            guard case .zoom = actions.last! else { preconditionFailure("wheel/Option-scroll must zoom") }
        }
    }
    let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                              windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w",
                              isARepeat: false, keyCode: 13)!
    input.keyDown(with: key)
    precondition(actions.last == .pan(0, -40), "W must move camera forward")
    print("PASS native Timeline input: orbit, Shift-drag, Move mode, right drag, trackpad, Option-scroll, mouse wheel, WASD")
}

struct BookmarkCheck {
    enum Step: String { case save, restore }
    let step: Step
    let directory: URL
}

/// A standalone viewer with a year slider, so the whole arc can be scrubbed
/// without going through Screen Saver settings.
final class TimelineApp: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var inputView: InputView!
    private var moveButton: NSButton!
    private var liveButton: NSButton!
    private let bookmarkCheck: BookmarkCheck?

    init(bookmarkCheck: BookmarkCheck? = nil) {
        self.bookmarkCheck = bookmarkCheck
        super.init()
    }
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
        window.minSize = NSSize(width: 1100, height: 560)
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
        inputView = input
        input.cameraInput = { [weak self] action in
            guard let self else { return }
            switch action {
            case .begin: self.beginFreeCamera()
            case .automatic: self.endFreeCamera()
            case .toggleMove: self.toggleMoveMode()
            case let .orbit(dx, dy): self.orbit(dx: dx, dy: dy)
            case let .pan(dx, dy): self.pan(dx: dx, dy: dy)
            case let .zoom(delta): self.zoom(delta)
            }
        }
        input.toolTip = "Drag to orbit · Shift/right/middle-drag or two-finger scroll to move · pinch or Option-scroll to zoom · WASD to move (Shift faster) · M toggles Move · double-click for auto camera"
        content.addSubview(input)

        let review = NSButton(title: "Save Review View…", target: self, action: #selector(saveReviewView))
        review.bezelStyle = .rounded
        review.frame = NSRect(x: size.width - 178, y: size.height - 42, width: 162, height: 30)
        review.autoresizingMask = [.minXMargin, .minYMargin]
        review.toolTip = "Save this exact view for reproducible river inspection"
        content.addSubview(review)
        let bookmarks = NSButton(title: "Bookmarks", target: self, action: #selector(showBookmarks(_:)))
        bookmarks.bezelStyle = .rounded
        bookmarks.frame = NSRect(x: size.width - 302, y: size.height - 42, width: 118, height: 30)
        bookmarks.autoresizingMask = [.minXMargin, .minYMargin]
        bookmarks.toolTip = "Save or revisit a favorite place in this world"
        content.addSubview(bookmarks)
        buildControls(in: content, width: size.width)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(input)

        if let value = readYear() { currentYear = value }
        slider.doubleValue = Double(currentYear)
        updateLabels()

        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window.attachedSheet == nil,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
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
        if let bookmarkCheck {
            DispatchQueue.main.async { [weak self] in self?.runBookmarkCheck(bookmarkCheck) }
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

        liveButton = NSButton(title: "Live", target: self, action: #selector(goLive))
        liveButton.bezelStyle = .rounded
        liveButton.setButtonType(.pushOnPushOff)
        liveButton.frame = NSRect(x: 90, y: 16, width: 60, height: 30)
        bar.addSubview(liveButton)

        let auto = NSButton(title: "Auto", target: self, action: #selector(autoCamera))
        auto.bezelStyle = .rounded
        auto.frame = NSRect(x: 154, y: 16, width: 60, height: 30)
        bar.addSubview(auto)

        moveButton = NSButton(title: "Move", target: self, action: #selector(toggleMoveMode))
        moveButton.setButtonType(.pushOnPushOff)
        moveButton.bezelStyle = .rounded
        moveButton.frame = NSRect(x: 218, y: 16, width: 64, height: 30)
        moveButton.toolTip = "Drag to move instead of orbit (M). Shift-drag and two-finger scrolling also move."
        bar.addSubview(moveButton)

        speedPopup = NSPopUpButton(frame: NSRect(x: 290, y: 14, width: 86, height: 32),
                                   pullsDown: false)
        speedPopup.addItems(withTitles: ["0.5x", "1x", "2x", "5x", "10x", "25x"])
        speedPopup.selectItem(at: 1)
        speedPopup.target = self
        speedPopup.action = #selector(speedChanged)
        bar.addSubview(speedPopup)

        eraPopup = NSPopUpButton(frame: NSRect(x: 382, y: 14, width: 170, height: 32),
                                 pullsDown: false)
        eraPopup.addItems(withTitles: Era.allCases.map { $0.name })
        eraPopup.target = self
        eraPopup.action = #selector(eraChanged)
        bar.addSubview(eraPopup)

        slider = NSSlider(value: 0, minValue: 0, maxValue: Double(maxYear),
                          target: self, action: #selector(sliderChanged))
        slider.isContinuous = true
        slider.frame = NSRect(x: 562, y: 16, width: width - 862, height: 30)
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

    private func bookmarkStore() throws -> TimelineBookmarkStore {
        if let bookmarkCheck { return TimelineBookmarkStore(directory: bookmarkCheck.directory) }
        return try TimelineBookmarkStore.local()
    }

    private func capturedView() -> RiverReviewView? {
        guard let data = saver.perform(Selector(("timelineBookmarkViewData")))?.takeUnretainedValue() as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(RiverReviewView.self, from: data).validated(maximumYear: .greatestFiniteMagnitude)
    }

    @objc private func showBookmarks(_ button: NSButton) {
        let menu = NSMenu()
        let save = NSMenuItem(title: "Save Bookmark…", action: #selector(promptForBookmark), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
        do {
            let seed = capturedView()?.seed
            let bookmarks = try bookmarkStore().load().filter { $0.view.seed == seed }
            if !bookmarks.isEmpty {
                menu.addItem(.separator())
                let remove = NSMenu()
                for bookmark in bookmarks {
                    let detail = bookmark.mode == .live ? "Live" : "Year \(Int(bookmark.view.year.rounded()))"
                    let title = "\(bookmark.name) · \(detail)"
                    let openItem = NSMenuItem(title: title, action: #selector(openBookmark(_:)), keyEquivalent: "")
                    openItem.target = self
                    openItem.representedObject = bookmark
                    menu.addItem(openItem)

                    let removeItem = NSMenuItem(title: title, action: #selector(confirmRemoveBookmark(_:)), keyEquivalent: "")
                    removeItem.target = self
                    removeItem.representedObject = bookmark
                    remove.addItem(removeItem)
                }
                menu.addItem(.separator())
                let removeItem = NSMenuItem(title: "Remove Bookmark…", action: nil, keyEquivalent: "")
                removeItem.submenu = remove
                menu.addItem(removeItem)
            }
        } catch {
            bookmarkAlert("Bookmarks could not be read", error.localizedDescription)
            return
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    @objc private func promptForBookmark() {
        guard let view = capturedView() else {
            bookmarkAlert("This view is still loading", "Wait for the world to appear, then save the bookmark.")
            return
        }
        let mode: TimelineBookmark.Mode = readLiveMode() ? .live : .historical
        let alert = NSAlert()
        alert.messageText = "Save Bookmark"
        alert.informativeText = mode == .live
            ? "This place will reopen in Live mode."
            : "This place will reopen at the year shown."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        name.placeholderString = "Name this place"
        name.stringValue = mode == .live ? "Live View" : "Year \(Int(view.year.rounded()))"
        alert.accessoryView = name
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let bookmark = TimelineBookmark(name: name.stringValue, mode: mode, view: view)
            do {
                _ = try bookmark.validated()
            } catch {
                self.bookmarkAlert("The bookmark could not be saved", "Enter a name of up to 80 characters and try again.")
                return
            }
            do {
                try self.bookmarkStore().save(bookmark)
            } catch {
                self.bookmarkAlert("The bookmark could not be saved", error.localizedDescription)
            }
        }
    }

    @objc private func openBookmark(_ item: NSMenuItem) {
        guard let bookmark = item.representedObject as? TimelineBookmark else { return }
        if !restoreBookmark(bookmark) {
            bookmarkAlert("This bookmark could not be opened", "Wait for its world to finish loading and try again.")
        }
    }

    private func restoreBookmark(_ bookmark: TimelineBookmark) -> Bool {
        guard let data = try? bookmark.encoded(),
              let result = saver.perform(Selector(("restoreTimelineBookmark:")),
                                         with: data as NSData)?.takeUnretainedValue() as? NSNumber,
              result.boolValue else { return false }
        playing = false
        playButton.title = "Play"
        syncTimeline()
        window.makeFirstResponder(inputView)
        return true
    }

    @objc private func confirmRemoveBookmark(_ item: NSMenuItem) {
        guard let bookmark = item.representedObject as? TimelineBookmark else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(bookmark.name)”?"
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            do {
                try self.bookmarkStore().remove(bookmark)
            } catch {
                self.bookmarkAlert("The bookmark could not be removed", error.localizedDescription)
            }
        }
    }

    private func bookmarkAlert(_ title: String, _ details: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = details
        alert.beginSheetModal(for: window)
    }

    @objc private func saveReviewView() {
        let captured = saver.perform(Selector(("riverReviewViewData")))?.takeUnretainedValue() as? Data
        let panel = NSSavePanel()
        panel.title = "Save Review View"
        panel.nameFieldStringValue = "river-view-\(Int(currentYear)).json"
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                guard let captured else { throw NSError(domain: "RiverReview", code: 1) }
                try captured.write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert(); alert.messageText = "The view could not be saved"
                alert.informativeText = "Wait for the world to finish loading and try again."
                alert.beginSheetModal(for: self.window)
            }
        }
    }

    @objc private func toggleMoveMode() {
        inputView.movesOnDrag.toggle()
        moveButton.state = inputView.movesOnDrag ? .on : .off
        window.makeFirstResponder(inputView)
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
        let height = max(saver.bounds.height, 1)
        _ = saver.perform(Selector(("panCameraX:")),
                          with: NSNumber(value: Float(dx / height)))
        _ = saver.perform(Selector(("panCameraY:")),
                          with: NSNumber(value: Float(dy / height)))
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
        syncTimeline()
    }

    private func tick() {
        if playing {
            setYear(currentYear + 4 * playbackSpeed)
        } else if readLiveMode(), readYear() != currentYear {
            syncTimeline()
        }
    }

    private func syncTimeline() {
        if let value = readYear() { currentYear = value }
        slider.doubleValue = Double(currentYear)
        updateLabels()
    }

    private func readLiveMode() -> Bool {
        (saver.perform(Selector(("isTimelineLive")))?.takeUnretainedValue() as? NSNumber)?.boolValue ?? false
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
        let live = readLiveMode()
        liveButton.state = live ? .on : .off
        yearLabel.stringValue = String(format: "Year %.0f · %@ · %@",
                                       currentYear, era.name, live ? "Live" : String(format: "%.1fx", playbackSpeed))
        if let index = Era.allCases.firstIndex(of: era) {
            eraPopup.selectItem(at: index)
        }
    }

    /// Runs in the bundled app, including its actual saver view and persistence.
    private func runBookmarkCheck(_ check: BookmarkCheck) {
        func require(_ condition: Bool, _ message: String) {
            if !condition {
                FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
                exit(1)
            }
        }

        func view(where match: (RiverReviewView) -> Bool = { _ in true }) -> RiverReviewView {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.04))
                if let frame = capturedView(), match(frame) { return frame }
            }
            FileHandle.standardError.write(Data("FAIL no matching native Timeline frame\n".utf8))
            exit(1)
        }

        func sameCamera(_ a: RiverReviewView, _ b: RiverReviewView) -> Bool {
            a.eye == b.eye && a.target == b.target && a.fov == b.fov
        }

        func screenshot(_ name: String) {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber),
                                 check.directory.appendingPathComponent(name).path]
            if (try? capture.run()) != nil { capture.waitUntilExit() }
        }

        do {
            let store = try bookmarkStore()
            let initial = view()
            let historicalYear: Float = 4400.25
            switch check.step {
            case .save:
                let existing = try store.load()
                require(existing.isEmpty, "fixture directory already contains bookmarks")
                require(readLiveMode(), "initial Timeline mode is Live")
                try store.save(TimelineBookmark(name: "Clifftop Live", mode: .live, view: initial))
                setYear(historicalYear)
                let unpanned = view { $0.year == historicalYear }
                pan(dx: 65, dy: -22)
                zoom(4)
                let historical = view { $0.year == historicalYear && !sameCamera($0, unpanned) }
                require(!readLiveMode(), "scrubbing pauses the live clock")
                try store.save(TimelineBookmark(name: "Market Bend", mode: .historical, view: historical))
                screenshot("saved-historical.png")
                print("PASS saved named historical and Live bookmarks for seed \(initial.seed)")
            case .restore:
                let bookmarks = try store.load()
                guard bookmarks.count == 2,
                      let historical = bookmarks.first(where: { $0.name == "Market Bend" }),
                      let live = bookmarks.first(where: { $0.name == "Clifftop Live" }) else {
                    require(false, "a separate launch must load both named bookmarks")
                    return
                }
                let item = NSMenuItem()
                item.representedObject = historical
                openBookmark(item)
                let restored = view { $0.year == historicalYear && sameCamera($0, historical.view) }
                require(restored.seed == initial.seed && !readLiveMode(), "historical bookmark must pin year in this world")
                try restored.write(to: check.directory.appendingPathComponent("restored-historical.json"))
                screenshot("restored-historical.png")

                pan(dx: 53, dy: 0)
                _ = view { !sameCamera($0, restored) }
                item.representedObject = live
                openBookmark(item)
                let resumed = view { sameCamera($0, live.view) && $0.year != historicalYear }
                require(resumed.seed == initial.seed && resumed.year >= initial.year && readLiveMode(),
                        "Live bookmark must follow the present world clock")
                try resumed.encoded(maximumYear: .greatestFiniteMagnitude)
                    .write(to: check.directory.appendingPathComponent("restored-live.json"), options: .atomic)
                screenshot("restored-live.png")

                var wrongWorld = historical.view
                wrongWorld.seed ^= 1
                require(!restoreBookmark(TimelineBookmark(name: "Another World", mode: .historical, view: wrongWorld)),
                        "bookmark from another world must be rejected")
                require(readLiveMode(), "rejecting a bookmark must preserve current mode")
                print("PASS separate launch restored exact historical camera/year and exact Live camera/current clock")
            }
            NSApp.terminate(nil)
        } catch {
            FileHandle.standardError.write(Data("FAIL bookmark check: \(error)\n".utf8))
            exit(1)
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
if CommandLine.arguments.contains("--check-navigation") {
    checkNavigationInput()
    exit(0)
}
let arguments = CommandLine.arguments
let check: BookmarkCheck?
if arguments.dropFirst().first == "--check-bookmarks" {
    guard arguments.count == 4, let step = BookmarkCheck.Step(rawValue: arguments[2]) else {
        print("usage: EvolvingTimeline --check-bookmarks <save|restore> <fixture-directory>")
        exit(2)
    }
    check = BookmarkCheck(step: step, directory: URL(fileURLWithPath: arguments[3], isDirectory: true))
} else {
    check = nil
}
let delegate = TimelineApp(bookmarkCheck: check)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
