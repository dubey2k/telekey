import Foundation

// MARK: - Link: the control connection to scrcpy's server

func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

// Standard HID descriptors. Mouse report: [buttons, dx, dy, wheel, pan (horizontal wheel)]. Keyboard: [mods, 0, 6 keys].
let mouseDescriptor: [UInt8] = [
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x03, 0x81, 0x01,
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
    0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,  // AC Pan
    0xC0, 0xC0]
let keyboardDescriptor: [UInt8] = [
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
    0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
    0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
    0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xC0]
let keyboardID = 1, mouseID = 2

final class Link: @unchecked Sendable {
    private var fd: Int32 = -1, port = "", server: Process?, closed = false
    private let device = serial  // this session's TV, even if another one is connected later
    var onDrop: () -> Void = {}  // called on the main thread if the TV goes away

    /// Pushes + starts the server, connects, registers the keyboard and mouse. Returns an error message, or nil.
    func open() async -> String? {
        // scrcpy's server ships inside the app (build.sh); the server checks it's started with its own version.
        guard let jar = Bundle.main.path(forResource: "scrcpy-server", ofType: nil),
              let version = Bundle.main.object(forInfoDictionaryKey: "ScrcpyVersion") as? String
        else { return "This copy of Telekey is missing scrcpy-server. Build it with ./build.sh." }
        let push = await adb("push", jar, "/data/local/tmp/scrcpy-server.jar")
        guard push.contains("pushed") else { return "Couldn't reach the TV: \(push)" }

        let scid = String(format: "%08x", UInt32.random(in: 1..<0x7FFF_FFFF))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["adb", "-s", device, "shell", "CLASSPATH=/data/local/tmp/scrcpy-server.jar", "app_process", "/",
                       "com.genymobile.scrcpy.Server", version, "scid=\(scid)", "log_level=warn", "video=false", "audio=false",
                       "tunnel_forward=true", "send_device_meta=false", "power_on=false", "clipboard_autosync=false", "cleanup=true"]
        p.terminationHandler = { [weak self] _ in self?.dropped() }
        guard (try? p.run()) != nil else { return "Couldn't start adb." }  // its exit before connecting = a failed start
        server = p
        port = text(await run(["adb", "-s", device, "forward", "tcp:0", "localabstract:scrcpy_\(scid)"]))
        guard let portNumber = UInt16(port) else { return "Couldn't open a tunnel to the TV: \(port)" }
        for _ in 0..<50 where !connect(portNumber) { try? await Task.sleep(for: .milliseconds(100)) }  // server takes ~1 s to start
        guard fd >= 0 else { return "The TV didn't start the control helper." }

        send(uhidCreate(keyboardID, "Telekey keyboard", keyboardDescriptor))
        send(uhidCreate(mouseID, "Telekey mouse", mouseDescriptor))
        Thread { [self] in  // the server sends clipboard/LED messages back; read and drop them, and notice when the TV goes away
            var buf = [UInt8](repeating: 0, count: 4096)
            while read(fd, &buf, buf.count) > 0 {}
            dropped()
        }.start()
        return nil
    }

    /// adb accepts the local connection even before the server listens; the server's first byte confirms it's real.
    private func connect(_ portNumber: UInt16) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = portNumber.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var one: Int32 = 1, wait = timeval(tv_sec: 1, tv_usec: 0), forever = timeval()
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, 4)  // send every mouse move right away
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
        var byte: UInt8 = 0
        guard ok, read(s, &byte, 1) == 1 else { Darwin.close(s); return false }
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &forever, socklen_t(MemoryLayout<timeval>.size))
        fd = s
        return true
    }

    /// UHID_CREATE: id, vendor id, product id, name (1-byte length), report descriptor (2-byte length)
    private func uhidCreate(_ id: Int, _ name: String, _ descriptor: [UInt8]) -> [UInt8] {
        var m: [UInt8] = [12]
        m += be16(id)
        m += be16(0)
        m += be16(0)
        m.append(UInt8(name.utf8.count))
        m += Array(name.utf8)
        m += be16(descriptor.count)
        return m + descriptor
    }

    func send(_ msg: [UInt8]) { if fd >= 0 { _ = msg.withUnsafeBufferPointer { write(fd, $0.baseAddress, msg.count) } } }
    func hid(_ id: Int, _ report: [UInt8]) { send([13] + be16(id) + be16(report.count) + report) }
    func key(_ androidKeycode: Int) {  // INJECT_KEYCODE: action (0 down, 1 up), keycode, repeat, metastate
        send([0, 0] + be32(androidKeycode) + be32(0) + be32(0))
        send([0, 1] + be32(androidKeycode) + be32(0) + be32(0))
    }
    func paste(_ s: String) {  // SET_CLIPBOARD: sequence 0 (no ack), paste = 1, text
        var t = Array(s.utf8)
        if t.count > 100_000 { t = Array(String(s.prefix(30_000)).utf8) }  // ≤ 4 bytes a character, never cut mid-character
        send([9] + [UInt8](repeating: 0, count: 8) + [1] + be32(t.count) + t)
    }

    func close() {
        guard !closed else { return }  // back() can run more than once for the same session
        closed = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1 }  // the server exits (and deletes itself) when this closes
        server?.terminate()
        removeTunnel()
    }

    /// Waits only while the app is quitting; otherwise runs in the background (adb can hang when the TV just vanished).
    func removeTunnel(wait: Bool = false) {
        guard !port.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["adb", "-s", device, "forward", "--remove", "tcp:\(port)"]
        port = ""
        try? p.run()
        if wait { p.waitUntilExit() }
    }

    private func dropped() {
        DispatchQueue.main.async {
            guard !self.closed else { return }
            self.closed = true
            self.removeTunnel()
            self.onDrop()
        }
    }
}
