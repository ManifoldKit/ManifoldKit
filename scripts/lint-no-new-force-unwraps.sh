#!/usr/bin/env bash
# Detects force-unwrap operators in production Sources/ code.
# Fails CI if new ones are introduced outside the reviewed allowlist below.
# To add a new safe force-unwrap: add an entry to ALLOWLIST_PATHS with a
# justification comment, then open a PR for review.
set -euo pipefail

SOURCES_DIR="${1:-Sources}"

# ---------------------------------------------------------------------------
# Reviewed-safe paths — narrow as possible; prefer file-level entries over
# whole-module directories.  Add justification + cleanup pointer for each.
# ---------------------------------------------------------------------------
ALLOWLIST_PATHS=(
    # Third-party model code vendored verbatim; reviewed in their own upstreams.
    "StableDiffusion"
    "FluxSwift"

    # Fuzzing harness + fuzz-chat CLI: force-unwraps are confined to
    # URL(string:)! with hard-coded chaos/mock scheme strings (guaranteed
    # non-nil) and randomElement(using:)! on non-empty literal arrays.
    # These targets never ship in the SDK product.
    "ManifoldFuzz"
    "ManifoldFuzzBackends"
    "fuzz-chat"

    # Test-support module (MockURLProtocol, DenyAllURLProtocol, ImageFixtures):
    # URLResponse(url:statusCode:httpVersion:headerFields:)! with non-nil URLs
    # that come from request.url, CGImage creation from fixture data,
    # copy() as! URLSessionConfiguration (standard URLSession test pattern),
    # and DispatchWorkItem! set via the makeStream closure trick.
    # Ships in ManifoldTestSupport, not in the SDK product.
    "ManifoldTestSupport"

    # AsyncThrowingStream / AsyncStream makeStream closure pattern:
    #   var continuation: SomeStream.Continuation!
    #   let stream = SomeStream { continuation = $0 }
    # The closure runs synchronously so continuation is always non-nil before
    # first use.  Tracked for migration to structured-concurrency APIs in #607.
    "ManifoldMCP/InternalMCPTransport.swift"
    "ManifoldMCP/MCPClient.swift"
    "ManifoldMCP/MCPNotificationLifecycleEventObserver.swift"
    "ManifoldInference/Services/GenerationQueue.swift"
    "ManifoldRuntime/Services/ConversationRuntime.swift"
    "ManifoldRuntime/Services/ImageGenerationRuntime.swift"
    "ManifoldRuntime/Services/VideoGenerationRuntime.swift"
    "ManifoldRuntime/Services/SessionListService.swift"
    "ManifoldAppIntents/IntentProgressReporter.swift"

    # CodingUserInfoKey(rawValue:)! with a compile-time-constant non-empty
    # string. Apple documents the initializer as failable only when the raw
    # value is empty; the recurring pattern across the codebase is a hardcoded
    # reverse-DNS key (e.g. "com.manifoldkit.appintents.resolvedEntities").
    "ManifoldAppIntents/AppIntentToolExecutor.swift"

    # UUID(uuidString:)! with compile-time constant strings — non-nil by
    # construction (a malformed literal would be caught in dev, not at runtime).
    # These are static catalog/fixture identifiers; a future pass can replace
    # with a StaticUUID helper (#608).
    "ManifoldMCP/MCPCatalog.swift"
    "ManifoldInference/Models/ModelInfo.swift"
    "ManifoldUI/Views/Chat/MessageActionMenu.swift"
    "ManifoldUI/Views/Sidebar/SessionRowView.swift"

    # MCPCatalog URL unwraps: endpoint.url!, issuer.url!, redirect.url! where
    # the URL is the result of a previously validated URLComponents struct —
    # guaranteed non-nil when the component's host/path are well-formed
    # (enforced at catalog construction time).  Tracked in #609.
    # Note: MCPCatalog.swift already listed above for UUID; no duplicate needed.

    # try! NSRegularExpression with a compile-time-constant pattern that is
    # known valid; will panic in development if ever broken, not in production.
    # Tracked for migration to a static let at module init (#610).
    "ManifoldUI/ViewModels/ChatViewModel+Generation.swift"

    # var loadCoordinator: ModelLoadCoordinator! — set via configure() before
    # first use; a SwiftUI @Observable limitation where stored properties cannot
    # be lazy.  Tracked for refactor in #611.
    "ManifoldUI/ViewModels/ChatViewModel.swift"

    # FoundationBackend.swift: return (session!, generationID) — session is
    # guaranteed non-nil at this point: the block above either reused an
    # existing non-nil session (checked via session != nil) or just assigned
    # a new LanguageModelSession().  Safe by local control flow.
    "ManifoldFoundation/FoundationBackend.swift"

    # String.data(using: .utf8)! — .utf8 encoding never fails for Swift
    # String values; this is a well-known Swift stdlib guarantee.
    "ManifoldRuntime/Services/MarkdownExportFormat.swift"

    # callbackContextRef!.toOpaque() — ref is set just before this call inside
    # the same withLock block; and .max()! on a non-empty array literal.
    "ManifoldLlama/LlamaModelLoader.swift"
    "ManifoldLlama/LlamaToolCallParser.swift"

    # HTTPField.Name("X-Accel-Buffering")! — HTTPFields header name literal
    # known valid at compile time; if the string were malformed it would crash
    # in dev/tests, not in production at runtime.
    "ManifoldServer/ServerApp.swift"

    # CGColorSpace(name: CGColorSpace.sRGB)! — CGColorSpace.sRGB is a
    # system-provided constant; non-nil on all supported OS versions.
    "ManifoldMLX/Diffusion/Flux/FluxDiffusionBackend.swift"

    # .first! on a non-empty search-path result; the path is constructed
    # immediately above with FileManager and is guaranteed to have at least
    # one element when the guard passes.  Tracked in #612.
    "ManifoldPersistenceSwiftData/ManifoldBootstrap.swift"

    # throw lastError! — lastError is set inside the loop body before the
    # throw; the throw only executes when the loop ran at least once (guarded
    # by the error-count check above it).  Tracked in #613.
    "ManifoldHuggingFace/BackgroundDownloadManager+URLSessionDelegate.swift"

    # URL(string: "https://huggingface.co")! — compile-time constant URL that
    # is known valid.  The two sites are fallback base-URL returns.
    "ManifoldHuggingFace/HuggingFaceService.swift"
    "ManifoldHuggingFace/BackgroundDownloadManager.swift"

    # systemPrompt! in PromptTemplate — called only after a non-nil check
    # in the same scope (the if-let guard above); safe by local control flow.
    # estimatedKVBytesPerToken! in ModelLoadPlan — accessed only when the
    # ternary condition confirmed the optional is non-nil.
    "ManifoldInference/Services/PromptTemplate.swift"
    "ManifoldHardware/ModelLoadPlan.swift"

    # as! SecKey — SecKey is a CF opaque type returned from the Keychain API
    # as `AnyObject`; the cast is guaranteed by the kSecReturnRef contract.
    # The swiftlint:disable:this force_cast annotation documents the review.
    "ManifoldSecrets/SecureEnclaveKeyManager.swift"

    # URL(string: "https://openrouter.ai/api/v1/")! — compile-time constant
    # fallback URL for OpenRouter in AnyLanguageModelCapabilities.
    "ManifoldBackendsUmbrella/Bridges/AnyLanguageModel/AnyLanguageModelCapabilities.swift"

    # manifold-tools CLI: URL(string: "http://localhost:11434")! default Ollama
    # base URL; hard-coded constant, always valid.  CLI binary, not SDK product.
    "manifold-tools/main.swift"
)

# Build find-exclusion args from the allowlist paths
FIND_EXCLUDES=()
for p in "${ALLOWLIST_PATHS[@]}"; do
    FIND_EXCLUDES+=("!" "-path" "*/$p*")
done

# Detect force-unwraps:
#   - word char or ) followed by !
#   - exclude: comment-only lines (both // and /// forms — grep output is
#     "file:line:content" so we match ": *//"), != operators, string/char
#     literals containing !
# Note: find -print0 | xargs -0 is used throughout for bash 3.2 compatibility
# (macOS ships bash 3.2; mapfile requires bash 4+).
VIOLATIONS=$(find "$SOURCES_DIR" -name "*.swift" "${FIND_EXCLUDES[@]}" -print0 \
    | xargs -0 grep -n '[a-zA-Z0-9_)]!' \
    | grep -v ':[[:space:]]*//' \
    | grep -v ' != ' \
    | grep -v '"[^"]*!"' \
    | grep -v "'\!'" \
    || true)

if [ -n "$VIOLATIONS" ]; then
    echo "Force-unwraps found in production Sources/ (outside reviewed allowlist):"
    echo ""
    echo "$VIOLATIONS"
    echo ""
    echo "Fix by using guard/throws/optional chaining, or add an entry to"
    echo "ALLOWLIST_PATHS in scripts/lint-no-new-force-unwraps.sh with a"
    echo "justification comment (requires PR review)."
    exit 1
fi

echo "No unreviewed force-unwraps in $SOURCES_DIR"
