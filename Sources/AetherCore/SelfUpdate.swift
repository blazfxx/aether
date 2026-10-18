import CryptoKit
import Foundation

public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let zipURL: URL
    public let zipName: String
    /// `<zip>.sha256` if the release published one.
    public let checksumURL: URL?
    public let pageURL: URL
    public let notes: String
}

public enum UpdateError: LocalizedError {
    case network(String)
    case badFeed
    case checksumMismatch
    case badArchive
    case wrongApp
    case versionMismatch(expected: String, found: String)
    case badSignature
    case cannotInstallHere

    public var errorDescription: String? {
        switch self {
        case .network(let m): return "Couldn't reach the update server (\(m))."
        case .badFeed: return "The update server sent something unexpected."
        case .checksumMismatch: return "The download didn't match its checksum, so it was discarded."
        case .badArchive: return "The update archive couldn't be opened."
        case .wrongApp: return "The download isn't Aether, so it was discarded."
        case .versionMismatch(let e, let f): return "Expected version \(e) but the download is \(f)."
        case .badSignature: return "The download's code signature is invalid, so it was discarded."
        case .cannotInstallHere: return "This copy of Aether can't replace itself. Install the new version by hand."
        }
    }
}

/// Where releases come from. Only ever downloads: nothing about your files or your Mac is sent.
public enum ReleaseFeed {
    public static let owner = "blazfxx"
    public static let repo = "aether"
    public static var latestURL: URL { URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")! }

    /// The newest *published, non-prerelease* release that has a macOS zip, or nil.
    public static func parse(_ data: Data) throws -> ReleaseInfo? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { throw UpdateError.badFeed }
        if (json["draft"] as? Bool) == true || (json["prerelease"] as? Bool) == true { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        func asset(_ pred: (String) -> Bool) -> (name: String, url: URL)? {
            for a in assets {
                if let name = a["name"] as? String, pred(name),
                   let s = a["browser_download_url"] as? String, let url = URL(string: s), url.scheme == "https" {
                    return (name, url)
                }
            }
            return nil
        }
        guard let zip = asset({ $0.hasSuffix("-macos.zip") }) else { return nil }
        let sum = asset { $0 == zip.name + ".sha256" }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(owner)/\(repo)/releases")!
        var version = tag
        if version.hasPrefix("v") { version.removeFirst() }
        return ReleaseInfo(version: version, zipURL: zip.url, zipName: zip.name, checksumURL: sum?.url, pageURL: page,
                           notes: (json["body"] as? String) ?? "")
    }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 300
        c.httpAdditionalHeaders = ["User-Agent": "Aether-Updater", "Accept": "application/vnd.github+json"]
        return URLSession(configuration: c)
    }

    public static func fetchLatest() async throws -> ReleaseInfo? {
        do {
            let (data, response) = try await session().data(from: latestURL)
            guard let http = response as? HTTPURLResponse else { throw UpdateError.badFeed }
            if http.statusCode == 404 { return nil }   // no releases yet
            guard http.statusCode == 200 else { throw UpdateError.network("HTTP \(http.statusCode)") }
            return try parse(data)
        } catch let e as UpdateError {
            throw e
        } catch {
            throw UpdateError.network((error as NSError).localizedDescription)
        }
    }

    /// Downloads the zip into `directory` and checks it against the published checksum when there is one.
    public static func download(_ release: ReleaseInfo, into directory: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(release.zipName)
        do {
            let (tmp, response) = try await session().download(from: release.zipURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.network("download failed") }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            if let sumURL = release.checksumURL {
                let (data, _) = try await session().data(from: sumURL)
                let expected = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased()
                guard let expected, try sha256(of: dest) == expected else {
                    try? fm.removeItem(at: dest)
                    throw UpdateError.checksumMismatch
                }
            }
            return dest
        } catch let e as UpdateError {
            throw e
        } catch {
            throw UpdateError.network((error as NSError).localizedDescription)
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Unpacks, verifies and swaps in a downloaded update.
public enum UpdateInstaller {
    public static let bundleID = "dev.aether.Aether"

    /// Extracts `zip` into a fresh folder under `workDir` and returns the verified `.app`.
    /// It must be Aether (bundle ID), the expected version, and carry a valid code signature.
    public static func stage(zip: URL, version: String, workDir: URL, bundleID: String = UpdateInstaller.bundleID) throws -> URL {
        let fm = FileManager.default
        let out = workDir.appendingPathComponent("staged-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        guard runStatus("/usr/bin/ditto", ["-x", "-k", zip.path, out.path]) == 0 else { throw UpdateError.badArchive }
        let apps = FileSizer.children(of: out).filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else { throw UpdateError.badArchive }
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID else { throw UpdateError.wrongApp }
        let found = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        guard AppVersion(found) == AppVersion(version) else { throw UpdateError.versionMismatch(expected: version, found: found) }
        guard runStatus("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else { throw UpdateError.badSignature }
        return app
    }

    /// Only a copy that lives in an Applications folder replaces itself. A build running from a developer's
    /// folder is never overwritten.
    public static func canReplace(_ target: URL) -> Bool {
        let path = target.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/"), target.pathExtension == "app" else { return false }
        return FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path)
    }

    /// POSIX sh: waits for `$1` (our pid) to exit, swaps `$2` over `$3`, restores the old copy if anything fails,
    /// and optionally relaunches. Paths arrive as arguments, never spliced into the script text.
    static let swapScript = """
    pid="$1"; staged="$2"; target="$3"; relaunch="$4"
    n=0
    while kill -0 "$pid" 2>/dev/null && [ $n -lt 300 ]; do sleep 0.2; n=$((n+1)); done
    backup="$target.old.$$"
    if mv "$target" "$backup"; then
      if /usr/bin/ditto "$staged" "$target"; then
        rm -rf "$backup" "$staged"
      else
        rm -rf "$target"; mv "$backup" "$target"
      fi
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null
    if [ "$relaunch" = "1" ]; then /usr/bin/open "$target"; fi
    """

    /// Starts the swap in a separate process that outlives this one.
    @discardableResult
    public static func spawnSwap(pid: Int32 = getpid(), staged: URL, target: URL, relaunch: Bool) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", swapScript, "aether-update", String(pid), staged.path, target.path, relaunch ? "1" : "0"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); return p } catch { return nil }
    }
}
