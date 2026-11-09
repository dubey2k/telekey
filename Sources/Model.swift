import Foundation

@MainActor final class Model: ObservableObject {
    enum Screen { case list, pairing, connecting, session }

    @Published var screen = Screen.list
    @Published var mine: [Found] = []
    @Published var others: [Found] = []
    @Published var scanned = false
    @Published var scanning = false
    @Published var setupTV: Found?
    @Published var waitingFor: Found?  // reconnect as soon as it answers
    @Published var banner = ""
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
    private var job: Task<Void, Never>?
    // Everything waits on this: two adb clients that both find no server each start one, and the loser crashes.
    private lazy var server = Task { _ = await run(["adb", "start-server"]) }

    var remembered: [String: String] { Configs.all().mapValues(\.name) }

    func start() async {
        await server.value
        cast.start()
        screen = .list
        let last = Configs.all().max { ($0.value.lastConnected ?? .distantPast) < ($1.value.lastConnected ?? .distantPast) }
        if waitingFor == nil, let last {
            waitingFor = Found(ip: last.key, addr: "\(last.key):5555", name: last.value.name, state: .ready)
        }
    }

    // MARK: - Finding TVs

    func refresh() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        await server.value

        let known = remembered, castNames = cast.tvs
        async let servicesQuery = mdnsServices()
        async let openQuery = open5555(Array(Set(known.keys).union(castNames.keys)))
        let (services, open) = await (servicesQuery, openQuery)

        // Port 5555 first: unlike Wireless debugging, it survives the TV sleeping.
        let mine = known.sorted { $0.value < $1.value }.map { ip, name in
            if open.contains(ip) { return Found(ip: ip, addr: "\(ip):5555", name: name, state: .ready) }
            if let s = services.first(where: { $0.type.hasPrefix("_adb-tls-connect") && $0.addr.hasPrefix(ip + ":") }) {
                return Found(ip: ip, addr: s.addr, name: name, state: .ready)
            }
            return Found(ip: ip, addr: "\(ip):5555", name: name, state: .offline)
        }

        var others: [Found] = []
        func seen(_ ip: String) -> Bool { mine.contains { $0.ip == ip } || others.contains { $0.ip == ip } }
        for plain in [true, false] {
            for s in services where s.type.hasPrefix(plain ? "_adb._tcp" : "_adb-tls-connect") {
                let ip = String(s.addr.split(separator: ":")[0])
                if !seen(ip) {
                    others.append(Found(ip: ip, addr: s.addr, name: castNames[ip] ?? "Android TV", state: plain ? .ready : .pair))
                }
            }
        }
        for (ip, name) in castNames.sorted(by: { $0.value < $1.value }) where !seen(ip) {
            others.append(Found(ip: ip, addr: "\(ip):5555", name: name, state: open.contains(ip) ? .ready : .setup))
        }

        self.mine = mine
        self.others = others
        scanned = true
        if screen == .list, let w = waitingFor, let tv = mine.first(where: { $0.ip == w.ip && $0.state == .ready }) {
            waitingFor = nil
            connect(tv)
        }
    }

    func restartAdb() {
        banner = "Resetting the Mac's link to TVs…"
        server = Task {
            _ = await run(["adb", "kill-server"])
            _ = await run(["adb", "start-server"])
        }
        Task {
            await server.value
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
        case .ready: connect(tv)
        case .pair: startPairing(tv)
        case .setup: setupTV = tv
        case .offline: banner = "\(tv.name) isn't answering. Turn it on and check it's on this Wi-Fi."
        }
    }

    func addByIP(_ input: String) {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard s.wholeMatch(of: validAddress) != nil else {
            banner = "“\(s)” isn't an IP address."
            return
        }
        let addr = s.contains(":") ? s : s + ":5555"
        let ip = String(addr.split(separator: ":")[0])
        pick(Found(ip: ip, addr: addr, name: remembered[ip] ?? ip, state: .ready))
    }

    // MARK: - Pairing

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
        job?.cancel()
        job = Task {
            defer { busy = false }
            var addr = address.trimmingCharacters(in: .whitespaces)
            if addr.isEmpty {  // advertised while the TV's pairing screen is open
                addr = await mdnsServices().first { $0.type.hasPrefix("_adb-tls-pairing") && $0.addr.hasPrefix(tv.ip + ":") }?.addr ?? ""
            }
            guard !Task.isCancelled else { return }
            guard !addr.isEmpty else {
                askPairAddress = true
                pairError = "Couldn't find the TV's pairing screen. Type the IP address & port shown under the code."
                return
            }
            let out = await run(["adb", "pair", addr, code.trimmingCharacters(in: .whitespaces)]).text
            guard !Task.isCancelled else { return }
            guard out.contains("Successfully paired") else {
                pairError = "That didn't work: the code was wrong or has expired. Close and re-open the pairing screen on the TV, then type the new code."
                return
            }
            connect(Found(ip: tv.ip, addr: tv.addr, name: tv.name, state: .ready))
        }
    }

    // MARK: - Connecting

    func connect(_ found: Found) {
        job?.cancel()
        job = Task { await connecting(found) }
    }

    private func connecting(_ found: Found) async {
        screen = .connecting
        connectingTo = found.name
        progress = "Connecting to \(found.name)…"

        switch await adbConnect(found.addr) {
        case .ok:
            break
        case .blocked:
            return back("macOS is blocking Telekey from your network. Turn Telekey on in System Settings → Privacy & Security → Local Network, then try again.")
        case .failed:
            guard !Task.isCancelled else { return }
            // Wireless debugging refuses Macs it isn't paired with
            if !found.addr.hasSuffix(":5555"), found.state != .offline { return startPairing(found) }
            return back("Couldn't connect to \(found.ip). Check that the TV is on and USB debugging is on.")
        }

        var addr = found.addr
        if !addr.hasSuffix(":5555") {
            progress = "Keeping \(found.name) reachable after sleep (adb port 5555, approved devices only)…"
            _ = await adb(addr, "tcpip", "5555")  // restarts adbd on the TV
            try? await Task.sleep(for: .seconds(2))
            if await adbConnect("\(found.ip):5555") == .ok {
                addr = "\(found.ip):5555"
            } else if await adbConnect(addr) != .ok {
                guard !Task.isCancelled else { return }
                return back("\(found.name) restarted its debugging service and didn't come back. Pick it again.")
            }
        }
        guard !Task.isCancelled else { return }

        var name = remembered[found.ip] ?? ""
        if name.isEmpty {
            let r = await shell(addr, "settings get global device_name")
            name = r.ok && !r.stdout.isEmpty && r.stdout != "null" ? r.stdout : found.ip
        }
        Configs.edit(found.ip) { $0.name = name; $0.lastConnected = Date() }

        progress = "Starting control on \(name)…"
        let r = Remote(ip: found.ip, device: addr)
        let error = await r.link.open()
        guard !Task.isCancelled else { return r.link.close() }
        if let error {
            r.link.close()
            return back(error)
        }

        let again = Found(ip: found.ip, addr: addr, name: name, state: .ready)
        let started = Date()
        r.link.onDrop = { [weak self] in
            // dying within seconds means something's wrong; don't reconnect in a loop
            self?.back("Lost the connection to \(name).", waitFor: Date().timeIntervalSince(started) > 15 ? again : nil)
        }
        let t = TV(device: addr)
        r.onScreenshot = { t.screenshot() }
        r.connected = true
        remote = r
        tv = t
        tvName = name
        screen = .session
    }

    private enum Reach { case ok, failed, blocked }

    private func adbConnect(_ addr: String) async -> Reach {
        var out = await run(["adb", "connect", addr]).text
        if out.contains("No route to host") {
            // A server left by a crashed Telekey can lose its network permission. It's ours (port 5038), so restart it.
            _ = await run(["adb", "kill-server"])
            _ = await run(["adb", "start-server"])
            out = await run(["adb", "connect", addr]).text
            if out.contains("No route to host") { return .blocked }
        }
        if out.contains("failed to connect") || out.contains("cannot connect") { return .failed }

        for _ in 0..<30 {
            if Task.isCancelled { return .failed }
            let state = await adb(addr, "get-state").text
            if state == "device" { return .ok }
            if state.contains("unauthorized") { progress = "Look at the TV and allow this Mac (tick “Always allow”)." }
            try? await Task.sleep(for: .seconds(1))
        }
        return .failed
    }

    func back(_ message: String, waitFor: Found? = nil) {
        job?.cancel()
        job = nil
        busy = false
        waitingFor = waitFor
        remote.release()
        remote.connected = false
        remote.link.close()
        banner = message
        screen = .list
    }
}
