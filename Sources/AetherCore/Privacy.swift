import AppKit
import Foundation

public struct PrivacyItem: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
}

public struct PrivacyGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let items: [PrivacyItem]
    /// Bundle ID of a browser that must be closed first, if it is currently running.
    public let blockedBy: String?
    public let blockedByName: String?
    public var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

public enum PrivacyScanner {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static func lib(_ p: String) -> URL { home.appendingPathComponent("Library/" + p) }

    private struct Browser {
        let id: String, name: String, symbol: String, bundleID: String
        let paths: [URL]
    }

    private static func chromiumPaths(_ vendor: String) -> [URL] {
        let base = lib("Application Support/\(vendor)")
        var profiles = FileSizer.children(of: base).filter {
            let n = $0.lastPathComponent
            return n == "Default" || n.hasPrefix("Profile ")
        }
        if profiles.isEmpty { profiles = [base.appendingPathComponent("Default")] }
        let names = ["History", "History-journal", "Cookies", "Cookies-journal", "Visited Links", "Top Sites", "Network Action Predictor"]
        return profiles.flatMap { p in names.map { p.appendingPathComponent($0) } }
    }

    private static var browsers: [Browser] {
        let ffProfiles = FileSizer.children(of: lib("Application Support/Firefox/Profiles"))
        let ffFiles = ffProfiles.flatMap { p in ["places.sqlite", "cookies.sqlite", "formhistory.sqlite"].map { p.appendingPathComponent($0) } }
        return [
            Browser(id: "safari", name: "Safari", symbol: "safari", bundleID: "com.apple.Safari", paths: [
                lib("Safari/History.db"), lib("Safari/History.db-wal"), lib("Safari/History.db-shm"),
                lib("Cookies/Cookies.binarycookies"), lib("Caches/com.apple.Safari"),
            ]),
            Browser(id: "chrome", name: "Google Chrome", symbol: "globe", bundleID: "com.google.Chrome",
                    paths: chromiumPaths("Google/Chrome") + [lib("Caches/Google/Chrome")]),
            Browser(id: "edge", name: "Microsoft Edge", symbol: "globe", bundleID: "com.microsoft.edgemac",
                    paths: chromiumPaths("Microsoft Edge") + [lib("Caches/Microsoft Edge")]),
            Browser(id: "brave", name: "Brave", symbol: "globe", bundleID: "com.brave.Browser",
                    paths: chromiumPaths("BraveSoftware/Brave-Browser") + [lib("Caches/BraveSoftware")]),
            Browser(id: "arc", name: "Arc", symbol: "globe", bundleID: "company.thebrowser.Browser",
                    paths: chromiumPaths("Arc/User Data") + [lib("Caches/company.thebrowser.Browser")]),
            Browser(id: "firefox", name: "Firefox", symbol: "flame", bundleID: "org.mozilla.firefox",
                    paths: ffFiles + [lib("Caches/Firefox")]),
        ]
    }

    public static func scan() async -> [PrivacyGroup] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var groups: [PrivacyGroup] = []

        for b in browsers {
            let existing = b.paths.filter { FileManager.default.fileExists(atPath: $0.path) }
            let items = await boundedMap(existing) { u -> PrivacyItem? in
                let s = FileSizer.allocatedSize(of: u)
                return s > 0 ? PrivacyItem(url: u, size: s) : nil
            }.compactMap { $0 }.sorted { $0.size > $1.size }
            guard !items.isEmpty else { continue }
            groups.append(PrivacyGroup(id: b.id, title: "\(b.name) history, cookies & cache", symbol: b.symbol, items: items,
                                       blockedBy: running.contains(b.bundleID) ? b.bundleID : nil,
                                       blockedByName: b.name))
        }

        let system: [URL] = [
            lib("Preferences/com.apple.LaunchServices.QuarantineEventsV2"),
            lib("Application Support/com.apple.sharedfilelist"),
            home.appendingPathComponent(".zsh_history"),
            home.appendingPathComponent(".bash_history"),
            home.appendingPathComponent(".lesshst"),
            home.appendingPathComponent(".python_history"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        let sysItems = await boundedMap(system) { u -> PrivacyItem? in
            let s = FileSizer.allocatedSize(of: u)
            return s > 0 ? PrivacyItem(url: u, size: s) : nil
        }.compactMap { $0 }.sorted { $0.size > $1.size }
        if !sysItems.isEmpty {
            groups.append(PrivacyGroup(id: "system", title: "Recent items & shell history", symbol: "clock.arrow.circlepath",
                                       items: sysItems, blockedBy: nil, blockedByName: nil))
        }
        return groups
    }
}
