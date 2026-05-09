/// Monotonic identity for each generation request.
public struct GenerationRequestToken: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    static let zero = Self(rawValue: 0)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { "gen-\(rawValue)" }
}

/// Priority for queued generation requests.
/// Higher priority runs first; FIFO within the same level.
public enum GenerationPriority: Int, Comparable, Sendable {
    case background = 0
    case normal = 1
    case userInitiated = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
