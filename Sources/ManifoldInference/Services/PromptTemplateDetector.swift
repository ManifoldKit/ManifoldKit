import Foundation

/// Detects the best `PromptTemplate` for a model based on GGUF metadata.
///
/// Uses a cascading strategy:
/// 1. If architecture maps to an unambiguous format (phi, gemma, mistral), trust it —
///    some Jinja templates contain compatibility-branch tokens from other formats.
/// 2. If a Jinja chat template string is present, pattern-match on template tokens.
/// 3. If only the model name is available, use keyword heuristics.
/// 4. Falls back to ChatML (the most widely compatible format).
struct PromptTemplateDetector {

    /// Detects the best prompt template from GGUF metadata.
    ///
    /// Architecture wins for unambiguous formats. For ambiguous architectures
    /// (e.g. "llama", where many fine-tunes use different chat formats), the
    /// Jinja template takes precedence over the architecture field.
    static func detect(from metadata: GGUFMetadata) -> PromptTemplate {
        // 1. Architecture wins for unambiguous formats — some phi3/phi4 Jinja templates
        //    contain <|im_start|> in compatibility branches, which fires the ChatML
        //    heuristic before the phi-specific token check.
        if let arch = metadata.generalArchitecture {
            let result = detect(fromArchitecture: arch)
            if result != .chatML { return result }
        }
        // 2. Chat template for ambiguous architectures (e.g. "llama" maps many
        //    fine-tunes that use different formats the architecture can't distinguish).
        if let chatTemplate = metadata.chatTemplate {
            return detect(fromChatTemplate: chatTemplate)
        }
        // 3. Model name heuristic as last resort.
        if let name = metadata.generalName {
            return detect(fromFileName: name)
        }
        return .chatML // default
    }

    /// Detects a prompt template from a Jinja chat template string.
    ///
    /// Looks for unique token markers that identify each format. Order matters:
    /// more specific patterns (ChatML, Llama 3, Gemma) are checked before broader
    /// ones (Mistral `[INST]`, Alpaca `### Instruction`).
    static func detect(fromChatTemplate template: String) -> PromptTemplate {
        if template.contains("<|im_start|>") { return .chatML }
        if template.contains("<|start_header_id|>") { return .llama3 }
        // Gemma 4 uses <|turn> — check before Gemma 1/2/3's <start_of_turn> since
        // both could theoretically coexist in a transitional template.
        if template.contains("<|turn>") { return .gemma4 }
        if template.contains("<start_of_turn>") { return .gemma }
        if template.contains("<|user|>") && template.contains("<|assistant|>") { return .phi }
        if template.contains("[INST]") { return .mistral }
        if template.contains("### Instruction") { return .alpaca }
        return .chatML
    }

    /// Detects which `ThinkingMarkers` preset (if any) a Jinja chat template
    /// advertises.
    ///
    /// Pure substring matching. Both halves of a marker pair must appear in
    /// the template for that family to be returned — a stray `<think>` with no
    /// closer is not a thinking template. Returns `nil` when no known pair
    /// matches, signalling that the model does not emit reasoning blocks.
    ///
    /// Precedence (most specific first): qwen3 → mistralReasoning → phi4 →
    /// reflection → gemma4. The first family whose tag pair appears in the
    /// template wins, so a Frankenstein template that mentions multiple
    /// pairs collapses to the most-Qwen-like one. That's deliberate — the
    /// chat-template tags say what the model *emits*, and Qwen-style is the
    /// default for the families we ship presets for.
    static func detectThinkingMarkers(from chatTemplate: String) -> ThinkingMarkers? {
        if chatTemplate.contains("<think>") && chatTemplate.contains("</think>") {
            return .qwen3
        }
        if chatTemplate.contains("<thinking>") && chatTemplate.contains("</thinking>") {
            return .mistralReasoning
        }
        if chatTemplate.contains("<reasoning>") && chatTemplate.contains("</reasoning>") {
            return .phi4
        }
        if chatTemplate.contains("<reflection>") && chatTemplate.contains("</reflection>") {
            return .reflection
        }
        // Gemma 4's thinking turn opens with `<|turn>think\n` and closes with the
        // standard `<|end_of_turn>` delimiter; both must appear.
        if chatTemplate.contains("<|turn>think\n") && chatTemplate.contains("<|end_of_turn>") {
            return .gemma4
        }
        return nil
    }

    /// Detects a prompt template from the GGUF `general.architecture` field.
    ///
    /// Maps known architecture identifiers to their canonical prompt formats.
    static func detect(fromArchitecture arch: String) -> PromptTemplate {
        switch arch.lowercased() {
        case "mistral": return .mistral
        case "gemma4", "gemma-4": return .gemma4
        case "gemma", "gemma2", "gemma3", "gemma-3": return .gemma
        case "phi", "phi3": return .phi
        // "llama" is too broad — many models (SmolLM2, TinyLlama, etc.) use the
        // LLaMA architecture but train with ChatML. Fall through to chatML default.
        default: return .chatML
        }
    }

    /// Heuristic detection from a filename or model name string.
    ///
    /// Least reliable strategy -- only used as a last resort when neither a chat
    /// template nor architecture string is available.
    static func detect(fromFileName name: String) -> PromptTemplate {
        let lower = name.lowercased()
        if lower.contains("llama") { return .llama3 }
        if lower.contains("mistral") { return .mistral }
        if lower.contains("gemma") { return .gemma }
        if lower.contains("phi") { return .phi }
        if lower.contains("alpaca") { return .alpaca }
        return .chatML
    }
}
