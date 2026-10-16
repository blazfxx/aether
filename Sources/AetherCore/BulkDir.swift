import Darwin
import Foundation

struct BulkEntry {
    let name: String
    /// vnode type: 1 regular file, 2 directory, 5 symlink.
    let type: UInt32
    let flags: UInt32
    /// Bytes allocated on disk (0 for directories and for iCloud files that are not downloaded).
    let alloc: Int64
    /// Seconds since 1970; 0 unless dates were requested.
    let modified: Int
    let accessed: Int

    /// SF_DATALESS: the item lives in iCloud (or another provider) and is not stored on this Mac. Opening a dataless
    /// folder makes macOS fetch its listing, which can block for minutes, so scans never go inside one.
    var isDataless: Bool { flags & 0x4000_0000 != 0 }
}

/// Directory listing through `getattrlistbulk(2)`: one syscall returns name, type, size and dates for many entries,
/// where Foundation's enumerator needs several calls per file. This is what makes Space Lens and the file scans fast.
enum BulkDir {
    static let regular: UInt32 = 1
    static let directory: UInt32 = 2
    static let symlink: UInt32 = 5

    // <sys/attr.h> values, spelled out so they have one concrete type.
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnAccTime: UInt32 = 0x0000_1000
    private static let cmnFlags: UInt32 = 0x0004_0000
    private static let fileAllocSize: UInt32 = 0x0000_0004
    private static let fsoptPackInvalAttrs: UInt64 = 0x0000_0008

    private static let bufferSize = 256 * 1024

    /// Entries of a directory, or nil if it can't be opened (missing, or blocked by macOS privacy protections).
    static func read(_ path: String, dates: Bool = false) -> [BulkEntry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = cmnReturnedAttrs | cmnName | cmnObjType | cmnFlags | (dates ? (cmnModTime | cmnAccTime) : 0)
        list.fileattr = fileAllocSize

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var out: [BulkEntry] = []
        while true {
            let count = getattrlistbulk(fd, &list, buffer, bufferSize, fsoptPackInvalAttrs)
            if count < 0 { return out.isEmpty ? nil : out }
            if count == 0 { break }

            var cursor = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let start = cursor
                let length = Int(start.loadUnaligned(as: UInt32.self))
                var p = start + 4
                let returned = p.loadUnaligned(as: attribute_set_t.self)
                p += MemoryLayout<attribute_set_t>.size

                var name = ""
                if returned.commonattr & cmnName != 0 {
                    let ref = p.loadUnaligned(as: attrreference_t.self)
                    let namePtr = (p + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                    name = String(cString: namePtr)
                    p += MemoryLayout<attrreference_t>.size
                }
                var type: UInt32 = 0
                if returned.commonattr & cmnObjType != 0 { type = p.loadUnaligned(as: UInt32.self); p += 4 }
                var modified = 0, accessed = 0
                if returned.commonattr & cmnModTime != 0 { modified = Int(p.loadUnaligned(as: timespec.self).tv_sec); p += MemoryLayout<timespec>.size }
                if returned.commonattr & cmnAccTime != 0 { accessed = Int(p.loadUnaligned(as: timespec.self).tv_sec); p += MemoryLayout<timespec>.size }
                var flags: UInt32 = 0
                if returned.commonattr & cmnFlags != 0 { flags = p.loadUnaligned(as: UInt32.self); p += 4 }
                var alloc: Int64 = 0
                if returned.fileattr & fileAllocSize != 0 { alloc = p.loadUnaligned(as: Int64.self); p += 8 }

                if !name.isEmpty {
                    out.append(BulkEntry(name: name, type: type, flags: flags, alloc: alloc, modified: modified, accessed: accessed))
                }
                cursor = start + length
            }
        }
        return out
    }

    /// Recursive on-disk size of a directory tree. Symlinks are not followed.
    static func totalSize(_ path: String, shouldStop: () -> Bool = { false }) -> Int64 {
        var total: Int64 = 0
        var stack = [path]
        while let dir = stack.popLast() {
            if shouldStop() { break }
            guard let entries = read(dir) else { continue }
            let prefix = dir == "/" ? "" : dir
            for e in entries {
                if e.type == regular { total += e.alloc }
                else if e.type == directory, !e.isDataless { stack.append(prefix + "/" + e.name) }
            }
        }
        return total
    }
}
