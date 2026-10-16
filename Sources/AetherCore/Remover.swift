import Foundation

public struct RemovalReport: Sendable {
    public var freed: Int64 = 0
    public var removed = 0
    public var failures: [(url: URL, reason: String)] = []
    public init() {}
}

public struct RemovalSummary: Sendable {
    /// Bytes actually returned to the disk (permanent deletions).
    public var freed: Int64 = 0
    /// Bytes moved to the Trash: recoverable, and not free until the Trash is emptied.
    public var trashed: Int64 = 0
    public var count = 0
    public var failures: [String] = []
    public init() {}

    public var headline: String {
        switch (freed > 0, trashed > 0) {
        case (true, true): return "Freed \(Bytes.string(freed)) and moved \(Bytes.string(trashed)) to the Trash"
        case (true, false): return "Freed \(Bytes.string(freed))"
        case (false, true): return "Moved \(Bytes.string(trashed)) to the Trash"
        default: return count == 0 ? "Nothing was removed" : "Done"
        }
    }
}

extension Remover {
    /// Removes permanent-mode and trash-mode items together and summarises the result.
    public static func execute(permanent: [(url: URL, size: Int64)], trash: [(url: URL, size: Int64)]) -> RemovalSummary {
        var s = RemovalSummary()
        let p = remove(permanent.map(\.url), mode: .permanent, sizes: Dictionary(permanent.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a }))
        let t = remove(trash.map(\.url), mode: .trash, sizes: Dictionary(trash.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a }))
        s.freed = p.freed
        s.trashed = t.freed
        s.count = p.removed + t.removed
        s.failures = (p.failures + t.failures).map { "\($0.url.lastPathComponent): \($0.reason)" }
        return s
    }
}

/// The only code path in Aether that deletes anything. Everything funnels through `isRemovable`.
public enum Remover {
    public enum Mode: Sendable {
        /// Recoverable: moves to the Trash. Space is not freed until the Trash is emptied.
        case trash
        /// Immediate. Used only for regenerable data (caches, logs) and the Trash itself.
        case permanent
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    private static var allowedRoots: [String] { [home + "/", "/Applications/"] }

    /// Locations that may never be removed themselves, only things inside them.
    private static var protectedExact: Set<String> {
        var s: Set<String> = [home, "/Applications", "/Applications/Utilities"]
        for d in ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures",
                  "Public", "Applications", ".Trash", "Library/Application Support", "Library/Caches",
                  "Library/Preferences", "Library/Containers", "Library/Group Containers", "Library/Logs",
                  "Library/Mobile Documents", "Library/Keychains", "Library/Mail", "Library/Messages",
                  "Library/Safari", "Library/Developer", "Library/LaunchAgents"] {
            s.insert(home + "/" + d)
        }
        return s
    }

    public static func isRemovable(_ url: URL) -> Bool {
        let std = url.standardizedFileURL
        // Resolve symlinks in the *parent* so a link can't smuggle us outside the allowed roots,
        // while a symlink item itself is removed as a link (never followed).
        let parent = std.deletingLastPathComponent().resolvingSymlinksInPath()
        let resolved = parent.appendingPathComponent(std.lastPathComponent).path
        guard allowedRoots.contains(where: { resolved.hasPrefix($0) }) else { return false }
        guard !protectedExact.contains(resolved) else { return false }
        guard !std.lastPathComponent.isEmpty, std.lastPathComponent != ".", std.lastPathComponent != ".." else { return false }
        return true
    }

    @discardableResult
    public static func remove(_ urls: [URL], mode: Mode, sizes: [URL: Int64] = [:]) -> RemovalReport {
        var report = RemovalReport()
        let fm = FileManager.default
        for url in urls {
            guard isRemovable(url) else {
                report.failures.append((url, "Protected location"))
                continue
            }
            guard fm.fileExists(atPath: url.path) || (try? url.checkResourceIsReachable()) == true
                    || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else {
                continue
            }
            let size = sizes[url] ?? FileSizer.allocatedSize(of: url)
            do {
                switch mode {
                case .trash: try fm.trashItem(at: url, resultingItemURL: nil)
                case .permanent: try fm.removeItem(at: url)
                }
                report.freed += size
                report.removed += 1
            } catch {
                report.failures.append((url, (error as NSError).localizedDescription))
            }
        }
        return report
    }
}
