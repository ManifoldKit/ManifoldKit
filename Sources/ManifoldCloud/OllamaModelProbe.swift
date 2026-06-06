#if Ollama
import Foundation
import os
import ManifoldInference

/// Decoded subset of Ollama's `/api/show` response we actually consume.
struct OllamaShowProbe {
    let thinking: Bool
    let thinkingMarkers: ThinkingMarkers?
    let contextLength: Int?

    static let empty = OllamaShowProbe(thinking: false, thinkingMarkers: nil, contextLength: nil)
}

enum OllamaModelProbe {

    /// Calls Ollama's `/api/show` endpoint and extracts thinking capability,
    /// auto-detected thinking markers, and the model's true context window.
    ///
    /// Thinking detection prefers `capabilities: ["thinking", ...]` (surfaced
    /// by modern Ollama releases) and falls back to auto-detecting marker pairs
    /// from the Jinja `template` field via ``ThinkingMarkers/fromChatTemplate(_:)``.
    /// Any template that yields a recognised ``ThinkingMarkers`` preset — including
    /// Gemma 4's `<|turn>think\n` / `<|end_of_turn>` family which Ollama does not
    /// yet advertise in the capabilities list — causes the thinking flag to be
    /// set. ``ThinkingMarkers`` are surfaced on the probe result so the
    /// wire-format fallback path (`OllamaBackend.parseResponseStream`) can route
    /// reasoning content through ``ThinkingTransform`` without hardcoding a
    /// specific marker pair.
    ///
    /// Context length is read from `model_info.context_length`. On HTTP
    /// failures or shape mismatches the probe returns ``ShowProbe/empty``;
    /// only true network exceptions throw, so callers can wrap the call in
    /// `try?` for best-effort behaviour.
    static func probeShow(baseURL: URL, modelName: String, urlSession: URLSession) async throws -> OllamaShowProbe {
        let showURL = baseURL.appendingPathComponent("api/show")

        var request = URLRequest(url: showURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelName])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            Log.network.info("OllamaBackend /api/show probe failed (\(error.localizedDescription, privacy: .public)) — treating \(modelName, privacy: .public) as non-thinking")
            return .empty
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            Log.network.info("OllamaBackend /api/show returned HTTP \(http.statusCode, privacy: .public) for \(modelName, privacy: .public) — treating as non-thinking")
            return .empty
        }

        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Log.network.info("OllamaBackend /api/show returned non-object JSON for \(modelName, privacy: .public) — treating as non-thinking")
                return .empty
            }
            json = parsed
        } catch {
            Log.network.info("OllamaBackend /api/show returned non-JSON for \(modelName, privacy: .public) — treating as non-thinking")
            return .empty
        }

        // Thinking capability — prefer the structured capabilities list.
        var thinking = false
        if let caps = json["capabilities"] as? [String],
           caps.contains(where: { $0.lowercased() == "thinking" }) {
            thinking = true
        }

        // Thinking markers — auto-detect from the Jinja template via the
        // shared ``PromptTemplateDetector`` rules. Then opportunistically
        // back-fill the thinking flag when the template carries a
        // recognised marker pair.
        var detectedMarkers: ThinkingMarkers?
        if let template = json["template"] as? String {
            detectedMarkers = ThinkingMarkers.fromChatTemplate(template)
            // Any template that carries a recognised marker pair implies
            // thinking capability — covers Gemma 4 (`<|turn>think\n`) and other
            // families that Ollama's capabilities list doesn't yet advertise.
            if !thinking && detectedMarkers != nil {
                thinking = true
            }
        }

        // model_info.context_length — the authoritative wire value. Missing
        // on snapshots compiled from older Modelfiles; fall back to the
        // caller's plan-derived window in that case.
        var contextLength: Int?
        if let modelInfo = json["model_info"] as? [String: Any] {
            // Ollama reports context length under either the canonical
            // `context_length` key or the architecture-prefixed
            // `<arch>.context_length` (e.g. `llama.context_length`).
            for (key, value) in modelInfo where key.hasSuffix("context_length") {
                if let int = value as? Int, int > 0 {
                    contextLength = int
                    break
                }
                if let int64 = value as? Int64, int64 > 0 {
                    contextLength = Int(int64)
                    break
                }
            }
        }

        return OllamaShowProbe(
            thinking: thinking,
            thinkingMarkers: detectedMarkers,
            contextLength: contextLength
        )
    }

    /// Extracts an error message from an Ollama error response body.
    ///
    /// Ollama error format: `{"error":"model not found"}`
    static func extractErrorMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8) else { return nil }
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = parsed["error"] as? String else {
                return nil
            }
            return message
        } catch {
            return nil
        }
    }
}
#endif
