import Foundation

/// Static cost table and estimator for common cloud inference models.
///
/// Rates are per million tokens (input / output) and were captured on
/// `costTableDate`. When a model is not in the table the estimator returns
/// a zero cost marked as approximate so callers can distinguish "free"
/// from "unknown".
public enum InferenceCostEstimator {

    /// ISO date string of the rate table bundled in this build.
    public static let costTableDate = "2026-05-24"

    // Per-million token prices: (inputUSD, outputUSD)
    // Sourced from public pricing pages as of costTableDate.
    private static let ratesPerMillion: [String: (input: Double, output: Double)] = [
        "claude-opus-4-7":      (15.00, 75.00),
        "claude-sonnet-4-6":    (3.00,  15.00),
        "claude-haiku-4-5":     (0.80,  4.00),
        "gpt-4o":               (2.50,  10.00),
        "gpt-4o-mini":          (0.15,  0.60),
    ]

    /// Estimates the cost of a single inference call.
    ///
    /// - Parameters:
    ///   - provider: Backend name (currently unused for routing; rates are
    ///     keyed by model identifier alone).
    ///   - model: Model identifier string. Compared case-insensitively against
    ///     the rate table; leading/trailing whitespace is stripped.
    ///   - promptTokens: Number of prompt tokens billed by the provider.
    ///   - completionTokens: Number of completion tokens billed by the provider.
    /// - Returns: A tuple with the estimated cost in USD and a flag indicating
    ///   whether the estimate is approximate (i.e. the model was not in the
    ///   rate table and the cost is zero rather than accurate).
    public static func estimatedCost(
        provider: String,
        model: String,
        promptTokens: Int,
        completionTokens: Int
    ) -> (usd: Double, isApproximate: Bool) {
        let key = model.trimmingCharacters(in: .whitespaces).lowercased()
        // Exact match first; fall back to prefix match for model variants
        // (e.g. "claude-sonnet-4-6-20261201" → "claude-sonnet-4-6").
        let rates: (input: Double, output: Double)?
        if let exact = ratesPerMillion[key] {
            rates = exact
        } else {
            rates = ratesPerMillion.first { key.hasPrefix($0.key) }?.value
        }

        guard let r = rates else {
            return (usd: 0, isApproximate: true)
        }

        let inputCost  = Double(promptTokens)    / 1_000_000 * r.input
        let outputCost = Double(completionTokens) / 1_000_000 * r.output
        return (usd: inputCost + outputCost, isApproximate: false)
    }
}
