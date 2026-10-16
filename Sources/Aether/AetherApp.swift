import SwiftUI
import AetherCore

@main
struct AetherApp: App {
    @State private var state = AppState()
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        Window("Aether", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1120, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Go") {
                ForEach(Array(Module.allCases.enumerated()), id: \.element.id) { i, m in
                    Button(m.title) { state.selection = m }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1 == 10 ? 0 : i + 1)")), modifiers: .command)
                }
            }
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView().environment(state)
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            AuroraBackground(module: state.selection)
                .id(state.selection)
                .transition(.opacity)

            HStack(spacing: 0) {
                Sidebar(selection: Binding(get: { state.selection }, set: { state.selection = $0 }))
                    .frame(width: 244)
                VStack(spacing: 0) {
                    if !state.hasFDA && !state.bannerDismissed {
                        FullDiskAccessBanner()
                    }
                    detail(for: state.selection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(state.selection)
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.45), value: state.selection)
        .preferredColorScheme(.dark)
        .background(WindowChrome())
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshPermissions()
        }
    }

    @ViewBuilder private func detail(for m: Module) -> some View {
        switch m {
        case .smartScan: SmartScanView()
        case .health: HealthView()
        case .junk: JunkView()
        case .privacy: PrivacyView()
        case .largeFiles: LargeFilesView()
        case .duplicates: DuplicatesView()
        case .spaceLens: SpaceLensView()
        case .apps: AppsView()
        case .startup: StartupView()
        case .maintenance: MaintenanceView()
        }
    }
}

/// Makes the title bar disappear so the aurora runs edge to edge; traffic lights stay.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(red: 0.05, green: 0.04, blue: 0.14, alpha: 1)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct Sidebar: View {
    @Binding var selection: Module

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Module.sections, id: \.name) { section in
                        Text(section.name.uppercased())
                            .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                            .foregroundStyle(.white.opacity(0.38))
                            .padding(.leading, 14).padding(.top, 12).padding(.bottom, 3)
                        ForEach(section.modules) { m in
                            SidebarItem(module: m, selected: selection == m) { selection = m }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 42)
            }
            DiskFooter().padding(12)
        }
        .background(.black.opacity(0.16))
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.07)).frame(width: 1) }
    }
}

struct SidebarItem: View {
    let module: Module
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                GradientBadge(module: module, size: 28)
                Text(module.title).font(.system(size: 14.5, weight: selected ? .medium : .regular))
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(selected ? 0.15 : (hover ? 0.07 : 0)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.22 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(selected ? 1 : 0.85))
        .onHover { hover = $0 }
    }
}

struct DiskFooter: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let d = state.health.snap.disk
        let tint: Color = d.usedFraction > 0.9 ? .red : (d.usedFraction > 0.8 ? .orange : .white)
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Macintosh HD").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Bytes.string(d.available)) free").font(.caption).foregroundStyle(.white.opacity(0.65))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(tint.opacity(0.9)).frame(width: max(6, g.size.width * d.usedFraction))
                }
            }.frame(height: 6)
        }
        .padding(12)
        .glass(radius: 12)
    }
}

struct FullDiskAccessBanner: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.title3).foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text("Aether can't see everything yet").font(.callout.weight(.medium))
                Text("Grant Full Disk Access to include the Trash, Mail downloads and device backups.")
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Button("Open Settings") { Permissions.openFullDiskAccessSettings() }.buttonStyle(SoftButtonStyle())
            Button { state.bannerDismissed = true } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glass(radius: 14, fill: 0.10)
        .padding(.horizontal, 24).padding(.top, 14)
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var quickMessage: String?
    @State private var busy = false

    var body: some View {
        let s = state.health.snap
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                MiniGauge(title: "CPU", value: s.cpuTotal, caption: "\(Int(s.cpuTotal * 100))%", tint: .blue)
                MiniGauge(title: "Memory", value: s.memory.pressure, caption: Bytes.string(Int64(s.memory.used)), tint: .purple)
                MiniGauge(title: "Disk", value: s.disk.usedFraction, caption: "\(Bytes.string(s.disk.available)) free",
                          tint: s.disk.usedFraction > 0.9 ? .red : .green)
            }
            if let b = s.battery {
                Label("Battery \(b.percent)%\(b.isCharging ? " · charging" : "")", systemImage: b.isCharging ? "battery.100.bolt" : "battery.75")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Button {
                busy = true; quickMessage = nil
                Task {
                    let r = await JunkScanner.scan(JunkCatalog.all.filter { $0.risk == .safe })
                    let items = r.flatMap { res in res.items.map { ($0.url, $0.size) } }
                    let summary = await Task.detached { Remover.execute(permanent: items, trash: []) }.value
                    quickMessage = summary.count == 0 ? "Already clean" : summary.headline
                    busy = false
                }
            } label: {
                HStack { Label("Quick Clean", systemImage: "sparkles"); Spacer(); if busy { ProgressView().controlSize(.small) } }
            }
            .disabled(busy)
            if let quickMessage { Text(quickMessage).font(.caption).foregroundStyle(.secondary) }
            Button { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } label: {
                Label("Open Aether", systemImage: "macwindow")
            }
            Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
        }
        .buttonStyle(.plain)
        .padding(14)
        .frame(width: 300)
    }
}

struct MiniGauge: View {
    let title: String, value: Double, caption: String, tint: Color
    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RingGauge(value: value, tint: tint, lineWidth: 6)
                Text("\(Int(value * 100))").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            }.frame(width: 52, height: 52)
            Text(title).font(.caption2.weight(.medium))
            Text(caption).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity)
    }
}
