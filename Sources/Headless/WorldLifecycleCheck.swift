import AppKit
import ScreenSaver
import ImageIO

/// Exercise the real saver view and its wake handlers with an isolated,
/// persisted world. The fixture never changes the Mac's clock or power state.
enum WorldLifecycleCheck {
    static func run(bundlePath: String, output: URL?) throws {
        guard let bundle = Bundle(path: bundlePath), bundle.load(),
              let principal = bundle.principalClass as? ScreenSaverView.Type else {
            fail("could not open saver for the native lifecycle check")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "com.mccullough.evolving.lifecycle-test." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { fail("could not create fixture preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        setenv("EVOLVING_DEV", "1", 1)
        setenv("EVOLVING_LIFECYCLE_SUITE", suite, 1)
        unsetenv("EVOLVING_AWAY_HOURS")
        unsetenv("EVOLVING_AGE_DAYS")
        unsetenv("EVOLVING_PACE")
        unsetenv("EVOLVING_SEED")

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let wake = start.addingTimeInterval(2 * 3600)
        let reopen = start.addingTimeInterval(3 * 86_400)
        let config = WorldConfig(seed: 6393821808673518700, epoch: start, paceName: "Time-lapse",
            clockAnchor: WorldClockAnchor(seed: 6393821808673518700, epoch: start,
                                           restoredAt: start, year: 3498.5))
        try WorldStore.save(config, to: defaults)
        WorldStore.setCameraMode(.coast, in: defaults)
        WorldStore.setSouthernHemisphere(true, in: defaults)

        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }

        func open(at date: Date, preview: Bool = false) -> (ScreenSaverView, NSWindow) {
            setenv("EVOLVING_LIFECYCLE_DATE", String(date.timeIntervalSince1970), 1)
            let rect = NSRect(x: 0, y: 0, width: 950, height: 650)
            guard let view = principal.init(frame: rect, isPreview: preview),
                  view.responds(to: Selector(("lifecycleFixtureWake"))) else {
                fail("saver does not expose the native lifecycle fixture")
            }
            let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Evolving lifecycle check"
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.center()
            window.orderFrontRegardless()
            return (view, window)
        }

        func rendered(_ view: ScreenSaverView, after count: Int = 0) {
            let deadline = Date().addingTimeInterval(6)
            while frames(view) <= count, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
            }
            guard frames(view) > count else { fail("native lifecycle view submitted no frame") }
        }

        func frames(_ view: ScreenSaverView) -> Int { (view.value(forKey: "framesDrawn") as? Int) ?? 0 }

        func invoke(_ view: ScreenSaverView, _ name: String, _ value: Any? = nil) {
            if let value {
                _ = view.perform(Selector(name), with: value)
            } else {
                _ = view.perform(Selector(name))
            }
        }

        func year(_ view: ScreenSaverView) -> Float {
            (view.perform(Selector(("currentTimelineYear")))?.takeUnretainedValue() as? NSNumber)?.floatValue ?? -1
        }

        func recap(_ view: ScreenSaverView) -> String? {
            view.perform(Selector(("lifecycleFixtureRecap")))?.takeUnretainedValue() as? String
        }

        func close(_ view: ScreenSaverView, _ window: NSWindow) {
            view.stopAnimation()
            window.orderOut(nil)
            window.contentView = nil
        }

        func capture(_ name: String, _ window: NSWindow) {
            guard let output else { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                       [.boundsIgnoreFraming, .bestResolution]),
                  let file = CGImageDestinationCreateWithURL(output.appendingPathComponent(name + ".png") as CFURL,
                                                              "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(file, image, nil)
            CGImageDestinationFinalize(file)
        }

        do {
            let (view, window) = open(at: start)
            guard WorldStore.lastSeen(in: defaults) == nil else { fail("constructing the saver changed last seen") }
            view.startAnimation()
            rendered(view)
            guard year(view) == 3498.5, WorldStore.lastSeen(in: defaults) == start else {
                fail("first live frame did not checkpoint the saved clock")
            }
            invoke(view, "lifecycleFixtureSleep")
            invoke(view, "setLifecycleFixtureDate:", wake as NSDate)
            guard WorldStore.lastSeen(in: defaults) == start else { fail("sleep recorded a frame that never happened") }
            let departed = frames(view)
            invoke(view, "lifecycleFixtureWake")
            rendered(view, after: departed)
            guard year(view) == config.simYear(at: wake),
                  WorldStore.lastSeen(in: defaults) == wake,
                  recap(view)?.contains("A new age has begun: Medieval.") == true else {
                fail("wake failed to catch up, acknowledge Live, and show the era change")
            }
            capture("wake-recap", window)

            invoke(view, "setLifecycleFixtureDate:", start as NSDate)
            invoke(view, "lifecycleFixtureWake")
            guard year(view) == config.simYear(at: wake), WorldStore.lastSeen(in: defaults) == wake else {
                fail("wall-clock rollback rewound Live or its checkpoint")
            }

            invoke(view, "setTimelineYear:", NSNumber(value: 12000))
            invoke(view, "setLifecycleFixtureDate:", reopen as NSDate)
            invoke(view, "lifecycleFixtureWake")
            guard year(view) == 12000, WorldStore.lastSeen(in: defaults) == wake, recap(view) == nil else {
                fail("historical Timeline view affected the Live visit")
            }
            close(view, window)
        }

        do {
            let (rolledBack, rolledBackWindow) = open(at: start)
            rolledBack.startAnimation()
            rendered(rolledBack)
            guard year(rolledBack) == config.simYear(at: wake), WorldStore.lastSeen(in: defaults) == wake else {
                fail("relaunch with an earlier wall clock rewound the world")
            }
            close(rolledBack, rolledBackWindow)

            let (preview, previewWindow) = open(at: reopen, preview: true)
            preview.startAnimation()
            rendered(preview)
            close(preview, previewWindow)
            guard WorldStore.lastSeen(in: defaults) == wake, recap(preview) == nil else {
                fail("preview consumed the absence")
            }
        }

        do {
            let (view, window) = open(at: reopen)
            view.startAnimation()
            rendered(view)
            guard year(view) == config.simYear(at: reopen), WorldStore.lastSeen(in: defaults) == reopen,
                  recap(view)?.contains("While you were away") == true else {
                fail("relaunch did not preserve the absence recap and catch up")
            }
            capture("relaunch-recap", window)
            invoke(view, "setTimelineYear:", NSNumber(value: 12000))
            invoke(view, "clearTimelineOverride")
            guard year(view) == config.simYear(at: reopen) else { fail("Go Live could not leave a future Timeline year") }
            close(view, window)
        }

        guard try WorldStore.load(from: defaults) == config,
              WorldStore.cameraMode(in: defaults) == .coast, WorldStore.southernHemisphere(in: defaults) == true else {
            fail("live lifecycle changed world identity, clock anchor or settings")
        }
        var imported = config
        imported.clockAnchor = WorldClockAnchor(seed: config.seed, epoch: config.epoch, restoredAt: reopen, year: 500)
        try WorldStore.save(imported, to: defaults)
        WorldStore.recordLiveFrame(reopen.addingTimeInterval(86_400), for: config, in: defaults)
        guard WorldStore.lastSeen(in: defaults) == reopen else { fail("stale saver changed a reimported world's visit") }

        print("PASS native sleep/wake and 3-day absence; exact Live year, era recap, preview isolation, rollback and preferences")
    }
}
