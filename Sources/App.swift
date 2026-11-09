import AppKit
import SwiftUI

@main enum Main {
    static func main() {
        // the bundled adb, on a private server port so we never disturb Android Studio's (5037)
        setenv("PATH", (Bundle.main.resourcePath ?? "") + ":/usr/bin:/bin", 1)
        setenv("ANDROID_ADB_SERVER_PORT", "5038", 1)
        let app = NSApplication.shared, delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var window: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.mainMenu = menu()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Telekey"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.acceptsMouseMovedEvents = true
        window.backgroundColor = NSColor(Theme.bg)
        window.minSize = NSSize(width: 470, height: 420)
        window.contentView = FirstClickHostingView(rootView: RootView(model: model))
        window.setFrameAutosaveName("Telekey")
        if !window.setFrameUsingName("Telekey") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        let events: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged,
        ]
        NSEvent.addLocalMonitorForEvents(matching: events) { [model] e in
            MainActor.assumeIsolated { model.remote.consumes(e) } ? nil : e
        }
        // ⌘Tab and friends give the mouse back
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [model] _ in
            MainActor.assumeIsolated { model.remote.release() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ n: Notification) {
        model.remote.release()
        model.remote.link.close()
        let stop = Process()  // also drops any port forward left behind
        stop.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        stop.arguments = ["adb", "kill-server"]
        try? stop.run()
        stop.waitUntilExit()
        Configs.flush()
    }

    // No Hide or Minimize: ⌘H and ⌘M are remote keys. The Edit menu is what gives text fields ⌘C/⌘V/⌘Z.
    private func menu() -> NSMenu {
        let app = NSMenu(), edit = NSMenu(title: "Edit")
        app.addItem(withTitle: "About Telekey", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Quit Telekey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let items = [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"),
                     ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")]
        for (title, action, key) in items {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let bar = NSMenu()
        for sub in [app, edit] {
            let item = NSMenuItem()
            item.submenu = sub
            bar.addItem(item)
        }
        return bar
    }
}

/// Lets the pad and buttons take the first click even when the window isn't focused.
final class FirstClickHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
