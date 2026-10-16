import Foundation

public enum FileSizer {
    static let keys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
    ]

    /// On-disk (allocated) size of a file, or the recursive total of a directory. Symlinks count as zero.
    public static func allocatedSize(of url: URL) -> Int64 {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isRegularFile == true { return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        guard v.isDirectory == true,
              let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        var n = 0
        for case let child as URL in walker {
            n += 1
            if n & 0x3FF == 0, Task.isCancelled { break }
            guard let cv = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if cv.isRegularFile == true {
                total += Int64(cv.totalFileAllocatedSize ?? cv.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    public static func children(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    public static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
