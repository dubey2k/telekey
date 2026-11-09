import AppKit

// MARK: - Remote: turns captured Mac input into HID reports

// macOS virtual keycode → HID keyboard usage. Covers the US layout; Android maps it to the TV's layout.
let hidUsage: [UInt16: UInt8] = [
    0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09, 5: 0x0A, 4: 0x0B, 34: 0x0C, 38: 0x0D, 40: 0x0E, 37: 0x0F,
    46: 0x10, 45: 0x11, 31: 0x12, 35: 0x13, 12: 0x14, 15: 0x15, 1: 0x16, 17: 0x17, 32: 0x18, 9: 0x19, 13: 0x1A, 7: 0x1B,
    16: 0x1C, 6: 0x1D, 18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 23: 0x22, 22: 0x23, 26: 0x24, 28: 0x25, 25: 0x26, 29: 0x27,
    36: 0x28, 53: 0x29, 51: 0x2A, 48: 0x2B, 49: 0x2C, 27: 0x2D, 24: 0x2E, 33: 0x2F, 30: 0x30, 42: 0x31, 41: 0x33, 39: 0x34,
    50: 0x35, 43: 0x36, 47: 0x37, 44: 0x38, 10: 0x64, 76: 0x58,
    122: 0x3A, 120: 0x3B, 99: 0x3C, 118: 0x3D, 96: 0x3E, 97: 0x3F, 98: 0x40, 100: 0x41, 101: 0x42, 109: 0x43, 103: 0x44, 111: 0x45,
    115: 0x4A, 116: 0x4B, 117: 0x4C, 119: 0x4D, 121: 0x4E, 124: 0x4F, 123: 0x50, 125: 0x51, 126: 0x52]
// Android keycodes for the remote buttons and ⌘ shortcuts.
let kBack = 4, kHome = 3, kVolUp = 24, kVolDown = 25, kMute = 164, kSettings = 176, kPlayPause = 85, kSleep = 223

@MainActor final class Remote: ObservableObject {
    let link = Link()
    @Published var connected = false
    @Published var captured = false
    let ip: String
    @Published var speed: Double {
        didSet { Configs.edit(ip) { $0.trackpadSpeed = speed }; UserDefaults.standard.set(speed, forKey: "speed") }
    }

    @Published var scrollSpeed: Double {
        didSet { Configs.edit(ip) { $0.scrollSpeed = scrollSpeed }; UserDefaults.standard.set(scrollSpeed, forKey: "scrollSpeed") }
    }

    /// Speeds are saved in the TV's config; a new TV starts from the last speeds used anywhere.
    init(ip: String = "") {
        self.ip = ip
        let c = Configs.load(ip), d = UserDefaults.standard
        speed = c?.trackpadSpeed ?? d.object(forKey: "speed") as? Double ?? 1.5
        scrollSpeed = c?.scrollSpeed ?? d.object(forKey: "scrollSpeed") as? Double ?? 0.5
    }
    private var buttons: UInt8 = 0, mods: UInt8 = 0, keys: [UInt8] = []
    private var restX = 0.0, restY = 0.0, restScroll = 0.0, restPan = 0.0, cmdDown = false, cmdUsed = false
    var onScreenshot: () -> Void = {}

    func capture() {
        guard connected, !captured else { return }
        captured = true
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)  // the Mac pointer stays put; movement goes to the TV
    }

    func release() {
        guard captured else { return }
        captured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        buttons = 0; mods = 0; keys = []; cmdDown = false
        mouse(0, 0, 0)
        keyboard()
    }

    func key(_ code: Int) { link.key(code) }

    /// Local event monitor: while captured, every input event goes to the TV and is swallowed here.
    /// The remote shortcuts (⌘ + key) also work whenever the window is in front, controlling the TV or not.
    func handle(_ e: NSEvent) -> NSEvent? {
        // typing in a text field (link, search, DNS…): ⌘V, ⌘↑ and friends belong to the field
        let typing = NSApp.keyWindow?.firstResponder is NSTextView
        if !captured, connected, !typing, e.type == .keyDown, e.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,  // arrows also carry .function/.numericPad
           remoteShortcut(e.keyCode) { return nil }
        guard captured else { return e }
        switch e.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            restX += e.deltaX * speed
            restY += e.deltaY * speed
            let dx = Int(restX), dy = Int(restY)  // keep the fractions so slow moves still add up
            restX -= Double(dx); restY -= Double(dy)
            if dx != 0 || dy != 0 { mouse(dx, dy, 0) }
        case .leftMouseDown: buttons |= 1; mouse(0, 0, 0)
        case .leftMouseUp: buttons &= ~1; mouse(0, 0, 0)
        case .rightMouseDown: buttons |= 2; mouse(0, 0, 0)  // Android: secondary click = Back
        case .rightMouseUp: buttons &= ~2; mouse(0, 0, 0)
        case .otherMouseDown: buttons |= 4; mouse(0, 0, 0)
        case .otherMouseUp: buttons &= ~4; mouse(0, 0, 0)
        case .scrollWheel:
            // Only while fingers move: the Mac's coasting after a flick would keep scrolling for a second, and apps
            // that move a whole row per wheel step (JioHotstar) then jump far past where you stopped.
            guard e.momentumPhase.isEmpty else { return nil }
            // at scroll speed 1×, 12 points of trackpad travel = 1 wheel notch
            let unit = e.hasPreciseScrollingDeltas ? 12.0 : 1.0
            restScroll += e.scrollingDeltaY / unit * scrollSpeed
            restPan -= e.scrollingDeltaX / unit * scrollSpeed  // HID pan + = right; Mac deltaX + = content moves right
            let notches = Int(restScroll), pans = Int(restPan)
            restScroll -= Double(notches); restPan -= Double(pans)
            if notches != 0 || pans != 0 { mouse(0, 0, notches, pans) }
        case .flagsChanged: flags(e)
        case .keyDown:
            if cmdDown { cmdUsed = true; shortcut(e.keyCode) }
            else if !e.isARepeat, let u = hidUsage[e.keyCode], !keys.contains(u), keys.count < 6 { keys.append(u); keyboard() }
        case .keyUp:
            if let u = hidUsage[e.keyCode], let i = keys.firstIndex(of: u) { keys.remove(at: i); keyboard() }
        default: return e
        }
        return nil
    }

    private func flags(_ e: NSEvent) {
        if e.keyCode == 55 || e.keyCode == 54 {  // ⌘ is never sent to the TV: ⌘+key = shortcut, ⌘ alone = release
            if e.modifierFlags.contains(.command) { cmdDown = true; cmdUsed = false }
            else { cmdDown = false; if !cmdUsed { release() } }
            return
        }
        if e.keyCode == 57 {  // Caps Lock: tap it on the TV
            keys.append(0x39); keyboard(); keys.removeAll { $0 == 0x39 }; keyboard()
            return
        }
        // left/right ctrl, shift, option from the device-dependent bits of the modifier flags
        let raw = e.modifierFlags.rawValue
        let bits: [(UInt, UInt8)] = [(0x1, 0x01), (0x2, 0x02), (0x20, 0x04), (0x2000, 0x10), (0x4, 0x20), (0x40, 0x40)]
        mods = bits.reduce(0) { raw & $1.0 != 0 ? $0 | $1.1 : $0 }
        keyboard()
    }

    /// While controlling the TV: the remote shortcuts, plus ⌘⌫ = Back and ⌘V = paste the Mac clipboard on the TV.
    private func shortcut(_ keyCode: UInt16) {
        if remoteShortcut(keyCode) { return }
        if keyCode == 51 { key(kBack) }
        if keyCode == 9, let s = NSPasteboard.general.string(forType: .string) { link.paste(s) }
    }

    /// One ⌘ shortcut per remote button (the labels under the buttons).
    private func remoteShortcut(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 11: key(kBack)         // ⌘B
        case 4: key(kHome)          // ⌘H
        case 35: key(kPlayPause)    // ⌘P
        case 125: key(kVolDown)     // ⌘↓
        case 126: key(kVolUp)       // ⌘↑
        case 46: key(kMute)         // ⌘M
        case 43: key(kSettings)     // ⌘,
        case 1: onScreenshot()      // ⌘S
        default: return false
        }
        return true
    }

    private func mouse(_ dx: Int, _ dy: Int, _ wheel: Int, _ pan: Int = 0) {
        var v = [dx, dy, wheel, pan]
        repeat {  // HID values are limited to ±127 per report
            let step = v.map { max(-127, min(127, $0)) }
            link.hid(mouseID, [buttons] + step.map { UInt8(bitPattern: Int8($0)) })
            v = zip(v, step).map { $0 - $1 }
        } while v.contains { $0 != 0 }
    }

    private func keyboard() { link.hid(keyboardID, [mods, 0] + keys.prefix(6) + [UInt8](repeating: 0, count: max(0, 6 - keys.count))) }
}
