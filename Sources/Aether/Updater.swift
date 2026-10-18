import SwiftUI
import AppKit
import AetherCore

/// Keeps Aether itself current from its GitHub releases.
///
/// - Checks at launch and every few hours (if enabled).
/// - With "install automatically" on, downloads and verifies the new version in the background and swaps it in
///   the moment Aether quits. "Restart to Update" does that right away.
/// - A copy that isn't in an Applications folder (a developer build) is never overwritten; it just tells you.
@MainActor @Observable final class SelfUpdater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(String)
        case ready(version: String, staged: URL)
        case installing
        case failed(String)
    }

    var state: State = .idle
    var lastChecked: Date? = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date

    let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    private let target = Bundle.main.bundleURL
    private var timer: Timer?
    private var quitObserver: NSObjectProtocol?
    private var busy = false

    private var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("dev.aether.Aether/updates")
    }

    var canReplaceItself: Bool { UpdateInstaller.canReplace(target) }

    func start() {
        try? FileManager.default.removeItem(at: cacheDir)   // leftovers from an earlier run
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyOnQuit() }
        }
        if Prefs.bool(Prefs.autoCheckUpdates, default: true) {
            Task { await check(userInitiated: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, Prefs.bool(Prefs.autoCheckUpdates, default: true) else { return }
                await self.check(userInitiated: false)
            }
        }
    }

    /// `userInitiated` shows "up to date" and errors; background checks stay quiet unless there is news.
    func check(userInitiated: Bool) async {
        guard !busy else { return }
        if case .ready = state { return }
        if case .downloading = state { return }
        busy = true
        defer { busy = false }
        if userInitiated { state = .checking }
        do {
            let release = try await ReleaseFeed.fetchLatest()
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: "lastUpdateCheck")
            guard let release, AppVersion(release.version) > AppVersion(currentVersion) else {
                if userInitiated || state == .checking { state = .upToDate }
                return
            }
            if canReplaceItself, Prefs.bool(Prefs.autoInstallUpdates, default: true) {
                await download(release)
            } else {
                state = .available(release)
            }
        } catch {
            if userInitiated { state = .failed(error.localizedDescription) } else if state == .checking { state = .idle }
        }
    }

    /// Downloads, verifies and unpacks the update. On success it waits in `.ready`.
    func download(_ release: ReleaseInfo) async {
        guard canReplaceItself else { openReleasePage(release); return }
        state = .downloading(release.version)
        do {
            let zip = try await ReleaseFeed.download(release, into: cacheDir)
            let dir = cacheDir
            let app = try await Task.detached { try UpdateInstaller.stage(zip: zip, version: release.version, workDir: dir) }.value
            try? FileManager.default.removeItem(at: zip)
            state = .ready(version: release.version, staged: app)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func downloadAvailable() {
        if case .available(let r) = state { Task { await download(r) } }
    }

    /// Swap the new version in now and reopen.
    func restartToUpdate() {
        guard case .ready(_, let staged) = state else { return }
        state = .installing
        guard UpdateInstaller.spawnSwap(staged: staged, target: target, relaunch: true) != nil else {
            state = .failed("Couldn't start the installer.")
            return
        }
        NSApp.terminate(nil)
    }

    /// If an update is waiting and "install automatically" is on, swap it in as Aether quits (no relaunch).
    private func applyOnQuit() {
        guard case .ready(_, let staged) = state, Prefs.bool(Prefs.autoInstallUpdates, default: true) else { return }
        UpdateInstaller.spawnSwap(staged: staged, target: target, relaunch: false)
    }

    func openReleasePage(_ release: ReleaseInfo) { NSWorkspace.shared.open(release.pageURL) }

    func dismissFailure() { if case .failed = state { state = .idle } }

    var statusLine: String {
        switch state {
        case .idle: return lastChecked.map { "Last checked \($0.shortAgo)" } ?? "Not checked yet"
        case .checking: return "Checking…"
        case .upToDate: return "Up to date" + (lastChecked.map { " · checked \($0.shortAgo)" } ?? "")
        case .available(let r): return "Version \(r.version) is available"
        case .downloading(let v): return "Downloading \(v)…"
        case .ready(let v, _): return "Version \(v) is ready to install"
        case .installing: return "Installing…"
        case .failed(let m): return m
        }
    }
}
