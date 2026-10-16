import SwiftUI
import AetherCore

struct StartupView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let m = state.startup
        VStack(spacing: 0) {
            PageHeader(module: .startup, title: "Startup Items",
                       subtitle: "Apps and background helpers that start with your Mac. Fewer means faster logins and less battery use.")
            if m.loading && !m.loaded {
                ScanningView(module: .startup, title: "Reading startup items", label: "Checking signatures")
            } else {
                List {
                    Section("Login items") {
                        if m.loginItems.isEmpty {
                            Text("None, or Aether hasn't been allowed to read them.").foregroundStyle(.secondary)
                        }
                        ForEach(m.loginItems, id: \.self) { name in
                            HStack {
                                Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(Module.startup.tint2)
                                Text(name)
                                Spacer()
                                Button("Remove") { m.removeLogin(name) }.buttonStyle(SoftButtonStyle())
                            }
                        }
                    }
                    ForEach([StartupItem.Kind.userAgent, .systemAgent, .daemon], id: \.self) { kind in
                        let rows = m.items.filter { $0.kind == kind }
                        if !rows.isEmpty {
                            Section(kind == .userAgent ? "Your background items (\(rows.count))" : "\(kind.rawValue)s (\(rows.count)) · need administrator rights to change") {
                                ForEach(rows) { item in StartupRow(model: m, item: item) }
                            }
                        }
                    }
                }
                .listStyle(.inset).glassPanel().padding(.horizontal, 24).padding(.bottom, 20)
            }
            if let msg = m.message {
                HStack { Text(msg).font(.callout); Spacer(); Button("Dismiss") { m.message = nil }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    .padding(.horizontal, 24).padding(.vertical, 10).background(.black.opacity(0.25))
            }
        }
        .task { if !m.loaded { m.load() } }
    }
}

private struct StartupRow: View {
    let model: StartupModel
    let item: StartupItem

    var body: some View {
        HStack(spacing: 12) {
            if let p = item.program, FileManager.default.fileExists(atPath: p) {
                FileIcon(url: URL(fileURLWithPath: p), size: 26)
            } else {
                Image(systemName: "questionmark.square.dashed").font(.title3).foregroundStyle(.secondary).frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.label).lineLimit(1).truncationMode(.middle)
                    if item.signed == false { Tag(text: "UNSIGNED") }
                }
                Text(item.program ?? item.plist.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if item.isManageable {
                Toggle("", isOn: Binding(get: { item.isLoaded }, set: { model.setEnabled(item, $0) })).labelsHidden().toggleStyle(.switch)
                Button { model.remove(item) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Move to Trash")
            } else {
                Text(item.isLoaded ? "Running" : "Not running").font(.caption).foregroundStyle(.secondary)
                Button { reveal(item.plist) } label: { Image(systemName: "magnifyingglass.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Maintenance

struct MaintenanceView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let m = state.maintenance
        VStack(spacing: 0) {
            PageHeader(module: .maintenance, title: "Maintenance",
                       subtitle: "Small fixes for common macOS annoyances. Some ask for your password.")
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Maintenance.tasks) { t in
                        Card {
                            HStack(spacing: 14) {
                                Image(systemName: t.symbol).font(.title2).foregroundStyle(Module.maintenance.tint2).frame(width: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(t.title).font(.headline)
                                        if t.needsAdmin { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help("Asks for your password") }
                                    }
                                    Text(t.detail).font(.callout).foregroundStyle(.secondary)
                                    if let r = m.results[t.id] {
                                        Label(r.message, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .font(.caption).foregroundStyle(r.ok ? .green : .orange)
                                    }
                                }
                                Spacer()
                                if m.running == t.id { ProgressView().controlSize(.small) }
                                else { Button("Run") { m.run(t) }.buttonStyle(SoftButtonStyle()).disabled(m.running != nil) }
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }
}
