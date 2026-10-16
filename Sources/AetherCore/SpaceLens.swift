import Foundation
import CoreGraphics

public final class DiskNode: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let name: String
    /// Filesystem path. Kept as a string while scanning: building a URL per folder is measurable on a million-file tree.
    public let fsPath: String
    public let isDirectory: Bool
    /// Synthetic bucket that stands in for many small items that were pruned from the tree.
    public let isOther: Bool
    public var size: Int64
    public var children: [DiskNode] = []
    public weak var parent: DiskNode?

    init(name: String, fsPath: String, isDirectory: Bool, size: Int64, isOther: Bool = false) {
        self.name = name; self.fsPath = fsPath; self.isDirectory = isDirectory; self.size = size; self.isOther = isOther
    }

    public var url: URL { URL(fileURLWithPath: fsPath, isDirectory: isDirectory) }

    public var canDrill: Bool { isDirectory && !children.isEmpty }

    public var path: [DiskNode] {
        var out: [DiskNode] = []
        var n: DiskNode? = self
        while let c = n { out.insert(c, at: 0); n = c.parent }
        return out
    }
}

public enum SpaceLensScanner {
    /// Anything smaller than this is folded into an "other" bucket to bound memory on huge trees.
    static let keepThreshold: Int64 = 1_000_000
    static let maxDepth = 7
    /// Folders are scanned in parallel this many levels down; below that, one thread walks its own subtree.
    static let parallelDepth = 3

    /// `CloudStorage` holds third-party cloud mounts (Google Drive, Dropbox): reading them can hit the network.
    private static let skipNames: Set<String> = [".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems", "CloudStorage"]

    /// Cancelling the task (or calling `progress.cancel()`) returns at once with an empty tree, even if worker threads
    /// are still stuck waiting on macOS (for example on a privacy prompt).
    public static func scan(root: URL, progress: ScanProgress) async -> DiskNode {
        let name = root.lastPathComponent.isEmpty ? "/" : root.lastPathComponent
        let gate = ResultGate<DiskNode>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<DiskNode, Never>) in
                gate.install(c)
                DispatchQueue.global(qos: .userInitiated).async {
                    gate.finish(scanDir(path: root.path, name: name, depth: 0, progress: progress))
                }
                gate.watch(stop: { progress.isCancelled },
                           partial: { DiskNode(name: name, fsPath: root.path, isDirectory: true, size: 0) })
            }
        } onCancel: {
            progress.cancel()
        }
    }

    private static func scanDir(path: String, name: String, depth: Int, progress: ScanProgress) -> DiskNode {
        let node = DiskNode(name: name, fsPath: path, isDirectory: true, size: 0)
        if progress.isCancelled { return node }
        if depth <= 2 { progress.setCurrent(path) }
        guard let entries = BulkDir.read(path) else { return node }

        let prefix = path == "/" ? "" : path
        var kids: [DiskNode] = []
        var other: Int64 = 0
        var fileBytes: Int64 = 0
        var subdirs: [String] = []
        for e in entries where !skipNames.contains(e.name) {
            if e.type == BulkDir.regular {
                fileBytes += e.alloc
                if e.alloc >= keepThreshold { kids.append(DiskNode(name: e.name, fsPath: prefix + "/" + e.name, isDirectory: false, size: e.alloc)) }
                else { other += e.alloc }
            } else if e.type == BulkDir.directory, !e.isDataless {
                subdirs.append(e.name)
            }
        }
        progress.add(files: entries.count, bytes: fileBytes)

        var children = [DiskNode?](repeating: nil, count: subdirs.count)
        if depth < parallelDepth, subdirs.count > 1 {
            children.withUnsafeMutableBufferPointer { buffer in
                let base = buffer.baseAddress!
                DispatchQueue.concurrentPerform(iterations: subdirs.count) { i in
                    base[i] = scanDir(path: prefix + "/" + subdirs[i], name: subdirs[i], depth: depth + 1, progress: progress)
                }
            }
        } else {
            for (i, d) in subdirs.enumerated() {
                children[i] = scanDir(path: prefix + "/" + d, name: d, depth: depth + 1, progress: progress)
            }
        }
        for case let child? in children {
            if child.size >= keepThreshold { kids.append(child) } else { other += child.size }
        }

        if depth >= maxDepth {
            // Too deep to keep: collapse into a sized leaf directory.
            node.size = kids.reduce(0) { $0 + $1.size } + other
            return node
        }
        finish(node, kids: kids, other: other)
        return node
    }

    private static func finish(_ node: DiskNode, kids: [DiskNode], other: Int64) {
        var children = kids.sorted { $0.size > $1.size }
        if other > 0 {
            children.append(DiskNode(name: "Smaller items", fsPath: node.fsPath, isDirectory: false, size: other, isOther: true))
        }
        for c in children { c.parent = node }
        node.children = children
        node.size = children.reduce(0) { $0 + $1.size }
    }
}

// MARK: - Squarified treemap

public enum Squarify {
    /// Lays out `sizes` (must be sorted descending, all > 0) inside `rect`. Returns one rect per input, same order.
    public static func layout(sizes: [Double], in rect: CGRect) -> [CGRect] {
        let n = sizes.count
        guard n > 0, rect.width > 0, rect.height > 0 else { return Array(repeating: .zero, count: n) }
        let total = sizes.reduce(0, +)
        guard total > 0 else { return Array(repeating: .zero, count: n) }
        let scale = Double(rect.width * rect.height) / total
        let areas = sizes.map { $0 * scale }
        var out = [CGRect](repeating: .zero, count: n)
        var remaining = rect
        var i = 0

        func worst(_ sum: Double, _ maxA: Double, _ minA: Double, _ side: Double) -> Double {
            let s2 = sum * sum, w2 = side * side
            return max(w2 * maxA / s2, s2 / (w2 * minA))
        }

        while i < n {
            let side = Double(min(remaining.width, remaining.height))
            var rowSum = areas[i], rowMax = areas[i], rowMin = areas[i]
            var j = i + 1
            while j < n {
                let a = areas[j]
                let current = worst(rowSum, rowMax, rowMin, side)
                let next = worst(rowSum + a, max(rowMax, a), min(rowMin, a), side)
                if next <= current { rowSum += a; rowMax = max(rowMax, a); rowMin = min(rowMin, a); j += 1 } else { break }
            }
            if remaining.width >= remaining.height {
                let w = CGFloat(rowSum / Double(remaining.height))
                var y = remaining.minY
                for k in i..<j {
                    let h = CGFloat(areas[k]) / w
                    out[k] = CGRect(x: remaining.minX, y: y, width: w, height: h)
                    y += h
                }
                remaining = CGRect(x: remaining.minX + w, y: remaining.minY, width: max(0, remaining.width - w), height: remaining.height)
            } else {
                let h = CGFloat(rowSum / Double(remaining.width))
                var x = remaining.minX
                for k in i..<j {
                    let w = CGFloat(areas[k]) / h
                    out[k] = CGRect(x: x, y: remaining.minY, width: w, height: h)
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + h, width: remaining.width, height: max(0, remaining.height - h))
            }
            i = j
        }
        return out
    }
}
