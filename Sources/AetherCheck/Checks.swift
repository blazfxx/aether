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

@main struct Runner {
    static func main() async {
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
        await check("duplicatesIgnoreSameSizeDifferentContent") { try await ScannerTests().duplicatesIgnoreSameSizeDifferentContent() }
        await check("hardLinksAreNotDuplicates") { try await ScannerTests().hardLinksAreNotDuplicates() }
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
