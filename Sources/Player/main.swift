import Cocoa
import ScreenSaver

/// A tiny full-screen host for the saver bundle. It runs outside the
/// ScreenSaver sandbox, so it shares the user-level world with the companion
/// and can be launched straight from the Dock or Finder.
final class PlayerApp: NSObject, NSApplicationDelegate {

    private var window: NSWindow?
    private var saver: ScreenSaverView?
    private var monitor: Any?
    private var launchedAt = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else {
            fail("No display is available.")
            return
        }

        guard let resources = Bundle.main.resourceURL else {
            fail("The app is missing its resources.")
            return
        }
        let saverURL = resources.appendingPathComponent("Evolving.saver")

        guard let bundle = Bundle(url: saverURL), bundle.load() else {
            fail("Could not load Evolving.saver from the app bundle.")
            return
        }
        guard let principal = bundle.principalClass as? ScreenSaverView.Type,
              let view = principal.init(frame: screen.frame, isPreview: false) else {
            fail("Could not create the saver view.")
            return
        }

        let window = NSWindow(contentRect: screen.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false,
                              screen: screen)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        view.startAnimation()

        self.window = window
        self.saver = view
        launchedAt = Date()

        NSApp.activate(ignoringOtherApps: true)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown,
                                                              .leftMouseDown,
                                                              .rightMouseDown,
                                                              .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { NSApp.terminate(nil) }
                return event
            }
            if Date().timeIntervalSince(self.launchedAt) > 1.0 {
                NSApp.terminate(nil)
            }
            return event
        }

        showHint(in: window, screen: screen)
    }

    private func showHint(in window: NSWindow, screen: NSScreen) {
        let label = NSTextField(labelWithString: "Press Esc to exit")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(white: 1, alpha: 0.75)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 26, width: screen.frame.width, height: 20)
        label.autoresizingMask = [.width]
        window.contentView?.addSubview(label)

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 1.2
                label.animator().alphaValue = 0
            }
        }
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Evolving could not start"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
let delegate = PlayerApp()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
