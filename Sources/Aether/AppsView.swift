import SwiftUI
import AetherCore

struct AppsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var m = state.apps
        VStack(spacing: 0) {
            PageHeader(module: .apps, title: "Uninstaller",
                       subtitle: "Removes an app together with the files it leaves in your Library.")
            Picker("", selection: $m.tab) {
                ForEach(AppsModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 280)
            .padding(.bottom, 12)
            if m.tab == .apps { AppList(model: m) } else { LeftoverList(model: m) }
            if let msg = m.message {
                HStack {
                    Text(msg).font(.callout)
                    Spacer()
                    Button("Dismiss") { m.message = nil }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24).padding(.vertical, 10).background(.black.opacity(0.25))
            }
        }
        .task { m.load() }
    }
}

private struct AppList: View {
    @Bindable var model: AppsModel
    @State private var confirm = false

    var body: some View {
        if model.loading && !model.loaded {
            ScanningView(module: .apps, title: "Reading your applications", label: "This takes a moment")
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search", text: $model.search).textFieldStyle(.plain)
                        Picker("", selection: $model.sort) {
                            ForEach(AppsModel.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 100)
                    }
                    .padding(10)
                    Divider()
                    List(model.shown, selection: Binding(get: { model.chosen }, set: { if let a = $0 { model.choose(a) } })) { app in
                        HStack(spacing: 10) {
                            FileIcon(url: app.url, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).lineLimit(1)
                                Text(usageText(app)).font(.caption).foregroundStyle(unused(app) ? Color.orange : .white.opacity(0.6))
                            }
                            Spacer()
                            SizePill(bytes: app.size)
                        }
                        .padding(.vertical, 2)
                        .tag(app)
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                }
                .frame(width: 360)
                Divider()
                if let app = model.chosen { AppDetail(model: model, app: app) }
                else {
                    VStack(spacing: 8) {
                        Image(systemName: "app.dashed").font(.system(size: 40)).foregroundStyle(.white.opacity(0.35))
                        Text("Select an app").foregroundStyle(.white.opacity(0.6))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .glassPanel().padding(.horizontal, 24).padding(.bottom, 20)
        }
    }

    private func unused(_ a: AppInfo) -> Bool { (a.monthsUnused ?? 0) >= 6 }

    private func usageText(_ a: AppInfo) -> String {
        guard let d = a.lastUsed else { return a.version.map { "v\($0)" } ?? "Never opened" }
        return unused(a) ? "Unused for \(a.monthsUnused ?? 0) months" : "Used \(d.shortAgo)"
    }
}

private struct AppDetail: View {
    @Bindable var model: AppsModel
    let app: AppInfo
    @State private var confirm = false

    var body: some View {
        let can = AppScanner.isUninstallable(app)
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                FileIcon(url: app.url, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.title2.weight(.semibold))
                    Text([app.version.map { "Version \($0)" }, app.fromAppStore ? "App Store" : nil, app.bundleID]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            if !can {
                Text("macOS apps and Aether itself can't be uninstalled here.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.loadingLeftovers {
                ProgressView("Looking for leftover files").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("Application") {
                        HStack { FileIcon(url: app.url, size: 22); Text(app.url.tildePath).lineLimit(1).truncationMode(.middle); Spacer(); SizePill(bytes: app.size) }
                    }
                    Section("Leftover files (\(model.leftovers.count))") {
                        if model.leftovers.isEmpty { Text("None found").foregroundStyle(.secondary) }
                        ForEach(model.leftovers) { l in
                            HStack(spacing: 10) {
                                CheckBox(state: model.leftoverSelection.contains(l.url) ? .on : .off, tint: Module.apps.tint) {
                                    if model.leftoverSelection.contains(l.url) { model.leftoverSelection.remove(l.url) } else { model.leftoverSelection.insert(l.url) }
                                }
                                Image(systemName: l.url.hasDirectoryPath ? "folder" : "doc").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(l.url.lastPathComponent).lineLimit(1)
                                    Text(l.url.deletingLastPathComponent().tildePath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                }
                                Spacer()
                                SizePill(bytes: l.size)
                            }
                        }
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
                ActionBar(summary: "Uninstall \(app.name)", sub: "Frees up to \(Bytes.string(model.uninstallBytes)) once the Trash is emptied",
                          module: .apps, buttonTitle: "Uninstall") { confirm = true }
            }
        }
        .confirmationDialog("Uninstall \(app.name)?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { model.uninstall() }
        } message: {
            Text("The app and the selected leftovers go to the Trash.")
        }
    }
}

private struct LeftoverList: View {
    @Bindable var model: AppsModel
    @State private var confirm = false

    var body: some View {
        if !model.orphansScanned && !model.scanningOrphans {
            Hero(module: .apps, headline: "Leftovers",
                 detail: "Finds support files, caches and preferences from apps that are no longer installed. Matches are best guesses, so nothing is selected until you choose it.",
                 button: "Find Leftovers") { model.scanOrphans() }
        } else if model.scanningOrphans {
            ScanningView(module: .apps, title: "Looking for orphaned files", label: "Comparing your Library with installed apps")
        } else if model.orphans.isEmpty {
            DoneView(module: .apps, headline: "No leftovers found", detail: "Every file in your Library belongs to an installed app.") {
                model.orphansScanned = false
            }
        } else {
            let sel = model.orphans.filter { model.orphanSelection.contains($0.url) }.reduce(0) { $0 + $1.size }
            VStack(spacing: 0) {
                List(model.orphans) { l in
                    HStack(spacing: 10) {
                        CheckBox(state: model.orphanSelection.contains(l.url) ? .on : .off, tint: Module.apps.tint) {
                            if model.orphanSelection.contains(l.url) { model.orphanSelection.remove(l.url) } else { model.orphanSelection.insert(l.url) }
                        }
                        Image(systemName: l.url.hasDirectoryPath ? "folder" : "doc").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(l.url.lastPathComponent).lineLimit(1)
                            Text(l.url.deletingLastPathComponent().tildePath).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        SizePill(bytes: l.size)
                        Button { reveal(l.url) } label: { Image(systemName: "magnifyingglass.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset).glassPanel().padding(.horizontal, 24)
                ActionBar(summary: sel > 0 ? "Move \(Bytes.string(sel)) to Trash" : "Nothing selected",
                          sub: "\(model.orphans.count) possible leftovers", module: .apps, buttonTitle: "Move to Trash",
                          enabled: sel > 0) { confirm = true } trailing: {
                    Button("Rescan") { model.scanOrphans() }.buttonStyle(SoftButtonStyle())
                }
            }
            .confirmationDialog("Move \(model.orphanSelection.count) item\(model.orphanSelection.count == 1 ? "" : "s") to the Trash?", isPresented: $confirm) {
                Button("Move to Trash", role: .destructive) { model.trashOrphans() }
            } message: {
                Text("You can restore them from the Trash if an app misbehaves.")
            }
        }
    }
}
