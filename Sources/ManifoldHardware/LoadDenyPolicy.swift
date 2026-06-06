import Foundation

/// Policy applied when a ``ModelLoadPlan`` produces a ``ModelLoadPlan/Verdict/deny`` verdict.
///
/// Three-way policy giving custom hooks full access to the plan (including `reasons`)
/// before deciding whether a load should proceed or fail.
public enum LoadDenyPolicy: Sendable {
    /// Throw ``InferenceError/memoryInsufficient``. iOS default — the app is jetsam-bound
    /// and unsafe loads should fail fast.
    case throwError

    /// Log a warning and proceed. macOS default — swap/pressure is tolerable and user
    /// choice may override conservative estimates.
    case warnOnly

    /// Hand off to a caller-supplied closure. The closure may throw to reject, or return
    /// normally to proceed. Receives the full plan so it can read `reasons` and make
    /// nuanced decisions.
    case custom(@Sendable (ModelLoadPlan) throws -> Void)

    /// Platform-appropriate default: ``LoadDenyPolicy/throwError`` on iOS,
    /// ``LoadDenyPolicy/warnOnly`` on macOS.
    public static var platformDefault: LoadDenyPolicy {
        #if os(iOS) || os(tvOS) || os(watchOS)
        return .throwError
        #else
        return .warnOnly
        #endif
    }
}
