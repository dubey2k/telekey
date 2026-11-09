import Foundation

// scrcpy control protocol, app/src/control_msg.c in scrcpy 5.0.1
private enum Msg: UInt8 { case injectKeycode = 0, setClipboard = 9, uhidCreate = 12, uhidInput = 13 }

func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
func be32(_ v: Int) -> [UInt8] { be16(v >> 16) + be16(v) }

let keyboardID = 1, mouseID = 2

// [buttons, dx, dy, wheel, pan]
let mouseDescriptor: [UInt8] = [
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x03, 0x81, 0x01,
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
    0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
    0xC0, 0xC0]

// [modifiers, reserved, 6 keys]
let keyboardDescriptor: [UInt8] = [
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
    0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
    0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
    0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xC0]

/// The control socket to scrcpy's server, which runs on the TV for one session and deletes itself after.
@MainActor final class Link {
    let device: String
    var onDrop: () -> Void = {}

    private var fd: Int32 = -1
    private var port = ""
    private var server: Process?
    private var closed = false

    init(device: String) { self.device = device }

    /// Returns an error message, or nil once the keyboard and mouse exist on the TV.
    func open() async -> String? {
        guard let jar = Bundle.main.path(forResource: "scrcpy-server", ofType: nil),
              let version = Bundle.main.object(forInfoDictionaryKey: "ScrcpyVersion") as? String
        else { return "This copy of Telekey is missing scrcpy-server. Build it with ./build.sh." }

        let push = await adb(device, "push", jar, "/data/local/tmp/scrcpy-server.jar")
        guard push.ok else { return "Couldn't reach the TV: \(push.text)" }

        let scid = String(format: "%08x", UInt32.random(in: 1..<0x7FFF_FFFF))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["adb", "-s", device, "shell", "CLASSPATH=/data/local/tmp/scrcpy-server.jar", "app_process", "/",
                       "com.genymobile.scrcpy.Server", version, "scid=\(scid)", "log_level=warn",
                       "video=false", "audio=false", "tunnel_forward=true", "send_device_meta=false",
                       "power_on=false", "clipboard_autosync=false", "cleanup=true"]
        Link.onExit(p) { [weak self] in Task { @MainActor in self?.dropped() } }
        guard (try? p.run()) != nil else { return "Couldn't start adb." }
        server = p

        let forward = await adb(device, "forward", "tcp:0", "localabstract:scrcpy_\(scid)")
        guard let local = UInt16(forward.stdout) else { return "Couldn't open a tunnel to the TV: \(forward.text)" }
        port = forward.stdout

        for _ in 0..<50 {  // the server needs about a second
            if let s = await background({ Link.connect(local) }) { fd = s; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard fd >= 0, !closed else { return "The TV didn't start the control helper." }

        send(uhidCreate(keyboardID, "Telekey keyboard", keyboardDescriptor))
        send(uhidCreate(mouseID, "Telekey mouse", mouseDescriptor))
        Link.drain(fd) { [weak self] in Task { @MainActor in self?.dropped() } }
        return nil
    }

    func hid(_ id: Int, _ report: [UInt8]) {
        send([Msg.uhidInput.rawValue] + be16(id) + be16(report.count) + report)
    }

    func key(_ keycode: Int) {
        for action: UInt8 in [0, 1] {  // down, up
            send([Msg.injectKeycode.rawValue, action] + be32(keycode) + be32(0) + be32(0))
        }
    }

    func paste(_ s: String) {
        var text = Array(s.utf8)
        if text.count > 100_000 { text = Array(String(s.prefix(25_000)).utf8) }  // cut on a character boundary
        send([Msg.setClipboard.rawValue] + [UInt8](repeating: 0, count: 8) + [1] + be32(text.count) + text)
    }

    func close() {
        guard !closed else { return }
        closed = true
        teardown()
    }

    private func dropped() {
        guard !closed else { return }
        closed = true
        teardown()
        onDrop()
    }

    private func teardown() {
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
        server?.terminate()
        guard !port.isEmpty else { return }
        let p = Process()  // not awaited: adb can hang when the TV has just vanished
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["adb", "-s", device, "forward", "--remove", "tcp:\(port)"]
        try? p.run()
        port = ""
    }

    private func send(_ msg: [UInt8]) {
        guard fd >= 0 else { return }
        var sent = 0
        while sent < msg.count {
            let n = msg.withUnsafeBytes { write(fd, $0.baseAddress! + sent, msg.count - sent) }
            if n > 0 { sent += n }
            else if n < 0, errno == EINTR { continue }
            else { return dropped() }
        }
    }

    private func uhidCreate(_ id: Int, _ name: String, _ descriptor: [UInt8]) -> [UInt8] {
        let head: [UInt8] = [Msg.uhidCreate.rawValue] + be16(id) + be16(0) + be16(0)  // id, vendor, product
        let label: [UInt8] = [UInt8(name.utf8.count)] + Array(name.utf8)
        return head + label + be16(descriptor.count) + descriptor
    }

    // These are nonisolated so their closures run fine off the main thread under Swift 6.

    private nonisolated static func onExit(_ p: Process, _ then: @escaping @Sendable () -> Void) {
        p.terminationHandler = { _ in then() }
    }

    /// The server sends clipboard and LED messages back; we only care when the socket closes.
    private nonisolated static func drain(_ s: Int32, then: @escaping @Sendable () -> Void) {
        Thread {
            var buf = [UInt8](repeating: 0, count: 4096)
            while read(s, &buf, buf.count) > 0 {}
            then()
        }.start()
    }

    /// adb accepts the connection before the server listens; only the server's first byte proves it's there.
    private nonisolated static func connect(_ port: UInt16) -> Int32? {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        var one: Int32 = 1, second = timeval(tv_sec: 1, tv_usec: 0), forever = timeval()
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, 4)
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &second, size)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &second, size)  // a stalled adb fails the write instead of the UI

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
        var byte: UInt8 = 0
        guard connected, read(s, &byte, 1) == 1 else {
            Darwin.close(s)
            return nil
        }
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &forever, size)
        return s
    }
}
