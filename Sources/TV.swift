import AppKit
import UniformTypeIdentifiers

let dnsPresets = [("Off", "Off (TV default)"), ("dns.adguard-dns.com", "AdGuard (blocks ads)"),
                  ("adblock.dns.mullvad.net", "Mullvad (blocks ads)"), ("Custom", "Custom…")]
// ponytail: name-based heuristics; a curated per-brand package list if these misfire.
// Protected = turning it off could leave the TV without settings/home/keyboard, or kill adb.
let protected = try! Regex(#"^android$|systemui|settings|launcher|packageinstaller|permissioncontroller|inputmethod|keyboard|gms|gsf|setupwizard|provision|bluetooth|wifi|networkstack|tethering|com\.android\.shell|webview|framework|providers|tv\.tuner|media\.tv|^com\.tcl\.(tv|tvinput|systemserver|globalkeyoverlay|initsetup|providers\.config)$|^com\.tvos$|remote\.service|vending|ext\.services|setupwraith|mediashell|katniss|tvlauncher|intentresolver|overlay|rro_"#)
/// Preinstalled extras that are safe to remove (they can be restored from the Removed list).
let bloat = [
    "com.tcl.esticker": "Store demo stickers", "com.tcl.exhibit": "Store demo mode",
    "com.tcl.waterfall.overseas": "TCL recommendations feed", "com.tcl.channelplus": "TCL Channel (free channels with ads)",
    "com.tcl.messagebox": "TCL promo messages", "com.tcl.usercenter": "TCL account", "com.tcl.logkit": "TCL log collection",
    "com.tcl.ocean.instructions": "Built-in manual", "com.tcl.repairguide": "Repair guide", "com.tcl.smartalexa": "Alexa link",
    "com.tcl.hotelmenu": "Hotel mode", "com.google.android.feedback": "Google feedback reporter",
    "com.android.tv.feedbackconsent": "Feedback consent", "com.google.android.play.games": "Play Games",
    "com.android.adservices.api": "Android ad services", "com.android.ondevicepersonalization.services": "Ad personalisation",
    "com.android.federatedcompute.services": "Usage learning for ads", "tv.mopa.ginga": "Brazil interactive TV",
]
let likelyAds = try! Regex(#"(^|\.)(ads?|advert\w*|analytic\w*|track\w*|acr\w*|samba\w*|promo\w*|recommend\w*|feedback\w*|log\w*)(\.|$)"#)

// MARK: - TV: settings and tools over adb

struct BigApp: Identifiable { let id: String; let bytes: Int }

@MainActor final class TV: ObservableObject {
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
    @Published var search = ""
    @Published var filter = "Bloat"
    @Published var yours: Set<String> = []
    @Published var removed: [String] = []
    @Published var sizes: [String: Int] = [:]  // package → app + data + cache bytes
    private var loaded: Set<String> = []  // each section loads its data the first time it's opened
    private let ip = String(serial.split(separator: ":").first ?? "")

    /// Records the TV's current settings in its config file.
    private func note(_ change: (inout TVConfig) -> Void) { Configs.edit(ip, change) }
    private var statusTask: Task<Void, Never>?

    var suggested: [String] { packages.filter { !yours.contains($0) && (bloat[$0] != nil || $0.contains(likelyAds)) } }

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
    func act(_ label: String, _ work: @escaping () async -> String) {
        status = label + "…"
        statusTask?.cancel()
        Task {
            let result = await work()
            status = result
            statusTask = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { status = "" } }
        }
    }

    func load(_ section: String) {
        guard loaded.insert(section).inserted else { return }
        Task {
            switch section {
            case "ads":
                let mode = await sh("settings get global private_dns_mode"), host = await sh("settings get global private_dns_specifier")
                if mode != "hostname" { dnsChoice = "Off" }
                else if dnsPresets.contains(where: { $0.0 == host }) { dnsChoice = host }
                else { dnsChoice = "Custom"; customDNS = host }
                screensaver = await sh("settings get secure screensaver_enabled") != "0"  // "null" = never set = on
                note { [screensaver] in $0.privateDNS = mode == "hostname" ? host : "off"; $0.screensaver = screensaver }
            case "apps": await loadPackages()
            case "speed":
                let a = await sh("settings get global window_animation_scale")
                anim = a == "0" || a == "0.0" ? "0" : a == "0.5" ? "0.5" : "1"
                note { [anim] in $0.animations = anim }
            case "storage": await loadStorage()
            case "tv":
                let make = await sh("getprop ro.product.manufacturer"), model = await sh("getprop ro.product.model")
                info = "\(make) \(model) · Android \(await sh("getprop ro.build.version.release")) · \(serial.split(separator: ":")[0])"
            default: break
            }
        }
    }

    func loadStorage() async {
        let cols = (await sh("df -h /data")).split(separator: "\n").last?.split(separator: " ") ?? []
        storage = cols.count >= 4 ? "\(cols[3]) free of \(cols[1])" : "unknown"
    }

    func loadPackages() async {
        func list(_ flag: String) async -> [String] {
            (await sh("pm list packages \(flag)")).split(separator: "\n").compactMap { $0.hasPrefix("package:") ? String($0.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        }
        packages = await list("").sorted()
        disabled = Set(await list("-d"))
        yours = Set(await list("-3"))
        let installed = Set(packages)
        removed = await list("-u").filter { !installed.contains($0) }.sorted()  // removed for this user, still restorable
        note { [disabled, removed] in $0.turnedOffApps = disabled.sorted(); $0.removedApps = removed }
        await measure()
    }

    /// App sizes as Android last measured them (it refreshes them about once a day).
    func measure() async {
        // diskstats has lines like: Package Names: ["a","b"] / App Sizes: [1,2] / App Data Sizes: … / Cache Sizes: …
        let stats = await sh("dumpsys diskstats")
        func array(_ key: String) -> [Any] {
            guard let line = stats.split(separator: "\n").first(where: { $0.hasPrefix(key + ": ") }) else { return [] }
            return (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(key.count + 2).utf8))) as? [Any] ?? []
        }
        let names = array("Package Names") as? [String] ?? []
        let parts = ["App Sizes", "App Data Sizes", "Cache Sizes"].map { array($0) as? [Int] ?? [] }
        sizes = Dictionary(names.indices.map { i in (names[i], parts.reduce(0) { $0 + (i < $1.count ? $1[i] : 0) }) }, uniquingKeysWith: max)
    }

    func loadBigApps() {
        act("Measuring apps") {
            await self.measure()
            self.bigApps = self.sizes.map { BigApp(id: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }.prefix(8).map { $0 }
            return self.bigApps.isEmpty ? "The TV didn't report app sizes." : "Done."
        }
    }

    func setDNS(_ input: String) {
        let choice = input.trimmingCharacters(in: .whitespaces)
        let preset = dnsPresets.contains { $0.0 == choice }
        dnsChoice = preset ? choice : "Custom"
        if choice == "Custom" { return }  // applied by the Apply button
        act("Setting Private DNS") {
            if choice == "Off" {
                _ = await sh("settings put global private_dns_mode opportunistic")
                self.note { $0.privateDNS = "off" }
                return "Private DNS is off."
            }
            guard choice.wholeMatch(of: validHost) != nil else { return "“\(choice)” isn't a valid hostname." }
            _ = await sh("settings put global private_dns_specifier \(choice)")
            _ = await sh("settings put global private_dns_mode hostname")
            guard await sh("settings get global private_dns_specifier") == choice else { return "The TV didn't accept that DNS." }
            self.note { $0.privateDNS = choice }
            return "TV now uses \(choice)."
        }
    }

    func setScreensaver(_ on: Bool) {
        screensaver = on
        act("Updating screensaver") {
            _ = await sh("settings put secure screensaver_enabled \(on ? 1 : 0)")
            self.note { $0.screensaver = on }
            return on ? "Screensaver on." : "Screensaver off."
        }
    }

    func setAnim(_ v: String) {
        anim = v
        act("Setting animations") {
            for k in ["window_animation_scale", "transition_animation_scale", "animator_duration_scale"] {
                _ = await sh("settings put global \(k) \(v)")
            }
            self.note { $0.animations = v }
            return "Animation speed set."
        }
    }

    func clearCaches() {
        act("Clearing app caches") {
            let before = self.storage
            _ = text(await run(["adb", "-s", serial, "shell", "pm trim-caches 9999G"], timeout: 120))
            await self.loadStorage()
            return "Cleared. Before: \(before). Now: \(self.storage)."
        }
    }

    func appAction(_ pkg: String, _ what: String) {
        guard pkg.wholeMatch(of: validPackage) != nil else { return }
        if pkg.contains(protected), what != "stop", what != "restore" { status = "\(pkg) is needed by the TV."; return }
        switch what {
        case "stop":
            act("Stopping \(pkg)") { _ = await sh("am force-stop \(pkg)"); return "Stopped \(pkg)." }
        case "clear":
            guard confirm("Clear all data for \(pkg)?", "The app goes back to fresh-install state: you'll have to sign in again.", "Clear data") else { return }
            act("Clearing \(pkg)") { "\(pkg): " + (await sh("pm clear \(pkg)")) }
        case "uninstall":
            let mine = yours.contains(pkg)
            guard confirm("Remove \(pkg)?", mine ? "It's uninstalled, with its data." : "It's removed for this TV's user, with its data. You can bring it back from Removed.", "Remove") else { return }
            act("Removing \(pkg)") {
                let out = await sh(mine ? "pm uninstall \(pkg)" : "pm uninstall --user 0 \(pkg)")
                await self.loadPackages()
                return out.contains("Success") ? "Removed \(pkg)." : "The TV refused: \(out)"
            }
        case "restore":
            act("Restoring \(pkg)") {
                let out = await sh("cmd package install-existing \(pkg)")
                await self.loadPackages()
                return out.contains("installed") ? "Restored \(pkg)." : out
            }
        default:  // toggle
            let off = disabled.contains(pkg)
            act(off ? "Turning on \(pkg)" : "Turning off \(pkg)") {
                let out = off ? await sh("pm enable \(pkg)") : await sh("pm disable-user --user 0 \(pkg)")
                await self.loadPackages()
                return out
            }
        }
    }

    func removeSuggested() {
        let list = suggested.filter { !$0.contains(protected) && $0.wholeMatch(of: validPackage) != nil }
        guard !list.isEmpty, confirm("Remove \(list.count) suggested apps?", list.map { p in bloat[p].map { "\($0) (\(p))" } ?? p }.joined(separator: "\n") + "\n\nYou can bring any of them back from Removed.", "Remove all") else { return }
        act("Removing \(list.count) apps") {
            var done = 0
            for p in list where await sh("pm uninstall --user 0 \(p)").contains("Success") { done += 1 }
            await self.loadPackages()
            return "Removed \(done) of \(list.count)." + (done < list.count ? " The TV kept the rest (built into the system)." : "")
        }
    }

    func openLink() {
        var url = link.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        if !url.contains("://") { url = "https://" + url }
        act("Opening on the TV") {
            // the TV lists the apps for a link best match first: YouTube for a YouTube link, else the browser.
            // frameworkpackagestubs is Android's "no browser installed" placeholder.
            let apps = await sh("cmd package query-activities --brief -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d \(quoted(url))")
            guard let app = apps.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.contains("/") && !$0.contains("=") && !$0.contains("frameworkpackagestubs") }) else {
                return "Nothing on the TV can open this link, and it has no web browser. Install one (e.g. TV Bro) from the Play Store."
            }
            let out = await sh("am start -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d \(quoted(url)) -n \(quoted(app))")
            return out.contains("Error") ? "The TV couldn't open that link." : "Opened in \(app.split(separator: "/")[0])."
        }
    }

    func installAPK() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        guard p.runModal() == .OK, let url = p.url else { return }
        act("Installing \(url.lastPathComponent)") {
            let out = text(await run(["adb", "-s", serial, "install", "-r", url.path], timeout: 600))  // big APKs take minutes
            return out.contains("Success") ? "Installed \(url.lastPathComponent)." : "Install failed: \(out.split(separator: "\n").last ?? "")"
        }
    }

    func screenshot() {
        act("Taking a screenshot") {
            let png = await run(["adb", "-s", serial, "exec-out", "screencap", "-p"])
            guard png.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return "Screenshot failed." }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/TV screenshot \(f.string(from: Date())).png")
            guard (try? png.write(to: url)) != nil else { return "Couldn't save the screenshot." }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return "Saved to your Desktop."
        }
    }

    func restart() {
        guard confirm("Restart the TV?", "Telekey disconnects. Reconnect once the TV is back on.", "Restart") else { return }
        act("Restarting") { _ = await adb("reboot"); return "Restarting…" }
    }
}
