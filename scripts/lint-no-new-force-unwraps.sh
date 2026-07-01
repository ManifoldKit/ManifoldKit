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
    "ManifoldInference/Models/ModelInfo.swift"  # legacy path — file moved to ManifoldModelCatalog in P1d (#1611)
    "ManifoldModelCatalog/ModelInfo.swift"
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

    # HTTPField.Name("X-Accel-Buffering")! — HTTPFields header name literal
    # known valid at compile time; if the string were malformed it would crash
    # in dev/tests, not in production at runtime.
    "ManifoldServer/ServerApp.swift"

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
    "ManifoldHardware/PromptTemplate.swift"

    # estimatedKVBytesPerToken! in ModelLoadPlan and its ManifoldInference
    # extension — accessed only when the ternary condition confirmed non-nil.
    "ManifoldHardware/ModelLoadPlan.swift"
    "ManifoldInference/Extensions/ModelLoadPlan+ModelInfo.swift"

    # as! SecKey — SecKey is a CF opaque type returned from the Keychain API
    # as `AnyObject`; the cast is guaranteed by the kSecReturnRef contract.
    # The swiftlint:disable:this force_cast annotation documents the review.
    "ManifoldSecrets/SecureEnclaveKeyManager.swift"

    # URL(string: "https://openrouter.ai/api/v1/")! — compile-time constant
    # fallback URL for OpenRouter in AnyLanguageModelCapabilities.
    "ManifoldAnyLanguageModel/AnyLanguageModelCapabilities.swift"

    # manifold-tools CLI: URL(string: "http://localhost:11434")! default Ollama
    # base URL; hard-coded constant, always valid.  CLI binary, not SDK product.
    "manifold-tools/main.swift"
    # manifold-tools bfcl subcommand: same hard-coded URL(string:)! default
    # Ollama base URL as main.swift; constant, always valid.  CLI binary, not
    # SDK product.  (Otherwise hidden from the detector only by the `://`
    # comment-regex false-match — allowlist it explicitly so the review is real.)
    "manifold-tools/BFCLCLI.swift"

    # URL(string: "https://…")! compile-time-constant API endpoints — the same
    # reviewed-safe pattern as the HuggingFace/AnyLanguageModel entries above
    # (HuggingFaceProbe.defaultURL; CloudReranker cohere/jina rerank presets,
    # which already carry an inline "safe: constant literal URL" comment). These
    # were only invisible to the detector before the `://` comment-regex
    # false-match was fixed in this PR; allowlist them now that they are visible.
    "ManifoldInference/Services/HuggingFaceProbe.swift"
    "ManifoldCloudSaaS/CloudReranker.swift"

    # Subscript force-unwraps (`rules[name]!`, `properties[key]!`,
    # `keyToRule[key]!`) — invisible to the detector before the regex widened
    # to also match `]!` (#2099). ToolGrammarBuilder builds `rules`/`keyToRule`
    # and the corresponding key list (`emittedOrder` / `sortedKeys` /
    # `required + optional`) together in the same function, immediately before
    # each unwrap site: every key read back via `!` was inserted into the
    # matching dictionary earlier in the same call. Safe by local control flow,
    # not by trusting external input.
    "ManifoldInference/Services/ToolGrammarBuilder.swift"

    # dict["items"]! — read only inside the `if case .object? = dict["items"]`
    # branch immediately above, which already confirmed the key is present.
    # Safe by local control flow. Only invisible to the detector before the
    # `]!` regex widening (#2099); FoundationToolSchema.swift parses
    # attacker-influenced JSON Schema, so review any *new* subscript unwrap
    # here carefully rather than reflexively allowlisting it.
    "ManifoldFoundation/Internal/FoundationToolSchema.swift"
)

# Build find-exclusion args from the allowlist paths
FIND_EXCLUDES=()
for p in "${ALLOWLIST_PATHS[@]}"; do
    FIND_EXCLUDES+=("!" "-path" "*/$p*")
done

# Detect force-unwraps:
#   - word char, ), or ] followed by !
#   - exclude: comment-only lines (both // and /// forms), != operators,
#     string/char literals containing !
# The `]` alternative (added #2099) catches subscript force-unwraps
# (`rules[name]!`, `dict["items"]!`) that were previously invisible to the
# detector — a real gap since e.g. FoundationToolSchema.swift parses
# attacker-influenced JSON Schema, where a future unsafe subscript unwrap
# would otherwise ship with this lint reporting clean.
# Comment exclusion is anchored to grep's "file:LINE:content" separator
# (`:[0-9]+:[[:space:]]*//`) so it only drops lines whose *content* starts with
# //.  The earlier unanchored `:[[:space:]]*//` false-matched the `://` inside
# any URL literal (e.g. URL(string: "https://…")!), silently hiding force-unwraps
# on URL constants repo-wide — see the URL-constant allowlist entries above.
# Note: find -print0 | xargs -0 is used throughout for bash 3.2 compatibility
# (macOS ships bash 3.2; mapfile requires bash 4+).
VIOLATIONS=$(find "$SOURCES_DIR" -name "*.swift" "${FIND_EXCLUDES[@]}" -print0 \
    | xargs -0 grep -n '[]a-zA-Z0-9_)]!' \
    | grep -vE ':[0-9]+:[[:space:]]*//' \
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
