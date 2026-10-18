import Foundation

/// A dotted version number such as `1.0.2` or `v2.10`. Compared numerically, so 1.10 > 1.9.
/// Anything after the first non-numeric component (`-beta`, `b3`) is ignored.
public struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let raw: String
    let parts: [Int]

    public init(_ string: String) {
        raw = string
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        var numbers: [Int] = []
        var current = ""
        for ch in text {
            if ch.isASCII, ch.isNumber { current.append(ch) }
            else if ch == ".", !current.isEmpty { numbers.append(Int(current) ?? 0); current = "" }
            else { break }
        }
        if !current.isEmpty { numbers.append(Int(current) ?? 0) }
        parts = numbers
    }

    public var description: String { raw }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { compare(a, b) == 0 }
    public static func < (a: AppVersion, b: AppVersion) -> Bool { compare(a, b) < 0 }

    private static func compare(_ a: AppVersion, _ b: AppVersion) -> Int {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    public var isValid: Bool { !parts.isEmpty }
}
