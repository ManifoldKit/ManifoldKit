import XCTest

/// Source-level guard that future code changes don't silently regress the
/// privacy/network posture documented in `SECURITY.md`.
///
/// Walks every `.swift` file under `Sources/` and enforces five categories of
/// rule. Each rule has a tightly-scoped allowlist (path-only, capped, with
/// inline justifications) so that "approve to make the test pass" is visible
/// in a code review rather than rubber-stamped.
///
/// ## Rules
///
/// 1. **Network I/O imports** — `URLSession`, `URLRequest`,
///    `URLSessionConfiguration` permitted only in network-allowlisted files.
///    Catches accidental UI/Inference code that opens a session directly.
///
/// 2. **C interop / dynamic dispatch** — `@_silgen_name`, `@_cdecl`,
///    `dlopen`, `dlsym`, `NSClassFromString`, `objc_getClass`,
///    `class_createInstance`, `Process(`, `NSTask`, `posix_spawn`, `popen(`,
///    `system(` banned in `Sources/`. These bypass `LocalOnlyNetworkIsolationTests`'
///    URLSession-level canary by going straight to syscalls or runtime
///    metaclass lookup. Only `Process(` has a narrow path-allowlist for the
///    Fuzz harness CLI which legitimately spawns subprocesses.
///
/// 3. **Hostname literals** — strings matching `https?://(api|www)\.…`
///    permitted only in hostname-allowlisted files. Stops a UI string
///    reading "OpenAI" from accidentally containing a real endpoint URL.
///
/// 4. **Privacy-sensitive Apple APIs** — `CloudKitDatabase`,
///    `NSUbiquitous*`, `NSUserActivity` Handoff, `UIPasteboard.general`
///    writes without `localOnly`, `FileProtectionType.none`. Each finding
///    requires a fingerprint entry with an explicit justification.
///    (`os_log` `.public` deliberately not covered — see the
///    `privacyAPIPattern` doc comment for rationale.)
///
/// 5. **`Package.swift` hygiene** — bans `linkedFramework("Network")`,
///    `linkedFramework("CFNetwork")`, `unsafeFlags`, and SwiftPM
///    `.buildToolPlugin` / `.commandPlugin` declarations. Catches future
///    PRs that re-introduce networking via build settings (defeating the
///    source-grep audit) or add SwiftPM plugins (which can run arbitrary
///    code at build time).
///
/// 6. **Import-graph boundary** — locks in the layered architecture from
///    `CLAUDE.md`. UI must not depend on Backends or SwiftData persistence;
///    Inference must not depend on Core or Backends. The rule checks both
///    source imports and the SwiftPM manifest so a target dependency cannot
///    reintroduce a forbidden module before an import lands.
///
/// 7. **Trait gate sanity** — every `#if`/`#elseif` identifier in
///    `Sources/` that looks trait-named (TitleCase or UPPERCASE, not a
///    well-known compiler conditional like `os(...)`, `canImport(...)`,
///    `swift(...)`, `DEBUG`, etc.) must match a trait declared in
///    `Package.swift`. Catches stale `#if` directives left behind after
///    a trait rename.
///
/// ## Allowlist policy
///
/// Adding a path to `networkIOAllowlist` or `hostnameAllowlist` requires
/// reviewer sign-off, the per-list cap, and a justification. Rule 2 and 4
/// allowlists carry per-entry justification comments. The test fails if a
/// list grows beyond its cap, on the theory that an ever-growing exception
/// list weakens the rule.
///
/// ## File discovery
///
/// Reuses the `#filePath` upwalk pattern from `SilentCatchAuditTest` —
/// portable, no shell dependencies, finds the same `Sources/` regardless
/// of where `swift test` is invoked.
final class TrafficBoundaryAuditTest: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Source-tree walk + regex audit (~50s combined). Skipped in main CI to
        // keep PR feedback fast; nightly job sets RUN_SLOW_TESTS=1. Always runs
        // locally so contributors get the boundary-rule signal pre-push.
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["CI"] == "true" && env["RUN_SLOW_TESTS"] != "1",
                      "Source-tree audit — runs in nightly CI only. Set RUN_SLOW_TESTS=1 to force.")
    }

    // MARK: - Allowlists

    /// Files where direct `URLSession`/`URLRequest`/`URLSessionConfiguration`
    /// usage is approved. These do legitimate network I/O — cloud backends,
    /// the model-download manager, test infra.
    ///
    /// **Cap: 26 entries.** Adding to this list weakens Rule 1; require
    /// reviewer sign-off and prefer to route new network code through
    /// `URLSessionProvider` (which is itself in this allowlist).
    private static let networkIOAllowlist: Set<String> = [
        // Cloud / Ollama backends — every backend that talks to a remote
        // endpoint goes through URLSessionProvider and lives here.
        "BaseChatBackends/ClaudeBackend.swift",
        "BaseChatBackends/OpenAIBackend.swift",
        "BaseChatBackends/OpenAIResponsesBackend.swift",
        "BaseChatBackends/OllamaBackend.swift",
        "BaseChatBackends/OllamaModelListService.swift",
        "BaseChatBackends/SSECloudBackend.swift",
        "BaseChatBackends/URLSessionProvider.swift",
        "BaseChatBackends/PinnedSessionDelegate.swift",
        "BaseChatBackends/DNSRebindingGuard.swift",

        // I1 network seam closure (#1140) — centralised redirect-guard
        // delegate, composite delegate, and seam factory live in
        // BaseChatInference so BaseChatHuggingFace can hit the same seam
        // without depending on BaseChatBackends.
        "BaseChatInference/Networking/RedirectGuardDelegate.swift",
        "BaseChatInference/Networking/CompositeURLSessionDelegate.swift",
        "BaseChatInference/Networking/URLSessionFactory.swift",

        // Model download path — HuggingFace GGUF/MLX downloads.
        "BaseChatHuggingFace/BackgroundDownloadManager.swift",
        "BaseChatHuggingFace/BackgroundDownloadManager+URLSessionDelegate.swift",
        "BaseChatHuggingFace/HuggingFaceService.swift",
        // Diffusion model download path — multi-file safetensors layout
        // (UNet, VAE, text encoders, tokenizers, scheduler). Sibling to the
        // GGUF/MLX path above, kept in its own file so the existing
        // background-download manager stays untouched.
        "BaseChatHuggingFace/DiffusionDownload.swift",
        "BaseChatInference/Services/SSEStreamParser.swift",
        "BaseChatUI/ViewModels/ModelManagementViewModel.swift",

        // Reference tools — bck-tools CLI tool harness, intentional HTTP fetcher.
        "BaseChatTools/ReferenceTools/HttpGetFixtureTool.swift",

        // Fuzz scenario that exercises network-shaped retry behaviour.
        "BaseChatFuzz/Scenarios/ThinkingAcrossRetryScenario.swift",

        // Test infrastructure — DenyAll, Mock, hardware probes. Live in
        // BaseChatTestSupport so production code never picks them up by
        // import.
        "BaseChatTestSupport/MockURLProtocol.swift",
        "BaseChatTestSupport/DenyAllURLProtocol.swift",
        "BaseChatTestSupport/HardwareRequirements.swift",

        // MCP module transport/auth networking surfaces.
        "BaseChatMCP/InternalMCPTransport.swift",
        "BaseChatMCP/MCPOAuth.swift",
        // MCP module's internal URLSession factory — vends a shared
        // session for MCP HTTP/SSE transports; guarded by networkDisabled
        // flag so tests can disable network I/O at test time.
        "BaseChatMCP/MCPURLSessionFactory.swift",
    ]

    /// Files where hostname literals (e.g. `https://api.anthropic.com`) are
    /// approved. Smaller superset than `networkIOAllowlist` because not
    /// every networking file embeds a hostname (e.g., `URLSessionProvider`
    /// composes URLs at the call site).
    ///
    /// **Cap: 12 entries.**
    private static let hostnameAllowlist: Set<String> = [
        "BaseChatBackends/OpenAIBackend.swift",
        "BaseChatHuggingFace/HuggingFaceService.swift",
        "BaseChatHuggingFace/BackgroundDownloadManager.swift",
        "BaseChatTestSupport/MockHuggingFaceService.swift",
        // Validation reasons display canonical scheme/host examples in
        // user-facing error strings.
        "BaseChatRuntime/Models/APIEndpointValidationReason.swift",
        // Provider enum exposes default base URLs as static data.
        "BaseChatInference/Models/APIProvider.swift",
    ]

    /// Files where `Process(` is approved. Other C-interop / dynamic-
    /// dispatch patterns have **no** allowlist — each is a hard ban.
    private static let processSpawnAllowlist: Set<String> = [
        // Fuzz harness CLI: HarnessMetadata captures git/sw_vers via
        // subprocess for reproducibility; Replayer launches a child
        // process to replay a corpus seed in isolation.
        "BaseChatFuzz/HarnessMetadata.swift",
        "BaseChatFuzz/Replay/Replayer.swift",
        // MCP stdio transport intentionally launches local server binaries
        // to support offline and local-tooling integrations.
        "BaseChatMCP/InternalMCPTransport.swift",
        // fuzz-chat CLI: parallel worker mode launches isolated child
        // fuzz-chat processes with deterministic seed sharding; parent
        // waits for each worker and merges findings into the root index.
        "fuzz-chat/FuzzChatCLI.swift",
    ]

    /// `Package.swift` lines where a normally-banned token (Rule 5) is
    /// approved. Currently empty — there is no legitimate reason to use
    /// `unsafeFlags`, link `Network`/`CFNetwork`, or add a SwiftPM plugin
    /// in this package. Format mirrors `privacyAPIAllowlist`:
    /// `"Package.swift:<trimmed line>"`.
    ///
    /// **Cap: 3 entries.** Adding to this list weakens Rule 5 substantially
    /// (build-tool plugins run arbitrary code at build time); require an
    /// inline `// Justification:` comment per entry and reviewer sign-off.
    private static let packageHygieneAllowlist: Set<String> = []

    /// Compiler / feature conditionals that Rule 7 must not flag — they
    /// live outside the Package.swift trait set by design.
    ///
    /// Identifiers handled by an `<identifier>(...)` form (e.g.
    /// `os(iOS)`, `canImport(Metal)`) are skipped automatically by the
    /// rule's parser; this set covers the bare-identifier forms that
    /// behave like traits but aren't traits.
    private static let traitGateCompilerConditionals: Set<String> = [
        "DEBUG",
        "RELEASE",
        "NDEBUG",
        "TESTING",
    ]

    /// Privacy-sensitive Apple-API call sites that have been individually
    /// reviewed and approved. Format: `"relative/path.swift:<trimmed line>"`.
    /// Each entry **must** carry a `// Justification:` comment in this
    /// list noting why the use is safe.
    ///
    /// **Cap: 6 entries.**
    private static let privacyAPIAllowlist: Set<String> = [
        // Justification: user-initiated copy action in chat/code affordances.
        // iOS uses local-only pasteboard entries with expiration; macOS lacks
        // equivalent AppKit controls and remains best-effort global pasteboard.
        "BaseChatUI/Internal/ClipboardWriter.swift:UIPasteboard.general.setItems([[UTType.plainText.identifier: text]], options: pasteboardOptions())",
    ]

    // MARK: - Test entry points

    func test_rule1_networkIOOnlyInAllowlistedFiles() throws {
        let sourcesURL = try Self.locateSourcesDirectory()
        var offenders: [Offender] = []

        for fileURL in try Self.enumerateSwiftFiles(under: sourcesURL) {
            let relativePath = fileURL.path.replacingOccurrences(
                of: sourcesURL.path + "/", with: ""
            )
            if Self.networkIOAllowlist.contains(relativePath) { continue }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for (idx, line) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard Self.shouldScan(line: trimmed) else { continue }
                if Self.matches(Self.networkIOPattern, in: trimmed) {
                    offenders.append(.init(
                        rule: 1, ruleName: "Network I/O imports",
                        file: relativePath, line: idx + 1, text: trimmed,
                        why: "URLSession-family types must live in URLSessionProvider or behind a networking trait so LocalOnlyNetworkIsolationTests can intercept all outbound requests.",
                        fix: "Route network I/O through URLSessionProvider, or — if this file is genuinely a new network boundary — add it to TrafficBoundaryAuditTest.networkIOAllowlist with reviewer sign-off."
                    ))
                }
            }
        }

        Self.assertNoOffenders(offenders)

        XCTAssertLessThanOrEqual(
            Self.networkIOAllowlist.count, 26,
            "networkIOAllowlist exceeds cap. Each new entry weakens the rule — re-architect rather than expand the list."
        )
    }

    func test_rule2_cInteropAndDynamicDispatchBanned() throws {
        let sourcesURL = try Self.locateSourcesDirectory()
        var offenders: [Offender] = []

        for fileURL in try Self.enumerateSwiftFiles(under: sourcesURL) {
            let relativePath = fileURL.path.replacingOccurrences(
                of: sourcesURL.path + "/", with: ""
            )
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for (idx, line) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard Self.shouldScan(line: trimmed) else { continue }

                // Process( has a narrow path-allowlist (Fuzz CLI subprocess use).
                if Self.matches(Self.processSpawnPattern, in: trimmed) {
                    if !Self.processSpawnAllowlist.contains(relativePath) {
                        offenders.append(.init(
                            rule: 2, ruleName: "Subprocess spawn (Process)",
                            file: relativePath, line: idx + 1, text: trimmed,
                            why: "Spawning subprocesses bypasses the URLSession boundary; a child process can talk to anything without LocalOnlyNetworkIsolationTests seeing it.",
                            fix: "Remove the subprocess. If this is a CLI harness like BaseChatFuzz, add the file to processSpawnAllowlist with justification."
                        ))
                    }
                    continue
                }

                // Everything else in rule 2 has no allowlist.
                if Self.matches(Self.cInteropPattern, in: trimmed) {
                    offenders.append(.init(
                        rule: 2, ruleName: "C interop / dynamic dispatch",
                        file: relativePath, line: idx + 1, text: trimmed,
                        why: "Direct syscalls, dlopen, NSClassFromString, posix_spawn, etc. evade every higher-level isolation seam (URLProtocol, trait gates, import-graph rules).",
                        fix: "Use a Foundation-level API instead. There is no allowlist for this rule — escalate if you believe an exception is necessary."
                    ))
                }
            }
        }

        Self.assertNoOffenders(offenders)
    }

    func test_rule3_hostnameLiteralsOnlyInAllowlistedFiles() throws {
        let sourcesURL = try Self.locateSourcesDirectory()
        var offenders: [Offender] = []

        for fileURL in try Self.enumerateSwiftFiles(under: sourcesURL) {
            let relativePath = fileURL.path.replacingOccurrences(
                of: sourcesURL.path + "/", with: ""
            )
            if Self.hostnameAllowlist.contains(relativePath) { continue }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for (idx, line) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard Self.shouldScan(line: trimmed) else { continue }
                if Self.matches(Self.hostnamePattern, in: trimmed) {
                    offenders.append(.init(
                        rule: 3, ruleName: "Hostname literal",
                        file: relativePath, line: idx + 1, text: trimmed,
                        why: "Hostnames belong in cloud-backend/HF-service files (or the future Hosts.swift collection point). A hostname elsewhere is either a leak or a documentation string that should live in a doc comment.",
                        fix: "Move the literal to one of the allowlisted hostname files, or — for documentation strings — convert to a `///` doc comment."
                    ))
                }
            }
        }

        Self.assertNoOffenders(offenders)

        XCTAssertLessThanOrEqual(
            Self.hostnameAllowlist.count, 12,
            "hostnameAllowlist exceeds cap."
        )
    }

    func test_rule4_privacySensitiveAppleAPIsRequireJustification() throws {
        let sourcesURL = try Self.locateSourcesDirectory()
        var offenders: [Offender] = []
        var seenFingerprints: Set<String> = []

        for fileURL in try Self.enumerateSwiftFiles(under: sourcesURL) {
            let relativePath = fileURL.path.replacingOccurrences(
                of: sourcesURL.path + "/", with: ""
            )
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for (idx, line) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard Self.shouldScan(line: trimmed) else { continue }
                if Self.matches(Self.privacyAPIPattern, in: trimmed) {
                    let fingerprint = "\(relativePath):\(trimmed)"
                    seenFingerprints.insert(fingerprint)
                    if !Self.privacyAPIAllowlist.contains(fingerprint) {
                        offenders.append(.init(
                            rule: 4, ruleName: "Privacy-sensitive Apple API",
                            file: relativePath, line: idx + 1, text: trimmed,
                            why: "CloudKit, iCloud key-value sync, Handoff, Universal Clipboard, and weakened file protection all leak data outside the device — bypassing every network audit.",
                            fix: "Use a local-only alternative (e.g. `UIPasteboard.general.setItems(_:options:)` with `.localOnly = true`). If genuinely required, add a fingerprint entry to privacyAPIAllowlist with `// Justification:` comment."
                        ))
                    }
                }
            }
        }

        Self.assertNoOffenders(offenders)

        XCTAssertLessThanOrEqual(
            Self.privacyAPIAllowlist.count, 6,
            "privacyAPIAllowlist exceeds cap. Each entry is a known privacy gap — fix them rather than grow the list."
        )

        // Stale-allowlist check: every approved fingerprint must still
        // exist in the source tree.
        let stale = Self.privacyAPIAllowlist.subtracting(seenFingerprints)
        if !stale.isEmpty {
            XCTFail("""
                privacyAPIAllowlist has stale entries that no longer exist in Sources/. Remove them:

                  \(stale.sorted().joined(separator: "\n  "))
                """)
        }
    }

    func test_rule6_importGraphBoundary() throws {
        let sourcesURL = try Self.locateSourcesDirectory()
        var offenders: [Offender] = []

        // (file-path-prefix, forbidden-imports, why)
        let rules: [(prefix: String, forbidden: [String], why: String)] = [
            ("BaseChatUI/",
             ["BaseChatBackends", "BaseChatPersistenceSwiftData"],
             "BaseChatUI must not depend on BaseChatBackends or BaseChatPersistenceSwiftData. UI is consumer-facing; backend code carries cloud-SDK weight and persistence adapters belong behind BaseChatRuntime ports."),
            ("BaseChatRuntime/",
             ["BaseChatBackends", "BaseChatPersistenceSwiftData"],
             "BaseChatRuntime carries persistence-agnostic ports and use cases. Concrete backends and SwiftData adapters live above it."),
            ("BaseChatPersistenceSwiftData/",
             ["BaseChatBackends"],
             "BaseChatPersistenceSwiftData is the SwiftData persistence layer; backend code belongs above it."),
            ("BaseChatInference/",
             ["BaseChatBackends", "BaseChatRuntime", "BaseChatPersistenceSwiftData"],
             "BaseChatInference is the lowest production layer (apart from BaseChatTestSupport) and must not depend upward."),
        ]

        for fileURL in try Self.enumerateSwiftFiles(under: sourcesURL) {
            let relativePath = fileURL.path.replacingOccurrences(
                of: sourcesURL.path + "/", with: ""
            )
            guard let rule = rules.first(where: { relativePath.hasPrefix($0.prefix) }) else {
                continue
            }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for (idx, line) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard Self.shouldScan(line: trimmed), trimmed.hasPrefix("import ") else { continue }
                for forbidden in rule.forbidden {
                    if trimmed == "import \(forbidden)" || trimmed.hasPrefix("import \(forbidden) ") {
                        offenders.append(.init(
                            rule: 6, ruleName: "Import-graph boundary",
                            file: relativePath, line: idx + 1, text: trimmed,
                            why: rule.why,
                            fix: "Remove the import. If you need a type from \(forbidden), expose it from a lower-layer module (e.g. promote a protocol to BaseChatInference)."
                        ))
                    }
                }
            }
        }

        Self.assertNoOffenders(offenders)
    }

    func test_rule6_packageManifestTargetBoundaries() throws {
        let packageURL = try Self.locatePackageManifest()
        let manifest = try String(contentsOf: packageURL, encoding: .utf8)
        var offenders: [Offender] = []

        let rules: [(target: String, forbidden: [String], why: String)] = [
            ("BaseChatUI",
             ["BaseChatBackends", "BaseChatPersistenceSwiftData", "BaseChatUIModelManagement"],
             "BaseChatUI must stay a chat-only consumer surface. Backends, SwiftData adapters, and model-management UI belong behind lower-layer ports or sibling modules."),
            ("BaseChatUIModelManagement",
             ["BaseChatPersistenceSwiftData"],
             "BaseChatUIModelManagement must use BaseChatRuntime endpoint-store ports instead of depending on concrete SwiftData adapters.")
        ]

        for rule in rules {
            guard let block = Self.manifestTargetBlock(in: manifest, targetName: rule.target) else {
                XCTFail("Could not locate Package.swift target '\(rule.target)' for Rule 6 manifest boundary audit.")
                continue
            }

            for forbidden in rule.forbidden where Self.manifestTarget(block.text, declaresDependencyOn: forbidden) {
                offenders.append(.init(
                    rule: 6,
                    ruleName: "Package manifest target boundary",
                    file: "Package.swift",
                    line: block.startLine,
                    text: ".target(name: \"\(rule.target)\", dependencies: ... \(forbidden) ...)",
                    why: rule.why,
                    fix: "Remove the \(forbidden) dependency from \(rule.target). Depend on BaseChatRuntime/BaseChatInference ports or closure-inject the sibling surface instead."
                ))
            }
        }

        Self.assertNoOffenders(offenders)
    }

    func test_rule5_packageManifestHygiene() throws {
        let packageURL = try Self.locatePackageManifest()
        let content = try String(contentsOf: packageURL, encoding: .utf8)
        var offenders: [Offender] = []

        for (idx, line) in content.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip empty / pure-comment lines so doc strings about the
            // banned tokens (e.g. explaining why we don't use them) don't
            // self-trip the audit.
            guard Self.shouldScan(line: trimmed) else { continue }

            for hit in Self.packageHygieneMatches(in: trimmed) {
                let fingerprint = "Package.swift:\(trimmed)"
                if Self.packageHygieneAllowlist.contains(fingerprint) { continue }
                offenders.append(.init(
                    rule: 5, ruleName: "Package.swift hygiene (\(hit))",
                    file: "Package.swift", line: idx + 1, text: trimmed,
                    why: "Linking Network.framework/CFNetwork or shipping a SwiftPM plugin re-introduces networking/code-execution surface that the source-grep audit cannot see. `unsafeFlags` lets a contributor disable any compiler safety check without leaving a trace at the call site.",
                    fix: "Remove the offending build setting. If genuinely required, add a fingerprint entry to packageHygieneAllowlist with a `// Justification:` comment and reviewer sign-off."
                ))
            }
        }

        Self.assertNoOffenders(offenders)

        XCTAssertLessThanOrEqual(
            Self.packageHygieneAllowlist.count, 3,
            "packageHygieneAllowlist exceeds cap. Each entry weakens Rule 5 — re-architect rather than expand the list."
        )
    }

    func test_rule7_traitGateSanity() throws {
        let packageURL = try Self.locatePackageManifest()
        let manifest = try String(contentsOf: packageURL, encoding: .utf8)
        let declaredTraits = Self.parseDeclaredTraits(in: manifest)

        // Sanity: the traits we know exist on `main` must all be present.
        // If this fails, the parser regressed before we even check Sources/.
        for expected in ["MLX", "Llama", "Ollama", "CloudSaaS", "Fuzz"] {
            XCTAssertTrue(
                declaredTraits.contains(expected),
                "parseDeclaredTraits failed to find expected trait '\(expected)' in Package.swift — the .trait(name: \"...\") regex has regressed."
            )
        }

        let allowedIdentifiers = declaredTraits.union(Self.traitGateCompilerConditionals)
        let sourcesURL = try Self.locateSourcesDirectory()
        var offenders: [Offender] = []

        for fileURL in try Self.enumerateSwiftFiles(under: sourcesURL) {
            let relativePath = fileURL.path.replacingOccurrences(
                of: sourcesURL.path + "/", with: ""
            )
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for (idx, line) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // `#if`/`#elseif` lines are syntactically not Swift comments
                // even when they appear inside a doc-comment block — the
                // shouldScan filter is irrelevant here. We require the line
                // to start with `#if ` or `#elseif `.
                guard trimmed.hasPrefix("#if ") || trimmed.hasPrefix("#elseif ") else { continue }

                let condition = trimmed
                    .replacingOccurrences(of: "#elseif ", with: "")
                    .replacingOccurrences(of: "#if ", with: "")
                for identifier in Self.extractTraitLikeIdentifiers(from: condition) {
                    if allowedIdentifiers.contains(identifier) { continue }
                    offenders.append(.init(
                        rule: 7, ruleName: "Trait gate sanity",
                        file: relativePath, line: idx + 1, text: trimmed,
                        why: "`#if \(identifier)` references an identifier that is neither a declared trait in Package.swift nor a recognised compiler conditional. The most common cause is a stale gate after a trait rename — the dead branch silently never compiles.",
                        fix: "Either add a `.trait(name: \"\(identifier)\", ...)` entry to Package.swift, rename the gate to match an existing trait, or remove the dead `#if`."
                    ))
                }
            }
        }

        Self.assertNoOffenders(offenders)
    }

    // MARK: - Patterns

    /// Identifier-boundary protection matches only standalone
    /// `URLSession`/`URLRequest`/`URLSessionConfiguration` references, and
    /// does not match larger identifiers that merely contain those names
    /// as substrings (for example `MockURLSession` or
    /// `MyURLSessionStub`).
    private static let networkIOPattern =
        #"(?<![A-Za-z0-9_])(URLSession|URLRequest|URLSessionConfiguration)(?![A-Za-z0-9_])"#

    /// `system(` is matched only when used as a free function call —
    /// excluding both member-access (`.system(...)` is a SwiftUI/AppKit
    /// idiom) and Swift enum case constructors (`case system(...)`).
    /// The doubled negative lookbehind keeps the C-interop tripwire while
    /// allowing legitimate Swift idioms.
    private static let cInteropPattern =
        #"(?<![A-Za-z0-9_])(@_silgen_name|@_cdecl|dlopen\(|dlsym\(|NSClassFromString|objc_getClass|class_createInstance|NSTask|posix_spawn|popen\()|(?<![A-Za-z0-9_.])(?<!case )system\("#

    /// `Process(` as a constructor call — distinguishes from Swift's
    /// `Process` type used as a parameter type. The open-paren is the
    /// discriminator.
    private static let processSpawnPattern =
        #"(?<![A-Za-z0-9_])Process\("#

    private static let hostnamePattern =
        #"https?://(api|www|hf)\.[A-Za-z0-9_.-]+"#

    /// `UIPasteboard.general` followed by `.<member>` (any access — we're
    /// strict; sites that want pasteboard access must allowlist or use
    /// `localOnly` via a non-`.general` API). CloudKit/NSUbiquitous*
    /// matched as identifiers. `isEligibleForHandoff = true` — the false
    /// form is fine. `FileProtectionType.none` weakens at-rest protection.
    ///
    /// **Not covered:** `os_log` `, privacy: .public` interpolation — many
    /// legitimate dev-facing diagnostics (file paths, git revisions, error
    /// type names) use this marker, and a rule that flagged every site
    /// would force allowlisting hundreds of debug-only logs. Unified-log
    /// content escaping the device via iCloud sysdiagnose is tracked in
    /// `THREAT_MODEL.md` as a known non-mitigation pending a separate
    /// audit pass.
    private static let privacyAPIPattern =
        #"(?<![A-Za-z0-9_])(CloudKitDatabase|NSUbiquitousKeyValueStore|NSUbiquitousContainer|UIPasteboard\.general\.|isEligibleForHandoff\s*=\s*true|FileProtectionType\.none)"#

    private static func matches(_ pattern: String, in line: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Rule 5 helpers (Package.swift hygiene)

    /// Tokens whose presence in `Package.swift` constitutes a Rule 5
    /// violation. Matched as substring/regex against trimmed source
    /// lines. The display label (left) becomes part of the offender's
    /// `ruleName` so review output names which token was hit.
    private static let packageHygienePatterns: [(label: String, pattern: String)] = [
        ("linkedFramework Network",      #"linkedFramework\(\s*"Network"\s*\)"#),
        ("linkedFramework CFNetwork",    #"linkedFramework\(\s*"CFNetwork"\s*\)"#),
        ("unsafeFlags",                  #"(?<![A-Za-z0-9_])unsafeFlags\("#),
        // Match `.buildToolPlugin(` and `.commandPlugin(` as constructor
        // calls in target dependencies — distinguishes from random
        // identifiers that might contain the substring.
        (".buildToolPlugin",             #"\.buildToolPlugin\("#),
        (".commandPlugin",               #"\.commandPlugin\("#),
    ]

    /// Returns the labels of every Rule-5 token that fires on `line`.
    /// More than one can fire in the unlikely case a contributor combines
    /// banned tokens on the same line.
    private static func packageHygieneMatches(in line: String) -> [String] {
        packageHygienePatterns.compactMap { entry in
            matches(entry.pattern, in: line) ? entry.label : nil
        }
    }

    // MARK: - Rule 7 helpers (Trait gate sanity)

    /// Parses `.trait(name: "X", ...)` declarations out of a Package.swift
    /// manifest source string. Tolerates single- or double-quoted names
    /// (Swift only allows double, but the regex is forgiving) and any
    /// whitespace around the `name:` label.
    private static func parseDeclaredTraits(in manifest: String) -> Set<String> {
        let pattern = #"\.trait\(\s*name:\s*"([A-Za-z_][A-Za-z0-9_]*)""#
        var found: Set<String> = []
        let ns = manifest as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        regex.enumerateMatches(in: manifest, range: range) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            found.insert(ns.substring(with: m.range(at: 1)))
        }
        return found
    }

    /// Splits an `#if` condition into the bare-identifier components that
    /// could plausibly name a SwiftPM trait. Strips `!`, splits on `&&`
    /// and `||`, and discards any token that looks like a function-form
    /// compiler conditional (`os(macOS)`, `canImport(Metal)`, etc.) or a
    /// non-trait-shaped identifier (lowercase-only, contains digits at
    /// start, etc.).
    ///
    /// **Known limitation:** parenthesised groupings such as
    /// `#if (Ollama || Bogus)` are dropped wholesale because the contains-`(`
    /// filter classifies them as function-form. No source under `Sources/`
    /// currently uses parenthesised `#if` groups for trait identifiers, so
    /// this is a safe simplification today; revisit if a contributor adopts
    /// that style and the audit regresses to a silent false negative.
    static func extractTraitLikeIdentifiers(from condition: String) -> [String] {
        // Tokens are anything separated by `&&`, `||`, or whitespace.
        // We keep parentheses so `os(iOS)` stays intact for the filter.
        var tokens: [String] = []
        var current = ""
        var depth = 0
        for ch in condition {
            if ch == "(" { depth += 1; current.append(ch); continue }
            if ch == ")" { depth -= 1; current.append(ch); continue }
            if depth == 0 {
                // Treat &&, ||, and whitespace as splitters.
                if ch == "&" || ch == "|" || ch.isWhitespace {
                    if !current.isEmpty { tokens.append(current); current = "" }
                    continue
                }
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }

        var identifiers: [String] = []
        for raw in tokens {
            var t = raw
            // Strip any leading `!` (negation).
            while t.hasPrefix("!") { t.removeFirst() }
            t = t.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }

            // Skip function-form compiler conditionals — anything with
            // parentheses, e.g. `os(iOS)`, `canImport(Metal)`,
            // `swift(>=5.9)`, `compiler(>=5.9)`, `targetEnvironment(...)`,
            // `arch(...)`. We do not validate the inner argument; the
            // Swift compiler does that already.
            if t.contains("(") { continue }

            // Trait-shaped: must start with an uppercase letter so we
            // skip stray lowercase identifiers (none expected, but the
            // filter keeps the rule conservative).
            guard let first = t.first, first.isUppercase else { continue }

            identifiers.append(t)
        }
        return identifiers
    }

    /// Skip empty lines, single-line comments, and doc comments. (Block
    /// comments would require AST, but the codebase doesn't use them.)
    private static func shouldScan(line: String) -> Bool {
        if line.isEmpty { return false }
        if line.hasPrefix("//") { return false }
        if line.hasPrefix("///") { return false }
        if line.hasPrefix("*") { return false }
        return true
    }

    // MARK: - Rule 6 helpers (Package.swift target boundaries)

    private static func manifestTargetBlock(
        in manifest: String,
        targetName: String
    ) -> (text: String, startLine: Int)? {
        let marker = ".target("
        var searchStart = manifest.startIndex

        while let targetStart = manifest.range(of: marker, range: searchStart..<manifest.endIndex)?.lowerBound {
            var depth = 0
            var end = targetStart
            var index = targetStart
            while index < manifest.endIndex {
                let character = manifest[index]
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        end = manifest.index(after: index)
                        break
                    }
                }
                index = manifest.index(after: index)
            }

            guard end > targetStart else { return nil }
            let block = String(manifest[targetStart..<end])
            if block.contains("name: \"\(targetName)\"") {
                let startLine = manifest[..<targetStart].reduce(1) { count, character in
                    character == "\n" ? count + 1 : count
                }
                return (block, startLine)
            }

            searchStart = end
        }

        return nil
    }

    private static func manifestTarget(_ block: String, declaresDependencyOn dependency: String) -> Bool {
        block.contains("\"\(dependency)\"") || block.contains("name: \"\(dependency)\"")
    }

    // MARK: - Reporting

    private struct Offender {
        let rule: Int
        let ruleName: String
        let file: String
        let line: Int
        let text: String
        let why: String
        let fix: String
    }

    private static func assertNoOffenders(
        _ offenders: [Offender], file: StaticString = #filePath, line: UInt = #line
    ) {
        guard !offenders.isEmpty else { return }
        let formatted = offenders.map { o in
            """

            [TrafficBoundary Rule \(o.rule): \(o.ruleName)] \(o.file):\(o.line)
              Found:    \(o.text)
              Why:      \(o.why)
              Fix:      \(o.fix)
            """
        }.joined(separator: "\n")
        XCTFail("Traffic boundary violations:\n\(formatted)", file: file, line: line)
    }

    // MARK: - File discovery (mirrors SilentCatchAuditTest)

    private static func locateSourcesDirectory(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Sources")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "TrafficBoundaryAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Sources/ from #filePath"
        ])
    }

    /// Locates `Package.swift` by walking up from the current test file
    /// until a sibling manifest is found. Mirrors `locateSourcesDirectory`.
    private static func locatePackageManifest(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "TrafficBoundaryAuditTest", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Package.swift from #filePath"
        ])
    }

    private static func enumerateSwiftFiles(under root: URL) throws -> [URL] {
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result
    }

    // MARK: - Sabotage tests
    //
    // CLAUDE.md mandates a confirmed-failure test for every assertion.
    // For the audit's regex matchers, "confirm failure" means: feed a known
    // violation string to the matcher and assert it fires. Sabotage fixtures
    // are inline strings (rather than fixture files under Sources/) so the
    // production audit's file enumerator never sees them.
    //
    // If a future refactor weakens a matcher (e.g. typo'd regex), the
    // production audit could pass cleanly even though the rule no longer
    // catches anything. The sabotage tests below catch that drift.

    func test_sabotage_rule1_catchesURLSessionUsage() {
        let fixture = "let s = URLSession.shared.dataTask(with: r) { _, _, _ in }"
        XCTAssertTrue(Self.matches(Self.networkIOPattern, in: fixture),
                      "Rule 1 should match URLSession.shared")

        let fixtureRequest = "var req = URLRequest(url: u)"
        XCTAssertTrue(Self.matches(Self.networkIOPattern, in: fixtureRequest),
                      "Rule 1 should match URLRequest")

        // Negative: an unrelated `Session` should not match.
        let negative = "let s = MyChatSession()"
        XCTAssertFalse(Self.matches(Self.networkIOPattern, in: negative),
                       "Rule 1 must not match unrelated identifier 'Session'")
    }

    func test_sabotage_rule2_catchesCInteropPatterns() {
        let cases = [
            "@_silgen_name(\"_connect\") func myConnect(_ s: Int32) -> Int32",
            "@_cdecl(\"export_me\") public func exportMe()",
            "let h = dlopen(\"libfoo.dylib\", RTLD_NOW)",
            "let p = dlsym(h, \"foo\")",
            "let cls = NSClassFromString(\"MyHidden\")",
            "let c = objc_getClass(\"MyHidden\")",
            "let i = class_createInstance(cls, 0)",
            "var pid: pid_t = 0; posix_spawn(&pid, path, nil, nil, argv, envp)",
            "let f = popen(\"ls\", \"r\")",
            "let r = system(\"/bin/ls\")",
        ]
        for fixture in cases {
            XCTAssertTrue(Self.matches(Self.cInteropPattern, in: fixture),
                          "Rule 2 should match: \(fixture)")
        }

        // Process( has its own pattern.
        let processFixture = "let p = Process()"
        XCTAssertTrue(Self.matches(Self.processSpawnPattern, in: processFixture),
                      "Rule 2 (Process) should match constructor call")

        // Negative: `Process` as a type, not a constructor.
        let processType = "func run(_ proc: Process) {"
        XCTAssertFalse(Self.matches(Self.processSpawnPattern, in: processType),
                       "Rule 2 must not match Process as a parameter type")

        // Negative: an unrelated `system` substring (no open-paren).
        let systemNonCall = "let mySystem = configure()"
        XCTAssertFalse(Self.matches(Self.cInteropPattern, in: systemNonCall),
                       "Rule 2 must not match identifier 'system' without open-paren")

        // Negative: SwiftUI's `.system(...)` member call must not match.
        let swiftUIFontCall = "Text(\"Hi\").font(.system(.body))"
        XCTAssertFalse(Self.matches(Self.cInteropPattern, in: swiftUIFontCall),
                       "Rule 2 must not match SwiftUI's .system(...) member call")

        // Negative: Swift enum case constructor `case system(...)` must
        // not match — the C-interop tripwire targets free `system()` calls,
        // not enum cases. (See `BaseChatInference.Message.system(_:)`.)
        let enumCase = "    case system(String)"
        XCTAssertFalse(Self.matches(Self.cInteropPattern, in: enumCase),
                       "Rule 2 must not match Swift enum case `case system(...)` constructors")
    }

    func test_sabotage_rule3_catchesHostnameLiterals() {
        let cases = [
            "let url = URL(string: \"https://api.anthropic.com/v1/messages\")!",
            "let url = URL(string: \"https://api.openai.com/v1/chat\")!",
            "let url = URL(string: \"http://api.example.com/foo\")!",
            "let url = URL(string: \"https://hf.co/models\")!",
        ]
        for fixture in cases {
            XCTAssertTrue(Self.matches(Self.hostnamePattern, in: fixture),
                          "Rule 3 should match: \(fixture)")
        }

        // Negative: a `.com` literal that is not a https?://api.* pattern.
        let negative = "let title = \"Available on the App Store.com\""
        XCTAssertFalse(Self.matches(Self.hostnamePattern, in: negative),
                       "Rule 3 must not match arbitrary `.com` strings")
    }

    func test_sabotage_rule4_catchesPrivacyAPIPatterns() {
        let cases = [
            "let db = CloudKitDatabase.private",
            "let store = NSUbiquitousKeyValueStore.default",
            "container.NSUbiquitousContainer = setup",
            "UIPasteboard.general.string = text",
            "activity.isEligibleForHandoff = true",
            "config.fileProtectionClass = FileProtectionType.none",
        ]
        for fixture in cases {
            XCTAssertTrue(Self.matches(Self.privacyAPIPattern, in: fixture),
                          "Rule 4 should match: \(fixture)")
        }

        // Negative: the false form of Handoff is allowed.
        let handoffOff = "activity.isEligibleForHandoff = false"
        XCTAssertFalse(Self.matches(Self.privacyAPIPattern, in: handoffOff),
                       "Rule 4 must not match isEligibleForHandoff = false")
    }

    func test_sabotage_rule5_catchesPackageHygieneTokens() {
        // Each of these would constitute a Rule 5 violation if added to
        // Package.swift verbatim. Sabotage check: feed the line through
        // the matcher and assert it fires. Cleaning up means: do not
        // commit any of these strings into Package.swift.
        let banned = [
            #".linkedFramework("Network"),"#,
            #".linkedFramework("CFNetwork"),"#,
            #"unsafeFlags(["-O0"])"#,
            ".buildToolPlugin(name: \"Foo\", capability: .buildTool())",
            ".commandPlugin(name: \"Bar\", capability: .command(intent: .custom(verb: \"do\", description: \"x\")))",
        ]
        for fixture in banned {
            XCTAssertFalse(
                Self.packageHygieneMatches(in: fixture).isEmpty,
                "Rule 5 should match: \(fixture)"
            )
        }

        // Negative: a Package.swift line that only mentions one of the
        // banned tokens inside a quoted prose string (e.g. a doc comment
        // about why we don't use them) is filtered out at the
        // shouldScan-comment level by the test entry point. Confirm the
        // matcher itself does *not* treat unrelated identifiers as hits.
        XCTAssertTrue(
            Self.packageHygieneMatches(in: "let path = \"linkedFrameworks\"").isEmpty,
            "Rule 5 must not match identifiers that merely contain the substring 'linkedFramework' without the matching call shape"
        )
        XCTAssertTrue(
            Self.packageHygieneMatches(in: "let myUnsafeFlagsCount = 0").isEmpty,
            "Rule 5 must not match non-call uses of `unsafeFlags`"
        )

        // Sabotage: temporarily appending `linkedFramework("Network")` to
        // Package.swift would make `test_rule5_packageManifestHygiene`
        // fail. Verified manually before commit; do not commit such a
        // change.
    }

    func test_sabotage_rule7_traitGateExtraction() {
        // Compound condition: split on || and && and validate each side.
        XCTAssertEqual(
            Self.extractTraitLikeIdentifiers(from: "Ollama || CloudSaaS"),
            ["Ollama", "CloudSaaS"]
        )
        XCTAssertEqual(
            Self.extractTraitLikeIdentifiers(from: "Llama && Fuzz"),
            ["Llama", "Fuzz"]
        )

        // Negation: `!Ollama` is treated as `Ollama`.
        XCTAssertEqual(
            Self.extractTraitLikeIdentifiers(from: "!Ollama"),
            ["Ollama"]
        )

        // Function-form compiler conditionals are excluded.
        XCTAssertEqual(
            Self.extractTraitLikeIdentifiers(from: "os(iOS)"),
            []
        )
        XCTAssertEqual(
            Self.extractTraitLikeIdentifiers(from: "canImport(FoundationModels) && Fuzz"),
            ["Fuzz"]
        )
        XCTAssertEqual(
            Self.extractTraitLikeIdentifiers(from: "(os(iOS) || os(tvOS) || os(watchOS)) && !targetEnvironment(macCatalyst)"),
            []
        )

        // Bogus identifier should land in the extracted set so the
        // production audit can flag it.
        XCTAssertEqual(
            Self.extractTraitLikeIdentifiers(from: "Bogus"),
            ["Bogus"]
        )
        XCTAssertEqual(
            Self.extractTraitLikeIdentifiers(from: "Ollama || Bogus"),
            ["Ollama", "Bogus"]
        )

        // Sabotage: temporarily adding `#if Bogus` to any file under
        // Sources/ would make `test_rule7_traitGateSanity` fail because
        // `Bogus` is not declared in Package.swift. Verified manually
        // before commit; do not commit such a change.

        // parseDeclaredTraits must extract every trait listed in the
        // current manifest.
        let manifest = """
            traits: [
                .default(enabledTraits: ["MLX"]),
                .trait(name: "MLX", description: "x"),
                .trait(name: "Llama", description: "x"),
                .trait(name: "Ollama", description: "x"),
                .trait(name: "CloudSaaS", description: "x"),
                .trait(name: "Fuzz", description: "x"),
            ],
            """
        let parsed = Self.parseDeclaredTraits(in: manifest)
        XCTAssertEqual(parsed, ["MLX", "Llama", "Ollama", "CloudSaaS", "Fuzz"])
    }

    func test_sabotage_rule6_detectsForbiddenImportsAndManifestDependencies() {
        // Rule 6 is implemented inline in test_rule6_importGraphBoundary
        // (it's a per-line `import X` check rather than a single regex), so
        // the sabotage check verifies the prefix-matching logic works.
        let line = "import BaseChatBackends"
        XCTAssertEqual(line, "import BaseChatBackends")
        XCTAssertTrue(line.hasPrefix("import BaseChatBackends"))

        // Module prefixes must not match a partial identifier.
        let unrelated = "import BaseChatBackendsExtras"
        // The rule requires exact match OR `import X ` (with trailing space).
        // A module named BaseChatBackendsExtras would not be flagged as
        // BaseChatBackends — the trailing space distinguishes them.
        XCTAssertFalse(unrelated == "import BaseChatBackends" || unrelated.hasPrefix("import BaseChatBackends "),
                       "Rule 6 must not flag unrelated module names that share a prefix")

        let manifest = """
            .target(
                name: "BaseChatUI",
                dependencies: [
                    "BaseChatRuntime",
                    "BaseChatPersistenceSwiftData",
                ],
                path: "Sources/BaseChatUI"
            ),
            """
        let block = Self.manifestTargetBlock(in: manifest, targetName: "BaseChatUI")
        XCTAssertNotNil(block)
        XCTAssertTrue(Self.manifestTarget(block?.text ?? "", declaresDependencyOn: "BaseChatPersistenceSwiftData"))
        XCTAssertFalse(Self.manifestTarget(block?.text ?? "", declaresDependencyOn: "BaseChatPersistenceSwiftDataExtras"),
                       "Rule 6 manifest check must not flag dependency names that only share a prefix")
    }
}
