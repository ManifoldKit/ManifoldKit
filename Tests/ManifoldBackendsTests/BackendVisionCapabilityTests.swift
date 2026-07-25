import XCTest
import ManifoldInference
@testable import ManifoldFoundation
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore

final class BackendVisionCapabilityTests: XCTestCase {
    func test_llamaVisionGate_requiresProjectorAndEngineEmbedding() {
        // Truth table for the probed form (#2381). A staged projector alone
        // must not light up vision — MultimodalProjectorConfigurable requires
        // a real image-embedding path as well.
        XCTAssertFalse(
            BackendVisionCapability.llamaSupportsImageInput(
                projectorStaged: false,
                engineSupportsImageEmbedding: false
            )
        )
        XCTAssertFalse(
            BackendVisionCapability.llamaSupportsImageInput(
                projectorStaged: true,
                engineSupportsImageEmbedding: false
            ),
            "Staged mmproj URL alone must not advertise vision"
        )
        XCTAssertFalse(
            BackendVisionCapability.llamaSupportsImageInput(
                projectorStaged: false,
                engineSupportsImageEmbedding: true
            ),
            "Engine embedding capability without a projector must not advertise vision"
        )
        XCTAssertTrue(
            BackendVisionCapability.llamaSupportsImageInput(
                projectorStaged: true,
                engineSupportsImageEmbedding: true
            ),
            "Both projector staged and engine embedding support must yield true"
        )
    }

    func test_mlxVisionGate_followsConfigProbeOnly() {
        XCTAssertFalse(BackendVisionCapability.mlxSupportsImageInput(probedCapabilities: nil))
        XCTAssertFalse(
            BackendVisionCapability.mlxSupportsImageInput(
                probedCapabilities: ModelCapabilities(supportsVision: false, supportsAudio: false, contextLength: 4096)
            )
        )
        XCTAssertTrue(
            BackendVisionCapability.mlxSupportsImageInput(
                probedCapabilities: ModelCapabilities(supportsVision: true, supportsAudio: false, contextLength: 8192)
            )
        )
    }

    func test_ollamaVisionGate_followsProbedCapabilityOnly() {
        XCTAssertFalse(
            BackendVisionCapability.ollamaSupportsImageInput(probedVision: false),
            "Ollama must not advertise vision for a model whose /api/show capabilities list omits \"vision\"."
        )
        XCTAssertTrue(
            BackendVisionCapability.ollamaSupportsImageInput(probedVision: true),
            "Ollama must advertise vision once /api/show reports the \"vision\" capability."
        )
    }

    func test_openAIChatCompletionsVisionGate_allowsOnlyImplementedVisionFamilies() {
        let supported = [
            "gpt-4o-mini",
            "openai/gpt-4o-2024-08-06",
            "gpt-4-turbo",
            "gpt-4.1-2025-04-14",
            "o1-mini",
            "openai:o3-mini",
        ]
        for model in supported {
            XCTAssertTrue(
                BackendVisionCapability.openAIChatCompletionsSupportsImageInput(modelName: model),
                "expected \(model) to use the implemented Chat Completions image_url path"
            )
        }

        let unsupported = [
            "gpt-3.5-turbo",
            "gpt-4",
            "gpt-foo1bar",
            "foo-o1",
            "custom/text-only",
        ]
        for model in unsupported {
            XCTAssertFalse(
                BackendVisionCapability.openAIChatCompletionsSupportsImageInput(modelName: model),
                "must not advertise vision for ambiguous or text-only OpenAI-compatible model \(model)"
            )
        }
    }

    func test_openAIResponsesVisionGate_staysFalseUntilInputImageEncodingExists() {
        for model in ["gpt-5", "gpt-4o", "openai/gpt-4.1"] {
            XCTAssertFalse(
                BackendVisionCapability.openAIResponsesSupportsImageInput(modelName: model),
                "Responses backend must stay text-only until it maps MessagePart.image to input_image items."
            )
        }
    }

    func test_claudeVisionGate_rejectsLegacyTextOnlyFamilies() {
        let supported = [
            "claude-3-opus-20240229",
            "claude-3-5-sonnet-20241022",
            "anthropic.claude-sonnet-4",
            "claude-opus-4-1",
        ]
        for model in supported {
            XCTAssertTrue(
                BackendVisionCapability.claudeMessagesSupportsImageInput(modelName: model),
                "expected \(model) to use the implemented Anthropic image content block path"
            )
        }

        let unsupported = [
            "claude-2.1",
            "claude-instant-1.2",
            "claude-v1",
            "custom/text-only",
        ]
        for model in unsupported {
            XCTAssertFalse(
                BackendVisionCapability.claudeMessagesSupportsImageInput(modelName: model),
                "must not advertise vision for legacy/text-only Claude model \(model)"
            )
        }
    }
}
