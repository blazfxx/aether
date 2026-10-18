import SwiftUI
import AetherCore

struct SmartScanView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let m = state.smart
        switch m.phase {
        case .idle:
            Hero(module: .smartScan, headline: "Smart Scan",
                 detail: "One pass checks for junk, privacy traces, app updates and startup items, and says which maintenance is actually needed. Nothing is removed until you say so.",
                 button: "Scan", note: "Takes about a minute. Your files are never uploaded anywhere; the update check only asks whether newer versions exist.") { m.run() }
        case .scanning:
            ScanSteps(model: m)
        case .results:
            SmartResults(model: m)
        case .working:
            ScanningView(module: .smartScan, title: "Cleaning", label: "Removing safe junk")
        case .done:
            DoneView(module: .smartScan, headline: m.summary?.headline ?? "Done",
                     detail: "Anything flagged for review was left alone.",
                     failures: m.summary?.failures ?? []) { m.reset() }
        }
    }
}

private struct ScanSteps: View {
    let model: SmartScanModel

    var body: some View {
        VStack(spacing: 26) {
            SpinnerBadge(module: .smartScan)
            Text("Scanning your Mac").font(.display(32))
            VStack(alignment: .leading, spacing: 12) {
                ForEach(SmartScanModel.Step.allCases, id: \.self) { step in
                    HStack(spacing: 12) {
                        ZStack {
                            if model.completed.contains(step) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else if model.current == step {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "circle").foregroundStyle(.white.opacity(0.25))
                            }
                        }.frame(width: 20)
                        Text(step.title)
                            .foregroundStyle(.white.opacity(model.completed.contains(step) || model.current == step ? 1 : 0.4))
                    }
                }
            }
            if model.current == .junk || model.current == .privacy {
                // Reading folders macOS protects can pause behind a permission dialog.
                Text("If macOS asks to let Aether access a folder, choose Allow.")
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            Button("Stop") { model.cancel() }.buttonStyle(SoftButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SmartResults: View {
    @Environment(AppState.self) private var state
    let model: SmartScanModel
    @State private var confirm = false

    var body: some View {
        let junk = model.junk, privacy = model.privacy, apps = model.apps, maint = model.maintenance
        let health = state.health
        let safe = junk.safeSelectedBytes
        let held = junk.safeBytes - safe
        let review = junk.totalFound - junk.safeBytes

        VStack(spacing: 0) {
            PageHeader(module: .smartScan, title: "Scan complete",
                       subtitle: safe > 0 ? "\(Bytes.string(safe)) of junk is safe to remove right now." : "Nothing selected to remove.")
            ScrollView {
                VStack(spacing: 12) {
                    ResultRow(module: .junk, title: "System Junk",
                              detail: junkDetail(review: review, held: held),
                              value: Bytes.string(junk.totalFound), button: "Review") { state.selection = .junk }
                    ResultRow(module: .privacy, title: "Privacy",
                              detail: "Browser history, cookies and recent-item traces.",
                              value: privacy.groups.isEmpty ? "None" : Bytes.string(privacy.totalFound), button: "Review") { state.selection = .privacy }
                    ResultRow(module: .apps, title: "App Updates",
                              detail: updatesDetail(apps),
                              value: model.updatesChecked ? (apps.updates.isEmpty ? "Up to date" : "\(apps.updates.count) available") : "Skipped",
                              button: "Review") { apps.tab = .updates; state.selection = .apps }
                    ResultRow(module: .startup, title: "Startup Items",
                              detail: model.unsignedStartup > 0 ? "\(model.unsignedStartup) background item\(model.unsignedStartup == 1 ? " is" : "s are") not code-signed." : "All background items are signed.",
                              value: "\(model.startupCount) at login", button: "Review") { state.selection = .startup }
                    ResultRow(module: .maintenance, title: "Maintenance",
                              detail: maintenanceDetail(maint),
                              value: maint.advice.isEmpty ? "All good" : "\(maint.advice.count) needed",
                              button: maint.advice.isEmpty ? "Open" : (maint.running == nil ? "Run" : "Running…")) {
                        if maint.advice.isEmpty { state.selection = .maintenance } else { maint.runRecommended() }
                    }
                    ResultRow(module: .health, title: "Mac Health",
                              detail: health.issues.first?.title ?? "Nothing needs attention.",
                              value: health.verdict, button: "Open") { state.selection = .health }
                }
                .padding(.horizontal, 24).padding(.bottom, 20)
            }
            ActionBar(summary: safe > 0 ? "Clean \(Bytes.string(safe)) of safe junk" : "Nothing to clean automatically",
                      sub: "Caches and logs are deleted. Review items are never touched here, and neither is anything you unticked.",
                      module: .smartScan, buttonTitle: "Clean", enabled: safe > 0) { confirm = true } trailing: {
                Button("Scan Again") { model.run() }.buttonStyle(SoftButtonStyle())
            }
        }
        .confirmationDialog("Delete \(Bytes.string(safe)) of safe junk?", isPresented: $confirm) {
            Button("Delete", role: .destructive) { model.cleanSafe() }
        } message: {
            Text("These are caches and logs that apps rebuild on their own. This can't be undone.")
        }
    }

    private func junkDetail(review: Int64, held: Int64) -> String {
        var parts = ["Caches, logs and build leftovers."]
        if held > 0 { parts = ["\(Bytes.string(held)) is unticked, as you left it."] }
        if review > 0 { parts.append("\(Bytes.string(review)) more needs a look before it goes.") }
        return parts.joined(separator: " ")
    }

    private func updatesDetail(_ apps: AppsModel) -> String {
        guard model.updatesChecked else { return "Turned off in Settings." }
        if apps.updates.isEmpty { return "Every app that publishes updates is current." }
        let names = apps.updates.prefix(3).map(\.app.name).joined(separator: ", ")
        return apps.updates.count > 3 ? "\(names) and \(apps.updates.count - 3) more." : names + "."
    }

    private func maintenanceDetail(_ m: MaintenanceModel) -> String {
        if m.advice.isEmpty {
            if let done = m.results.values.first(where: { $0.ok }) { return "Done: \(done.message)." }
            return "Nothing needs doing right now."
        }
        return m.advice.map { "\($0.task.title): \($0.reason)" }.joined(separator: " ")
    }
}

struct ResultRow: View {
    let module: Module
    let title: String
    let detail: String
    let value: String
    let button: String
    let action: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 14) {
                GradientBadge(module: module, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                Button(button, action: action).buttonStyle(SoftButtonStyle())
            }
        }
    }
}
