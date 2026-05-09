import Foundation
import CryptoKit

public enum Severity: String, Codable, Sendable, Comparable {
    case flaky
    case confirmed
    case regression
    case crash

    private var rank: Int {
        switch self {
        case .flaky: return 0
        case .confirmed: return 1
        case .regression: return 2
        case .crash: return 3
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct Finding: Codable, Sendable, Hashable {
    public var detectorId: String
    public var subCheck: String
    public var severity: Severity
    public var hash: String
    public var trigger: String
    public var modelId: String
    public var firstSeen: String
    public var count: Int

    public init(
        detectorId: String,
        subCheck: String,
        severity: Severity,
        trigger: String,
        modelId: String,
        firstSeen: String = ISO8601DateFormatter().string(from: Date()),
        count: Int = 1
    ) {
        self.detectorId = detectorId
        self.subCheck = subCheck
        self.severity = severity
        self.trigger = trigger
        self.modelId = modelId
        self.firstSeen = firstSeen
        self.count = count
        self.hash = Self.computeHash(modelId: modelId, detectorId: detectorId, subCheck: subCheck, trigger: trigger)
    }

    static func computeHash(modelId: String, detectorId: String, subCheck: String, trigger: String) -> String {
        let key = "\(modelId)|\(detectorId)|\(subCheck)|\(String(trigger.prefix(200)))"
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(12).lowercased()
    }
}
