import Foundation
import Network

// MARK: - Model: find, pair, connect

struct Found: Identifiable, Equatable {
    enum State { case ready, pair, setup, offline }  // setup = an Android TV without debugging turned on
    var id: String { ip }
    let ip: String, addr: String, name: String, state: State
}

/// Finds Android/Google TVs through Google Cast, which they all advertise, so TVs show up even before
/// debugging is turned on. Keeps IP → friendly name.
final class CastBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    private var resolving: Set<String> = []
    private(set) var tvs: [String: String] = [:]  // touched on the main queue only

    func start() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in results.forEach { self?.resolve($0) } }
        b.start(queue: .main)
        browser = b
    }

    private func resolve(_ r: NWBrowser.Result) {
        guard case .bonjour(let txt) = r.metadata, resolving.insert("\(r.endpoint)").inserted else { return }
        // ponytail: "ca" bit 1 = video out; skips speakers. A model list if odd devices still slip through.
        if let ca = Int(txt["ca"] ?? ""), ca & 1 == 0 { return }
        let name = txt["fn"] ?? txt["md"] ?? "Android TV"
        let c = NWConnection(to: r.endpoint, using: .tcp)  // connecting is the simplest way to learn the IP
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if case .hostPort(.ipv4(let a), _)? = c.currentPath?.remoteEndpoint {
                    self?.tvs[a.rawValue.map(String.init).joined(separator: ".")] = name
                }
                c.cancel()
            case .failed, .waiting: c.cancel()
            default: break
            }
        }
        c.start(queue: .main)
    }
}

@MainActor final class Model: ObservableObject {
    enum Screen { case list, pairing, connecting, session }
    @Published var screen = Screen.list
    @Published var mine: [Found] = []    // TVs used before
    @Published var others: [Found] = []  // everything else on the network
    @Published var scanned = false
    @Published var scanning = false
    @Published var setupTV: Found?
    @Published var waitingFor: Found?  // connect to this TV as soon as it answers (last TV at launch, or one that dropped)
    private var attempt = 0  // bumped by back(): a connect still in flight sees it and gives up
    @Published var banner = ""  // why we're back on the TV list
    @Published var progress = ""
    @Published var connectingTo = "Telekey"
    @Published var pairing: Found?
    @Published var pairError = ""
    @Published var askPairAddress = false
    @Published var busy = false
    @Published var tvName = ""
    @Published var remote = Remote()
    @Published var tv = TV()
    let cast = CastBrowser()
    private var connectError = ""

    /// Remembered TVs (from tvs.json), IP → name. They're tried on port 5555 first.
    var remembered: [String: String] { Configs.all().mapValues(\.name) }

    func start() async {
        _ = await run(["adb", "start-server"])
        cast.start()
        screen = .list
        if waitingFor == nil, let last = Configs.all().max(by: { ($0.value.lastConnected ?? .distantPast) < ($1.value.lastConnected ?? .distantPast) }) {
            waitingFor = Found(ip: last.key, addr: "\(last.key):5555", name: last.value.name, state: .ready)
        }
    }

    /// Port 5555 (plain adb) stays open through sleep and, on many TVs, restarts; Wireless debugging doesn't,
    /// so it's preferred. Your TVs: remembered ones, online or not. Others: adb's mDNS, then Cast-only TVs.
    func refresh() async {
        guard !scanning else { return }
        scanning = true
        let known = remembered
        func open5555(_ ip: String) async -> Bool { text(await run(["nc", "-z", "-v", "-G", "1", ip, "5555"])).contains("succeeded") }
        // `adb mdns services` lines: adb-SERIAL-xyz<TAB>_adb-tls-connect._tcp<TAB>192.168.1.5:37123
        let services = text(await run(["adb", "mdns", "services"])).split(separator: "\n")
            .map { $0.split(separator: "\t").map(String.init) }.filter { $0.count >= 3 }
        func service(_ ip: String, _ type: String) -> String? { services.first { $0[1].hasPrefix(type) && $0[2].hasPrefix(ip + ":") }?[2] }

        var mine: [Found] = []
        for (ip, name) in known.sorted(by: { $0.value < $1.value }) {
            if await open5555(ip) { mine.append(Found(ip: ip, addr: "\(ip):5555", name: name, state: .ready)) }
            else if let a = service(ip, "_adb-tls-connect") { mine.append(Found(ip: ip, addr: a, name: name, state: .ready)) }
            else { mine.append(Found(ip: ip, addr: "\(ip):5555", name: name, state: .offline)) }
        }
        var others: [Found] = []
        let castNames = cast.tvs
        func seen(_ ip: String) -> Bool { mine.contains { $0.ip == ip } || others.contains { $0.ip == ip } }
        for plain in [true, false] {
            for f in services where f[1].hasPrefix(plain ? "_adb._tcp" : "_adb-tls-connect") {
                let ip = String(f[2].split(separator: ":")[0])
                if !seen(ip) { others.append(Found(ip: ip, addr: f[2], name: castNames[ip] ?? "Android TV", state: plain ? .ready : .pair)) }
            }
        }
        for (ip, name) in castNames.sorted(by: { $0.value < $1.value }) where !seen(ip) {
            others.append(Found(ip: ip, addr: "\(ip):5555", name: name, state: await open5555(ip) ? .ready : .setup))
        }
        self.mine = mine
        self.others = others
        scanned = true
        scanning = false
        if screen == .list, let w = waitingFor, let tv = mine.first(where: { $0.ip == w.ip && $0.state == .ready }) {
            waitingFor = nil
            Task { await connect(tv) }
        }
    }

    /// Fixes most "can't reach the TV" problems on the Mac side: adb's background server gets stuck or loses network access.
    func restartAdb() {
        banner = "Resetting the Mac's link to TVs…"
        Task {
            _ = await run(["adb", "kill-server"])
            _ = await run(["adb", "start-server"])
            banner = "Link reset. Pick your TV again."
            await refresh()
        }
    }

    func forget(_ tv: Found) {
        Configs.delete(tv.ip)
        if waitingFor?.ip == tv.ip { waitingFor = nil }
        mine.removeAll { $0.ip == tv.ip }
    }

    func pick(_ tv: Found) {
        banner = ""
        setupTV = nil
        waitingFor = nil
        switch tv.state {
        case .ready: Task { await connect(tv) }
        case .pair: startPairing(tv)
        case .setup: setupTV = tv
        case .offline: banner = "\(tv.name) isn't answering. Turn it on and check it's on this Wi-Fi."
        }
    }

    func addByIP(_ input: String) {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard s.wholeMatch(of: validAddress) != nil else { banner = "“\(s)” isn't an IP address."; return }
        let addr = s.contains(":") ? s : s + ":5555"  // older TVs' "Network debugging" listens on 5555
        let ip = String(addr.split(separator: ":")[0])
        pick(Found(ip: ip, addr: addr, name: remembered[ip] ?? ip, state: .ready))
    }

    func startPairing(_ tv: Found) {
        pairing = tv
        pairError = ""
        askPairAddress = false
        screen = .pairing
    }

    func pair(code: String, address: String) {
        guard let tv = pairing else { return }
        busy = true
        pairError = ""
        Task {
            var paddr = address.trimmingCharacters(in: .whitespaces)
            if paddr.isEmpty {  // the TV advertises its pairing port while the pairing screen is open
                paddr = text(await run(["adb", "mdns", "services"])).split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
                    .first { $0.count >= 3 && $0[1].hasPrefix("_adb-tls-pairing") && $0[2].hasPrefix(tv.ip + ":") }?[2] ?? ""
            }
            guard !paddr.isEmpty else {
                askPairAddress = true
                pairError = "Couldn't find the TV's pairing screen. Type the IP address & port shown under the code."
                busy = false
                return
            }
            let out = text(await run(["adb", "pair", paddr, code.trimmingCharacters(in: .whitespaces)]))
            busy = false
            guard out.contains("Successfully paired") else {
                pairError = "That didn't work: the code was wrong or has expired. Close and re-open the pairing screen on the TV, then type the new code."
                return
            }
            await connect(Found(ip: tv.ip, addr: tv.addr, name: tv.name, state: .ready))
        }
    }

    func connect(_ found: Found) async {
        attempt += 1
        let me = attempt
        screen = .connecting
        connectingTo = found.name
        progress = "Connecting to \(found.name)…"
        let ok = await adbConnect(found.addr)
        guard me == attempt else { return }  // cancelled
        guard ok else {
            if !found.addr.hasSuffix(":5555"), connectError.isEmpty, found.state != .offline { startPairing(found); return }  // Wireless debugging: pairing missing or forgotten
            back(connectError.isEmpty ? "Couldn't connect to \(found.ip). Check that the TV is on and USB debugging is on." : connectError)
            return
        }
        var addr = found.addr
        if !addr.hasSuffix(":5555") {  // also open port 5555, so the next connection survives the TV sleeping
            progress = "Keeping \(found.name) reachable after sleep (adb port 5555, approved devices only)…"
            _ = await run(["adb", "-s", addr, "tcpip", "5555"])
            try? await Task.sleep(for: .seconds(2))
            if await adbConnect("\(found.ip):5555") { addr = "\(found.ip):5555" }
            else if !(await adbConnect(addr)) { back("\(found.name) restarted its debugging service and didn't come back. Pick it again."); return }  // tcpip restarts adbd
        }
        guard me == attempt else { return }
        serial = addr
        var name = remembered[found.ip] ?? ""
        if name.isEmpty {
            name = await sh("settings get global device_name")
            if name.isEmpty || name == "null" { name = found.ip }
        }
        Configs.edit(found.ip) { $0.name = name; $0.lastConnected = Date() }
        progress = "Starting control on \(name)…"
        let r = Remote(ip: found.ip)
        let error = await r.link.open()
        guard me == attempt else { r.link.close(); return }
        if let error { r.link.close(); back(error); return }
        let again = Found(ip: found.ip, addr: addr, name: name, state: .ready)
        let started = Date()
        r.link.onDrop = { [weak self] in  // dropping within seconds = something's wrong, so don't retry in a loop
            MainActor.assumeIsolated { self?.back("Lost the connection to \(name).", waitFor: Date().timeIntervalSince(started) > 15 ? again : nil) }
        }
        let t = TV()
        r.onScreenshot = { t.screenshot() }
        r.connected = true
        remote = r
        tv = t
        tvName = name
        screen = .session
    }

    private func adbConnect(_ addr: String) async -> Bool {
        connectError = ""
        var out = text(await run(["adb", "connect", addr]))
        if out.contains("No route to host") {
            // adb's background server keeps the network permission of the app that started it; one left over from an
            // earlier Telekey that crashed is cut off. It's Telekey's private server (port 5038), so restarting it is safe.
            _ = await run(["adb", "kill-server"])
            _ = await run(["adb", "start-server"])
            out = text(await run(["adb", "connect", addr]))
            if out.contains("No route to host") {
                connectError = "macOS is blocking Telekey from your network. Turn Telekey on in System Settings → Privacy & Security → Local Network, then try again."
                return false
            }
        }
        if out.contains("failed to connect") || out.contains("cannot connect") { return false }
        for _ in 0..<30 {
            let state = text(await run(["adb", "-s", addr, "get-state"]))
            if state == "device" { return true }
            if state.contains("unauthorized") { progress = "Look at the TV and allow this Mac (tick “Always allow”)." }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// Ends the session or connection attempt and shows the TV list, with `message` on top.
    /// `waitFor` reconnects to that TV by itself once it answers again.
    func back(_ message: String, waitFor: Found? = nil) {
        attempt += 1
        waitingFor = waitFor
        remote.release()
        remote.connected = false
        remote.link.close()
        banner = message
        screen = .list
    }
}
