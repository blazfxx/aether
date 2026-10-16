import SwiftUI
import AppKit
import AetherCore

// MARK: - Modules

enum Module: String, CaseIterable, Identifiable {
    case smartScan, health, junk, privacy, largeFiles, duplicates, spaceLens, apps, startup, maintenance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartScan: "Smart Scan"
        case .health: "Mac Health"
        case .junk: "System Junk"
        case .privacy: "Privacy"
        case .largeFiles: "Large & Old Files"
        case .duplicates: "Duplicates"
        case .spaceLens: "Space Lens"
        case .apps: "Uninstaller"
        case .startup: "Startup Items"
        case .maintenance: "Maintenance"
        }
    }

    var symbol: String {
        switch self {
        case .smartScan: "sparkles"
        case .health: "heart.text.square"
        case .junk: "trash.slash"
        case .privacy: "hand.raised"
        case .largeFiles: "doc.zipper"
        case .duplicates: "square.on.square"
        case .spaceLens: "chart.pie"
        case .apps: "app.dashed"
        case .startup: "power"
        case .maintenance: "wrench.and.screwdriver"
        }
    }

    /// Main accent. Also the body colour of the glossy orb.
    var tint: Color {
        switch self {
        case .smartScan: Color(red: 0.62, green: 0.30, blue: 0.95)
        case .health: Color(red: 0.12, green: 0.72, blue: 0.52)
        case .junk: Color(red: 0.95, green: 0.35, blue: 0.40)
        case .privacy: Color(red: 0.10, green: 0.62, blue: 0.85)
        case .largeFiles: Color(red: 0.28, green: 0.50, blue: 0.98)
        case .duplicates: Color(red: 0.14, green: 0.72, blue: 0.62)
        case .spaceLens: Color(red: 0.22, green: 0.48, blue: 0.98)
        case .apps: Color(red: 0.92, green: 0.32, blue: 0.48)
        case .startup: Color(red: 0.97, green: 0.60, blue: 0.14)
        case .maintenance: Color(red: 0.42, green: 0.55, blue: 0.78)
        }
    }

    /// Lighter companion used for highlights and glows.
    var tint2: Color {
        switch self {
        case .smartScan: Color(red: 0.95, green: 0.45, blue: 0.95)
        case .health: Color(red: 0.55, green: 0.92, blue: 0.55)
        case .junk: Color(red: 1.00, green: 0.62, blue: 0.40)
        case .privacy: Color(red: 0.35, green: 0.90, blue: 0.85)
        case .largeFiles: Color(red: 0.50, green: 0.72, blue: 1.00)
        case .duplicates: Color(red: 0.50, green: 0.95, blue: 0.62)
        case .spaceLens: Color(red: 0.40, green: 0.85, blue: 1.00)
        case .apps: Color(red: 1.00, green: 0.58, blue: 0.40)
        case .startup: Color(red: 1.00, green: 0.82, blue: 0.30)
        case .maintenance: Color(red: 0.65, green: 0.80, blue: 0.95)
        }
    }

    /// Window backdrop: dark corner, mid tone, lit corner.
    var backdrop: [Color] {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        switch self {
        case .smartScan: return [c(0.04, 0.03, 0.26), c(0.30, 0.08, 0.50), c(0.52, 0.12, 0.62)]
        case .health: return [c(0.02, 0.10, 0.16), c(0.03, 0.30, 0.34), c(0.05, 0.50, 0.42)]
        case .junk: return [c(0.18, 0.03, 0.20), c(0.50, 0.09, 0.30), c(0.82, 0.28, 0.32)]
        case .privacy: return [c(0.02, 0.07, 0.24), c(0.03, 0.28, 0.48), c(0.05, 0.50, 0.62)]
        case .largeFiles: return [c(0.03, 0.05, 0.26), c(0.08, 0.20, 0.58), c(0.18, 0.40, 0.86)]
        case .duplicates: return [c(0.02, 0.12, 0.18), c(0.04, 0.32, 0.38), c(0.08, 0.55, 0.50)]
        case .spaceLens: return [c(0.02, 0.04, 0.22), c(0.05, 0.18, 0.55), c(0.10, 0.42, 0.85)]
        case .apps: return [c(0.20, 0.03, 0.14), c(0.52, 0.08, 0.26), c(0.86, 0.30, 0.32)]
        case .startup: return [c(0.20, 0.07, 0.04), c(0.55, 0.22, 0.08), c(0.92, 0.52, 0.14)]
        case .maintenance: return [c(0.05, 0.07, 0.17), c(0.16, 0.22, 0.42), c(0.30, 0.42, 0.64)]
        }
    }

    static let sections: [(name: String, modules: [Module])] = [
        ("Overview", [.smartScan, .health]),
        ("Cleanup", [.junk, .privacy, .largeFiles, .duplicates]),
        ("Storage", [.spaceLens]),
        ("Apps & Speed", [.apps, .startup, .maintenance]),
    ]
}

// MARK: - Backdrop

/// Full-window gradient with two slow, soft light blooms. Drawn with radial gradients (no blur) so it stays cheap.
struct AuroraBackground: View {
    let module: Module

    var body: some View {
        ZStack {
            LinearGradient(colors: module.backdrop, startPoint: .topLeading, endPoint: .bottomTrailing)
            TimelineView(.animation(minimumInterval: 1.0 / 24)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                Canvas { g, size in
                    func bloom(_ x: Double, _ y: Double, _ r: Double, _ color: Color) {
                        let center = CGPoint(x: size.width * x, y: size.height * y)
                        let radius = max(size.width, size.height) * r
                        g.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                               with: .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: center, startRadius: 0, endRadius: radius))
                    }
                    bloom(0.30 + 0.07 * sin(t / 7), 0.28 + 0.06 * cos(t / 9), 0.55, module.tint2.opacity(0.20))
                    bloom(0.80 + 0.06 * cos(t / 8), 0.78 + 0.06 * sin(t / 6), 0.60, module.tint.opacity(0.28))
                }
            }
            // Gentle vignette keeps text readable near the edges.
            RadialGradient(colors: [.clear, .black.opacity(0.28)], center: .center, startRadius: 300, endRadius: 900)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Orb

/// Glossy glass sphere with the module symbol inside. Stands in for CleanMyMac-style hero art.
struct GradientBadge: View {
    let module: Module
    var size: CGFloat = 120

    var body: some View {
        ZStack {
            Circle().fill(module.tint2.opacity(0.55))
                .blur(radius: size * 0.2).scaleEffect(0.92).offset(y: size * 0.10)
            Circle().fill(RadialGradient(colors: [module.tint2, module.tint, module.tint.opacity(0.6).mix(with: .black, by: 0.5)],
                                         center: UnitPoint(x: 0.34, y: 0.24), startRadius: 0, endRadius: size * 0.8))
            // Lit rim, brighter at the top.
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.05), .white.opacity(0.30)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: max(0.8, size * 0.012))
            // Specular highlight.
            Ellipse().fill(LinearGradient(colors: [.white.opacity(0.62), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.64, height: size * 0.38).offset(y: -size * 0.29)
            // Soft bounce light at the bottom.
            Ellipse().fill(RadialGradient(colors: [module.tint2.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: size * 0.3))
                .frame(width: size * 0.6, height: size * 0.22).offset(y: size * 0.36)
            Image(systemName: module.symbol)
                .font(.system(size: size * 0.40, weight: .regular))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.28), radius: size * 0.04, y: size * 0.025)
        }
        .frame(width: size, height: size)
    }
}

extension Color {
    /// Blend towards another colour in sRGB.
    func mix(with other: Color, by amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        let t = CGFloat(amount)
        return Color(red: a.redComponent * (1 - t) + b.redComponent * t,
                     green: a.greenComponent * (1 - t) + b.greenComponent * t,
                     blue: a.blueComponent * (1 - t) + b.blueComponent * t)
    }
}

/// Orb that gently floats, with faint rings that breathe behind it.
struct HeroOrb: View {
    let module: Module
    var size: CGFloat = 190

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .strokeBorder(.white.opacity(0.07 - Double(i) * 0.015), lineWidth: 1)
                        .frame(width: size * (1.28 + Double(i) * 0.26 + 0.03 * sin(t * 0.9 + Double(i))),
                               height: size * (1.28 + Double(i) * 0.26 + 0.03 * sin(t * 0.9 + Double(i))))
                }
                GradientBadge(module: module, size: size)
                    .offset(y: 7 * sin(t * 1.1))
            }
        }
        .frame(width: size * 1.9, height: size * 1.5)
    }
}

/// Orb with a rotating arc, shown while work is running.
struct SpinnerBadge: View {
    let module: Module
    var size: CGFloat = 150

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = t.truncatingRemainder(dividingBy: 1.3) / 1.3 * 360
            ZStack {
                Circle().strokeBorder(.white.opacity(0.10), lineWidth: 3).frame(width: size + 34, height: size + 34)
                Circle().trim(from: 0, to: 0.22)
                    .stroke(LinearGradient(colors: [.white.opacity(0), .white], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .frame(width: size + 34, height: size + 34)
                    .rotationEffect(.degrees(angle))
                GradientBadge(module: module, size: size)
                    .scaleEffect(1 + 0.015 * sin(t * 2.2))
            }
        }
        .frame(width: size + 50, height: size + 50)
    }
}

// MARK: - Buttons

/// Glass capsule: reads on any backdrop colour.
struct PrimaryButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(LinearGradient(colors: [.white.opacity(configuration.isPressed ? 0.36 : 0.30), .white.opacity(0.14)],
                                              startPoint: .top, endPoint: .bottom))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 1))
            .shadow(color: tint.opacity(0.5), radius: configuration.isPressed ? 4 : 12, y: 3)
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.22 : 0.12)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }
}

/// The big round "Scan" button with a breathing halo.
struct RoundActionButton: View {
    let title: String
    let module: Module
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(
                    Circle().fill(LinearGradient(colors: [module.tint2, module.tint], startPoint: .top, endPoint: .bottom))
                )
                .overlay(Circle().strokeBorder(.white.opacity(hover ? 0.9 : 0.6), lineWidth: 2))
                .overlay(
                    Ellipse().fill(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
                        .frame(width: 66, height: 34).offset(y: -26)
                )
                .scaleEffect(hover ? 1.04 : 1)
                .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain)
        .background(
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                Circle().fill(module.tint2.opacity(0.55))
                    .frame(width: 96, height: 96)
                    .scaleEffect(1.25 + 0.12 * sin(t * 1.8))
                    .blur(radius: 26)
            }
        )
        .onHover { hover = $0 }
        .keyboardShortcut(.defaultAction)
    }
}

// MARK: - Surfaces

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(radius: 16)
    }
}

extension View {
    /// Translucent white panel with a hairline border.
    func glass(radius: CGFloat = 16, fill: Double = 0.08) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.white.opacity(fill)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.13), lineWidth: 1))
    }

    /// Lists and scroll areas sitting on the aurora: transparent rows inside a soft panel.
    func glassPanel(radius: CGFloat = 16) -> some View {
        scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.black.opacity(0.14)))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

enum CheckState { case off, mixed, on }

struct CheckBox: View {
    let state: CheckState
    var tint: Color = .accentColor
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(state == .off ? AnyShapeStyle(.white.opacity(0.06)) : AnyShapeStyle(.white))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(state == .off ? 0.45 : 0), lineWidth: 1.2)
                if state != .off {
                    Image(systemName: state == .on ? "checkmark" : "minus")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(tint.mix(with: .black, by: 0.25))
                }
            }
            .frame(width: 19, height: 19)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct FileIcon: View {
    let url: URL
    var size: CGFloat = 28
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable().interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct RingGauge: View {
    let value: Double
    var tint: Color
    var lineWidth: CGFloat = 10
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.5), radius: 5)
                .animation(.easeOut(duration: 0.4), value: value)
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var tint: Color
    var maxValue: Double? = 1

    var body: some View {
        GeometryReader { geo in
            let top = maxValue ?? max(values.max() ?? 1, 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: values.count > 1 ? geo.size.width * CGFloat(i) / CGFloat(values.count - 1) : 0,
                        y: geo.size.height * (1 - CGFloat(min(v / top, 1))))
            }
            ZStack {
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: CGPoint(x: f.x, y: geo.size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [tint.opacity(0.40), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            }
        }
    }
}

// MARK: - Page scaffolding

extension Font {
    /// Thin display type used for titles, like the CleanMyMac look.
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .light) }
}

struct PageHeader: View {
    let module: Module
    let title: String
    var subtitle: String?
    var body: some View {
        HStack(spacing: 14) {
            GradientBadge(module: module, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.display(28))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.65)) }
            }
            Spacer()
        }
        .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 14)
    }
}

struct Hero: View {
    let module: Module
    let headline: String
    let detail: String
    let button: String
    var note: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            HeroOrb(module: module)
            VStack(spacing: 10) {
                Text(headline).font(.display(42))
                Text(detail).font(.system(size: 16, weight: .light)).foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            .padding(.top, -10)
            Spacer(minLength: 20)
            if button.count <= 6 {
                RoundActionButton(title: button, module: module, action: action)
            } else {
                Button(button, action: action)
                    .buttonStyle(PrimaryButtonStyle(tint: module.tint)).keyboardShortcut(.defaultAction)
                    .padding(.vertical, 28)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                    .frame(maxWidth: 460).padding(.top, 18)
            }
            Spacer().frame(height: 34)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Remembers when a scan's counter last moved, to tell "slow" from "waiting on you".
final class StallTracker {
    private var files = -1
    private var since = Date()
    func stalledFor(_ current: Int) -> TimeInterval {
        if current != files { files = current; since = Date() }
        return Date().timeIntervalSince(since)
    }
}

struct ScanningView: View {
    let module: Module
    let title: String
    var progress: ScanProgress?
    var label: String = ""
    var cancel: (() -> Void)?
    @State private var tracker = StallTracker()

    var body: some View {
        VStack(spacing: 24) {
            SpinnerBadge(module: module)
            Text(title).font(.display(32))
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let s = progress?.snapshot
                let stalled = s.map { tracker.stalledFor($0.files) } ?? 0
                VStack(spacing: 4) {
                    if let s, s.files > 0 {
                        Text("\(s.files.formatted()) items checked" + (s.bytes > 0 ? " · \(Bytes.string(s.bytes))" : "")).monospacedDigit()
                    } else if !label.isEmpty {
                        Text(label)
                    }
                    Text(s?.current ?? "")
                        .font(.caption).foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 420)
                    if progress != nil, stalled > 4 {
                        Text("Nothing has moved for \(Int(stalled)) seconds. If macOS asked to let Aether access a folder, choose Allow. Granting Full Disk Access in System Settings stops those prompts for good.")
                            .font(.caption).foregroundStyle(.yellow.opacity(0.9))
                            .multilineTextAlignment(.center).frame(maxWidth: 440).padding(.top, 8)
                    }
                }
                .font(.callout).foregroundStyle(.white.opacity(0.7))
                .frame(minHeight: 38)
            }
            if let cancel { Button("Stop", action: cancel).buttonStyle(SoftButtonStyle()) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DoneView: View {
    let module: Module
    let headline: String
    var detail: String?
    var failures: [String] = []
    let again: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                HeroOrb(module: module, size: 150)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40)).foregroundStyle(.white, .green)
                    .background(Circle().fill(.white).padding(5))
                    .offset(x: 56, y: 50)
            }
            Text(headline).font(.display(36)).multilineTextAlignment(.center)
            if let detail { Text(detail).font(.system(size: 16, weight: .light)).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center).frame(maxWidth: 460) }
            if !failures.isEmpty {
                DisclosureGroup("\(failures.count) item\(failures.count == 1 ? "" : "s") could not be removed") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(failures.prefix(50), id: \.self) { Text($0).font(.caption).foregroundStyle(.white.opacity(0.6)) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                }
                .frame(maxWidth: 440).font(.callout)
            }
            Button("Done", action: again).buttonStyle(PrimaryButtonStyle(tint: module.tint)).padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Floating glass bar pinned to the bottom of a results screen.
struct ActionBar<Trailing: View>: View {
    let summary: String
    var sub: String?
    let module: Module
    let buttonTitle: String
    var enabled = true
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary).font(.system(size: 16, weight: .medium)).contentTransition(.numericText())
                if let sub { Text(sub).font(.caption).foregroundStyle(.white.opacity(0.6)) }
            }
            Spacer()
            trailing
            Button(buttonTitle, action: action)
                .buttonStyle(PrimaryButtonStyle(tint: module.tint))
                .disabled(!enabled)
        }
        .padding(.horizontal, 22).padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black.opacity(0.30)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 18)
    }
}

extension ActionBar where Trailing == EmptyView {
    init(summary: String, sub: String? = nil, module: Module, buttonTitle: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.init(summary: summary, sub: sub, module: module, buttonTitle: buttonTitle, enabled: enabled, action: action) { EmptyView() }
    }
}

struct SizePill: View {
    let bytes: Int64
    var body: some View {
        Text(Bytes.string(bytes)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            .foregroundStyle(.white.opacity(0.7))
    }
}

/// Small coloured tag, e.g. REVIEW / UNSIGNED.
struct Tag: View {
    let text: String
    var color: Color = .orange
    var body: some View {
        Text(text).font(.system(size: 8.5, weight: .bold)).tracking(0.4)
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(Capsule().fill(color.opacity(0.28)))
            .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 0.5))
            .foregroundStyle(color.mix(with: .white, by: 0.45))
    }
}

// MARK: - Misc

enum Permissions {
    /// Full Disk Access shows up as the ability to open TCC.db (EPERM when it is missing).
    static func hasFullDiskAccess() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return errno != EPERM
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

extension Date {
    var shortAgo: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: self, relativeTo: Date())
    }
}
