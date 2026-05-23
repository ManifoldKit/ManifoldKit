import Foundation

/// Result a hook may return. The contract is **sanitize-only, not redirect**:
/// `updatedInput` may narrow or scrub the tool input (e.g. constrain a path
/// to a sandbox dir) but must reference the same logical target as the
/// original. To redirect or refuse, use `block: true` instead — wholesale
/// rewriting tool arguments produces incoherent transcripts because the
/// model's prior assistant message still references the original target.
public struct HookOutput: Sendable, Equatable {
    /// If non-nil, replaces the tool call's `arguments` JSON string before
    /// dispatch. Subject to the sanitize-only invariant above. Only honoured
    /// for `.preToolUse`.
    public let updatedInput: String?

    /// If true, the operation is cancelled — for `.preToolUse`, the tool
    /// call returns a typed denial without dispatching.
    public let block: Bool

    /// Optional message attached to the cancellation (when `block == true`).
    public let denyReason: String?

    public init(
        updatedInput: String? = nil,
        block: Bool = false,
        denyReason: String? = nil
    ) {
        self.updatedInput = updatedInput
        self.block = block
        self.denyReason = denyReason
    }

    /// Sentinel for "hook did nothing". Equivalent to a hook that wasn't
    /// registered at all.
    public static let passthrough = HookOutput()
}
