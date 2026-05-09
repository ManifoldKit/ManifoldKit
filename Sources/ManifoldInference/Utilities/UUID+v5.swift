import Foundation
import CryptoKit

extension UUID {
    /// Creates a version-5 (SHA-1 name-based) UUID per RFC 4122 §4.3.
    ///
    /// Given the same namespace and name, this always returns the same UUID.
    /// Used by `ModelInfo` to produce stable IDs from file paths so that
    /// model selection survives `refreshModels()` rescans.
    static func v5(namespace: UUID, name: String) -> UUID {
        let namespaceBytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        let nameBytes = Array(name.utf8)

        var sha1 = Insecure.SHA1()
        sha1.update(data: namespaceBytes)
        sha1.update(data: nameBytes)
        let hash = Array(sha1.finalize())

        // Set version (4 bits) to 0101 (v5) and variant (2 bits) to 10.
        var uuid = (
            hash[0], hash[1], hash[2], hash[3],
            hash[4], hash[5],
            (hash[6] & 0x0F) | 0x50,  // version 5
            hash[7],
            (hash[8] & 0x3F) | 0x80,  // variant 10
            hash[9], hash[10], hash[11],
            hash[12], hash[13], hash[14], hash[15]
        )

        return UUID(uuid: uuid)
    }
}
