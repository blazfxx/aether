import AppKit
import Foundation
import CoreServices

public struct AppInfo: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let bundleID: String?
    public let version: String?
    public let size: Int64
    public let lastUsed: Date?
    public let fromAppStore: Bool

    public var monthsUnused: Int? {
        guard let d = lastUsed else { return nil }
        return Calendar.current.dateComponents([.month], from: d, to: Date()).month
    }
}

public struct Leftover: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
}

public enum AppScanner {
    public static let searchDirs: [URL] = {
        let fm = FileManager.default
        return [URL(fileURLWithPath: "/Applications"),
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }()

    /// Finds `.app` bundles, descending one level into plain folders (e.g. /Applications/Utilities).
    public static func appURLs() -> [URL] {
        var out: [URL] = []
        for dir in searchDirs {
            for u in FileSizer.children(of: dir) {
                if u.pathExtension == "app" { out.append(u); continue }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                    out.append(contentsOf: FileSizer.children(of: u).filter { $0.pathExtension == "app" })
                }
            }
        }
        return out
    }

    public static func scan() async -> [AppInfo] {
        await boundedMap(appURLs()) { url -> AppInfo? in
            let bundle = Bundle(url: url)
            let info = bundle?.infoDictionary ?? [:]
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let used = MDItemCreateWithURL(nil, url as CFURL)
                .flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
            return AppInfo(
                url: url, name: name, bundleID: bundle?.bundleIdentifier,
                version: info["CFBundleShortVersionString"] as? String,
                size: FileSizer.allocatedSize(of: url), lastUsed: used,
                fromAppStore: FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt").path))
        }.compactMap { $0 }.sorted { $0.size > $1.size }
    }

    /// Apple's own apps and Aether itself can't be uninstalled from here.
    public static func isUninstallable(_ app: AppInfo) -> Bool {
        if let id = app.bundleID, id.hasPrefix("com.apple.") { return false }
        if app.bundleID == Bundle.main.bundleIdentifier { return false }
        return Remover.isRemovable(app.url)
    }
}

public enum LeftoverFinder {
    private static let lib = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")

    /// Folders under ~/Library where apps leave data keyed by bundle ID.
    static let idKeyed = ["Application Support", "Caches", "Containers", "Group Containers", "Saved Application State",
                          "Logs", "HTTPStorages", "WebKit", "Cookies", "LaunchAgents", "Application Scripts"]

    /// Leftovers belonging to a specific app.
    public static func find(for app: AppInfo) async -> [Leftover] {
        guard let bid = app.bundleID, bid.split(separator: ".").count >= 2, !bid.hasPrefix("com.apple.") else { return [] }
        let nameKeyed = app.name.count >= 4 ? app.name : nil
        var hits: [URL] = []
        for sub in idKeyed + ["Preferences", "Preferences/ByHost"] {
            let dir = lib.appendingPathComponent(sub)
            for u in FileSizer.children(of: dir) {
                let n = u.lastPathComponent
                let stem = n.hasSuffix(".plist") ? String(n.dropLast(6)) : (n.hasSuffix(".savedState") ? String(n.dropLast(11)) : n)
                let idMatch = stem == bid || stem.hasPrefix(bid + ".")
                    || (sub == "Group Containers" && (n.hasSuffix("." + bid) || n.contains("." + bid + ".")))
                let nameMatch = nameKeyed != nil && ["Application Support", "Caches", "Logs"].contains(sub) && n == nameKeyed
                if idMatch || nameMatch { hits.append(u) }
            }
        }
        return await sized(hits)
    }

    /// Bundle IDs of every app we can find, including ones currently running.
    static func installedIDs() -> Set<String> {
        var ids = Set<String>()
        for u in AppScanner.appURLs() { if let id = Bundle(url: u)?.bundleIdentifier { ids.insert(id) } }
        for u in FileSizer.children(of: URL(fileURLWithPath: "/System/Applications")) {
            if let id = Bundle(url: u)?.bundleIdentifier { ids.insert(id) }
        }
        for app in NSWorkspace.shared.runningApplications { if let id = app.bundleIdentifier { ids.insert(id) } }
        return ids
    }

    /// Data left behind by apps that no longer exist. Deliberately conservative: only reverse-DNS names that
    /// match no installed or running bundle ID (exactly, or as a dotted prefix in either direction), never `com.apple.*`.
    public static func orphans() async -> [Leftover] {
        let installed = installedIDs()
        let pattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9_-]+){2,}$")
        var hits: [URL] = []
        for sub in ["Application Support", "Caches", "Preferences", "Saved Application State", "HTTPStorages", "WebKit", "Containers"] {
            for u in FileSizer.children(of: lib.appendingPathComponent(sub)) {
                let n = u.lastPathComponent
                var stem = n
                for ext in [".plist", ".savedState"] where stem.hasSuffix(ext) { stem = String(stem.dropLast(ext.count)) }
                let range = NSRange(stem.startIndex..., in: stem)
                guard pattern.firstMatch(in: stem, range: range) != nil else { continue }
                if stem.hasPrefix("com.apple.") || stem.hasPrefix("group.com.apple") { continue }
                let owned = installed.contains { stem == $0 || stem.hasPrefix($0 + ".") || $0.hasPrefix(stem + ".") }
                if !owned { hits.append(u) }
            }
        }
        return await sized(hits)
    }

    private static func sized(_ urls: [URL]) async -> [Leftover] {
        await boundedMap(urls) { u -> Leftover? in
            let s = FileSizer.allocatedSize(of: u)
            return s > 0 ? Leftover(url: u, size: s) : nil
        }.compactMap { $0 }.sorted { $0.size > $1.size }
    }
}
