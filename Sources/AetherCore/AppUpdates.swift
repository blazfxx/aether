import Foundation

public struct AppUpdate: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case appStore(trackID: Int)
        case sparkle(download: URL?)
    }

    public var id: URL { app.url }
    public let app: AppInfo
    public let installed: String
    public let latest: String
    public let source: Source

    /// Where the "Update" button sends you: the App Store page, or the vendor's download.
    public var openURL: URL? {
        switch source {
        case .appStore(let id): return URL(string: "macappstore://apps.apple.com/app/id\(id)")
        case .sparkle(let download): return download
        }
    }

    public var sourceName: String {
        switch source {
        case .appStore: return "App Store"
        case .sparkle: return "Developer"
        }
    }
}

/// Looks for newer versions of installed apps. Each check is a plain GET to the same place the app's own updater
/// asks (Apple's lookup service, or the app's published Sparkle feed). Nothing about your files is sent.
public enum AppUpdateChecker {
    public static func check(_ apps: [AppInfo]) async -> [AppUpdate] {
        let candidates = apps.filter { a in
            guard let id = a.bundleID else { return false }
            return !id.hasPrefix("com.apple.") && id != UpdateInstaller.bundleID
        }
        let found = await boundedMap(candidates, limit: 6) { app -> AppUpdate? in
            if Task.isCancelled { return nil }
            if app.fromAppStore { return await appStoreUpdate(for: app) }
            return await sparkleUpdate(for: app)
        }
        return found.compactMap { $0 }.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 15
        c.httpCookieStorage = nil
        c.httpAdditionalHeaders = ["User-Agent": "Aether-Updater"]
        return URLSession(configuration: c)
    }

    // MARK: Mac App Store

    static func lookupURL(bundleID: String, country: String) -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/lookup")
        c?.queryItems = [.init(name: "bundleId", value: bundleID), .init(name: "country", value: country), .init(name: "entity", value: "macSoftware")]
        return c?.url
    }

    static func parseLookup(_ data: Data) -> (version: String, trackID: Int)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let version = first["version"] as? String,
              let id = first["trackId"] as? Int else { return nil }
        return (version, id)
    }

    private static func appStoreUpdate(for app: AppInfo) async -> AppUpdate? {
        guard let bid = app.bundleID, let installed = app.version, AppVersion(installed).isValid else { return nil }
        let country = Locale.current.region?.identifier.lowercased() ?? "us"
        guard let url = lookupURL(bundleID: bid, country: country),
              let (data, _) = try? await session().data(from: url),
              let latest = parseLookup(data), AppVersion(latest.version) > AppVersion(installed) else { return nil }
        return AppUpdate(app: app, installed: installed, latest: latest.version, source: .appStore(trackID: latest.trackID))
    }

    // MARK: Sparkle

    struct AppcastItem: Equatable {
        var title = ""
        var version: String?          // sparkle:version (build)
        var shortVersion: String?     // sparkle:shortVersionString
        var download: URL?
        var channel: String?
        var minimumSystem: String?
    }

    /// The newest stable item this Mac can run, or nil.
    static func newest(in items: [AppcastItem], osVersion: AppVersion) -> AppcastItem? {
        items
            .filter { $0.channel == nil }
            .filter { item in item.minimumSystem.map { AppVersion($0) <= osVersion } ?? true }
            .filter { ($0.shortVersion ?? $0.version).map { AppVersion($0).isValid } ?? false }
            .max { AppVersion(($0.shortVersion ?? $0.version)!) < AppVersion(($1.shortVersion ?? $1.version)!) }
    }

    static func parseAppcast(_ data: Data) -> [AppcastItem] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    private static func sparkleUpdate(for app: AppInfo) async -> AppUpdate? {
        guard let info = Bundle(url: app.url)?.infoDictionary,
              let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)),
              feed.scheme == "https",
              let (data, response) = try? await session().data(from: feed),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard let item = newest(in: parseAppcast(data), osVersion: AppVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")) else { return nil }

        let installedShort = info["CFBundleShortVersionString"] as? String
        let installedBuild = info["CFBundleVersion"] as? String
        let newer: Bool
        let latestLabel: String
        if let s = item.shortVersion, let installedShort {
            newer = AppVersion(s) > AppVersion(installedShort); latestLabel = s
        } else if let b = item.version, let installedBuild {
            newer = AppVersion(b) > AppVersion(installedBuild); latestLabel = b
        } else { return nil }
        guard newer else { return nil }
        return AppUpdate(app: app, installed: installedShort ?? installedBuild ?? "?", latest: latestLabel, source: .sparkle(download: item.download))
    }
}

private final class AppcastParser: NSObject, XMLParserDelegate {
    var items: [AppUpdateChecker.AppcastItem] = []
    private var current: AppUpdateChecker.AppcastItem?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "item" { current = .init() }
        guard current != nil else { return }
        if name == "enclosure" {
            if let u = attributes["url"].flatMap(URL.init(string:)), u.scheme == "https" { current?.download = u }
            if let v = attributes["sparkle:version"] { current?.version = v }
            if let v = attributes["sparkle:shortVersionString"] { current?.shortVersion = v }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard current != nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": if current?.title.isEmpty == true { current?.title = value }
        case "sparkle:version": if !value.isEmpty { current?.version = value }
        case "sparkle:shortVersionString": if !value.isEmpty { current?.shortVersion = value }
        case "sparkle:channel": if !value.isEmpty { current?.channel = value }
        case "sparkle:minimumSystemVersion": if !value.isEmpty { current?.minimumSystem = value }
        case "item":
            if let c = current { items.append(c) }
            current = nil
        default: break
        }
        text = ""
    }
}
