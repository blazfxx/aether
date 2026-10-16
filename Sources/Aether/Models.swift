import SwiftUI
import AppKit
import AetherCore

enum Phase: Equatable { case idle, scanning, results, working, done }

// MARK: - Junk

@MainActor @Observable final class JunkModel {
    var phase: Phase = .idle
    var results: [JunkResult] = []
    var selected: Set<URL> = []
    var focused: String?
    var scanLabel = "Looking for junk"
    var summary = RemovalSummary()
    private var task: Task<Void, Never>?

    var visible: [JunkResult] { results.filter { !$0.items.isEmpty } }
    var totalFound: Int64 { results.reduce(0) { $0 + $1.total } }
    var selectedBytes: Int64 { results.flatMap(\.items).filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size } }
    var safeBytes: Int64 { results.filter { $0.category.risk == .safe }.reduce(0) { $0 + $1.total } }
    /// Categories that came back empty only because macOS blocked the read.
    func blockedCategories(hasFDA: Bool) -> [JunkCategory] {
        hasFDA ? [] : results.filter { $0.category.needsFullDiskAccess && $0.items.isEmpty }.map(\.category)
    }

    func scan() {
        phase = .scanning
        task = Task {
            let r = await JunkScanner.scan { [weak self] name in
                Task { @MainActor in self?.scanLabel = "Checking \(name)" }
            }
            guard !Task.isCancelled else { return }
            results = r
            selected = Set(r.filter { $0.category.risk == .safe }.flatMap(\.items).map(\.url))
            focused = visible.first?.category.id
            phase = .results
        }
    }

    func cancel() { task?.cancel(); phase = .idle }

    func state(for r: JunkResult) -> CheckState {
        let n = r.items.filter { selected.contains($0.url) }.count
        return n == 0 ? .off : (n == r.items.count ? .on : .mixed)
    }

    func toggle(_ r: JunkResult) {
        if state(for: r) == .on { r.items.forEach { selected.remove($0.url) } }
        else { r.items.forEach { selected.insert($0.url) } }
    }

    func toggle(_ item: JunkItem) {
        if selected.contains(item.url) { selected.remove(item.url) } else { selected.insert(item.url) }
    }

    /// `safeOnly` is the menu bar / Smart Scan path: never touches anything flagged for review.
    func clean(safeOnly: Bool = false) {
        var perm: [(URL, Int64)] = [], trash: [(URL, Int64)] = []
        for r in results where !safeOnly || r.category.risk == .safe {
            for i in r.items where safeOnly || selected.contains(i.url) {
                if r.category.mode == .permanent { perm.append((i.url, i.size)) } else { trash.append((i.url, i.size)) }
            }
        }
        phase = .working
        Task {
            let s = await Task.detached(priority: .userInitiated) { Remover.execute(permanent: perm, trash: trash) }.value
            summary = s
            phase = .done
        }
    }

    func reset() { phase = .idle; results = []; selected = [] }
}

// MARK: - Privacy

@MainActor @Observable final class PrivacyModel {
    var phase: Phase = .idle
    var groups: [PrivacyGroup] = []
    var selected: Set<URL> = []
    var summary = RemovalSummary()

    var totalFound: Int64 { groups.reduce(0) { $0 + $1.total } }
    var selectedBytes: Int64 { groups.filter { $0.blockedBy == nil }.flatMap(\.items).filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size } }

    func scan() {
        phase = .scanning
        Task {
            groups = await PrivacyScanner.scan()
            // Shell history is useful to most people, so it starts unselected; everything else starts selected.
            selected = Set(groups.flatMap { g in g.items.filter { g.id != "system" || !$0.url.lastPathComponent.hasSuffix("history") }.map(\.url) })
            phase = .results
        }
    }

    func state(for g: PrivacyGroup) -> CheckState {
        let n = g.items.filter { selected.contains($0.url) }.count
        return n == 0 ? .off : (n == g.items.count ? .on : .mixed)
    }

    func toggle(_ g: PrivacyGroup) {
        if state(for: g) == .on { g.items.forEach { selected.remove($0.url) } } else { g.items.forEach { selected.insert($0.url) } }
    }

    func toggle(_ i: PrivacyItem) {
        if selected.contains(i.url) { selected.remove(i.url) } else { selected.insert(i.url) }
    }

    func quit(bundleID: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
        Task { try? await Task.sleep(for: .seconds(1.5)); scan() }
    }

    func clean() {
        let items = groups.filter { $0.blockedBy == nil }.flatMap(\.items).filter { selected.contains($0.url) }.map { ($0.url, $0.size) }
        phase = .working
        Task {
            summary = await Task.detached { Remover.execute(permanent: items, trash: []) }.value
            phase = .done
        }
    }

    func reset() { phase = .idle; groups = []; selected = [] }
}

// MARK: - Large & old files

@MainActor @Observable final class LargeFilesModel {
    enum Sort: String, CaseIterable { case size = "Size", lastUsed = "Last used" }
    var phase: Phase = .idle
    var files: [FileEntry] = []
    var selected: Set<URL> = []
    var minSizeMB = 100
    var sort: Sort = .size
    var kind = "All"
    var onlyStale = false
    var roots: [URL] = LargeFileScanner.defaultRoots
    let progress = ScanProgress()
    var summary = RemovalSummary()
    private var task: Task<Void, Never>?

    var kinds: [String] { ["All"] + Set(files.map(\.kind)).sorted() }

    var shown: [FileEntry] {
        var out = files
        if kind != "All" { out = out.filter { $0.kind == kind } }
        if onlyStale { out = out.filter { ($0.daysSinceUse ?? 0) > 180 } }
        switch sort {
        case .size: out.sort { $0.size > $1.size }
        case .lastUsed: out.sort { ($0.daysSinceUse ?? 0) > ($1.daysSinceUse ?? 0) }
        }
        return out
    }

    var selectedBytes: Int64 { files.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size } }

    func scan() {
        phase = .scanning
        let min = Int64(minSizeMB) * 1_000_000
        let roots = roots
        task = Task {
            let found = await LargeFileScanner.scan(roots: roots, minSize: min, progress: progress)
            guard !Task.isCancelled else { return }
            files = found; selected = []; kind = "All"
            phase = .results
        }
    }

    func cancel() { task?.cancel(); phase = .idle }

    func trashSelected() {
        let items = files.filter { selected.contains($0.url) }.map { ($0.url, $0.size) }
        phase = .working
        Task {
            summary = await Task.detached { Remover.execute(permanent: [], trash: items) }.value
            phase = .done
        }
    }

    func reset() { phase = .idle; files = []; selected = [] }
}

// MARK: - Duplicates

@MainActor @Observable final class DuplicatesModel {
    var phase: Phase = .idle
    var groups: [DuplicateGroup] = []
    var selected: Set<URL> = []
    var roots: [URL] = LargeFileScanner.defaultRoots
    let progress = ScanProgress()
    var summary = RemovalSummary()
    private var task: Task<Void, Never>?

    var reclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }
    var selectedBytes: Int64 { groups.flatMap(\.files).filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size } }

    func scan() {
        phase = .scanning
        let roots = roots
        task = Task {
            let g = await DuplicateScanner.scan(roots: roots, progress: progress)
            guard !Task.isCancelled else { return }
            groups = g
            autoSelect()
            phase = .results
        }
    }

    func cancel() { task?.cancel(); phase = .idle }

    /// Keeps the oldest copy in every group and selects the rest.
    func autoSelect() {
        selected = Set(groups.flatMap { $0.files.dropFirst() }.map(\.url))
    }

    /// A group must always keep at least one copy: refuse to select the last unselected file.
    func toggle(_ f: FileEntry, in g: DuplicateGroup) {
        if selected.contains(f.url) { selected.remove(f.url); return }
        let remaining = g.files.filter { !selected.contains($0.url) && $0.url != f.url }
        if !remaining.isEmpty { selected.insert(f.url) }
    }

    func trashSelected() {
        let items = groups.flatMap(\.files).filter { selected.contains($0.url) }.map { ($0.url, $0.size) }
        phase = .working
        Task {
            summary = await Task.detached { Remover.execute(permanent: [], trash: items) }.value
            phase = .done
        }
    }

    func reset() { phase = .idle; groups = []; selected = [] }
}

// MARK: - Space Lens

@MainActor @Observable final class SpaceLensModel {
    var phase: Phase = .idle
    var root: URL = FileManager.default.homeDirectoryForCurrentUser
    var tree: DiskNode?
    var current: DiskNode?
    var selection: DiskNode?
    /// Bumped whenever the (non-observable) tree is mutated so views redraw.
    var revision = 0
    let progress = ScanProgress()
    var message: String?
    private var task: Task<Void, Never>?

    func scan(_ url: URL? = nil) {
        if let url { root = url }
        phase = .scanning
        message = nil
        let root = root
        task = Task {
            let node = await SpaceLensScanner.scan(root: root, progress: progress)
            guard !Task.isCancelled else { return }
            tree = node; current = node; selection = nil
            phase = .results
        }
    }

    func cancel() { task?.cancel(); phase = .idle }

    func drill(_ node: DiskNode) {
        guard node.canDrill else { return }
        current = node; selection = nil
    }

    func up() {
        if let p = current?.parent { current = p; selection = nil }
    }

    func trash(_ node: DiskNode) {
        guard !node.isOther else { return }
        let report = Remover.remove([node.url], mode: .trash, sizes: [node.url: node.size])
        if report.removed == 1 {
            var p = node.parent
            while let q = p { q.size -= node.size; p = q.parent }
            node.parent?.children.removeAll { $0 === node }
            if selection === node { selection = nil }
            message = "Moved \(node.name) to the Trash (\(Bytes.string(node.size)))"
            revision += 1
        } else {
            message = report.failures.first.map { "Couldn't remove \(node.name): \($0.reason)" }
        }
    }

    func reset() { phase = .idle; tree = nil; current = nil; selection = nil }
}

// MARK: - Apps

@MainActor @Observable final class AppsModel {
    enum Tab: String, CaseIterable { case apps = "Applications", leftovers = "Leftovers" }
    enum Sort: String, CaseIterable { case size = "Size", name = "Name", lastUsed = "Last used" }

    var tab: Tab = .apps
    var apps: [AppInfo] = []
    var loaded = false
    var loading = false
    var search = ""
    var sort: Sort = .size
    var chosen: AppInfo?
    var leftovers: [Leftover] = []
    var leftoverSelection: Set<URL> = []
    var loadingLeftovers = false

    var orphans: [Leftover] = []
    var orphanSelection: Set<URL> = []
    var orphansScanned = false
    var scanningOrphans = false

    var message: String?

    var shown: [AppInfo] {
        var out = apps
        if !search.isEmpty { out = out.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        switch sort {
        case .size: out.sort { $0.size > $1.size }
        case .name: out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .lastUsed: out.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
        return out
    }

    func load() {
        guard !loaded, !loading else { return }
        loading = true
        Task {
            apps = await AppScanner.scan()
            loaded = true; loading = false
        }
    }

    func choose(_ app: AppInfo) {
        chosen = app
        leftovers = []; leftoverSelection = []
        loadingLeftovers = true
        Task {
            let found = await LeftoverFinder.find(for: app)
            guard chosen == app else { return }
            leftovers = found
            leftoverSelection = Set(found.map(\.url))
            loadingLeftovers = false
        }
    }

    var uninstallBytes: Int64 {
        (chosen?.size ?? 0) + leftovers.filter { leftoverSelection.contains($0.url) }.reduce(0) { $0 + $1.size }
    }

    func uninstall() {
        guard let app = chosen, AppScanner.isUninstallable(app) else { return }
        if app.bundleID.map({ id in NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }) == false {
            message = "\(app.name) is running. Quit it first."
            return
        }
        let items = [(app.url, app.size)] + leftovers.filter { leftoverSelection.contains($0.url) }.map { ($0.url, $0.size) }
        Task {
            let s = await Task.detached { Remover.execute(permanent: [], trash: items) }.value
            message = s.failures.isEmpty ? "Uninstalled \(app.name). \(s.headline)." : "Some items couldn't be removed: \(s.failures.first ?? "")"
            apps.removeAll { $0 == app }
            chosen = nil
        }
    }

    func scanOrphans() {
        scanningOrphans = true
        Task {
            orphans = await LeftoverFinder.orphans()
            orphanSelection = []   // never pre-selected: these are heuristic matches
            orphansScanned = true; scanningOrphans = false
        }
    }

    func trashOrphans() {
        let items = orphans.filter { orphanSelection.contains($0.url) }.map { ($0.url, $0.size) }
        Task {
            let s = await Task.detached { Remover.execute(permanent: [], trash: items) }.value
            message = s.headline
            let gone = Set(items.map(\.0))
            orphans.removeAll { gone.contains($0.url) }
            orphanSelection = []
        }
    }
}

// MARK: - Startup & maintenance

@MainActor @Observable final class StartupModel {
    var items: [StartupItem] = []
    var loginItems: [String] = []
    var loaded = false
    var loading = false
    var message: String?

    func load() {
        guard !loading else { return }
        loading = true
        Task {
            async let agents = StartupScanner.scan()
            async let logins = Task.detached { StartupScanner.loginItems() }.value
            items = await agents
            loginItems = await logins
            loaded = true; loading = false
        }
    }

    func setEnabled(_ item: StartupItem, _ on: Bool) {
        Task {
            let ok = await Task.detached { StartupScanner.setEnabled(item, on) }.value
            if ok, let i = items.firstIndex(where: { $0.id == item.id }) { items[i].isLoaded = on }
            else if !ok { message = "Couldn't \(on ? "enable" : "disable") \(item.label)." }
        }
    }

    func remove(_ item: StartupItem) {
        guard item.isManageable else { return }
        Task {
            _ = await Task.detached { StartupScanner.setEnabled(item, false) }.value
            let r = await Task.detached { Remover.remove([item.plist], mode: .trash) }.value
            if r.removed == 1 { items.removeAll { $0.id == item.id } } else { message = "Couldn't remove \(item.label)." }
        }
    }

    func removeLogin(_ name: String) {
        Task {
            let ok = await Task.detached { StartupScanner.removeLoginItem(named: name) }.value
            if ok { loginItems.removeAll { $0 == name } } else { message = "Couldn't remove \(name). Allow Aether to control System Events in Privacy & Security." }
        }
    }
}

@MainActor @Observable final class MaintenanceModel {
    var running: String?
    var results: [String: (ok: Bool, message: String)] = [:]

    func run(_ task: Maintenance.Task) {
        running = task.id
        Task {
            let r = await Task.detached { Maintenance.run(task) }.value
            results[task.id] = r
            running = nil
        }
    }
}

// MARK: - Health

struct HealthIssue: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let severity: Int   // 1 minor, 2 notable, 3 serious
    let fix: Module?
}

@MainActor @Observable final class HealthModel {
    var snap = SystemSnapshot()
    var cpuHistory: [Double] = []
    var memHistory: [Double] = []
    var downHistory: [Double] = []
    var upHistory: [Double] = []
    var processes: [ProcessStat] = []
    private let sampler = SystemSampler()
    private var timer: Timer?
    private var ticks = 0
    private let historyLength = 60

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let s = sampler.sample()
        snap = s
        push(&cpuHistory, s.cpuTotal)
        push(&memHistory, s.memory.pressure)
        push(&downHistory, s.netDownBps)
        push(&upHistory, s.netUpBps)
        if ticks % 3 == 0 {
            Task {
                let p = await Task.detached { SystemSampler.topProcesses(limit: 8) }.value
                processes = p
            }
        }
        ticks += 1
    }

    private func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > historyLength { a.removeFirst(a.count - historyLength) }
    }

    func quitApp(pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    var issues: [HealthIssue] {
        var out: [HealthIssue] = []
        let d = snap.disk
        if d.total > 0 {
            if d.usedFraction > 0.9 {
                out.append(.init(title: "Disk is almost full", detail: "\(Bytes.string(d.available)) left. macOS slows down and can't update below about 10 GB.", severity: 3, fix: .junk))
            } else if d.usedFraction > 0.8 {
                out.append(.init(title: "Disk is getting full", detail: "\(Bytes.string(d.available)) free. Clearing junk keeps room for updates.", severity: 2, fix: .junk))
            }
        }
        let m = snap.memory
        if m.pressure > 0.9 {
            out.append(.init(title: "Memory is under heavy pressure", detail: "Quit the apps at the top of the list below.", severity: 3, fix: nil))
        } else if m.swapUsed > 4 << 30 {
            out.append(.init(title: "Heavy swap use", detail: "\(Bytes.string(Int64(m.swapUsed))) is swapped to disk. Too many apps for the RAM available.", severity: 2, fix: nil))
        }
        if let b = snap.battery, let h = b.healthPercent, h < 80 {
            out.append(.init(title: "Battery capacity is reduced", detail: "It holds \(h)% of its original charge (\(b.cycleCount ?? 0) cycles).", severity: 2, fix: nil))
        }
        if snap.thermal == .serious || snap.thermal == .critical {
            out.append(.init(title: "Mac is running hot", detail: "Performance is being throttled. Check what is using the CPU.", severity: 3, fix: nil))
        }
        if snap.uptime > 14 * 86400 {
            out.append(.init(title: "Not restarted in \(Int(snap.uptime / 86400)) days", detail: "A restart clears leaked memory and applies pending updates.", severity: 1, fix: nil))
        }
        return out.sorted { $0.severity > $1.severity }
    }

    var score: Int { max(0, 100 - issues.reduce(0) { $0 + [0, 6, 14, 26][$1.severity] }) }

    var verdict: String {
        switch score {
        case 90...: "Excellent"
        case 75..<90: "Good"
        case 55..<75: "Needs attention"
        default: "Poor"
        }
    }
}

// MARK: - Smart Scan

@MainActor @Observable final class SmartScanModel {
    enum Step: Int, CaseIterable {
        case junk, privacy, large, startup
        var title: String {
            switch self {
            case .junk: "Searching for junk"
            case .privacy: "Checking privacy traces"
            case .large: "Looking for large files"
            case .startup: "Reviewing startup items"
            }
        }
    }

    var phase: Phase = .idle
    var completed: Set<Step> = []
    var current: Step?
    var largeBytes: Int64 = 0
    var largeCount = 0
    var startupCount = 0
    var unsignedStartup = 0
    var summary: RemovalSummary?

    let junk: JunkModel, privacy: PrivacyModel, large: LargeFilesModel, startup: StartupModel
    let largeProgress = ScanProgress()
    var largePartial = false

    init(junk: JunkModel, privacy: PrivacyModel, large: LargeFilesModel, startup: StartupModel) {
        self.junk = junk; self.privacy = privacy; self.large = large; self.startup = startup
    }

    func run() {
        phase = .scanning; completed = []; summary = nil; largePartial = false
        largeProgress.reset()
        Task {
            current = .junk
            let r = await JunkScanner.scan()
            junk.results = r
            junk.selected = Set(r.filter { $0.category.risk == .safe }.flatMap(\.items).map(\.url))
            junk.focused = junk.visible.first?.category.id
            junk.phase = .results
            completed.insert(.junk)

            current = .privacy
            privacy.groups = await PrivacyScanner.scan()
            completed.insert(.privacy)

            current = .large
            // A big home folder can take many minutes to walk; Smart Scan gives it 45 seconds, or until Skip is pressed.
            let found = await LargeFileScanner.scan(roots: LargeFileScanner.defaultRoots, minSize: 500_000_000, progress: largeProgress, timeLimit: 45)
            largePartial = largeProgress.wasTruncated
            largeCount = found.count; largeBytes = found.reduce(0) { $0 + $1.size }
            completed.insert(.large)

            current = .startup
            let items = await StartupScanner.scan()
            startup.items = items; startup.loaded = true
            startupCount = items.filter { $0.kind == .userAgent && $0.runsAtLoad }.count
            unsignedStartup = items.filter { $0.signed == false }.count
            completed.insert(.startup)

            current = nil
            phase = .results
        }
    }

    func cleanSafe() {
        phase = .working
        let perm = junk.results.filter { $0.category.risk == .safe }.flatMap { r in r.items.map { ($0.url, $0.size) } }
        Task {
            summary = await Task.detached { Remover.execute(permanent: perm, trash: []) }.value
            junk.reset()
            phase = .done
        }
    }

    func reset() { phase = .idle }
}

// MARK: - Root state

@MainActor @Observable final class AppState {
    var selection: Module = .smartScan
    var hasFDA = Permissions.hasFullDiskAccess()
    var bannerDismissed = false

    let junk = JunkModel()
    let privacy = PrivacyModel()
    let large = LargeFilesModel()
    let dupes = DuplicatesModel()
    let lens = SpaceLensModel()
    let apps = AppsModel()
    let startup = StartupModel()
    let maintenance = MaintenanceModel()
    let health = HealthModel()
    let smart: SmartScanModel

    init() {
        smart = SmartScanModel(junk: junk, privacy: privacy, large: large, startup: startup)
        health.start()
    }

    func refreshPermissions() { hasFDA = Permissions.hasFullDiskAccess() }
}
