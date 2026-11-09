import Foundation
import Network

struct Found: Identifiable, Equatable {
    enum State { case ready, pair, setup, offline }  // setup: debugging is still off
    var id: String { ip }
    let ip: String, addr: String, name: String, state: State
}

/// Every Android TV advertises Google Cast, so this finds TVs before debugging is even on. IP → name.
/// Main queue only.
final class CastBrowser: @unchecked Sendable {
    private(set) var tvs: [String: String] = [:]
    private var browser: NWBrowser?
    private var resolving: Set<String> = []

    func start() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in results.forEach { self?.resolve($0) } }
        b.start(queue: .main)
        browser = b
    }

    private func resolve(_ r: NWBrowser.Result) {
        let key = "\(r.endpoint)"
        guard case .bonjour(let txt) = r.metadata, resolving.insert(key).inserted else { return }
        if let ca = Int(txt["ca"] ?? ""), ca & 1 == 0 { return }  // no video out: a speaker
        let name = txt["fn"] ?? txt["md"] ?? "Android TV"

        // Connecting is the easy way to get the IP. adb needs IPv4.
        let params = NWParameters.tcp
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let c = NWConnection(to: r.endpoint, using: params)
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if case .hostPort(.ipv4(let a), _)? = c.currentPath?.remoteEndpoint {
                    self?.tvs[a.rawValue.map(String.init).joined(separator: ".")] = name
                } else {
                    self?.resolving.remove(key)
                }
                c.cancel()
            case .failed, .waiting:
                self?.resolving.remove(key)  // retried on the next browse update
                c.cancel()
            default:
                break
            }
        }
        c.start(queue: .main)
    }
}

/// `adb mdns services` lines look like: name<TAB>_adb-tls-connect._tcp<TAB>192.168.1.5:37123
func mdnsServices() async -> [(type: String, addr: String)] {
    await run(["adb", "mdns", "services"]).stdout.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t").map(String.init)
        return f.count >= 3 ? (f[1], f[2]) : nil
    }
}

/// IPs that accept a connection on adb's plain port, probed in parallel.
func open5555(_ ips: [String]) async -> Set<String> {
    await withTaskGroup(of: String?.self) { group in
        for ip in ips {
            group.addTask { await run(["nc", "-z", "-G", "1", ip, "5555"]).ok ? ip : nil }
        }
        var open: Set<String> = []
        for await ip in group { if let ip { open.insert(ip) } }
        return open
    }
}
