// Telekey: control an Android TV from this Mac. Find the TV, pair it once, click the control pad, and the Mac's
// keyboard and trackpad drive the TV as a plugged-in USB keyboard and mouse.
// Connecting uses adb. Control speaks scrcpy's control protocol to scrcpy's server, which is pushed to the TV
// for the session and deletes itself afterwards. Nothing stays installed on the TV. Build with ./build.sh.
import AppKit
import SwiftUI

/// Buttons and the control pad respond to the first click even when the window isn't focused.
final class FirstClickHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var window: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        // without an Edit menu, text fields get no ⌘X/⌘C/⌘V/⌘A/⌘Z. ponytail: no Hide/Minimize items: ⌘H and ⌘M are remote keys.
        let app = NSMenu(), edit = NSMenu(title: "Edit")
        app.addItem(withTitle: "About Telekey", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Quit Telekey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                     ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let menu = NSMenu()
        for sub in [app, edit] { let item = NSMenuItem(); item.submenu = sub; menu.addItem(item) }
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Telekey"
        window.acceptsMouseMovedEvents = true
        window.backgroundColor = NSColor(Theme.bg)  // no flash of grey before SwiftUI draws
        window.minSize = NSSize(width: 470, height: 420)
        window.contentView = FirstClickHostingView(rootView: RootView(model: model))
        window.setFrameAutosaveName("Telekey")
        if !window.setFrameUsingName("Telekey") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                                    .scrollWheel, .keyDown, .keyUp, .flagsChanged]) { [model] e in
            nonisolated(unsafe) let e = e  // local monitors run on the main thread
            return MainActor.assumeIsolated { model.remote.handle(e) }
        }
        // switching apps (⌘Tab, a notification…) gives the mouse back
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [model] _ in
            MainActor.assumeIsolated { model.remote.release() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ n: Notification) {
        model.remote.release()
        model.remote.link.close()
        model.remote.link.removeTunnel(wait: true)
        let stop = Process()  // our private adb server goes with us, so it never outlives Telekey's network permission
        stop.executableURL = URL(fileURLWithPath: "/usr/bin/env"); stop.arguments = ["adb", "kill-server"]
        try? stop.run(); stop.waitUntilExit()
        Configs.flush()
    }
}

@main enum Main {
    static func main() {
        // adb ships inside the app, so it's always the version Telekey was tested with
        setenv("PATH", (Bundle.main.resourcePath ?? "") + ":/usr/bin:/bin", 1)
        // Telekey's own adb server, on its own port: it has Telekey's Local Network permission, and restarting it
        // never cuts Android Studio or another adb (which use 5037)
        setenv("ANDROID_ADB_SERVER_PORT", "5038", 1)
        let app = NSApplication.shared, delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
