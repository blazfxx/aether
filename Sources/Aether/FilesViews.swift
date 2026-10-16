import SwiftUI
import AetherCore

// MARK: - Large & Old Files

struct LargeFilesView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var m = state.large
        switch m.phase {
        case .idle:
            VStack(spacing: 0) {
                Hero(module: .largeFiles, headline: "Large & Old Files",
                     detail: "Finds the biggest files in Desktop, Documents, Downloads, Movies, Music and Pictures, and how long since you last opened them.",
                     button: "Scan", note: "Files you remove go to the Trash, so you can put them back.") { m.scan() }
                HStack(spacing: 10) {
                    Text("Only files larger than").foregroundStyle(.secondary)
                    Picker("", selection: $m.minSizeMB) {
                        Text("50 MB").tag(50); Text("100 MB").tag(100); Text("500 MB").tag(500); Text("1 GB").tag(1000)
                    }.labelsHidden().frame(width: 100)
                }
                .padding(.bottom, 28)
            }
        case .scanning:
            ScanningView(module: .largeFiles, title: "Finding large files", progress: m.progress) { m.cancel() }
        case .results:
            LargeFilesResults(model: m)
        case .working:
            ScanningView(module: .largeFiles, title: "Moving to Trash", label: "Working")
        case .done:
            DoneView(module: .largeFiles, headline: m.summary.headline, detail: "Empty the Trash to reclaim the space.",
                     failures: m.summary.failures) { m.reset() }
        }
    }
}

private struct LargeFilesResults: View {
    @Bindable var model: LargeFilesModel
    @State private var confirm = false

    var body: some View {
        let shown = model.shown
        VStack(spacing: 0) {
            PageHeader(module: .largeFiles, title: "\(model.files.count) large file\(model.files.count == 1 ? "" : "s")",
                       subtitle: "\(Bytes.string(model.files.reduce(0) { $0 + $1.size })) in total")
            HStack(spacing: 12) {
                Picker("Kind", selection: $model.kind) { ForEach(model.kinds, id: \.self) { Text($0).tag($0) } }.frame(width: 190)
                Picker("Sort", selection: $model.sort) { ForEach(LargeFilesModel.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 170)
                Toggle("Not opened in 6+ months", isOn: $model.onlyStale)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 10)
            if shown.isEmpty {
                Text("No files match these filters.").foregroundStyle(.white.opacity(0.6)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { f in
                    HStack(spacing: 10) {
                        CheckBox(state: model.selected.contains(f.url) ? .on : .off, tint: Module.largeFiles.tint) {
                            if model.selected.contains(f.url) { model.selected.remove(f.url) } else { model.selected.insert(f.url) }
                        }
                        FileIcon(url: f.url, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(f.url.deletingLastPathComponent().tildePath).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Text(f.kind).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        Text(f.daysSinceUse.map { $0 < 1 ? "today" : "\($0)d ago" } ?? "")
                            .font(.caption).foregroundStyle((f.daysSinceUse ?? 0) > 180 ? .orange : .secondary)
                            .frame(width: 70, alignment: .trailing)
                        SizePill(bytes: f.size).frame(width: 70, alignment: .trailing)
                        Button { reveal(f.url) } label: { Image(systemName: "magnifyingglass.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain).glassPanel().padding(.horizontal, 24)
            }
            ActionBar(summary: model.selectedBytes > 0 ? "Move \(Bytes.string(model.selectedBytes)) to Trash" : "Nothing selected",
                      sub: "\(model.selected.count) selected", module: .largeFiles, buttonTitle: "Move to Trash",
                      enabled: !model.selected.isEmpty) { confirm = true } trailing: {
                Button("Scan Again") { model.scan() }.buttonStyle(SoftButtonStyle())
            }
        }
        .confirmationDialog("Move \(model.selected.count) item\(model.selected.count == 1 ? "" : "s") to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { model.trashSelected() }
        } message: {
            Text("You can restore them from the Trash.")
        }
    }
}

// MARK: - Duplicates

struct DuplicatesView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let m = state.dupes
        switch m.phase {
        case .idle:
            Hero(module: .duplicates, headline: "Duplicates",
                 detail: "Finds files with identical contents in your main folders. Matches are checked byte for byte, not by name. You always keep at least one copy.",
                 button: "Scan", note: "Skips hidden files, app packages and anything under 100 KB.") { m.scan() }
        case .scanning:
            ScanningView(module: .duplicates, title: "Comparing files", progress: m.progress) { m.cancel() }
        case .results:
            if m.groups.isEmpty {
                DoneView(module: .duplicates, headline: "No duplicates found", detail: "Every file in the scanned folders is unique.") { m.reset() }
            } else {
                DuplicatesResults(model: m)
            }
        case .working:
            ScanningView(module: .duplicates, title: "Moving to Trash", label: "Working")
        case .done:
            DoneView(module: .duplicates, headline: m.summary.headline, detail: "Empty the Trash to reclaim the space.",
                     failures: m.summary.failures) { m.reset() }
        }
    }
}

private struct DuplicatesResults: View {
    let model: DuplicatesModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(module: .duplicates, title: "\(Bytes.string(model.reclaimable)) in duplicates",
                       subtitle: "\(model.groups.count) set\(model.groups.count == 1 ? "" : "s") of identical files. The oldest copy of each is kept by default.")
            List {
                ForEach(model.groups) { g in
                    Section {
                        ForEach(g.files) { f in
                            HStack(spacing: 10) {
                                CheckBox(state: model.selected.contains(f.url) ? .on : .off, tint: Module.duplicates.tint) { model.toggle(f, in: g) }
                                FileIcon(url: f.url, size: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Text(f.url.deletingLastPathComponent().tildePath + (f.modified.map { " · \($0.shortAgo)" } ?? ""))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                }
                                Spacer()
                                if !model.selected.contains(f.url) { Tag(text: "KEEP", color: .green) }
                                Button { reveal(f.url) } label: { Image(systemName: "magnifyingglass.circle") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
                            }
                        }
                    } header: {
                        HStack {
                            Text("\(g.files.count) copies · \(Bytes.string(g.size)) each")
                            Spacer()
                            Text("Save \(Bytes.string(g.reclaimable))").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset).glassPanel().padding(.horizontal, 24)
            ActionBar(summary: model.selectedBytes > 0 ? "Move \(Bytes.string(model.selectedBytes)) to Trash" : "Nothing selected",
                      sub: "\(model.selected.count) duplicate\(model.selected.count == 1 ? "" : "s") selected",
                      module: .duplicates, buttonTitle: "Move to Trash", enabled: !model.selected.isEmpty) { confirm = true } trailing: {
                Button("Reset Selection") { model.autoSelect() }.buttonStyle(SoftButtonStyle())
            }
        }
        .confirmationDialog("Move \(model.selected.count) duplicate\(model.selected.count == 1 ? "" : "s") to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { model.trashSelected() }
        } message: {
            Text("At least one copy of every file stays where it is.")
        }
    }
}
