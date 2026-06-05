import Foundation

/// Sanitises upstream HTTP error messages before they are surfaced via
/// ``CloudBackendError/serverError(statusCode:message:)``.
///
/// Upstream cloud providers (OpenAI, Anthropic, Ollama) and user-configured
/// custom endpoints may return error bodies that contain HTML from transparent
/// proxies (e.g. a Cloudflare 502 page), control characters, multi-kilobyte
/// stack traces, or accidentally echoed tokens/URLs. Surfacing these raw to the
/// UI risks:
///
/// 1. **Content injection** — any future UI that renders an error as attributed
///    text, markdown, or HTML would silently regress, allowing an attacker who
///    controls the upstream response (or the custom endpoint) to inject
///    clickable/styled content into the chat surface.
/// 2. **Information leakage** — internal service names, trace IDs, backend URLs,
///    or stack traces leaking to end users.
/// 3. **Denial-of-UX** — multi-kilobyte strings wedging error banners.
///
/// ``sanitize(_:host:)`` enforces:
/// - Drop all non-printable characters (zero-width joiners, RTL override,
///   control bytes, etc.) except whitespace which is collapsed to a single
///   space.
/// - Reject HTML-shaped bodies (contain ``<`` followed by an ASCII letter) and
///   replace them with a generic "Server error" fallback.
/// - Redact messages that look like they contain JWTs (``eyJ...``) or URLs
///   (``http://`` / ``https://``), because these frequently represent tokens or
///   callback URLs that a confused upstream echoed back.
/// - Truncate to 256 UTF-8 characters with an ellipsis.
///
/// The function is pure, idempotent, and safe to call on already-sanitised
/// input.
///
/// `public` so that sibling modules (`ManifoldCloud`) can call it when
/// sanitising in-stream SSE error events as well as non-2xx HTTP bodies.
/// Host apps should not need to invoke this directly.
public enum CloudErrorSanitizer {

    /// Maximum length of the sanitised message in characters, including the
    /// trailing ellipsis when truncation applies.
    public static let maxLength = 256

    /// Sanitises a raw upstream error string for UI surfacing.
    ///
    /// - Parameters:
    ///   - raw: The message as extracted from the upstream body (may be `nil`).
    ///   - host: The upstream host used to build the generic fallback. Pass the
    ///     value of ``URL.host()`` from the configured base URL, or `nil` when
    ///     unknown.
    /// - Returns: A safe, bounded string suitable for use as a
    ///   ``CloudBackendError/serverError(statusCode:message:)`` message.
    public static func sanitize(_ raw: String?, host: String? = nil) -> String {
        guard let raw, !raw.isEmpty else {
            return genericServerError(host: host)
        }

        // Step 1 — collapse whitespace and drop control/zero-width/RTL-override
        // characters. We do this first so length heuristics run against the
        // cleaned form.
        let cleaned = stripControlAndCollapseWhitespace(raw)

        if cleaned.isEmpty {
            return genericServerError(host: host)
        }

        // Step 2 — reject HTML-shaped payloads (transparent proxy pages,
        // Cloudflare 5xx interstitials, etc.) and short-circuit to a generic
        // fallback. We use a conservative heuristic: `<` followed by an ASCII
        // letter is a strong indicator of a tag opener, while `<` in
        // conversational prose ("value < 100") almost never precedes a letter
        // without a space.
        if containsHTMLTag(cleaned) {
            return genericServerError(host: host)
        }

        // Step 3 — redact bodies that look like they are carrying URLs or JWTs.
        // An honest error message should never contain these; if it does, the
        // upstream is almost certainly echoing back a token or callback URL
        // that we should not surface.
        if containsURLOrJWT(cleaned) {
            return genericServerError(host: host)
        }

        // Step 4 — cap length with an ellipsis. The ellipsis character `…` is a
        // single Unicode scalar so it counts as one character toward the cap.
        return truncate(cleaned, to: maxLength)
    }

    // MARK: - Private helpers

    /// Collapses runs of whitespace (including newlines) into a single ASCII
    /// space and removes anything that is neither a Unicode letter, number,
    /// punctuation, symbol, nor whitespace.
    ///
    /// This preserves readable prose in any language but drops:
    /// - C0/C1 control bytes (bell, backspace, CR/LF as-is, etc.)
    /// - Zero-width joiners, zero-width spaces, and BOMs
    /// - RTL override / LRO / PDF bidirectional overrides
    /// - Private-use-area and unassigned scalars
    private static func stripControlAndCollapseWhitespace(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var lastWasWhitespace = false

        for scalar in input.unicodeScalars {
            let value = scalar.value

            // Reject bidirectional override / zero-width formatting characters
            // outright — they have no honest place in a server error message.
            if isBidiOrZeroWidthFormatting(value) {
                continue
            }

            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasWhitespace && !result.isEmpty {
                    result.append(" ")
                    lastWasWhitespace = true
                }
                continue
            }

            let category = scalar.properties.generalCategory
            switch category {
            case .lowercaseLetter, .uppercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber,
                 .dashPunctuation, .openPunctuation, .closePunctuation, .connectorPunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                result.unicodeScalars.append(scalar)
                lastWasWhitespace = false
            default:
                // Control / format / surrogate / private-use / unassigned.
                continue
            }
        }

        // Trim a trailing space left by the collapse.
        if result.hasSuffix(" ") {
            result.removeLast()
        }
        return result
    }

    /// True for scalars that should always be stripped even though some of
    /// them fall into the Unicode "format" or "other symbol" categories.
    private static func isBidiOrZeroWidthFormatting(_ value: UInt32) -> Bool {
        switch value {
        case 0x200B, 0x200C, 0x200D,           // zero-width space / ZWNJ / ZWJ
             0x200E, 0x200F,                    // LTR / RTL mark
             0x202A, 0x202B, 0x202C, 0x202D, 0x202E, // LRE, RLE, PDF, LRO, RLO
             0x2066, 0x2067, 0x2068, 0x2069,    // LRI, RLI, FSI, PDI
             0xFEFF:                            // BOM / zero-width no-break space
            return true
        default:
            return false
        }
    }

    /// Returns `true` when the string contains `<` directly followed by an
    /// ASCII letter, indicating an HTML tag opener.
    ///
    /// The pairwise scan expresses its upper bound as `scalars.count - 1`, so
    /// it must not be called with fewer than two scalars — with zero scalars
    /// the range would trap as `0..<-1`. `sanitize(_:host:)` already early-
    /// returns for empty input, but we guard here defensively because a
    /// reorder upstream would otherwise be a crash rather than a logic bug.
    ///
    /// Exposed at `internal` so that unit tests can exercise the empty and
    /// single-character edge cases without having to round-trip through
    /// `sanitize(_:host:)`'s early returns.
    static func containsHTMLTag(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        guard scalars.count >= 2 else { return false }
        for i in 0..<(scalars.count - 1) where scalars[i].value == 0x3C { // '<'
            let next = scalars[i + 1].value
            let isLetter = (next >= 0x41 && next <= 0x5A) || (next >= 0x61 && next <= 0x7A)
            if isLetter { return true }
        }
        return false
    }

    /// Returns `true` when the string contains a URL scheme (``http://``,
    /// ``https://``) or a likely JWT prefix (``eyJ``). Case-insensitive.
    private static func containsURLOrJWT(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.contains("http://") || lower.contains("https://") {
            return true
        }
        // JWTs are base64url-encoded; the header `{"alg":` encodes to `eyJhbGc`,
        // and `{"typ":` encodes to `eyJ0eXA`. Any `eyJ` prefix followed by at
        // least a handful of base64 characters is a strong indicator. We use
        // the case-sensitive original here — base64 is case-sensitive.
        if s.contains("eyJ") {
            return true
        }
        return false
    }

    /// Truncates a string to at most `limit` characters, appending an ellipsis
    /// when truncation occurs. The returned string's count is always ≤ `limit`.
    private static func truncate(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        // Reserve one character for the ellipsis.
        let prefix = s.prefix(limit - 1)
        return "\(prefix)\u{2026}"
    }

    /// Generic fallback message used whenever the raw body is unsafe to
    /// surface. Mentions the upstream host when known so that users with
    /// multiple configured endpoints can tell which one failed.
    private static func genericServerError(host: String?) -> String {
        if let host, !host.isEmpty {
            return "Server error from \(host)"
        }
        return "Server error"
    }
}

