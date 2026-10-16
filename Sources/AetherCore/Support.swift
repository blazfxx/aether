import Foundation

public enum Bytes {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()

    /// Finder-style (base 10) size string.
    public static func string(_ n: Int64) -> String {
        if n <= 0 { return "Zero KB" }
        return formatter.string(fromByteCount: n)
    }
}

public extension URL {
    /// Path with the home directory abbreviated to `~`.
    var tildePath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// Runs `transform` over `items` with at most `limit` in flight. Result order is not preserved.
public func boundedMap<T: Sendable, R: Sendable>(
    _ items: [T],
    limit: Int = max(2, ProcessInfo.processInfo.activeProcessorCount - 1),
    _ transform: @escaping @Sendable (T) async -> R
) async -> [R] {
    await withTaskGroup(of: R.self) { group in
        var iterator = items.makeIterator()
        var results: [R] = []
        results.reserveCapacity(items.count)
        for _ in 0..<limit {
            guard let next = iterator.next() else { break }
            group.addTask { await transform(next) }
        }
        while let done = await group.next() {
            results.append(done)
            if let next = iterator.next() {
                group.addTask { await transform(next) }
            }
        }
        return results
    }
}

/// Thread-safe counters the UI can poll while a scan is running.
public final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _files = 0
    private var _bytes: Int64 = 0
    private var _current = ""
    private var _cancelled = false
    private var _truncated = false

    public init() {}

    /// Asks the scan using this to stop early and return what it has found so far.
    public func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    /// Set by a scan that stopped before it finished (cancelled or out of time).
    public func markTruncated() { lock.lock(); _truncated = true; lock.unlock() }
    public var wasTruncated: Bool { lock.lock(); defer { lock.unlock() }; return _truncated }

    public func reset() { lock.lock(); _files = 0; _bytes = 0; _current = ""; _cancelled = false; _truncated = false; lock.unlock() }

    public func add(files: Int = 1, bytes: Int64 = 0) {
        lock.lock(); _files += files; _bytes += bytes; lock.unlock()
    }

    public func setCurrent(_ s: String) {
        lock.lock(); _current = s; lock.unlock()
    }

    public var snapshot: (files: Int, bytes: Int64, current: String) {
        lock.lock(); defer { lock.unlock() }
        return (_files, _bytes, _current)
    }
}

/// Hands a result to an async caller exactly once, from whichever finishes first: the worker, or a stop request.
/// Worker threads can be blocked inside the kernel (for example while macOS waits for a privacy prompt to be answered)
/// and cannot be interrupted, so the caller must not wait on them.
final class ResultGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: T?
    private var continuation: CheckedContinuation<T, Never>?

    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }

    func install(_ c: CheckedContinuation<T, Never>) {
        lock.lock()
        if let r = result { lock.unlock(); c.resume(returning: r) } else { continuation = c; lock.unlock() }
    }

    func finish(_ value: T) {
        lock.lock()
        if result != nil { lock.unlock(); return }
        result = value
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    /// Polls `stop` and finishes the gate with `partial()` as soon as it says so.
    func watch(stop: @escaping @Sendable () -> Bool, partial: @escaping @Sendable () -> T) {
        DispatchQueue.global(qos: .utility).async { [self] in
            while !isDone {
                Thread.sleep(forTimeInterval: 0.2)
                if stop() { finish(partial()); return }
            }
        }
    }
}
