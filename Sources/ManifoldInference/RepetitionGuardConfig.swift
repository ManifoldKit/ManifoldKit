import Foundation

/// Tuning knobs for the streaming repetition guard.
///
/// The runtime's turn loop stops a generation when the accumulated visible (or
/// thinking) text looks like the model has fallen into a repetition loop —
/// endlessly repeating the same phrase or sentence. Detection is performed by
/// ``RepetitionDetector/looksLikeLooping(_:config:)`` and gated by
/// ``GenerationStreamConsumer/shouldStopForLoop(content:)``.
///
/// `TurnConfig.loopDetectionEnabled` is the on/off switch; this struct exposes
/// the detector's *thresholds* so a host can tune sensitivity without forking
/// the detector. Every field defaults to the value the detector shipped with
/// before the thresholds were surfaced, so ``default`` reproduces the historic
/// behaviour byte-for-byte — a host that never touches this value sees no change.
///
/// The detector runs two modes:
/// - **Triple-repeat (3×):** a unit of ``tripleRepeatMinimumUnit`` –
///   ``tripleRepeatMaximumUnit`` characters repeated three consecutive times.
/// - **Double-repeat (2×):** a longer unit of ``doubleRepeatMinimumUnit`` –
///   ``doubleRepeatMaximumUnit`` characters repeated twice consecutively.
public struct RepetitionGuardConfig: Sendable, Equatable, Codable {

    /// Minimum accumulated characters before the guard runs at all. Below this
    /// the guard is a no-op — short outputs are never flagged. Default: `100`.
    public var minimumTriggerCharacters: Int

    /// The detector only ever inspects the final `tailWindow` characters of the
    /// accumulated text, which keeps each call O(1) in total length. Default: `500`.
    public var tailWindow: Int

    /// Minimum characters required before 2× (double-repeat) detection runs.
    /// Default: `100`.
    public var doubleRepeatMinimumCharacters: Int

    /// Shortest repeated unit length considered for 2× detection. A single
    /// sentence repeated once is common in prose, so this is deliberately large.
    /// Default: `50`.
    public var doubleRepeatMinimumUnit: Int

    /// Longest repeated unit length considered for 2× detection. Default: `200`.
    public var doubleRepeatMaximumUnit: Int

    /// Minimum characters required before 3× (triple-repeat) detection runs.
    /// Default: `48`.
    public var tripleRepeatMinimumCharacters: Int

    /// Shortest repeated unit length considered for 3× detection. Default: `8`.
    public var tripleRepeatMinimumUnit: Int

    /// Longest repeated unit length considered for 3× detection. Default: `120`.
    public var tripleRepeatMaximumUnit: Int

    public init(
        minimumTriggerCharacters: Int = 100,
        tailWindow: Int = 500,
        doubleRepeatMinimumCharacters: Int = 100,
        doubleRepeatMinimumUnit: Int = 50,
        doubleRepeatMaximumUnit: Int = 200,
        tripleRepeatMinimumCharacters: Int = 48,
        tripleRepeatMinimumUnit: Int = 8,
        tripleRepeatMaximumUnit: Int = 120
    ) {
        self.minimumTriggerCharacters = minimumTriggerCharacters
        self.tailWindow = tailWindow
        self.doubleRepeatMinimumCharacters = doubleRepeatMinimumCharacters
        self.doubleRepeatMinimumUnit = doubleRepeatMinimumUnit
        self.doubleRepeatMaximumUnit = doubleRepeatMaximumUnit
        self.tripleRepeatMinimumCharacters = tripleRepeatMinimumCharacters
        self.tripleRepeatMinimumUnit = tripleRepeatMinimumUnit
        self.tripleRepeatMaximumUnit = tripleRepeatMaximumUnit
    }

    /// The historic default thresholds. Reproduces the detector's pre-exposure
    /// behaviour exactly.
    public static let `default` = RepetitionGuardConfig()
}
