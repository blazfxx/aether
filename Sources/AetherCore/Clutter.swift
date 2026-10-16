import Foundation
import CryptoKit

public struct FileEntry: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public let modified: Date?
    public let accessed: Date?

    public var kind: String {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "mkv", "avi", "m4v", "webm": return "Video"
        case "jpg", "jpeg", "png", "heic", "raw", "cr2", "dng", "tiff", "psd": return "Image"
        case "mp3", "wav", "aiff", "flac", "m4a": return "Audio"
        case "zip", "tar", "gz", "7z", "rar", "dmg", "iso", "pkg", "xz": return "Archive"
        case "pdf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "ppt", "pptx": return "Document"
        case "utm", "pvm", "vmwarevm", "vdi", "qcow2": return "Virtual machine"
        default: return "Other"
        }
    }

    public var daysSinceUse: Int? {
        guard let d = [accessed, modified].compactMap({ $0 }).max() else { return nil }
        return Calendar.current.dateComponents([.day], from: d, to: Date()).day
    }
}

public enum LargeFileScanner {
    /// Folders full of small generated files: never where a large file you care about lives, and slow to walk.
    private static let skippedFolders: Set<String> = ["node_modules", "Pods", "DerivedData", "__pycache__", ".venv", "venv"]
    /// Packages we should never offer up as "large files".
    private static let protectedPackages: Set<String> = ["photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle"]
    /// Folders that macOS treats as one item (and that we size as a whole instead of walking into).
    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "xcodeproj", "xcworkspace", "playground", "rtfd", "sparsebundle",
        "pvm", "utm", "vmwarevm", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle",
    ]
    /// Subfolders are walked in parallel this many levels down.
    private static let parallelDepth = 2

    private final class Run: @unchecked Sendable {
        let minSize: Int64
        let progress: ScanProgress
        let deadline: Date?
        private let lock = NSLock()
        private var found: [FileEntry] = []

        init(minSize: Int64, progress: ScanProgress, deadline: Date?) {
            self.minSize = minSize; self.progress = progress; self.deadline = deadline
        }

        func shouldStop() -> Bool {
            if progress.isCancelled { progress.markTruncated(); return true }
            if let deadline, Date() > deadline { progress.markTruncated(); return true }
            return false
        }

        func add(_ entries: [FileEntry]) {
            guard !entries.isEmpty else { return }
            lock.lock(); found.append(contentsOf: entries); lock.unlock()
        }

        var results: [FileEntry] { lock.lock(); defer { lock.unlock() }; return found }
    }

    /// `timeLimit` stops the walk after that many seconds and returns what was found (the progress is marked truncated).
    /// Cancelling the task or calling `progress.cancel()` does the same.
    public static func scan(
        roots: [URL], minSize: Int64, progress: ScanProgress, timeLimit: TimeInterval? = nil
    ) async -> [FileEntry] {
        let run = Run(minSize: minSize, progress: progress, deadline: timeLimit.map { Date().addingTimeInterval($0) })
        let gate = ResultGate<[FileEntry]>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<[FileEntry], Never>) in
                gate.install(c)
                DispatchQueue.global(qos: .userInitiated).async {
                    DispatchQueue.concurrentPerform(iterations: roots.count) { i in
                        walk(roots[i].path, depth: 0, run)
                    }
                    gate.finish(run.results.sorted { $0.size > $1.size })
                }
                // A folder macOS is still waiting to open (privacy prompt) must not hold up Skip or the time limit.
                gate.watch(stop: { run.shouldStop() }, partial: { run.results.sorted { $0.size > $1.size } })
            }
        } onCancel: {
            progress.cancel()
        }
    }

    private static func walk(_ path: String, depth: Int, _ run: Run) {
        if run.shouldStop() { return }
        guard let entries = BulkDir.read(path, dates: true) else { return }
        run.progress.add(files: entries.count)
        if depth <= 2 { run.progress.setCurrent(path) }

        let prefix = path == "/" ? "" : path
        var local: [FileEntry] = []
        var subdirs: [String] = []
        for e in entries where !e.name.hasPrefix(".") {
            func entry(_ size: Int64) -> FileEntry {
                FileEntry(url: URL(fileURLWithPath: prefix + "/" + e.name), size: size,
                          modified: e.modified > 0 ? Date(timeIntervalSince1970: TimeInterval(e.modified)) : nil,
                          accessed: e.accessed > 0 ? Date(timeIntervalSince1970: TimeInterval(e.accessed)) : nil)
            }
            if e.type == BulkDir.regular {
                if e.alloc >= run.minSize { local.append(entry(e.alloc)) }
            } else if e.type == BulkDir.directory {
                if skippedFolders.contains(e.name) || e.isDataless { continue }
                let ext = (e.name as NSString).pathExtension.lowercased()
                if packageExtensions.contains(ext) {
                    if protectedPackages.contains(ext) { continue }
                    let size = BulkDir.totalSize(prefix + "/" + e.name) { run.shouldStop() }
                    if size >= run.minSize { local.append(entry(size)) }
                } else {
                    subdirs.append(e.name)
                }
            }
        }
        run.add(local)

        if depth < parallelDepth, subdirs.count > 1 {
            DispatchQueue.concurrentPerform(iterations: subdirs.count) { i in
                walk(prefix + "/" + subdirs[i], depth: depth + 1, run)
            }
        } else {
            for d in subdirs { walk(prefix + "/" + d, depth: depth + 1, run) }
        }
    }

    public static var defaultRoots: [URL] {
        let h = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
            .map { h.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - Duplicates

public struct DuplicateGroup: Identifiable, Sendable {
    public let id: String
    public let size: Int64
    /// Oldest first, so index 0 is the natural copy to keep.
    public let files: [FileEntry]
    public var reclaimable: Int64 { size * Int64(files.count - 1) }
}

public enum DuplicateScanner {
    public static func scan(roots: [URL], minSize: Int64 = 100_000, progress: ScanProgress) async -> [DuplicateGroup] {
        guard let bySize = groupBySize(roots: roots, minSize: minSize, progress: progress) else { return [] }
        let candidates = bySize.values.filter { $0.count > 1 }

        // 2. Within a size group, hash head+tail, then the whole file only for survivors.
        let partial = await boundedMap(Array(candidates)) { group -> [[FileEntry]] in
            var buckets: [String: [FileEntry]] = [:]
            for f in group {
                if Task.isCancelled { return [] }
                guard let h = hash(f.url, partialOnly: true) else { continue }
                buckets[h, default: []].append(f)
            }
            return buckets.values.filter { $0.count > 1 }
        }
        let survivors = partial.flatMap { $0 }
        // A same-size/same-head group can still split into several true groups, so one input may yield many.
        let finalGroups = await boundedMap(survivors) { group -> [DuplicateGroup] in
            var buckets: [String: [FileEntry]] = [:]
            for f in group {
                if Task.isCancelled { return [] }
                progress.setCurrent(f.url.lastPathComponent)
                guard let h = hash(f.url, partialOnly: false) else { continue }
                buckets[h, default: []].append(f)
            }
            return buckets.compactMap { (digest, files) -> DuplicateGroup? in
                guard files.count > 1 else { return nil }
                let ordered = files.sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
                return DuplicateGroup(id: digest, size: ordered[0].size, files: ordered)
            }
        }
        return finalGroups.flatMap { $0 }.sorted { $0.reclaimable > $1.reclaimable }
    }

    /// Step 1: walk the roots and bucket regular files by byte size. Returns nil if cancelled.
    static func groupBySize(roots: [URL], minSize: Int64, progress: ScanProgress) -> [Int64: [FileEntry]]? {
        var bySize: [Int64: [FileEntry]] = [:]
        var seenInodes = Set<String>()
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey, .contentAccessDateKey, .isSymbolicLinkKey]
        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            var n = 0
            for case let url as URL in walker {
                n += 1
                if n & 0xFF == 0 { if Task.isCancelled { return nil }; progress.setCurrent(url.deletingLastPathComponent().path) }
                guard let v = try? url.resourceValues(forKeys: Set(keys)),
                      v.isRegularFile == true, v.isSymbolicLink != true,
                      let size = v.fileSize, Int64(size) >= minSize else { continue }
                progress.add()
                var st = stat()
                if stat(url.path, &st) == 0 {
                    let key = "\(st.st_dev):\(st.st_ino)"
                    if !seenInodes.insert(key).inserted { continue }   // hard link to a file already seen
                }
                bySize[Int64(size), default: []].append(
                    FileEntry(url: url, size: Int64(size), modified: v.contentModificationDate, accessed: v.contentAccessDate))
            }
        }
        return bySize
    }

    static func hash(_ url: URL, partialOnly: Bool) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunk = 1 << 20
        do {
            if partialOnly {
                let size = try handle.seekToEnd()
                try handle.seek(toOffset: 0)
                if let head = try handle.read(upToCount: 16 * 1024) { hasher.update(data: head) }
                if size > 32 * 1024 {
                    try handle.seek(toOffset: size - 16 * 1024)
                    if let tail = try handle.read(upToCount: 16 * 1024) { hasher.update(data: tail) }
                }
            } else {
                while let data = try handle.read(upToCount: chunk), !data.isEmpty {
                    hasher.update(data: data)
                    if Task.isCancelled { return nil }
                }
            }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
