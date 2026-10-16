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
    private static let keys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isPackageKey,
        .contentModificationDateKey, .contentAccessDateKey, .isSymbolicLinkKey, .isDirectoryKey,
    ]
    /// Folders full of small generated files: never where a large file you care about lives, and slow to walk.
    private static let skippedFolders: Set<String> = ["node_modules", "Pods", "DerivedData", "__pycache__", ".venv", "venv"]
    /// Packages we should never offer up as "large files".
    private static let protectedPackages: Set<String> = ["photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle"]

    /// `timeLimit` stops the walk after that many seconds and returns what was found (the progress is marked truncated).
    public static func scan(
        roots: [URL], minSize: Int64, progress: ScanProgress, timeLimit: TimeInterval? = nil
    ) async -> [FileEntry] {
        let deadline = timeLimit.map { Date().addingTimeInterval($0) }
        let parts = await boundedMap(roots, limit: max(1, roots.count)) { root in
            scanOne(root: root, minSize: minSize, progress: progress, deadline: deadline)
        }
        return parts.flatMap { $0 }.sorted { $0.size > $1.size }
    }

    private static func scanOne(root: URL, minSize: Int64, progress: ScanProgress, deadline: Date?) -> [FileEntry] {
        var out: [FileEntry] = []
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }) else { return [] }
        var n = 0
        for case let url as URL in walker {
            n += 1
            if n & 0x3F == 0 {
                if Task.isCancelled || progress.isCancelled || (deadline.map { Date() > $0 } ?? false) {
                    progress.markTruncated()
                    break
                }
                progress.setCurrent(url.deletingLastPathComponent().path)
            }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            if v.isDirectory == true, v.isPackage != true, skippedFolders.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            progress.add()
            if v.isRegularFile == true {
                let s = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                if s >= minSize {
                    out.append(FileEntry(url: url, size: s, modified: v.contentModificationDate, accessed: v.contentAccessDate))
                }
            } else if v.isPackage == true, !protectedPackages.contains(url.pathExtension.lowercased()) {
                let s = FileSizer.allocatedSize(of: url)
                if s >= minSize {
                    out.append(FileEntry(url: url, size: s, modified: v.contentModificationDate, accessed: v.contentAccessDate))
                }
            }
        }
        return out
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
