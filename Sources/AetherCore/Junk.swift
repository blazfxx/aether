import AppKit
import Foundation

public enum Risk: Int, Sendable {
    /// Regenerates on its own; selected by default.
    case safe
    /// Probably fine, but the user should look first; unselected by default.
    case review
}

public struct JunkCategory: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let blurb: String
    public let risk: Risk
    public let mode: Remover.Mode
    /// Needs Full Disk Access to read on current macOS.
    public let needsFullDiskAccess: Bool
    let locate: @Sendable () -> [URL]
}

public struct JunkItem: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public let modified: Date?
}

public struct JunkResult: Identifiable, Sendable {
    public var id: String { category.id }
    public let category: JunkCategory
    public let items: [JunkItem]
    public var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

public enum JunkCatalog {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static func lib(_ p: String) -> URL { home.appendingPathComponent("Library/" + p) }
    static func h(_ p: String) -> URL { home.appendingPathComponent(p) }

    /// Apple cache folders that are safe and worth clearing; the rest of `com.apple.*` is left alone.
    private static let appleCacheAllowlist: Set<String> = [
        "com.apple.dt.Xcode", "com.apple.python", "com.apple.helpd", "com.apple.Safari.SafeBrowsing",
    ]
    private static let cacheDenylist: Set<String> = ["CloudKit", "FamilyCircle", "GeoServices", "Metadata"]

    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    static func userCaches() -> [URL] {
        let running = runningBundleIDs()
        return FileSizer.children(of: lib("Caches")).filter { u in
            let n = u.lastPathComponent
            if n.hasPrefix(".") || cacheDenylist.contains(n) { return false }
            if n.hasPrefix("com.apple.") && !appleCacheAllowlist.contains(n) { return false }
            return !running.contains(n)
        }
    }

    static func filesIn(_ dir: URL, extensions: Set<String>) -> [URL] {
        FileSizer.children(of: dir).filter { extensions.contains($0.pathExtension.lowercased()) }
    }

    public static let all: [JunkCategory] = [
        JunkCategory(
            id: "caches", title: "User Cache Files", symbol: "internaldrive",
            blurb: "App caches that rebuild themselves. Apps that are open are skipped.",
            risk: .safe, mode: .permanent, needsFullDiskAccess: false,
            locate: { userCaches() }),
        JunkCategory(
            id: "logs", title: "Log Files", symbol: "doc.text",
            blurb: "Old application logs.",
            risk: .safe, mode: .permanent, needsFullDiskAccess: false,
            locate: { FileSizer.children(of: lib("Logs")).filter { $0.lastPathComponent != "DiagnosticReports" } }),
        JunkCategory(
            id: "crashes", title: "Crash Reports", symbol: "exclamationmark.triangle",
            blurb: "Diagnostic reports from crashed apps.",
            risk: .safe, mode: .permanent, needsFullDiskAccess: false,
            locate: { FileSizer.children(of: lib("Logs/DiagnosticReports")) }),
        JunkCategory(
            id: "xcode", title: "Xcode Derived Data", symbol: "hammer",
            blurb: "Build products and indexes. Xcode recreates them on the next build.",
            risk: .safe, mode: .permanent, needsFullDiskAccess: false,
            locate: { FileSizer.children(of: lib("Developer/Xcode/DerivedData")) + FileSizer.children(of: lib("Developer/CoreSimulator/Caches")) }),
        JunkCategory(
            id: "devcaches", title: "Developer Tool Caches", symbol: "terminal",
            blurb: "npm, Gradle and Cargo download caches. Re-downloaded when needed.",
            risk: .safe, mode: .permanent, needsFullDiskAccess: false,
            locate: {
                [h(".npm/_cacache"), h(".gradle/caches")].filter { FileManager.default.fileExists(atPath: $0.path) }
                    + FileSizer.children(of: h(".cargo/registry/cache"))
            }),
        JunkCategory(
            id: "trash", title: "Trash", symbol: "trash",
            blurb: "Everything currently in your Trash.",
            risk: .safe, mode: .permanent, needsFullDiskAccess: true,
            locate: { FileSizer.children(of: h(".Trash")) }),
        JunkCategory(
            id: "installers", title: "Old Installers", symbol: "shippingbox",
            blurb: "Disk images and installer packages sitting in Downloads.",
            risk: .review, mode: .trash, needsFullDiskAccess: false,
            locate: { filesIn(h("Downloads"), extensions: ["dmg", "pkg", "iso", "xip"]) }),
        JunkCategory(
            id: "mail", title: "Mail Downloads", symbol: "envelope",
            blurb: "Attachments Mail saved to disk. They stay on the server.",
            risk: .review, mode: .trash, needsFullDiskAccess: true,
            locate: { FileSizer.children(of: lib("Containers/com.apple.mail/Data/Library/Mail Downloads")) }),
        JunkCategory(
            id: "xcode-archives", title: "Xcode Archives & Device Support", symbol: "archivebox",
            blurb: "Old app archives and iOS debug symbols. Device support re-downloads when you plug a device in.",
            risk: .review, mode: .trash, needsFullDiskAccess: false,
            locate: {
                FileSizer.children(of: lib("Developer/Xcode/iOS DeviceSupport"))
                    + FileSizer.children(of: lib("Developer/Xcode/watchOS DeviceSupport"))
                    + FileSizer.children(of: lib("Developer/Xcode/Archives"))
            }),
        JunkCategory(
            id: "dotcache", title: "~/.cache", symbol: "folder.badge.gearshape",
            blurb: "Tool caches such as pip and model downloads. Check before removing: some are large downloads.",
            risk: .review, mode: .trash, needsFullDiskAccess: false,
            locate: { FileSizer.children(of: h(".cache")) }),
        JunkCategory(
            id: "ios-backups", title: "iPhone & iPad Backups", symbol: "iphone",
            blurb: "Local device backups. Deleting one is permanent unless it is also in iCloud.",
            risk: .review, mode: .trash, needsFullDiskAccess: true,
            locate: { FileSizer.children(of: lib("Application Support/MobileSync/Backup")) }),
    ]
}

public enum JunkScanner {
    /// Scans the given categories. Missing folders and unreadable (FDA-protected) locations yield empty results.
    public static func scan(
        _ categories: [JunkCategory] = JunkCatalog.all,
        onCategory: (@Sendable (String) -> Void)? = nil
    ) async -> [JunkResult] {
        let results = await boundedMap(categories, limit: 4) { cat -> JunkResult in
            onCategory?(cat.title)
            let urls = cat.locate()
            let items = await boundedMap(urls) { url -> JunkItem? in
                if Task.isCancelled { return nil }
                let size = FileSizer.allocatedSize(of: url)
                guard size > 0 else { return nil }
                return JunkItem(url: url, size: size, modified: FileSizer.modified(url))
            }.compactMap { $0 }.sorted { $0.size > $1.size }
            return JunkResult(category: cat, items: items)
        }
        let order = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($1.id, $0) })
        return results.sorted { order[$0.category.id]! < order[$1.category.id]! }
    }
}
