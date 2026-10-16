import Foundation

public enum FileSizer {
    /// On-disk (allocated) size of a file, or the recursive total of a directory. Symlinks count as zero.
    public static func allocatedSize(of url: URL) -> Int64 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return Int64(st.st_blocks) * 512
        case S_IFDIR: return BulkDir.totalSize(url.path) { Task.isCancelled }
        default: return 0
        }
    }

    public static func children(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    public static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
