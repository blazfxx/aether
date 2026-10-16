import SwiftUI
import AetherCore

struct PrivacyView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let m = state.privacy
        switch m.phase {
        case .idle:
            Hero(module: .privacy, headline: "Privacy",
                 detail: "Clears browsing history, cookies and cache for Safari, Chrome, Edge, Brave, Arc and Firefox, plus recent-item lists and shell history.",
                 button: "Scan",
                 note: "Browsers must be closed first. Saved passwords and bookmarks are never touched.") { m.scan() }
        case .scanning:
            ScanningView(module: .privacy, title: "Checking for traces", label: "Looking through browsers")
        case .results:
            if m.groups.isEmpty {
                DoneView(module: .privacy, headline: "No traces found", detail: "Nothing to clear right now.") { m.reset() }
            } else {
                PrivacyResults(model: m)
            }
        case .working:
            ScanningView(module: .privacy, title: "Clearing", label: "Removing selected data")
        case .done:
            DoneView(module: .privacy, headline: m.summary.headline, failures: m.summary.failures) { m.reset() }
        }
    }
}

private struct PrivacyResults: View {
    let model: PrivacyModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(module: .privacy, title: "\(Bytes.string(model.totalFound)) of traces",
                       subtitle: "Clearing history and cookies signs you out of websites.")
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.groups) { g in
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                HStack(spacing: 12) {
                                    CheckBox(state: g.blockedBy == nil ? model.state(for: g) : .off, tint: Module.privacy.tint) { model.toggle(g) }
                                        .disabled(g.blockedBy != nil)
                                    Image(systemName: g.symbol).foregroundStyle(Module.privacy.tint2).frame(width: 22)
                                    Text(g.title).font(.headline)
                                    Spacer()
                                    if let id = g.blockedBy, let name = g.blockedByName {
                                        Button("Quit \(name)") { model.quit(bundleID: id) }.buttonStyle(SoftButtonStyle())
                                    }
                                    SizePill(bytes: g.total)
                                }
                                .padding(14)
                                Divider()
                                ForEach(g.items) { item in
                                    HStack(spacing: 10) {
                                        CheckBox(state: g.blockedBy == nil && model.selected.contains(item.url) ? .on : .off,
                                                 tint: Module.privacy.tint) { model.toggle(item) }
                                            .disabled(g.blockedBy != nil)
                                        Text(label(for: item.url)).lineLimit(1)
                                        Spacer()
                                        SizePill(bytes: item.size)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .opacity(g.blockedBy == nil ? 1 : 0.5)
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
            ActionBar(summary: model.selectedBytes > 0 ? "Clear \(Bytes.string(model.selectedBytes))" : "Nothing selected",
                      sub: "Deleted permanently.", module: .privacy, buttonTitle: "Clear", enabled: model.selectedBytes > 0) { confirm = true } trailing: {
                Button("Scan Again") { model.scan() }.buttonStyle(SoftButtonStyle())
            }
        }
        .confirmationDialog("Clear \(Bytes.string(model.selectedBytes)) of private data?", isPresented: $confirm) {
            Button("Clear", role: .destructive) { model.clean() }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func label(for url: URL) -> String {
        let n = url.lastPathComponent
        switch n {
        case "History", "History.db", "History-journal", "History.db-wal", "History.db-shm", "places.sqlite": return "Browsing history (\(n))"
        case "Cookies", "Cookies-journal", "Cookies.binarycookies", "cookies.sqlite": return "Cookies (\(n))"
        case "Visited Links", "Top Sites", "Network Action Predictor", "formhistory.sqlite": return "\(n)"
        case "com.apple.LaunchServices.QuarantineEventsV2": return "Download history log"
        case "com.apple.sharedfilelist": return "Recent items"
        case ".zsh_history", ".bash_history", ".python_history", ".lesshst": return "Shell history (\(n))"
        default: return url.deletingLastPathComponent().lastPathComponent == "Caches" || url.path.contains("/Caches/") ? "Cache" : n
        }
    }
}
