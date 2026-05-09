import Foundation

// MARK: - Streaming argument accumulator

/// Buffers tool-call deltas indexed by `index` (Chat Completions) or by
/// `item_id`→`call_id` mapping (Responses) so backends can emit
/// `.toolCallStart` once, stream `.toolCallArgumentsDelta` events, and fire
/// `.toolCall` only when the entry is finalized.
///
/// Compat servers (Together, Groq) sometimes drop `id` after the first delta
/// for a given index — the accumulator keys on integer index so subsequent
/// argument fragments still land in the right slot. The first non-empty `id`
/// observed for a given index is sticky.
///
/// This type is OpenAI-shaped (slot-keyed by index and id) — it is NOT a
/// generic streaming primitive. Preserve its exact semantics; do not
/// over-generalise.
package final class StreamingArgumentAccumulator {

    package struct Entry {
        package var id: String
        package var name: String
        package var arguments: String
        /// Whether `.toolCallStart` has already been emitted for this entry.
        package var started: Bool
    }

    /// Tracks entries in insertion order so `.toolCall` events can be
    /// emitted in the same order the model produced them, regardless of
    /// arrival interleaving. Keyed by `index` (Chat Completions) or by
    /// `item_id` (Responses).
    package private(set) var entriesByKey: [String: Entry] = [:]
    package private(set) var orderedKeys: [String] = []

    package init() {}

    /// Returns `true` if a new entry was created (caller should emit
    /// `.toolCallStart` if a name is now known and this is the first sighting).
    @discardableResult
    package func upsert(key: String, id: String?, name: String?, argumentsDelta: String?) -> Bool {
        if var existing = entriesByKey[key] {
            // Sticky id: first non-empty id wins.
            if existing.id.isEmpty, let id, !id.isEmpty {
                existing.id = id
            }
            if existing.name.isEmpty, let name, !name.isEmpty {
                existing.name = name
            }
            if let argumentsDelta {
                existing.arguments.append(argumentsDelta)
            }
            entriesByKey[key] = existing
            return false
        } else {
            let entry = Entry(
                id: id ?? "",
                name: name ?? "",
                arguments: argumentsDelta ?? "",
                started: false
            )
            entriesByKey[key] = entry
            orderedKeys.append(key)
            return true
        }
    }

    /// Marks the entry's `.toolCallStart` as emitted.
    package func markStarted(key: String) {
        guard var entry = entriesByKey[key] else { return }
        entry.started = true
        entriesByKey[key] = entry
    }

    /// Returns the resolved call id for this key, synthesising a deterministic
    /// fallback when the wire never delivered one (rare, but observed on some
    /// compat servers).
    package func resolvedId(forKey key: String) -> String {
        guard let entry = entriesByKey[key] else { return key }
        if !entry.id.isEmpty { return entry.id }
        // Fallback: stable per-stream id derived from the key. Ids are only
        // used for call/result pairing inside one turn so a deterministic
        // synthetic value is sufficient.
        return "openai-call-\(key)"
    }

    /// Returns all completed entries in insertion order. `entry.arguments`
    /// is normalised to `"{}"` when empty so downstream JSON consumers can
    /// always parse the value.
    package func finalizedEntries() -> [(callId: String, name: String, arguments: String)] {
        orderedKeys.compactMap { key in
            guard let entry = entriesByKey[key] else { return nil }
            let id = !entry.id.isEmpty ? entry.id : "openai-call-\(key)"
            let name = entry.name
            // Drop entries with no name — the model never finished declaring
            // them, so we can't dispatch them anyway.
            guard !name.isEmpty else { return nil }
            let args = entry.arguments.isEmpty ? "{}" : entry.arguments
            return (callId: id, name: name, arguments: args)
        }
    }
}
