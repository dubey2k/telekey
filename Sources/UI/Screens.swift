import SwiftUI

struct RootView: View {
    @ObservedObject var model: Model
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            Group {
                switch model.screen {
                case .list: ListView(model: model)
                case .pairing: PairView(model: model)
                case .connecting: ConnectingView(model: model)
                case .session: SessionView(model: model, remote: model.remote, tv: model.tv)
                }
            }
            .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.2), value: model.screen)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .focusEffectDisabled()  // the system focus ring is the Mac's accent colour (often purple), off-palette here
        .task { await model.start() }
    }
}

struct TVRow: View {
    let tv: Found, detail: String, action: () -> Void
    @State private var hover = false

    var body: some View {
        let (label, dot): (String, Color) = switch tv.state {
        case .ready: ("Connect", Theme.live)
        case .pair: ("Pair", Theme.accent)
        case .setup: ("Set up", Theme.accent)
        case .offline: ("Offline", Theme.line)
        }
        Button(action: action) {
            HStack(spacing: 12) {
                Circle().fill(dot).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tv.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(tv.state == .offline ? Theme.dim : Theme.text)
                    Text(detail).font(.mono(11)).foregroundStyle(Theme.dim)
                }
                Spacer()
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(tv.state == .offline ? Theme.dim : Theme.accent)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tv.state == .offline ? Theme.dim : Theme.accent).offset(x: hover ? 3 : 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(hover ? Theme.raised : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

struct ListView: View {
    @ObservedObject var model: Model
    @State private var ip = ""

    var body: some View {
        Page {
            Header(title: "Telekey", status: model.scanning && !model.scanned ? "looking for TVs…" : "pick a TV") {
                Button { Task { await model.refresh() } } label: {
                    Label(model.scanning ? "Scanning" : "Scan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.quiet).disabled(model.scanning)
                .help("Look for TVs now (the list also refreshes by itself)")
                Button { model.restartAdb() } label: { Label("Fix connection", systemImage: "bolt.horizontal") }
                    .buttonStyle(.quiet)
                    .help("TV is on but won't connect? Restarts the Mac's link to TVs (adb) and scans again.")
            }
            if let w = model.waitingFor {
                Notice(text: "Waiting for \(w.name). It connects by itself as soon as the TV is on.", tone: Theme.live) {
                    Button("Stop") { model.waitingFor = nil }.buttonStyle(.quiet)
                }
            }
            if !model.banner.isEmpty {
                Notice(text: model.banner) { Button { model.banner = "" } label: { Image(systemName: "xmark") }.buttonStyle(.quiet) }
            }
            if let tv = model.setupTV { setupSteps(tv) }
            if !model.mine.isEmpty {
                Eyebrow(text: "Your TVs")
                Rows(items: model.mine) { tv in
                    TVRow(tv: tv, detail: lastUsed(tv)) { model.pick(tv) }
                        .contextMenu { Button("Forget \(tv.name)") { model.forget(tv) } }
                }
            }
            Eyebrow(text: "On this network")
            if model.others.isEmpty {
                Text(model.scanned ? "No other Android TVs here. A TV shows up once it's on and on this Wi-Fi." : "Looking…")
                    .font(.system(size: 12)).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14).plate()
            } else {
                Rows(items: model.others) { tv in
                    TVRow(tv: tv, detail: tv.state == .setup ? "\(tv.ip) · needs debugging on" : tv.ip) { model.pick(tv) }
                }
            }
            Eyebrow(text: "Connect by IP")
            HStack {
                TextField("192.168.1.20", text: $ip).field().onSubmit { model.addByIP(ip) }
                Button("Connect") { model.addByIP(ip) }.buttonStyle(.flat).disabled(ip.isEmpty)
            }
        }
        .task {  // keeps the list fresh while it's on screen (and reconnects a TV that comes back)
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func lastUsed(_ tv: Found) -> String {
        guard let d = Configs.load(tv.ip)?.lastConnected else { return tv.ip }
        return "\(tv.ip) · used \(RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date()))"
    }

    func setupSteps(_ tv: Found) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Set up \(tv.name)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button("Done") { model.setupTV = nil }.buttonStyle(.quiet)
            }
            ForEach(Array([
                "On the TV: Settings → System → About. Click “Android TV OS build” 7 times.",
                "Settings → System → Developer options. Turn on USB debugging and Wireless debugging.",
                "Back here, the TV shows Connect or Pair.",
            ].enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(i + 1)").font(.mono(11, .semibold)).foregroundStyle(Theme.accent)
                    Text(step).font(.system(size: 12)).foregroundStyle(Theme.text)
                }
            }
        }
        .padding(16).plate()
    }
}

struct PairView: View {
    @ObservedObject var model: Model
    @State private var code = ""
    @State private var address = ""
    var body: some View {
        Page {
            Header(title: "Pair", status: "\(model.pairing?.name ?? "TV") · first time only") { EmptyView() }
            VStack(alignment: .leading, spacing: 14) {
                Text("On the TV: Settings → System → Developer options → Wireless debugging → **Pair device with pairing code**. Type the code it shows:")
                    .font(.system(size: 13)).foregroundStyle(Theme.text)
                TextField("000000", text: $code)
                    .font(.mono(34, .semibold)).tracking(10).multilineTextAlignment(.center)
                    .textFieldStyle(.plain).foregroundStyle(Theme.text)
                    .padding(.vertical, 14).plate(Theme.bg, radius: 8)
                    .onSubmit(submit)
                if model.askPairAddress {
                    TextField("IP address & port under the code, e.g. 192.168.1.20:41234", text: $address).field()
                }
                if !model.pairError.isEmpty {
                    Notice(text: model.pairError, tone: Theme.danger) { EmptyView() }
                }
                HStack {
                    Button("Back") { model.back("") }.buttonStyle(.quiet)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("Pair", action: submit).buttonStyle(.accent).disabled(code.count < 6 || model.busy)
                }
            }
            .padding(16).plate()
        }
    }
    func submit() { model.pair(code: code, address: address) }
}

struct ConnectingView: View {
    @ObservedObject var model: Model
    var body: some View {
        Page {
            Header(title: model.connectingTo, status: "connecting") { EmptyView() }
            VStack(spacing: 16) {
                ProgressView().controlSize(.regular)
                Text(model.progress).font(.system(size: 13)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                Button("Cancel") { model.back("") }.buttonStyle(.quiet)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 32).plate()
        }
    }
}
