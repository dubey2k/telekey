import SwiftUI

// MARK: - UI
// Design: an instrument panel. Flat graphite surfaces, hairline edges, one signal-orange accent (a standby LED),
// condensed headings, monospaced legends for anything technical (keys, IPs, sizes). No glass, no glow, no depth.

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum Theme {
    static let bg = Color(hex: 0x0E0F11)
    static let surface = Color(hex: 0x16171A)
    static let raised = Color(hex: 0x1F2124)
    static let line = Color(hex: 0x2B2E33)
    static let text = Color(hex: 0xECECEC)
    static let dim = Color(hex: 0x8A9099)
    static let accent = Color(hex: 0xFF6A2B)
    static let live = Color(hex: 0x3DDC84)
    static let danger = Color(hex: 0xFF5A52)
}

extension Font {
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .bold).width(.condensed) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

extension View {
    /// A flat panel: solid fill, hairline edge.
    func plate(_ fill: Color = Theme.surface, radius: CGFloat = 10) -> some View {
        background(RoundedRectangle(cornerRadius: radius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.line, lineWidth: 1))
    }

    func field() -> some View {
        textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text)
            .padding(.horizontal, 10).padding(.vertical, 8).plate(Theme.raised, radius: 7)
    }
}

struct Flat: ButtonStyle {
    enum Kind { case accent, plain, quiet, danger }
    var kind = Kind.plain
    func makeBody(configuration: Configuration) -> some View { FlatBody(kind: kind, c: configuration) }
}

private struct FlatBody: View {
    let kind: Flat.Kind, c: ButtonStyleConfiguration
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let fill: Color = switch kind {
        case .accent: Theme.accent
        case .plain: hover ? Theme.line : Theme.raised
        case .quiet: hover ? Theme.raised : .clear
        case .danger: hover ? Theme.danger.opacity(0.18) : Theme.raised
        }
        c.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(kind == .accent ? Color.black : kind == .danger ? Theme.danger : Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(kind == .plain || kind == .danger ? Theme.line : .clear))
            .brightness(kind == .accent && hover ? 0.06 : 0)
            .opacity(c.isPressed ? 0.7 : enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

extension ButtonStyle where Self == Flat {
    static var accent: Flat { Flat(kind: .accent) }
    static var flat: Flat { Flat() }
    static var quiet: Flat { Flat(kind: .quiet) }
    static var danger: Flat { Flat(kind: .danger) }
}

/// A shortcut legend, drawn like the printing on a hardware key.
struct Keycap: View {
    let key: String
    var body: some View {
        Text(key).font(.mono(10, .medium)).foregroundStyle(Theme.dim)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.mono(10, .semibold)).tracking(1.2).foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }
}

/// A one-line message with a coloured edge, and an optional action on the right.
struct Notice<Action: View>: View {
    let text: String
    var tone = Theme.accent
    @ViewBuilder var action: Action
    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 10)
        .plate()
        .overlay(alignment: .leading) { Rectangle().fill(tone).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct Page<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(spacing: 12) { content }
                .frame(maxWidth: 560)  // stays readable when the window is maximised
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 38)
                .padding(.bottom, 20)
        }
        .scrollIndicators(.never)
    }
}

struct Header<Trailing: View>: View {
    let title: String, status: String
    var live = false
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.display(28)).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 6) {
                    if live { Circle().fill(Theme.live).frame(width: 6, height: 6) }
                    Text(status).font(.mono(11)).foregroundStyle(Theme.dim)
                }
            }
            Spacer()
            trailing
        }
        .padding(.bottom, 6)
    }
}

/// Stacks rows inside one plate with hairlines between them.
struct Rows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                row(item)
            }
        }
        .plate()
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
