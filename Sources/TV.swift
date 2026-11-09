import AppKit
import UniformTypeIdentifiers

let dnsPresets = [
    ("Off", "Off (TV default)"),
    ("dns.adguard-dns.com", "AdGuard (blocks ads)"),
    ("adblock.dns.mullvad.net", "Mullvad (blocks ads)"),
    ("Custom", "Custom…"),
]

struct BigApp: Identifiable { let id: String; let bytes: Int }

/// Everything behind the tabs, for one connected TV.
@MainActor final class TV: ObservableObject {
    enum Section { case apps, ads, speed, storage, about }
    enum AppAction { case stop, clear, toggle, remove, restore }

    let device: String

    @Published var status = ""
    @Published var dnsChoice = "Off"
    @Published var customDNS = ""
    @Published var link = ""
    @Published var screensaver = true
    @Published var anim = "1"
    @Published var storage = "…"
    @Published var bigApps: [BigApp] = []
    @Published var info = "…"
    @Published var packages: [String] = []
    @Published var disabled: Set<String> = []
    @Published var yours: Set<String> = []
    @Published var removed: [String] = []
    @Published var sizes: [String: Int] = [:]
    @Published var search = ""
    @Published var filter = "Bloat"

    private var loaded: Set<Section> = []
    private var statusTask: Task<Void, Never>?

    init(device: String = "") { self.device = device }

    var suggested: [String] {
        packages.filter { !yours.contains($0) && (bloat[$0] != nil || $0.contains(likelyAds)) }
    }

    var shownPackages: [String] {
        if !search.isEmpty { return (packages + removed).filter { $0.localizedCaseInsensitiveContains(search) } }
        switch filter {
        case "Bloat": return suggested
        case "Yours": return packages.filter { yours.contains($0) }
        case "System": return packages.filter { !yours.contains($0) }
        case "Off": return packages.filter { disabled.contains($0) }
        case "Removed": return removed
        default: return packages
        }
    }

    /// Shows "label…" while `work` runs, then its result for a few seconds.
    func act(_ label: String, _ work: @escaping @MainActor () async -> String) {
        status = label + "…"
        statusTask?.cancel()
        Task {
            status = await work()
            statusTask = Task {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { status = "" }
            }
        }
    }

    // nil if adb failed, so its error text never shows up as data
    private func query(_ cmd: String) async -> String? {
        let r = await shell(device, cmd)
        return r.ok ? r.stdout : nil
    }

    private func exec(_ cmd: String, timeout: Duration = .seconds(20)) async -> String {
        await shell(device, cmd, timeout: timeout).text
    }

    // MARK: - Loading

    func load(_ section: Section) {
        guard loaded.insert(section).inserted else { return }
        Task {
            let ok = switch section {
            case .ads: await loadAds()
            case .apps: await loadPackages()
            case .speed: await loadAnimations()
            case .storage: await loadStorage()
            case .about: await loadAbout()
            }
            if !ok {
                loaded.remove(section)  // retry next time it opens
                act("Reading from the TV") { "The TV didn't answer. Open the section again to retry." }
            }
        }
    }

    private func loadAds() async -> Bool {
        guard let mode = await query("settings get global private_dns_mode"),
              let host = await query("settings get global private_dns_specifier"),
              let saver = await query("settings get secure screensaver_enabled") else { return false }
        if mode != "hostname" {
            dnsChoice = "Off"
        } else if dnsPresets.contains(where: { $0.0 == host }) {
            dnsChoice = host
        } else {
            dnsChoice = "Custom"
            customDNS = host
        }
        screensaver = saver != "0"  // "null" means never set, which is on
        return true
    }

    private func loadAnimations() async -> Bool {
        guard let a = await query("settings get global window_animation_scale") else { return false }
        anim = a == "0" || a == "0.0" ? "0" : a == "0.5" ? "0.5" : "1"
        return true
    }

    private func loadAbout() async -> Bool {
        guard let make = await query("getprop ro.product.manufacturer"),
              let model = await query("getprop ro.product.model"),
              let version = await query("getprop ro.build.version.release") else { return false }
        info = "\(make) \(model) · Android \(version) · \(device.split(separator: ":")[0])"
        return true
    }

    @discardableResult
    func loadStorage() async -> Bool {
        guard let df = await query("df -h /data") else { return false }
        let cols = df.split(separator: "\n").last?.split(separator: " ") ?? []  // Filesystem Size Used Avail …
        storage = cols.count >= 4 ? "\(cols[3]) free of \(cols[1])" : "unknown"
        return true
    }

    @discardableResult
    func loadPackages() async -> Bool {
        func list(_ flag: String) async -> [String]? {
            await query("pm list packages \(flag)")?.split(separator: "\n").compactMap {
                $0.hasPrefix("package:") ? String($0.dropFirst(8)).trimmingCharacters(in: .whitespaces) : nil
            }
        }
        guard let all = await list(""), let off = await list("-d"),
              let third = await list("-3"), let any = await list("-u") else { return false }
        packages = all.sorted()
        disabled = Set(off)
        yours = Set(third)
        removed = Set(any).subtracting(all).sorted()  // removed for this user, still restorable
        await measure()
        return true
    }

    /// Sizes as Android last measured them, about once a day.
    private func measure() async {
        // lines like  Package Names: ["a","b"]  /  App Sizes: [1,2]
        guard let stats = await query("dumpsys diskstats") else { return }
        func array(_ key: String) -> [Any] {
            guard let line = stats.split(separator: "\n").first(where: { $0.hasPrefix(key + ": ") }) else { return [] }
            return (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(key.count + 2).utf8))) as? [Any] ?? []
        }
        let names = array("Package Names") as? [String] ?? []
        let parts = ["App Sizes", "App Data Sizes", "Cache Sizes"].map { array($0) as? [Int] ?? [] }
        let totals = names.indices.map { i in (names[i], parts.reduce(0) { $0 + (i < $1.count ? $1[i] : 0) }) }
        sizes = Dictionary(totals, uniquingKeysWith: max)
    }

    // MARK: - Settings

    func setDNS(_ input: String) {
        let choice = input.trimmingCharacters(in: .whitespaces)
        dnsChoice = dnsPresets.contains { $0.0 == choice } ? choice : "Custom"
        if choice == "Custom" { return }  // waits for Apply
        act("Setting Private DNS") {
            if choice == "Off" {
                _ = await self.exec("settings put global private_dns_mode opportunistic")
                return "Private DNS is off."
            }
            guard choice.wholeMatch(of: validHost) != nil else { return "“\(choice)” isn't a valid hostname." }
            _ = await self.exec("settings put global private_dns_specifier \(choice)")
            _ = await self.exec("settings put global private_dns_mode hostname")
            guard await self.query("settings get global private_dns_specifier") == choice else {
                return "The TV didn't accept that DNS."
            }
            return "TV now uses \(choice)."
        }
    }

    func setScreensaver(_ on: Bool) {
        screensaver = on
        act("Updating screensaver") {
            _ = await self.exec("settings put secure screensaver_enabled \(on ? 1 : 0)")
            return on ? "Screensaver on." : "Screensaver off."
        }
    }

    func setAnim(_ v: String) {
        guard ["0", "0.5", "1"].contains(v) else { return }
        anim = v
        act("Setting animations") {
            for k in ["window_animation_scale", "transition_animation_scale", "animator_duration_scale"] {
                _ = await self.exec("settings put global \(k) \(v)")
            }
            return "Animation speed set."
        }
    }

    // MARK: - Apps

    func appAction(_ pkg: String, _ action: AppAction) {
        guard pkg.wholeMatch(of: validPackage) != nil else { return }
        if pkg.contains(protected), action != .stop, action != .restore {
            status = "\(pkg) is needed by the TV."
            return
        }
        switch action {
        case .stop:
            act("Stopping \(pkg)") {
                _ = await self.exec("am force-stop \(pkg)")
                return "Stopped \(pkg)."
            }
        case .clear:
            guard confirm("Clear all data for \(pkg)?", "The app goes back to fresh-install state: you'll have to sign in again.", "Clear data") else { return }
            act("Clearing \(pkg)") { "\(pkg): " + (await self.exec("pm clear \(pkg)")) }
        case .remove:
            let mine = yours.contains(pkg)  // preinstalled apps are only removed for this user
            let detail = mine ? "It's uninstalled, with its data." : "It's removed for this TV's user, with its data. You can bring it back from Removed."
            guard confirm("Remove \(pkg)?", detail, "Remove") else { return }
            act("Removing \(pkg)") {
                let out = await self.exec(mine ? "pm uninstall \(pkg)" : "pm uninstall --user 0 \(pkg)")
                await self.loadPackages()
                return out.contains("Success") ? "Removed \(pkg)." : "The TV refused: \(out)"
            }
        case .restore:
            act("Restoring \(pkg)") {
                let out = await self.exec("cmd package install-existing \(pkg)")
                await self.loadPackages()
                return out.contains("installed") ? "Restored \(pkg)." : out
            }
        case .toggle:
            let off = disabled.contains(pkg)
            act(off ? "Turning on \(pkg)" : "Turning off \(pkg)") {
                let out = await self.exec(off ? "pm enable \(pkg)" : "pm disable-user --user 0 \(pkg)")
                await self.loadPackages()
                return out
            }
        }
    }

    func removeSuggested() {
        let list = suggested.filter { !$0.contains(protected) && $0.wholeMatch(of: validPackage) != nil }
        let names = list.map { p in bloat[p].map { "\($0) (\(p))" } ?? p }.joined(separator: "\n")
        guard !list.isEmpty,
              confirm("Remove \(list.count) suggested apps?", names + "\n\nYou can bring any of them back from Removed.", "Remove all")
        else { return }
        act("Removing \(list.count) apps") {
            var done = 0
            for p in list where await self.exec("pm uninstall --user 0 \(p)").contains("Success") { done += 1 }
            await self.loadPackages()
            let kept = done < list.count ? " The TV kept the rest (built into the system)." : ""
            return "Removed \(done) of \(list.count).\(kept)"
        }
    }

    func loadBigApps() {
        act("Measuring apps") {
            await self.measure()
            self.bigApps = self.sizes.map { BigApp(id: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }.prefix(8).map { $0 }
            return self.bigApps.isEmpty ? "The TV didn't report app sizes." : "Done."
        }
    }

    func clearCaches() {
        act("Clearing app caches") {
            let before = self.storage
            _ = await self.exec("pm trim-caches 9999G", timeout: .seconds(120))  // "free up to 9999G" = everything
            await self.loadStorage()
            return "Cleared. Before: \(before). Now: \(self.storage)."
        }
    }

    // MARK: - Send

    func openLink() {
        var url = link.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        if !url.contains("://") { url = "https://" + url }
        act("Opening on the TV") {
            // Best match first: YouTube for a YouTube link, else the browser. frameworkpackagestubs = no browser.
            let intent = "-a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d \(quoted(url))"
            let apps = await self.exec("cmd package query-activities --brief \(intent)")
            let app = apps.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.contains("/") && !$0.contains("=") && !$0.contains("frameworkpackagestubs") }
            guard let app else {
                return "Nothing on the TV can open this link, and it has no web browser. Install one (e.g. TV Bro) from the Play Store."
            }
            let out = await self.exec("am start \(intent) -n \(quoted(app))")
            return out.contains("Error") ? "The TV couldn't open that link." : "Opened in \(app.split(separator: "/")[0])."
        }
    }

    func installAPK() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        act("Installing \(url.lastPathComponent)") {
            let out = await adb(self.device, "install", "-r", url.path, timeout: .seconds(600)).text
            return out.contains("Success") ? "Installed \(url.lastPathComponent)." : "Install failed: \(out.split(separator: "\n").last ?? "")"
        }
    }

    func screenshot() {
        act("Taking a screenshot") {
            let png = await adb(self.device, "exec-out", "screencap", "-p").out
            guard png.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return "Screenshot failed." }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/TV screenshot \(f.string(from: Date())).png")
            guard (try? png.write(to: url)) != nil else { return "Couldn't save the screenshot." }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return "Saved to your Desktop."
        }
    }

    func restart() {
        guard confirm("Restart the TV?", "Telekey disconnects. It reconnects by itself once the TV is back on.", "Restart") else { return }
        act("Restarting") {
            _ = await adb(self.device, "reboot")
            return "Restarting…"
        }
    }
}

@MainActor func confirm(_ message: String, _ detail: String, _ ok: String) -> Bool {
    let a = NSAlert()
    a.messageText = message
    a.informativeText = detail
    a.addButton(withTitle: ok)
    a.addButton(withTitle: "Cancel")
    return a.runModal() == .alertFirstButtonReturn
}
