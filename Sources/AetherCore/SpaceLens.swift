import Foundation
import CoreGraphics

public final class DiskNode: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let name: String
    public let url: URL
    public let isDirectory: Bool
    /// Synthetic bucket that stands in for many small items that were pruned from the tree.
    public let isOther: Bool
    public var size: Int64
    public var children: [DiskNode] = []
    public weak var parent: DiskNode?

    init(name: String, url: URL, isDirectory: Bool, size: Int64, isOther: Bool = false) {
        self.name = name; self.url = url; self.isDirectory = isDirectory; self.size = size; self.isOther = isOther
    }

    public var canDrill: Bool { isDirectory && !children.isEmpty }

    public var path: [DiskNode] {
        var out: [DiskNode] = []
        var n: DiskNode? = self
        while let c = n { out.insert(c, at: 0); n = c.parent }
        return out
    }
}

public enum SpaceLensScanner {
    private static let keys: Set<URLResourceKey> = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
    ]
    /// Anything smaller than this is folded into an "other" bucket to bound memory on huge trees.
    static let keepThreshold: Int64 = 1_000_000
    static let maxDepth = 7

    private static let skipNames: Set<String> = [".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems", "CloudStorage"]

    public static func scan(root: URL, progress: ScanProgress) async -> DiskNode {
        let rootNode = DiskNode(name: root.lastPathComponent.isEmpty ? "/" : root.lastPathComponent,
                                url: root, isDirectory: true, size: 0)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys), options: [])) ?? []

        var topDirs: [URL] = []
        var kids: [DiskNode] = []
        var other: Int64 = 0
        for e in entries where !skipNames.contains(e.lastPathComponent) {
            guard let v = try? e.resourceValues(forKeys: keys), v.isSymbolicLink != true else { continue }
            if v.isDirectory == true {
                topDirs.append(e)
            } else {
                let s = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                progress.add(bytes: s)
                if s >= keepThreshold { kids.append(DiskNode(name: e.lastPathComponent, url: e, isDirectory: false, size: s)) }
                else { other += s }
            }
        }

        let dirNodes = await boundedMap(topDirs) { dir in
            scanDir(dir, depth: 1, progress: progress)
        }
        for d in dirNodes {
            if d.size >= keepThreshold { kids.append(d) } else { other += d.size }
        }
        finish(rootNode, kids: kids, other: other)
        return rootNode
    }

    private static func scanDir(_ url: URL, depth: Int, progress: ScanProgress) -> DiskNode {
        let node = DiskNode(name: url.lastPathComponent, url: url, isDirectory: true, size: 0)
        if Task.isCancelled { return node }
        if depth == 1 || depth == 2 { progress.setCurrent(url.path) }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: [])) ?? []
        var kids: [DiskNode] = []
        var other: Int64 = 0
        for e in entries where !skipNames.contains(e.lastPathComponent) {
            guard let v = try? e.resourceValues(forKeys: keys), v.isSymbolicLink != true else { continue }
            if v.isDirectory == true {
                let child = scanDir(e, depth: depth + 1, progress: progress)
                if child.size >= keepThreshold { kids.append(child) } else { other += child.size }
            } else {
                let s = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                progress.add(bytes: s)
                if s >= keepThreshold { kids.append(DiskNode(name: e.lastPathComponent, url: e, isDirectory: false, size: s)) }
                else { other += s }
            }
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
            children.append(DiskNode(name: "Smaller items", url: node.url, isDirectory: false, size: other, isOther: true))
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
