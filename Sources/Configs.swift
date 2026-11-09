import Foundation

struct TVConfig: Codable {
    var name: String
    var trackpadSpeed: Double?
    var scrollSpeed: Double?
    var lastConnected: Date?
}

/// ~/Library/Application Support/Telekey/tvs.json, keyed by IP.
@MainActor enum Configs {
    nonisolated static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Telekey/tvs.json")

    private static var tvs: [String: TVConfig] = read()
    private static var pending: DispatchWorkItem?
    private static var unsaved: Data?
    private nonisolated static let disk = DispatchQueue(label: "Telekey.configs")

    static func load(_ ip: String) -> TVConfig? { tvs[ip] }
    static func all() -> [String: TVConfig] { tvs }

    static func edit(_ ip: String, _ change: (inout TVConfig) -> Void) {
        guard ip.wholeMatch(of: validAddress) != nil else { return }
        var c = tvs[ip] ?? TVConfig(name: ip)
        change(&c)
        tvs[ip] = c
        save()
    }

    static func delete(_ ip: String) {
        tvs[ip] = nil
        save()
    }

    static func flush() {
        pending?.cancel()
        if let unsaved { writeNow(unsaved) }
    }

    private static func save() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(tvs) else { return }
        pending?.cancel()
        unsaved = data
        pending = writeLater(data)  // debounced: a dragged slider writes once
    }

    private static func read() -> [String: TVConfig] {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file) else { return [:] }
        if let tvs = try? d.decode([String: TVConfig].self, from: data) { return tvs }
        try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable"))
        return [:]
    }

    // Nonisolated so the closures aren't main-actor code, which Swift 6 traps on when it runs on `disk`.
    private nonisolated static func writeLater(_ data: Data) -> DispatchWorkItem {
        let work = DispatchWorkItem { write(data) }
        disk.asyncAfter(deadline: .now() + 0.5, execute: work)
        return work
    }

    private nonisolated static func writeNow(_ data: Data) { disk.sync { write(data) } }

    private nonisolated static func write(_ data: Data) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
