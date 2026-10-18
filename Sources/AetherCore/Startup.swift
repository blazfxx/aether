import Foundation

public struct StartupItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case userAgent = "User launch agent", systemAgent = "System launch agent", daemon = "System daemon" }

    public var id: URL { plist }
    public let plist: URL
    public let label: String
    public let program: String?
    public let kind: Kind
    public let runsAtLoad: Bool
    public var isLoaded: Bool
    public let signed: Bool?

    /// Only the user's own agents can be changed without administrator rights.
    public var isManageable: Bool { kind == .userAgent }
}

public enum StartupScanner {
    private static let uid = getuid()

    static var locations: [(URL, StartupItem.Kind)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            (home.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .systemAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemon),
        ]
    }

    public static func scan() async -> [StartupItem] {
        let loaded = loadedLabels()
        var jobs: [(URL, StartupItem.Kind)] = []
        for (dir, kind) in locations {
            for u in FileSizer.children(of: dir) where u.pathExtension == "plist" { jobs.append((u, kind)) }
        }
        let items = await boundedMap(jobs) { job -> StartupItem? in
            let (url, kind) = job
            guard let data = try? Data(contentsOf: url),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            let label = (dict["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
            let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
            return StartupItem(
                plist: url, label: label, program: program, kind: kind,
                runsAtLoad: (dict["RunAtLoad"] as? Bool) ?? false,
                isLoaded: loaded.contains(label),
                signed: program.map { isSigned($0) })
        }.compactMap { $0 }
        return items.sorted { ($0.kind == .userAgent ? 0 : 1, $0.label) < ($1.kind == .userAgent ? 0 : 1, $1.label) }
    }

    static func loadedLabels() -> Set<String> {
        guard let out = run("/bin/launchctl", ["list"]) else { return [] }
        var labels = Set<String>()
        for line in out.split(separator: "\n").dropFirst() {
            if let last = line.split(separator: "\t").last { labels.insert(String(last)) }
        }
        return labels
    }

    static func isSigned(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return runStatus("/usr/bin/codesign", ["--verify", path]) == 0
    }

    public static func setEnabled(_ item: StartupItem, _ enabled: Bool) -> Bool {
        guard item.isManageable else { return false }
        let domain = "gui/\(uid)"
        if enabled {
            return runStatus("/bin/launchctl", ["bootstrap", domain, item.plist.path]) == 0
        } else {
            return runStatus("/bin/launchctl", ["bootout", domain, item.plist.path]) == 0
        }
    }

    // MARK: Login items (System Events)

    public static func loginItems() -> [String] {
        let script = "tell application \"System Events\" to get the name of every login item"
        guard let out = run("/usr/bin/osascript", ["-e", script]) else { return [] }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public static func removeLoginItem(named name: String) -> Bool {
        // Escape for AppleScript string literal.
        let safe = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"System Events\" to delete login item \"\(safe)\""
        return runStatus("/usr/bin/osascript", ["-e", script]) == 0
    }
}

/// One-click maintenance routines. Fixed commands only: nothing user-supplied reaches a shell.
public enum Maintenance {
    public struct Task: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let detail: String
        public let symbol: String
        public let needsAdmin: Bool
        let command: String
    }

    public static let tasks: [Task] = [
        Task(id: "dns", title: "Flush DNS Cache", detail: "Clears cached hostnames. Fixes sites that won't resolve after a network change.",
             symbol: "network", needsAdmin: true,
             command: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"),
        Task(id: "spotlight", title: "Reindex Spotlight", detail: "Rebuilds the search index for the startup disk. Search is slow while it runs.",
             symbol: "magnifyingglass", needsAdmin: true,
             command: "/usr/bin/mdutil -E /"),
        Task(id: "launchservices", title: "Rebuild Launch Services", detail: "Fixes duplicate entries in 'Open With' and wrong default apps.",
             symbol: "square.stack.3d.up", needsAdmin: false,
             command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user"),
        Task(id: "purge", title: "Free Up Inactive Memory", detail: "Asks macOS to release purgeable memory. The system does this on its own, so expect a small effect.",
             symbol: "memorychip", needsAdmin: true,
             command: "/usr/sbin/purge"),
        Task(id: "quicklook", title: "Reset Quick Look Cache", detail: "Fixes stale or missing file previews.",
             symbol: "eye", needsAdmin: false,
             command: "/usr/bin/qlmanage -r cache"),
    ]

    public static func task(_ id: String) -> Task? { tasks.first { $0.id == id } }

    // MARK: Running

    public static func run(_ task: Task) -> (ok: Bool, message: String) {
        let result = task.needsAdmin ? runAsAdmin(task.command) : runPlain(task.command)
        if result.ok { recordRun(task.id) }
        return result
    }

    /// Runs several tasks. Everything that needs administrator rights is combined so the password is asked for once.
    public static func runMany(_ tasks: [Task]) -> [String: (ok: Bool, message: String)] {
        var results: [String: (ok: Bool, message: String)] = [:]
        for t in tasks where !t.needsAdmin { results[t.id] = run(t) }
        let admin = tasks.filter(\.needsAdmin)
        if !admin.isEmpty {
            let r = runAsAdmin(admin.map(\.command).joined(separator: "; "))
            for t in admin { results[t.id] = r; if r.ok { recordRun(t.id) } }
        }
        return results
    }

    private static func runAsAdmin(_ command: String) -> (ok: Bool, message: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let (code, out) = runCapture("/usr/bin/osascript", ["-e", script])
        if code == 0 { return (true, "Done") }
        return (false, out.contains("-128") ? "Cancelled" : "Failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    private static func runPlain(_ command: String) -> (ok: Bool, message: String) {
        let (code, out) = runCapture("/bin/sh", ["-c", command])
        return (code == 0, code == 0 ? "Done" : "Failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    // MARK: History

    private static func key(_ id: String) -> String { "aether.maintenance.lastRun.\(id)" }
    public static func lastRun(_ id: String) -> Date? { UserDefaults.standard.object(forKey: key(id)) as? Date }
    static func recordRun(_ id: String) { UserDefaults.standard.set(Date(), forKey: key(id)) }
}

// MARK: - What actually needs doing

public struct MaintenanceAdvice: Identifiable, Sendable {
    public var id: String { task.id }
    public let task: Maintenance.Task
    /// Plain-language evidence for why this is recommended.
    public let reason: String
}

/// Recommends maintenance only when there is evidence it will help, never on a schedule.
/// Rebuilding Launch Services and resetting Quick Look have no cheap test, so they are never suggested automatically.
public enum MaintenanceAdvisor {
    public static let slowDNSSeconds = 1.5
    public static let heavyMemoryPressure = 0.85

    public static func recommend(memoryPressure: Double) async -> [MaintenanceAdvice] {
        async let dns = Task.detached { dnsLookupSeconds() }.value
        async let spotlight = Task.detached { spotlightProblem() }.value
        var out: [MaintenanceAdvice] = []

        if let t = Maintenance.task("dns"), let seconds = await dns, seconds > slowDNSSeconds {
            out.append(.init(task: t, reason: "Looking up a website took \(String(format: "%.1f", seconds)) seconds."))
        }
        if let t = Maintenance.task("spotlight"), let problem = await spotlight {
            out.append(.init(task: t, reason: problem))
        }
        if let t = purgeAdvice(memoryPressure: memoryPressure) { out.append(t) }
        return out
    }

    static func purgeAdvice(memoryPressure: Double) -> MaintenanceAdvice? {
        guard memoryPressure >= heavyMemoryPressure, let t = Maintenance.task("purge") else { return nil }
        return .init(task: t, reason: "Memory is \(Int(memoryPressure * 100))% in use.")
    }

    /// Seconds a DNS lookup took, or nil if it failed (offline: flushing the cache would not help).
    static func dnsLookupSeconds(host: String = "www.apple.com", giveUpAfter: TimeInterval = 4) -> Double? {
        let start = Date()
        let done = DispatchSemaphore(value: 0)
        let box = LookupBox()
        DispatchQueue.global(qos: .utility).async {
            var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &res)
            if res != nil { freeaddrinfo(res) }
            box.ok = status == 0
            done.signal()
        }
        if done.wait(timeout: .now() + giveUpAfter) == .timedOut { return giveUpAfter }
        return box.ok ? Date().timeIntervalSince(start) : nil
    }

    private final class LookupBox: @unchecked Sendable { var ok = false }

    static func spotlightProblem() -> String? {
        let (c1, count) = runCapture("/usr/bin/mdfind", ["-count", "-onlyin", "/Applications", "kMDItemContentType == 'com.apple.application-bundle'"])
        guard c1 == 0, let n = Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        guard n == 0 else { return spotlightVerdict(appCount: n, volumeStatus: nil) }
        // `/` is the sealed system volume (indexing is always off there). Your files live on the Data volume.
        let volume = FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/"
        let (c2, status) = runCapture("/usr/bin/mdutil", ["-s", volume])
        return spotlightVerdict(appCount: n, volumeStatus: c2 == 0 ? status : nil)
    }

    /// Spotlight is only worth reindexing when it is switched on yet can't find a single app. If indexing is
    /// off on purpose, a reindex wouldn't change that, so nothing is suggested.
    static func spotlightVerdict(appCount: Int?, volumeStatus: String?) -> String? {
        guard appCount == 0, let status = volumeStatus?.lowercased() else { return nil }
        if status.contains("indexing disabled") { return nil }
        return "Spotlight can't find any of your apps."
    }
}

// MARK: - Process helpers

@discardableResult
func runCapture(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func run(_ exe: String, _ args: [String]) -> String? {
    let (code, out) = runCapture(exe, args)
    return code == 0 ? out : nil
}

func runStatus(_ exe: String, _ args: [String]) -> Int32 {
    runCapture(exe, args).0
}
