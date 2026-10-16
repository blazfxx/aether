import SwiftUI
import AetherCore

struct SmartScanView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let m = state.smart
        switch m.phase {
        case .idle:
            Hero(module: .smartScan, headline: "Smart Scan",
                 detail: "One pass checks for junk, privacy traces, large files and startup items. Nothing is removed until you say so.",
                 button: "Scan", note: "Takes about a minute. Your files are never uploaded anywhere.") { m.run() }
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
            if model.current == .large {
                // Walking a big home folder takes a while, and macOS may be waiting for you to allow access to a folder.
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let p = model.largeProgress.snapshot
                    VStack(spacing: 8) {
                        Text("\(p.files.formatted()) files checked")
                            .font(.callout).foregroundStyle(.white.opacity(0.75))
                        if !p.current.isEmpty {
                            Text(p.current).font(.caption).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.white.opacity(0.45)).frame(maxWidth: 420)
                        } else {
                            Text("If macOS asks for access to a folder, choose Allow.")
                                .font(.caption).foregroundStyle(.white.opacity(0.6))
                        }
                        Button("Skip large files") { model.largeProgress.cancel() }
                            .buttonStyle(.plain).font(.callout).foregroundStyle(.white.opacity(0.85))
                            .padding(.top, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SmartResults: View {
    @Environment(AppState.self) private var state
    let model: SmartScanModel
    @State private var confirm = false

    var body: some View {
        let junk = model.junk, privacy = model.privacy
        let health = state.health
        let safe = junk.safeBytes
        let review = junk.totalFound - safe

        VStack(spacing: 0) {
            PageHeader(module: .smartScan, title: "Scan complete",
                       subtitle: safe > 0 ? "\(Bytes.string(safe)) of junk is safe to remove right now." : "Nothing risky found.")
            ScrollView {
                VStack(spacing: 12) {
                    ResultRow(module: .junk, title: "System Junk",
                              detail: review > 0 ? "\(Bytes.string(review)) more needs a look before it goes." : "Caches, logs and build leftovers.",
                              value: Bytes.string(junk.totalFound), button: "Review") { state.selection = .junk }
                    ResultRow(module: .privacy, title: "Privacy",
                              detail: "Browser history, cookies and recent-item traces.",
                              value: privacy.groups.isEmpty ? "None" : Bytes.string(privacy.totalFound), button: "Review") { state.selection = .privacy }
                    ResultRow(module: .largeFiles, title: "Large Files",
                              detail: model.largePartial ? "Only part of your folders was checked: \(model.largeCount) file\(model.largeCount == 1 ? "" : "s") over 500 MB so far. Review scans the rest." : model.largeCount == 0 ? "No files over 500 MB in your main folders." : "\(model.largeCount) file\(model.largeCount == 1 ? "" : "s") over 500 MB.",
                              value: Bytes.string(model.largeBytes), button: "Review") { state.selection = .largeFiles }
                    ResultRow(module: .startup, title: "Startup Items",
                              detail: model.unsignedStartup > 0 ? "\(model.unsignedStartup) background item\(model.unsignedStartup == 1 ? " is" : "s are") not code-signed." : "All background items are signed.",
                              value: "\(model.startupCount) at login", button: "Review") { state.selection = .startup }
                    ResultRow(module: .health, title: "Mac Health",
                              detail: health.issues.first?.title ?? "Nothing needs attention.",
                              value: health.verdict, button: "Open") { state.selection = .health }
                }
                .padding(.horizontal, 24).padding(.bottom, 20)
            }
            ActionBar(summary: safe > 0 ? "Clean \(Bytes.string(safe)) of safe junk" : "Nothing to clean automatically",
                      sub: "Caches and logs are deleted. Review items are never touched here.",
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
