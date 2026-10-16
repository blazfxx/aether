import SwiftUI
import AetherCore

struct JunkView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let m = state.junk
        switch m.phase {
        case .idle:
            Hero(module: .junk, headline: "System Junk",
                 detail: "Finds caches, logs, crash reports, old installers and developer leftovers, and shows exactly what each one is before anything is removed.",
                 button: "Scan") { m.scan() }
        case .scanning:
            ScanningView(module: .junk, title: "Looking for junk", label: m.scanLabel) { m.cancel() }
        case .results:
            if m.visible.isEmpty {
                DoneView(module: .junk, headline: "Your Mac is clean", detail: "No junk found in the places Aether checks.") { m.reset() }
            } else {
                JunkResults(model: m)
            }
        case .working:
            ScanningView(module: .junk, title: "Cleaning", label: "Removing selected items")
        case .done:
            DoneView(module: .junk, headline: m.summary.headline,
                     detail: m.summary.trashed > 0 ? "Empty the Trash to reclaim the rest." : nil,
                     failures: m.summary.failures) { m.reset() }
        }
    }
}

private struct JunkResults: View {
    @Environment(AppState.self) private var state
    let model: JunkModel
    @State private var confirm = false

    var body: some View {
        let blocked = model.blockedCategories(hasFDA: state.hasFDA)
        VStack(spacing: 0) {
            PageHeader(module: .junk, title: "\(Bytes.string(model.totalFound)) found",
                       subtitle: "Items marked Review go to the Trash. Everything else is rebuilt by your apps.")
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.visible) { r in
                            CategoryRow(model: model, result: r)
                        }
                        if !blocked.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Not scanned").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(blocked) { c in
                                    Label(c.title, systemImage: "lock").font(.caption).foregroundStyle(.tertiary)
                                }
                                Button("Grant Full Disk Access") { Permissions.openFullDiskAccessSettings() }
                                    .buttonStyle(SoftButtonStyle()).padding(.top, 2)
                            }
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
                .frame(width: 330)
                Divider()
                if let r = model.visible.first(where: { $0.category.id == model.focused }) ?? model.visible.first {
                    JunkItems(model: model, result: r)
                }
            }
            .glassPanel().padding(.horizontal, 24)
            ActionBar(summary: model.selectedBytes > 0 ? "Clean \(Bytes.string(model.selectedBytes))" : "Nothing selected",
                      sub: "\(model.selected.count) item\(model.selected.count == 1 ? "" : "s") selected",
                      module: .junk, buttonTitle: "Clean", enabled: model.selectedBytes > 0) { confirm = true } trailing: {
                Button("Scan Again") { model.scan() }.buttonStyle(SoftButtonStyle())
            }
        }
        .confirmationDialog("Clean \(Bytes.string(model.selectedBytes))?", isPresented: $confirm) {
            Button("Clean", role: .destructive) { model.clean() }
        } message: {
            Text("Caches and logs are deleted permanently. Items marked Review are moved to the Trash.")
        }
    }
}

private struct CategoryRow: View {
    let model: JunkModel
    let result: JunkResult

    var body: some View {
        let focused = model.focused == result.category.id
        HStack(spacing: 10) {
            CheckBox(state: model.state(for: result), tint: Module.junk.tint) { model.toggle(result) }
            Image(systemName: result.category.symbol)
                .foregroundStyle(Module.junk.tint2).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(result.category.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if result.category.risk == .review { Tag(text: "REVIEW") }
                }
                Text("\(result.items.count) item\(result.items.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SizePill(bytes: result.total)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(focused ? 0.13 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { model.focused = result.category.id }
    }
}

private struct JunkItems: View {
    let model: JunkModel
    let result: JunkResult

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.category.title).font(.title3.weight(.semibold))
                Text(result.category.blurb).font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            List(result.items) { item in
                HStack(spacing: 10) {
                    CheckBox(state: model.selected.contains(item.url) ? .on : .off, tint: Module.junk.tint) { model.toggle(item) }
                    FileIcon(url: item.url, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(item.url.deletingLastPathComponent().tildePath + (item.modified.map { " · \($0.shortAgo)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    SizePill(bytes: item.size)
                    Button { reveal(item.url) } label: { Image(systemName: "magnifyingglass.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity)
    }
}
