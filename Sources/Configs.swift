import Foundation

// MARK: - Configs: every TV in one JSON file

/// What Telekey knows about a TV and what you set on it. Optional fields are only written once known.
struct TVConfig: Codable {
    var name: String
    var trackpadSpeed: Double?
    var scrollSpeed: Double?
    var lastConnected: Date?
    var privateDNS: String?        // hostname, or "off"
    var screensaver: Bool?
    var animations: String?        // "0", "0.5" or "1"
    var turnedOffApps: [String]?
    var removedApps: [String]?
}

/// All TVs in one file, ~/Library/Application Support/Telekey/tvs.json, as { "<ip>": TVConfig }.
/// Read once at launch; edits update memory at once and are written to disk in the background.
/// ponytail: keyed by IP, so give the TV a fixed IP on the router; key by serial number if TVs hop addresses.
@MainActor enum Configs {
    static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Telekey/tvs.json")
    private static var tvs: [String: TVConfig] = read()
    private static var pendingWrite: DispatchWorkItem?

    static func load(_ ip: String) -> TVConfig? { tvs[ip] }
    static func all() -> [String: TVConfig] { tvs }

    static func edit(_ ip: String, _ change: (inout TVConfig) -> Void) {
        guard ip.wholeMatch(of: validAddress) != nil else { return }
        var c = tvs[ip] ?? TVConfig(name: ip)
        change(&c)
        tvs[ip] = c
        save()
    }

    static func delete(_ ip: String) { tvs[ip] = nil; save() }

    /// Writes after 0.5 s of quiet (a dragged slider makes one write, not hundreds), off the main thread.
    private static func save() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(tvs) else { return }
        pendingWrite?.cancel()
        let work = DispatchWorkItem {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)  // temp file + swap: a crash never leaves half a file
        }
        pendingWrite = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes a pending change right away (on quit).
    static func flush() { if let w = pendingWrite, !w.isCancelled { w.cancel(); w.perform() } }

    private static func read() -> [String: TVConfig] {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file) else { return [:] }
        if let tvs = try? d.decode([String: TVConfig].self, from: data) { return tvs }
        // unreadable (hand-edited, or from a newer version): keep it aside rather than save over it
        try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable"))
        return [:]
    }
}
