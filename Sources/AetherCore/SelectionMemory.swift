import Foundation

/// Remembers which items the user ticked or un-ticked, so the next scan starts the way they left it.
/// Only explicit choices are stored; everything else follows the item's default.
public final class SelectionMemory: @unchecked Sendable {
    public static let shared = SelectionMemory()

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private var overrides: [String: Bool]
    /// Old entries are dropped first once the list grows past this, so it can't grow without bound.
    private let limit = 4000
    private var order: [String]

    public init(defaults: UserDefaults = .standard, key: String = "aether.selectionOverrides") {
        self.defaults = defaults
        self.key = key
        let stored = defaults.dictionary(forKey: key) as? [String: Bool] ?? [:]
        overrides = stored
        order = defaults.stringArray(forKey: key + ".order") ?? Array(stored.keys)
    }

    /// `true`/`false` if the user chose, `nil` if they never touched it.
    public func choice(for url: URL) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return overrides[url.path]
    }

    /// Whether an item should start selected: the user's earlier choice, else the default.
    public func isSelected(_ url: URL, default fallback: Bool) -> Bool {
        choice(for: url) ?? fallback
    }

    public func set(_ url: URL, selected: Bool) {
        lock.lock()
        record(url.path, selected)
        lock.unlock()
        save()
    }

    public func set(_ urls: [URL], selected: Bool) {
        lock.lock()
        for u in urls { record(u.path, selected) }
        lock.unlock()
        save()
    }

    public func forgetAll() {
        lock.lock(); overrides = [:]; order = []; lock.unlock()
        save()
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return overrides.count }

    private func record(_ path: String, _ value: Bool) {
        if overrides[path] == nil { order.append(path) }
        overrides[path] = value
        if order.count > limit {
            for old in order.prefix(order.count - limit) { overrides[old] = nil }
            order.removeFirst(order.count - limit)
        }
    }

    private func save() {
        lock.lock()
        let snapshot = overrides, ordered = order
        lock.unlock()
        defaults.set(snapshot, forKey: key)
        defaults.set(ordered, forKey: key + ".order")
    }
}
