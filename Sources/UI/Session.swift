import SwiftUI

/// A section that starts open and can be folded. Folded ids are remembered across launches.
struct Fold<Content: View>: View {
    let id: String, title: String, subtitle: String
    @Binding var folded: String  // comma-separated ids
    var onOpen: () -> Void = {}
    @ViewBuilder let content: Content
    var isOpen: Bool { !folded.split(separator: ",").contains(Substring(id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    folded = isOpen ? folded + "," + id : folded.split(separator: ",").filter { $0 != id }.joined(separator: ",")
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.dim)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                Rectangle().fill(Theme.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding(14)
                    .onAppear(perform: onOpen)  // load the section's data from the TV only once it's visible
            }
        }
        .plate()
    }
}

struct TabBar: View {
    @Binding var tab: String
    @Namespace private var underline
    static let tabs = [("send", "Send"), ("apps", "Apps"), ("ads", "Ad block"), ("tv", "TV")]

    var body: some View {
        HStack(spacing: 22) {
            ForEach(Self.tabs, id: \.0) { id, title in
                Button { withAnimation(.snappy(duration: 0.22)) { tab = id } } label: {
                    VStack(spacing: 7) {
                        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(tab == id ? Theme.text : Theme.dim)
                        ZStack {
                            Color.clear.frame(height: 2)
                            if tab == id { Theme.accent.frame(height: 2).matchedGeometryEffect(id: "u", in: underline) }
                        }
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .padding(.top, 8)
    }
}

/// The surface you click to drive the TV: a dot-matrix plate whose dots light up while it has your input.
struct ControlPad: View {
    @ObservedObject var remote: Remote
    @State private var tuning = false

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let step: CGFloat = 16, color = remote.captured ? Theme.accent.opacity(0.45) : Theme.line
                for y in stride(from: step / 2, to: size.height, by: step) {
                    for x in stride(from: step / 2, to: size.width, by: step) {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(color))
                    }
                }
            }
            VStack(spacing: 8) {
                Text(remote.captured ? "CONTROLLING TV" : "CLICK TO CONTROL")
                    .font(.display(24)).tracking(1.5).foregroundStyle(remote.captured ? Theme.accent : Theme.text)
                HStack(spacing: 5) {
                    if remote.captured {
                        Text("press"); Keycap(key: "⌘"); Text("alone to get your mouse back")
                    } else {
                        Text("trackpad and keyboard go to the TV ·"); Keycap(key: "esc"); Text("back")
                    }
                }
                .font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Theme.surface)  // a clean patch so the words sit above the dots
        }
        .frame(maxWidth: .infinity).frame(height: 200)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(remote.captured ? Theme.accent : Theme.line, lineWidth: remote.captured ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { remote.capture() }
        .overlay(alignment: .topTrailing) {
            if !remote.captured {
                Button { tuning.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.quiet).padding(8)
                    .help("Pointer and scroll speed for this TV")
                    .popover(isPresented: $tuning, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow(text: "Pointer · this TV")
                            SliderRow(title: "Trackpad", value: $remote.speed, range: 0.5...4)
                            SliderRow(title: "Scroll", value: $remote.scrollSpeed, range: 0.1...2)
                        }
                        .padding(16).frame(width: 300).tint(Theme.accent)
                    }
            }
        }
        .animation(.easeOut(duration: 0.18), value: remote.captured)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12)).frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: "%.1f×", value)).font(.mono(11)).foregroundStyle(Theme.dim).frame(width: 36, alignment: .trailing)
        }
    }
}

struct StripKey: View {
    let icon: String, help: String, key: String, action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                Keycap(key: key)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(hover ? Theme.raised : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

/// The remote's buttons as one strip, each with its shortcut printed under it.
struct RemoteStrip: View {
    let remote: Remote, tv: TV
    var body: some View {
        let keys: [(String, String, String, () -> Void)] = [
            ("arrow.uturn.backward", "Back (also Esc or two-finger click while controlling)", "⌘B", { remote.key(kBack) }),
            ("house", "Home", "⌘H", { remote.key(kHome) }),
            ("playpause", "Play / pause", "⌘P", { remote.key(kPlayPause) }),
            ("speaker.minus", "Volume down", "⌘↓", { remote.key(kVolDown) }),
            ("speaker.plus", "Volume up", "⌘↑", { remote.key(kVolUp) }),
            ("speaker.slash", "Mute", "⌘M", { remote.key(kMute) }),
            ("gearshape", "TV settings", "⌘,", { remote.key(kSettings) }),
            ("camera", "Screenshot to your Desktop", "⌘S", { tv.screenshot() }),
        ]
        HStack(spacing: 0) {
            ForEach(0..<keys.count, id: \.self) { i in
                if i > 0 { Theme.line.frame(width: 1) }
                StripKey(icon: keys[i].0, help: keys[i].1, key: keys[i].2, action: keys[i].3)
            }
        }
        .frame(height: 64)
        .plate()
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct AppRow: View {
    let p: String
    @ObservedObject var tv: TV
    var body: some View {
        let off = tv.disabled.contains(p), gone = !tv.packages.contains(p)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p).font(.mono(11.5)).foregroundStyle(off || gone ? Theme.dim : Theme.text)
                    .strikethrough(off || gone).lineLimit(1).truncationMode(.middle)
                if let what = bloat[p] { Text(what).font(.system(size: 11)).foregroundStyle(Theme.dim) }
            }
            Spacer(minLength: 8)
            if off { Keycap(key: "off") }
            if let b = tv.sizes[p], !gone {
                Text(ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)).font(.mono(11)).foregroundStyle(Theme.dim)
            }
            if gone {
                Button("Restore") { tv.appAction(p, "restore") }.buttonStyle(.flat)
            } else {
                Menu {
                    Button("Force stop") { tv.appAction(p, "stop") }
                    if p.contains(protected) {
                        Text("Needed by the TV: can't be turned off or removed")
                    } else {
                        Button("Clear data…") { tv.appAction(p, "clear") }
                        Button(off ? "Turn on" : "Turn off") { tv.appAction(p, "toggle") }
                        Button("Remove…", role: .destructive) { tv.appAction(p, "uninstall") }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

struct SessionView: View {
    @ObservedObject var model: Model
    @ObservedObject var remote: Remote
    @ObservedObject var tv: TV
    @AppStorage("tab") private var tab = "send"
    @AppStorage("folded") private var folded = ""
    func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> { Binding(get: get, set: set) }

    var body: some View {
        Page {
            Header(title: model.tvName, status: "connected · \(serial.split(separator: ":").first ?? "")", live: true) {
                Button("Disconnect") { model.back("") }.buttonStyle(.flat)
            }
            ControlPad(remote: remote)
            RemoteStrip(remote: remote, tv: tv)
            TabBar(tab: $tab)
                .onAppear { if !TabBar.tabs.contains(where: { $0.0 == tab }) { tab = "send" } }  // tab names from older versions
            switch tab {
            case "apps": apps
            case "ads": VStack(spacing: 12) { dns; screensaver }
            case "tv": VStack(spacing: 12) { storage; animations; about }
            default: VStack(spacing: 12) { link; install }
            }
        }
        .overlay(alignment: .bottom) {
            if !tv.status.isEmpty {
                Text(tv.status).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2)
                    .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 9)
                    .plate(Theme.raised, radius: 8)
                    .overlay(alignment: .leading) { Theme.accent.frame(width: 3) }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: tv.status)
    }

    var link: some View {
        Fold(id: "send", title: "Open a link", subtitle: "in the app that fits it", folded: $folded) {
            HStack {
                TextField("youtube.com/watch?v=…  or any website", text: $tv.link).field().onSubmit { tv.openLink() }
                Button("Open") { tv.openLink() }.buttonStyle(.accent).disabled(tv.link.isEmpty)
            }
            Text("YouTube links open in YouTube. Anything else opens in the TV's browser.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
    }

    var install: some View {
        Fold(id: "install", title: "Install an app", subtitle: "from an .apk file", folded: $folded) {
            Button("Choose APK…") { tv.installAPK() }.buttonStyle(.flat)
        }
    }

    var apps: some View {
        Fold(id: "apps", title: "Apps", subtitle: tv.packages.isEmpty ? "every app on the TV" : "\(tv.shownPackages.count) shown", folded: $folded, onOpen: { tv.load("apps") }) {
            Picker("", selection: $tv.filter) {
                ForEach(["Bloat", "Yours", "System", "Off", "Removed", "All"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().disabled(!tv.search.isEmpty)
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.dim)
                    TextField("Search all apps", text: $tv.search).textFieldStyle(.plain).font(.system(size: 13))
                }
                .padding(.horizontal, 10).padding(.vertical, 8).plate(Theme.raised, radius: 7)
                if tv.filter == "Bloat" && tv.search.isEmpty {
                    Button("Remove all…") { tv.removeSuggested() }.buttonStyle(.danger).disabled(tv.suggested.isEmpty)
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tv.shownPackages, id: \.self) { AppRow(p: $0, tv: tv) }
                }
            }
            .frame(height: 320)
        }
    }

    var dns: some View {
        Fold(id: "ads", title: "Private DNS", subtitle: "blocks ad servers for the whole TV", folded: $folded, onOpen: { tv.load("ads") }) {
            Picker("", selection: bind({ tv.dnsChoice }, tv.setDNS)) {
                ForEach(dnsPresets, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.radioGroup).labelsHidden()
            if tv.dnsChoice == "Custom" {
                HStack {
                    TextField("Hostname, e.g. abc123.dns.nextdns.io", text: $tv.customDNS).field()
                    Button("Apply") { tv.setDNS(tv.customDNS) }.buttonStyle(.flat)
                }
            }
            Text("Blocks most ads in apps and on the home screen, not YouTube's. Stays on after you disconnect.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
    }

    var screensaver: some View {
        Fold(id: "screensaver", title: "Ambient mode", subtitle: "the screensaver, which often shows ads", folded: $folded, onOpen: { tv.load("ads") }) {
            Toggle("Show ambient mode when the TV is idle", isOn: bind({ tv.screensaver }, tv.setScreensaver)).toggleStyle(.switch)
        }
    }

    var storage: some View {
        Fold(id: "storage", title: "Storage", subtitle: tv.storage, folded: $folded, onOpen: { tv.load("storage") }) {
            HStack {
                Button("Clear caches") { tv.clearCaches() }.buttonStyle(.flat)
                Button("Show biggest apps") { tv.loadBigApps() }.buttonStyle(.flat)
            }
            ForEach(tv.bigApps) { a in
                HStack {
                    Text(a.id).font(.mono(11.5)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(a.bytes), countStyle: .file)).font(.mono(11)).foregroundStyle(Theme.dim)
                }
            }
        }
    }

    var animations: some View {
        Fold(id: "speed", title: "Animations", subtitle: "faster menus", folded: $folded, onOpen: { tv.load("speed") }) {
            Picker("", selection: bind({ tv.anim }, tv.setAnim)) {
                Text("Off").tag("0"); Text("Fast").tag("0.5"); Text("Normal").tag("1")
            }
            .pickerStyle(.segmented).labelsHidden()
        }
    }

    var about: some View {
        Fold(id: "tv", title: "About & power", subtitle: "", folded: $folded, onOpen: { tv.load("tv") }) {
            Text(tv.info).font(.mono(11)).foregroundStyle(Theme.dim).textSelection(.enabled)
            HStack {
                Button("Sleep") { remote.key(kSleep) }.buttonStyle(.flat)
                Button("Restart…") { tv.restart() }.buttonStyle(.danger)
            }
        }
    }
}
