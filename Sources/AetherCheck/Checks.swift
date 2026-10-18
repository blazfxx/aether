import Foundation
@testable import AetherCore

// Engine checks. Command Line Tools ship no XCTest/Testing overlay, so this is a plain executable:
//   swift build -c release -Xswiftc -enable-testing --product AetherCheck && .build/release/AetherCheck
// (or simply `swift run AetherCheck` in a debug build).

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ name: String, _ body: () async throws -> Void) async {
    do { try await body(); print("  ok   \(name)") } catch { failures += 1; print("  ERR  \(name): \(error)") }
}

func expect(_ cond: @autoclosure () -> Bool, _ msg: String = "", line: Int = #line) {
    checks += 1
    if !cond() { failures += 1; print("    FAIL line \(line) \(msg)") }
}

/// Like `expect`, for conditions that call throwing code.
func expectT(_ cond: @autoclosure () throws -> Bool, _ msg: String = "", line: Int = #line) throws {
    checks += 1
    if !(try cond()) { failures += 1; print("    FAIL line \(line) \(msg)") }
}

private let home = FileManager.default.homeDirectoryForCurrentUser

private func tempDir(in base: URL = FileManager.default.temporaryDirectory) throws -> URL {
    let d = base.appendingPathComponent("aether-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

struct RemoverTests {
    func protectedLocationsAreRefused() {
        expect(!Remover.isRemovable(URL(fileURLWithPath: "/")))
        expect(!Remover.isRemovable(URL(fileURLWithPath: "/System/Library")))
        expect(!Remover.isRemovable(URL(fileURLWithPath: "/usr/bin/ls")))
        expect(!Remover.isRemovable(URL(fileURLWithPath: "/Library/Caches/x")))
        expect(!Remover.isRemovable(URL(fileURLWithPath: "/Applications")))
        expect(!Remover.isRemovable(home))
        for d in ["Documents", "Desktop", "Downloads", "Library", "Library/Caches", "Library/Application Support", "Pictures"] {
            expect(!Remover.isRemovable(home.appendingPathComponent(d)), "\(d)")
        }
    }

    func childrenOfAllowedRootsAreRemovable() {
        expect(Remover.isRemovable(home.appendingPathComponent("Library/Caches/com.example.app")))
        expect(Remover.isRemovable(URL(fileURLWithPath: "/Applications/Foo.app")))
    }

    func dotDotCannotEscape() {
        expect(!Remover.isRemovable(home.appendingPathComponent("Library/Caches/../../../../etc/hosts")))
    }

    func symlinkedParentCannotEscape() throws {
        let dir = try tempDir(in: home)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc"))
        expect(!Remover.isRemovable(link.appendingPathComponent("hosts")))
    }

    func permanentRemoveReportsFreedSpace() throws {
        let dir = try tempDir(in: home)
        try Data(repeating: 7, count: 300_000).write(to: dir.appendingPathComponent("blob"))
        let report = Remover.remove([dir], mode: .permanent)
        expect(report.removed == 1)
        expect(report.freed > 250_000)
        expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    func refusedItemIsReportedNotDeleted() {
        let report = Remover.remove([URL(fileURLWithPath: "/etc/hosts")], mode: .permanent)
        expect(report.removed == 0)
        expect(report.failures.count == 1)
        expect(FileManager.default.fileExists(atPath: "/etc/hosts"))
    }

    func trashModeIsRecoverable() throws {
        let dir = try tempDir(in: home)
        let f = dir.appendingPathComponent("keep-me.txt")
        try Data("hello".utf8).write(to: f)
        let report = Remover.remove([f], mode: .trash)
        defer { try? FileManager.default.removeItem(at: dir) }
        expect(report.removed == 1)
        expect(!FileManager.default.fileExists(atPath: f.path))
    }
}

struct TreemapTests {
    func areasAreProportionalAndInsideBounds() {
        let sizes: [Double] = [60, 25, 10, 3, 2]
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let rects = Squarify.layout(sizes: sizes, in: bounds)
        expect(rects.count == sizes.count)
        let total = sizes.reduce(0, +)
        for (r, s) in zip(rects, sizes) {
            let expected = Double(bounds.width * bounds.height) * s / total
            expect(abs(Double(r.width * r.height) - expected) < 1.0)
            expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(r))
        }
    }

    func tilesDoNotOverlap() {
        let rects = Squarify.layout(sizes: [40, 30, 20, 10, 5, 5, 1], in: CGRect(x: 0, y: 0, width: 500, height: 320))
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                let o = rects[i].intersection(rects[j])
                expect(o.isNull || o.width * o.height < 0.5)
            }
        }
    }

    func degenerateInputs() {
        expect(Squarify.layout(sizes: [], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        expect(Squarify.layout(sizes: [1], in: .zero) == [.zero])
    }
}

struct ScannerTests {
    private func makeTree() throws -> URL {
        let root = try tempDir()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("a/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000_000).write(to: root.appendingPathComponent("a/big.bin"))
        try Data(repeating: 1, count: 2_000_000).write(to: root.appendingPathComponent("b/copy.bin"))   // duplicate of a/big.bin
        try Data(repeating: 2, count: 2_000_000).write(to: root.appendingPathComponent("b/other.bin"))  // same size, different bytes
        try Data(repeating: 3, count: 3_000_000).write(to: root.appendingPathComponent("a/deep/huge.bin"))
        return root
    }

    func spaceLensSizesAddUp() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let node = await SpaceLensScanner.scan(root: root, progress: ScanProgress())
        expect(node.size >= 9_000_000)
        expect(node.children.reduce(0) { $0 + $1.size } == node.size)
        expect(node.children.first?.name == "a")   // 5 MB beats 4 MB
        expect(node.children.first?.children.first?.name == "deep")
    }

    func largeFileScanRespectsThreshold() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = await LargeFileScanner.scan(roots: [root], minSize: 2_500_000, progress: ScanProgress())
        expect(found.map(\.url.lastPathComponent) == ["huge.bin"])
    }

    func largeFileScanCanBeStoppedAndSkipsGeneratedFolders() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        // A big file inside node_modules is not offered, and the walk never goes in.
        let modules = root.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 3_000_000).write(to: modules.appendingPathComponent("big.bin"))
        let found = await LargeFileScanner.scan(roots: [root], minSize: 2_500_000, progress: ScanProgress())
        expect(found.map(\.url.lastPathComponent) == ["huge.bin"])
        // A scan told to stop returns at once, and says it did not finish.
        let stopped = ScanProgress()
        stopped.cancel()
        for i in 0..<300 { try Data().write(to: root.appendingPathComponent("f\(i).txt")) }
        _ = await LargeFileScanner.scan(roots: [root], minSize: 2_500_000, progress: stopped)
        expect(stopped.wasTruncated)
        // An expired time limit does the same.
        let late = ScanProgress()
        _ = await LargeFileScanner.scan(roots: [root], minSize: 2_500_000, progress: late, timeLimit: -1)
        expect(late.wasTruncated)
    }

    func duplicatesIgnoreSameSizeDifferentContent() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let groups = await DuplicateScanner.scan(roots: [root], minSize: 1_000_000, progress: ScanProgress())
        expect(groups.count == 1)
        expect(Set(groups.first?.files.map(\.url.lastPathComponent) ?? []) == ["big.bin", "copy.bin"])
        expect(groups.first?.reclaimable == groups.first?.size)
    }

    func hardLinksAreNotDuplicates() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.bin")
        try Data(repeating: 9, count: 1_500_000).write(to: a)
        try FileManager.default.linkItem(at: a, to: root.appendingPathComponent("b.bin"))
        let groups = await DuplicateScanner.scan(roots: [root], minSize: 1_000_000, progress: ScanProgress())
        expect(groups.isEmpty)
    }
}

struct BulkDirTests {
    private func write(_ n: Int, to url: URL) throws { try Data(repeating: 5, count: n).write(to: url) }

    func entriesMatchLstatNamesTypesSizesAndDates() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(300_000, to: root.appendingPathComponent("a.bin"))
        try write(5, to: root.appendingPathComponent("b.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("d"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("ln"), withDestinationURL: root.appendingPathComponent("a.bin"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                              ofItemAtPath: root.appendingPathComponent("a.bin").path)
        guard let entries = BulkDir.read(root.path, dates: true) else { expect(false, "read returned nil"); return }
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        expect(Set(byName.keys) == ["a.bin", "b.txt", "d", "ln"], "\(byName.keys.sorted())")
        for name in ["a.bin", "b.txt"] {
            var st = stat()
            expect(lstat(root.appendingPathComponent(name).path, &st) == 0)
            expect(byName[name]?.alloc == Int64(st.st_blocks) * 512, "\(name) alloc \(byName[name]?.alloc ?? -1) vs \(Int64(st.st_blocks) * 512)")
            expect(byName[name]?.type == BulkDir.regular)
        }
        expect(byName["d"]?.type == BulkDir.directory)
        expect(byName["ln"]?.type == BulkDir.symlink)
        expect(byName["a.bin"]?.modified == 1_600_000_000, "mtime \(byName["a.bin"]?.modified ?? -1)")
        expect((byName["a.bin"]?.accessed ?? 0) > 1_500_000_000)
    }

    func totalSizeMatchesAFoundationWalk() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for d in 0..<5 {
            let dir = root.appendingPathComponent("d\(d)/sub")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 0..<8 { try write(1_000 * (d + 1) * (f + 1) + 17, to: dir.appendingPathComponent("f\(f).bin")) }
        }
        func oracle(_ url: URL) -> Int64 {
            var total: Int64 = 0
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
            for case let u as URL in FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)! {
                let v = try? u.resourceValues(forKeys: Set(keys))
                if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
            }
            return total
        }
        expect(BulkDir.totalSize(root.path) == oracle(root), "tmp tree")
        expect(FileSizer.allocatedSize(of: root) == oracle(root))
        // A real, static tree as a second opinion (skipped if the Command Line Tools are not installed).
        let real = URL(fileURLWithPath: "/Library/Developer/CommandLineTools/usr/include")
        if FileManager.default.fileExists(atPath: real.path) {
            expect(BulkDir.totalSize(real.path) == oracle(real), "CLT include")
        }
    }

    func bigDirectoriesSpanSeveralBuffers() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<6_000 { FileManager.default.createFile(atPath: root.appendingPathComponent("file-with-a-fairly-long-name-\(i).txt").path, contents: nil) }
        let entries = BulkDir.read(root.path) ?? []
        expect(entries.count == 6_000, "\(entries.count)")
        expect(Set(entries.map(\.name)).count == 6_000)
    }

    func missingOrForbiddenDirectoryIsNil() {
        expect(BulkDir.read("/definitely/not/here") == nil)
        expect(BulkDir.read("/etc/hosts") == nil)   // a file, not a directory
    }
}

struct GateTests {
    func firstResultWinsAndALateListenerStillGetsIt() async {
        let g = ResultGate<Int>()
        g.finish(1); g.finish(2)
        let v = await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in g.install(c) }
        expect(v == 1)
    }

    /// The real-world case: a worker thread is parked in open() waiting for a macOS privacy prompt and never returns.
    func stopReleasesACallerWhoseWorkIsBlockedForever() async {
        let g = ResultGate<String>()
        let flag = ScanProgress()
        g.watch(stop: { flag.isCancelled }, partial: { "partial" })
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { flag.cancel() }
        let t = Date()
        let v = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in g.install(c) }   // the worker never calls finish
        expect(v == "partial")
        expect(Date().timeIntervalSince(t) < 2, "took \(Date().timeIntervalSince(t))s")
    }

    func spaceLensReturnsAtOnceWhenAlreadyStopped() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = ScanProgress()
        p.cancel()
        let t = Date()
        let node = await SpaceLensScanner.scan(root: root, progress: p)
        expect(Date().timeIntervalSince(t) < 2)
        expect(node.children.isEmpty)
    }
}

struct VersionTests {
    func comparesNumericallyNotAlphabetically() {
        expect(AppVersion("1.10") > AppVersion("1.9"))
        expect(AppVersion("1.0.2") > AppVersion("1.0.1"))
        expect(AppVersion("2") == AppVersion("2.0.0"))
        expect(AppVersion("v2.1") == AppVersion("2.1"))
        expect(AppVersion("1.0-beta") == AppVersion("1.0"))
        expect(AppVersion("10.0") > AppVersion("9.99.99"))
        expect(!AppVersion("abc").isValid)
        expect(AppVersion("3.0b1").isValid)
    }
}

struct SelectionMemoryTests {
    private func fresh() -> (SelectionMemory, UserDefaults, String) {
        let name = "aether-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (SelectionMemory(defaults: d), d, name)
    }

    func untickedItemsStayUntickedNextTime() {
        let (m, d, name) = fresh()
        defer { d.removePersistentDomain(forName: name) }
        let cache = URL(fileURLWithPath: "/Users/x/Library/Caches/com.example.app")
        expect(m.isSelected(cache, default: true))                 // never touched: default
        m.set(cache, selected: false)
        expect(!m.isSelected(cache, default: true))                // remembered
        let reborn = SelectionMemory(defaults: d)                  // next launch
        expect(!reborn.isSelected(cache, default: true))
    }

    func reviewItemsYouTickedStayTicked() {
        let (m, d, name) = fresh()
        defer { d.removePersistentDomain(forName: name) }
        let installer = URL(fileURLWithPath: "/Users/x/Downloads/Thing.dmg")
        expect(!m.isSelected(installer, default: false))
        m.set(installer, selected: true)
        expect(m.isSelected(installer, default: false))
    }

    func forgetAllRestoresDefaults() {
        let (m, d, name) = fresh()
        defer { d.removePersistentDomain(forName: name) }
        let u = URL(fileURLWithPath: "/tmp/a")
        m.set(u, selected: false)
        m.forgetAll()
        expect(m.isSelected(u, default: true))
        expect(m.count == 0)
    }

    func theListStaysBounded() {
        let (m, d, name) = fresh()
        defer { d.removePersistentDomain(forName: name) }
        let urls = (0..<4_500).map { URL(fileURLWithPath: "/tmp/item-\($0)") }
        m.set(urls, selected: false)
        expect(m.count <= 4_000, "\(m.count)")
        expect(m.choice(for: urls.last!) == false)     // newest kept
        expect(m.choice(for: urls.first!) == nil)      // oldest dropped
    }
}

struct UpdateFeedTests {
    private func json(tag: String = "v1.2.3", draft: Bool = false, pre: Bool = false, assets: [(String, String)]) -> Data {
        let a = assets.map { "{\"name\":\"\($0.0)\",\"browser_download_url\":\"\($0.1)\"}" }.joined(separator: ",")
        return Data("{\"tag_name\":\"\(tag)\",\"draft\":\(draft),\"prerelease\":\(pre),\"html_url\":\"https://github.com/blazfxx/aether/releases/tag/\(tag)\",\"body\":\"notes\",\"assets\":[\(a)]}".utf8)
    }

    func parsesTheRealReleaseShape() throws {
        let r = try ReleaseFeed.parse(json(assets: [
            ("Aether-1.2.3-macos.zip", "https://github.com/blazfxx/aether/releases/download/v1.2.3/Aether-1.2.3-macos.zip"),
            ("Aether-1.2.3-macos.zip.sha256", "https://github.com/blazfxx/aether/releases/download/v1.2.3/Aether-1.2.3-macos.zip.sha256"),
        ]))
        expect(r?.version == "1.2.3")
        expect(r?.zipName == "Aether-1.2.3-macos.zip")
        expect(r?.checksumURL?.lastPathComponent == "Aether-1.2.3-macos.zip.sha256")
        expect(r?.notes == "notes")
    }

    func ignoresDraftsPrereleasesAndReleasesWithoutAMacZip() throws {
        let zip = [("Aether-1.2.3-macos.zip", "https://example.com/a.zip")]
        try expectT(ReleaseFeed.parse(json(draft: true, assets: zip)) == nil)
        try expectT(ReleaseFeed.parse(json(pre: true, assets: zip)) == nil)
        try expectT(ReleaseFeed.parse(json(assets: [("source.tar.gz", "https://example.com/s.tgz")])) == nil)
    }

    func refusesPlainHTTPDownloads() throws {
        try expectT(ReleaseFeed.parse(json(assets: [("Aether-1.2.3-macos.zip", "http://example.com/a.zip")])) == nil)
    }

    func rejectsGarbage() {
        var threw = false
        do { _ = try ReleaseFeed.parse(Data("not json".utf8)) } catch { threw = true }
        expect(threw)
    }
}

struct UpdateInstallTests {
    /// A tiny ad-hoc-signed app that stands in for a downloaded Aether.
    private func fakeApp(in dir: URL, id: String = UpdateInstaller.bundleID, version: String = "9.9.9", sign: Bool = true) throws -> URL {
        let app = dir.appendingPathComponent("Aether.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macos.appendingPathComponent("Aether"))
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": "Aether",
                                    "CFBundlePackageType": "APPL", "CFBundleName": "Aether"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if sign { expect(runStatus("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) == 0, "codesign") }
        return app
    }

    private func zip(_ app: URL, to dir: URL) throws -> URL {
        let z = dir.appendingPathComponent("update.zip")
        expect(runStatus("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, z.path]) == 0)
        return z
    }

    private func rejects(_ build: (URL) throws -> URL, version: String = "9.9.9") throws -> Bool {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src"), work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let z = try build(src)
        do { _ = try UpdateInstaller.stage(zip: z, version: version, workDir: work); return false } catch { return true }
    }

    func acceptsAValidSignedAetherBundle() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let z = try zip(try fakeApp(in: src), to: root)
        let staged = try UpdateInstaller.stage(zip: z, version: "9.9.9", workDir: root.appendingPathComponent("work"))
        expect(staged.pathExtension == "app")
        expect(Bundle(url: staged)?.bundleIdentifier == UpdateInstaller.bundleID)
    }

    func rejectsAnotherApp() throws {
        try expectT(rejects { src in try zip(try fakeApp(in: src, id: "com.evil.Other"), to: src.deletingLastPathComponent()) })
    }

    func rejectsTheWrongVersion() throws {
        try expectT(rejects { src in try zip(try fakeApp(in: src, version: "1.0.0"), to: src.deletingLastPathComponent()) })
    }

    func rejectsAnUnsignedBundle() throws {
        try expectT(rejects { src in try zip(try fakeApp(in: src, sign: false), to: src.deletingLastPathComponent()) })
    }

    func rejectsABundleTamperedWithAfterSigning() throws {
        try expectT(rejects { src in
            let app = try fakeApp(in: src)
            let exe = app.appendingPathComponent("Contents/MacOS/Aether")
            let h = try FileHandle(forWritingTo: exe)
            try h.seekToEnd(); try h.write(contentsOf: Data("malicious".utf8)); try h.close()
            return try zip(app, to: src.deletingLastPathComponent())
        })
    }

    func rejectsAZipThatIsNotAnApp() throws {
        try expectT(rejects { src in
            let junk = src.appendingPathComponent("hello.txt")
            try Data("hi".utf8).write(to: junk)
            let z = src.deletingLastPathComponent().appendingPathComponent("update.zip")
            _ = runStatus("/usr/bin/ditto", ["-c", "-k", "--keepParent", junk.path, z.path])
            return z
        })
    }

    func onlyApplicationsFoldersReplaceThemselves() {
        expect(!UpdateInstaller.canReplace(URL(fileURLWithPath: "/Users/someone/Developer/Aether/build/Aether.app")))
        expect(!UpdateInstaller.canReplace(URL(fileURLWithPath: "/Users/someone/Desktop/Aether.app")))
        expect(!UpdateInstaller.canReplace(URL(fileURLWithPath: "/Applications/Aether")))   // not a bundle
    }

    func swapReplacesTheTargetEvenWithSpacesInPaths() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("My Apps/Aether.app")
        let staged = root.appendingPathComponent("new stuff/Aether.app")
        for (dir, marker) in [(target, "old"), (staged, "new")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: dir.appendingPathComponent("marker"))
        }
        let p = UpdateInstaller.spawnSwap(pid: 999_999, staged: staged, target: target, relaunch: false)
        p?.waitUntilExit()
        expect(p?.terminationStatus == 0)
        expect((try? String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8)) == "new")
        expect(!FileManager.default.fileExists(atPath: staged.path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)) ?? []
        expect(leftovers == ["Aether.app"], "\(leftovers)")   // no .old backup left behind
    }

    func aFailedSwapRestoresTheOldApp() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Aether.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("marker"))
        let missing = root.appendingPathComponent("does-not-exist.app")
        UpdateInstaller.spawnSwap(pid: 999_999, staged: missing, target: target, relaunch: false)?.waitUntilExit()
        expect((try? String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8)) == "old")
    }
}

struct AppUpdateTests {
    private let appcast = Data("""
    <?xml version="1.0"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
    <item><title>2.1</title><sparkle:version>210</sparkle:version><sparkle:shortVersionString>2.1</sparkle:shortVersionString>
      <enclosure url="https://x.test/App-2.1.zip" sparkle:version="210"/></item>
    <item><title>3.0 beta</title><sparkle:channel>beta</sparkle:channel><sparkle:version>300</sparkle:version><sparkle:shortVersionString>3.0b1</sparkle:shortVersionString></item>
    <item><title>2.5</title><sparkle:version>250</sparkle:version><sparkle:shortVersionString>2.5</sparkle:shortVersionString><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion></item>
    <item><title>2.0</title><enclosure url="https://x.test/App-2.0.zip" sparkle:shortVersionString="2.0" sparkle:version="200"/></item>
    </channel></rss>
    """.utf8)

    func picksTheNewestStableItemThisMacCanRun() {
        let items = AppUpdateChecker.parseAppcast(appcast)
        expect(items.count == 4)
        let now = AppUpdateChecker.newest(in: items, osVersion: AppVersion("15.0"))
        expect(now?.shortVersion == "2.1", "\(now?.shortVersion ?? "nil")")   // not the beta, not the one needing macOS 99
        expect(now?.download?.absoluteString == "https://x.test/App-2.1.zip")
        let future = AppUpdateChecker.newest(in: items, osVersion: AppVersion("99.0"))
        expect(future?.shortVersion == "2.5")
    }

    func emptyOrBrokenFeedsGiveNothing() {
        expect(AppUpdateChecker.newest(in: AppUpdateChecker.parseAppcast(Data("<rss></rss>".utf8)), osVersion: AppVersion("15.0")) == nil)
        expect(AppUpdateChecker.newest(in: AppUpdateChecker.parseAppcast(Data("garbage".utf8)), osVersion: AppVersion("15.0")) == nil)
    }

    func readsAnAppStoreLookup() {
        let ok = AppUpdateChecker.parseLookup(Data("{\"resultCount\":1,\"results\":[{\"version\":\"4.2.1\",\"trackId\":12345}]}".utf8))
        expect(ok?.version == "4.2.1" && ok?.trackID == 12345)
        expect(AppUpdateChecker.parseLookup(Data("{\"resultCount\":0,\"results\":[]}".utf8)) == nil)
        expect(AppUpdateChecker.lookupURL(bundleID: "com.x.y", country: "us")?.absoluteString.contains("bundleId=com.x.y") == true)
    }

    func theAppStoreButtonOpensTheStore() {
        let app = AppInfo(url: URL(fileURLWithPath: "/Applications/X.app"), name: "X", bundleID: "com.x", version: "1", size: 0, lastUsed: nil, fromAppStore: true)
        let u = AppUpdate(app: app, installed: "1", latest: "2", source: .appStore(trackID: 42))
        expect(u.openURL?.absoluteString == "macappstore://apps.apple.com/app/id42")
    }
}

struct AdvisorTests {
    func memoryAdviceNeedsRealPressure() {
        expect(MaintenanceAdvisor.purgeAdvice(memoryPressure: 0.95) != nil)
        expect(MaintenanceAdvisor.purgeAdvice(memoryPressure: 0.30) == nil)
    }

    func spotlightIsOnlyBlamedWhenItIsOnAndEmpty() {
        let on = "/System/Volumes/Data:\n\tIndexing enabled. "
        let off = "/:\n\tIndexing disabled."
        expect(MaintenanceAdvisor.spotlightVerdict(appCount: 54, volumeStatus: on) == nil)        // finds apps: healthy
        expect(MaintenanceAdvisor.spotlightVerdict(appCount: 0, volumeStatus: off) == nil)        // switched off on purpose
        expect(MaintenanceAdvisor.spotlightVerdict(appCount: 0, volumeStatus: on) != nil)         // on but empty: broken
        expect(MaintenanceAdvisor.spotlightVerdict(appCount: 0, volumeStatus: nil) == nil)        // can't tell: say nothing
        expect(MaintenanceAdvisor.spotlightVerdict(appCount: nil, volumeStatus: on) == nil)
    }

    func everyRecommendationIsARealTaskWithAReason() async {
        let advice = await MaintenanceAdvisor.recommend(memoryPressure: 0.99)
        expect(advice.contains { $0.task.id == "purge" })
        let known = Set(Maintenance.tasks.map(\.id))
        for a in advice { expect(known.contains(a.task.id) && !a.reason.isEmpty, a.task.id) }
        // Rebuilding Launch Services and Quick Look have no cheap test, so they are never suggested on their own.
        expect(!advice.contains { $0.task.id == "launchservices" || $0.task.id == "quicklook" })
    }
}

struct CatalogTests {
    func categoriesAreUniqueAndReviewOnesAreRecoverable() {
        let ids = JunkCatalog.all.map(\.id)
        expect(Set(ids).count == ids.count)
        // Anything a person might want back must go to the Trash rather than be deleted outright.
        for c in JunkCatalog.all where c.risk == .review { expect(c.mode == .trash, "\(c.id)") }
    }

    func everyLocatedJunkItemPassesTheSafetyGate() {
        for c in JunkCatalog.all {
            for u in c.locate() { expect(Remover.isRemovable(u), "\(c.id): \(u.path)") }
        }
    }

    func runningAppCachesAreSkipped() {
        let running = JunkCatalog.runningBundleIDs()
        let names = Set(JunkCatalog.userCaches().map(\.lastPathComponent))
        expect(names.isDisjoint(with: running))
    }
}

struct AppTests {
    func appleAndSelfAreNotUninstallable() async {
        let apps = await AppScanner.scan()
        for a in apps where a.bundleID?.hasPrefix("com.apple.") == true { expect(!AppScanner.isUninstallable(a), "\(a.name)") }
    }

    func leftoversNeverTouchAppleIDs() async {
        let fake = AppInfo(url: URL(fileURLWithPath: "/Applications/Safari.app"), name: "Safari", bundleID: "com.apple.Safari",
                           version: nil, size: 0, lastUsed: nil, fromAppStore: false)
        let found = await LeftoverFinder.find(for: fake)
        expect(found.isEmpty)
    }

    func orphansExcludeInstalledAndApple() async {
        let installed = LeftoverFinder.installedIDs()
        let orphans = await LeftoverFinder.orphans()
        for o in orphans {
            let n = o.url.lastPathComponent
            expect(!n.hasPrefix("com.apple."), "\(n)")
            expect(!installed.contains(n), "\(n)")
        }
    }
}

struct MonitorTests {
    func samplerProducesSaneNumbers() {
        let sampler = SystemSampler()
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 0.3)
        let s = sampler.sample()
        expect(!s.cpuPerCore.isEmpty)
        expect(s.cpuPerCore.allSatisfy { $0 >= 0 && $0 <= 1 })
        expect(s.memory.total > 0)
        expect(s.memory.used > 0 && s.memory.used <= s.memory.total)
        expect(s.disk.total > 0)
        expect(s.uptime > 0)
    }

    func topProcessesNonEmpty() {
        let p = SystemSampler.topProcesses(limit: 5)
        expect(!p.isEmpty && p.count <= 5)
    }
}

/// `AetherCheck --bench`: how long the scanners take on this Mac's real folders.
func bench() async {
    func secs(_ t: Date) -> String { String(format: "%.1fs", Date().timeIntervalSince(t)) }
    let home = FileManager.default.homeDirectoryForCurrentUser

    setvbuf(stdout, nil, _IOLBF, 0)
    var t = Date()
    var p = ScanProgress()
    let ticker = Task {   // live progress, so a slow or blocked scan is visible
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            let s = p.snapshot
            print("  ... \(secs(t)) \(s.files.formatted()) items \(Bytes.string(s.bytes)) \(s.current)")
        }
    }
    defer { ticker.cancel() }
    let tree = await SpaceLensScanner.scan(root: home, progress: p)
    print("Space Lens (home):  \(p.snapshot.files.formatted()) items, \(Bytes.string(tree.size)) in \(secs(t))")

    t = Date(); p = ScanProgress()
    let big = await LargeFileScanner.scan(roots: LargeFileScanner.defaultRoots, minSize: 500_000_000, progress: p)
    print("Large files (500MB): \(p.snapshot.files.formatted()) items, \(big.count) found in \(secs(t))")

    t = Date()
    let apps = await AppScanner.scan()
    let updates = await AppUpdateChecker.check(apps)
    print("App updates:        \(apps.count) apps checked, \(updates.count) with updates in \(secs(t))")
    for u in updates { print("  \(u.app.name): \(u.installed) -> \(u.latest)  [\(u.sourceName)]") }

    t = Date()
    let pressure = SystemSampler().sample().memory.pressure
    let advice = await MaintenanceAdvisor.recommend(memoryPressure: pressure)
    print("Maintenance:        memory \(Int(pressure * 100))% in use; \(advice.count) recommended in \(secs(t))")
    for a in advice { print("  \(a.task.title): \(a.reason)") }
}

@main struct Runner {
    static func main() async {
        if CommandLine.arguments.contains("--bench") { await bench(); exit(0) }
        print("RemoverTests")
        await check("protectedLocationsAreRefused") { RemoverTests().protectedLocationsAreRefused() }
        await check("childrenOfAllowedRootsAreRemovable") { RemoverTests().childrenOfAllowedRootsAreRemovable() }
        await check("dotDotCannotEscape") { RemoverTests().dotDotCannotEscape() }
        await check("symlinkedParentCannotEscape") { try RemoverTests().symlinkedParentCannotEscape() }
        await check("permanentRemoveReportsFreedSpace") { try RemoverTests().permanentRemoveReportsFreedSpace() }
        await check("refusedItemIsReportedNotDeleted") { RemoverTests().refusedItemIsReportedNotDeleted() }
        await check("trashModeIsRecoverable") { try RemoverTests().trashModeIsRecoverable() }
        print("TreemapTests")
        await check("areasAreProportionalAndInsideBounds") { TreemapTests().areasAreProportionalAndInsideBounds() }
        await check("tilesDoNotOverlap") { TreemapTests().tilesDoNotOverlap() }
        await check("degenerateInputs") { TreemapTests().degenerateInputs() }
        print("ScannerTests")
        await check("spaceLensSizesAddUp") { try await ScannerTests().spaceLensSizesAddUp() }
        await check("largeFileScanRespectsThreshold") { try await ScannerTests().largeFileScanRespectsThreshold() }
        await check("largeFileScanCanBeStoppedAndSkipsGeneratedFolders") { try await ScannerTests().largeFileScanCanBeStoppedAndSkipsGeneratedFolders() }
        await check("duplicatesIgnoreSameSizeDifferentContent") { try await ScannerTests().duplicatesIgnoreSameSizeDifferentContent() }
        await check("hardLinksAreNotDuplicates") { try await ScannerTests().hardLinksAreNotDuplicates() }
        print("BulkDirTests")
        await check("entriesMatchLstatNamesTypesSizesAndDates") { try BulkDirTests().entriesMatchLstatNamesTypesSizesAndDates() }
        await check("totalSizeMatchesAFoundationWalk") { try BulkDirTests().totalSizeMatchesAFoundationWalk() }
        await check("bigDirectoriesSpanSeveralBuffers") { try BulkDirTests().bigDirectoriesSpanSeveralBuffers() }
        await check("missingOrForbiddenDirectoryIsNil") { BulkDirTests().missingOrForbiddenDirectoryIsNil() }
        print("GateTests")
        await check("firstResultWinsAndALateListenerStillGetsIt") { await GateTests().firstResultWinsAndALateListenerStillGetsIt() }
        await check("stopReleasesACallerWhoseWorkIsBlockedForever") { await GateTests().stopReleasesACallerWhoseWorkIsBlockedForever() }
        await check("spaceLensReturnsAtOnceWhenAlreadyStopped") { try await GateTests().spaceLensReturnsAtOnceWhenAlreadyStopped() }
        print("VersionTests")
        await check("comparesNumericallyNotAlphabetically") { VersionTests().comparesNumericallyNotAlphabetically() }
        print("SelectionMemoryTests")
        await check("untickedItemsStayUntickedNextTime") { SelectionMemoryTests().untickedItemsStayUntickedNextTime() }
        await check("reviewItemsYouTickedStayTicked") { SelectionMemoryTests().reviewItemsYouTickedStayTicked() }
        await check("forgetAllRestoresDefaults") { SelectionMemoryTests().forgetAllRestoresDefaults() }
        await check("theListStaysBounded") { SelectionMemoryTests().theListStaysBounded() }
        print("UpdateFeedTests")
        await check("parsesTheRealReleaseShape") { try UpdateFeedTests().parsesTheRealReleaseShape() }
        await check("ignoresDraftsPrereleasesAndReleasesWithoutAMacZip") { try UpdateFeedTests().ignoresDraftsPrereleasesAndReleasesWithoutAMacZip() }
        await check("refusesPlainHTTPDownloads") { try UpdateFeedTests().refusesPlainHTTPDownloads() }
        await check("rejectsGarbage") { UpdateFeedTests().rejectsGarbage() }
        print("UpdateInstallTests")
        await check("acceptsAValidSignedAetherBundle") { try UpdateInstallTests().acceptsAValidSignedAetherBundle() }
        await check("rejectsAnotherApp") { try UpdateInstallTests().rejectsAnotherApp() }
        await check("rejectsTheWrongVersion") { try UpdateInstallTests().rejectsTheWrongVersion() }
        await check("rejectsAnUnsignedBundle") { try UpdateInstallTests().rejectsAnUnsignedBundle() }
        await check("rejectsABundleTamperedWithAfterSigning") { try UpdateInstallTests().rejectsABundleTamperedWithAfterSigning() }
        await check("rejectsAZipThatIsNotAnApp") { try UpdateInstallTests().rejectsAZipThatIsNotAnApp() }
        await check("onlyApplicationsFoldersReplaceThemselves") { UpdateInstallTests().onlyApplicationsFoldersReplaceThemselves() }
        await check("swapReplacesTheTargetEvenWithSpacesInPaths") { try UpdateInstallTests().swapReplacesTheTargetEvenWithSpacesInPaths() }
        await check("aFailedSwapRestoresTheOldApp") { try UpdateInstallTests().aFailedSwapRestoresTheOldApp() }
        print("AppUpdateTests")
        await check("picksTheNewestStableItemThisMacCanRun") { AppUpdateTests().picksTheNewestStableItemThisMacCanRun() }
        await check("emptyOrBrokenFeedsGiveNothing") { AppUpdateTests().emptyOrBrokenFeedsGiveNothing() }
        await check("readsAnAppStoreLookup") { AppUpdateTests().readsAnAppStoreLookup() }
        await check("theAppStoreButtonOpensTheStore") { AppUpdateTests().theAppStoreButtonOpensTheStore() }
        print("AdvisorTests")
        await check("memoryAdviceNeedsRealPressure") { AdvisorTests().memoryAdviceNeedsRealPressure() }
        await check("spotlightIsOnlyBlamedWhenItIsOnAndEmpty") { AdvisorTests().spotlightIsOnlyBlamedWhenItIsOnAndEmpty() }
        await check("everyRecommendationIsARealTaskWithAReason") { await AdvisorTests().everyRecommendationIsARealTaskWithAReason() }
        print("CatalogTests")
        await check("categoriesAreUniqueAndReviewOnesAreRecoverable") { CatalogTests().categoriesAreUniqueAndReviewOnesAreRecoverable() }
        await check("everyLocatedJunkItemPassesTheSafetyGate") { CatalogTests().everyLocatedJunkItemPassesTheSafetyGate() }
        await check("runningAppCachesAreSkipped") { CatalogTests().runningAppCachesAreSkipped() }
        print("AppTests")
        await check("appleAndSelfAreNotUninstallable") { await AppTests().appleAndSelfAreNotUninstallable() }
        await check("leftoversNeverTouchAppleIDs") { await AppTests().leftoversNeverTouchAppleIDs() }
        await check("orphansExcludeInstalledAndApple") { await AppTests().orphansExcludeInstalledAndApple() }
        print("MonitorTests")
        await check("samplerProducesSaneNumbers") { MonitorTests().samplerProducesSaneNumbers() }
        await check("topProcessesNonEmpty") { MonitorTests().topProcessesNonEmpty() }
        print("\n\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
