import Foundation
import ManifoldNetworking
import ManifoldSecrets
import os

/// Global configuration for ManifoldKit. Set this once at app startup before
/// using any ManifoldKit types.
///
/// ```swift
/// ManifoldConfiguration.shared = ManifoldConfiguration(
///     appName: "MyApp",
///     bundleIdentifier: "com.example.myapp",
///     features: .init(
///         showCloudAPIManagement: false,   // offline-only app
///         showAdvancedSettings: false       // simplified UI
///     )
/// )
/// ```
public struct ManifoldConfiguration: Sendable {
    // OSAllocatedUnfairLock wraps value and lock together, making it
    // structurally impossible to access the value without holding the lock.
    private static let storage = OSAllocatedUnfairLock(
        initialState: ManifoldConfiguration()
    )

    public static var shared: ManifoldConfiguration {
        get { storage.withLock { $0 } }
        set {
            storage.withLock { $0 = newValue }
            // Keep the ManifoldSecrets leaf module's Keychain service name
            // in sync whenever the configuration changes. ManifoldSecrets is
            // zero-dependency so it cannot import ManifoldConfiguration
            // directly; this setter is the reliable wiring point.
            KeychainService.serviceNameProvider = {
                ManifoldConfiguration.shared.keychainServiceName
            }
        }
    }

    /// Display name used in export headers, empty states, etc.
    public var appName: String

    /// Base identifier for keychain, download sessions, logging, etc.
    public var bundleIdentifier: String

    /// Directory name inside Documents where models are stored.
    public var modelsDirectoryName: String

    /// Controls which UI features are available in the kit.
    ///
    /// All features are enabled by default. Disable individual features to
    /// simplify the interface or lock down functionality for specific deployments.
    public var features: Features

    /// Data Protection class applied to the SwiftData store on iOS/tvOS/watchOS.
    ///
    /// Defaults to `.completeUntilFirstUserAuthentication` — the store is sealed
    /// until the user unlocks the device once after reboot, then remains
    /// accessible until the next reboot. This is the right balance for a chat
    /// app: sensitive data is protected at rest, but background tasks (silent
    /// pushes, downloads resumed after app termination) continue to work.
    ///
    /// Set to `.complete` for the strongest protection (file is sealed whenever
    /// the device is locked) — note this breaks background reads while locked.
    /// Set to `nil` to opt out entirely (not recommended; the OS default applies).
    ///
    /// This value is ignored on macOS and Mac Catalyst, where at-rest protection
    /// is handled by FileVault. It is also ignored for in-memory SwiftData stores.
    public var fileProtectionClass: FileProtectionType?

    /// Caps applied to SSE / NDJSON streaming from cloud backends. These
    /// defend against hostile or misconfigured upstream servers that try to
    /// exhaust client memory or starve the consumer. See ``SSEStreamLimits``.
    ///
    /// Defaults to ``SSEStreamLimits/default`` — well above any realistic
    /// provider throughput. Host apps that point `CustomEndpoint.baseURL` at
    /// untrusted servers can tighten these further.
    public var sseStreamLimits: SSEStreamLimits

    /// When `true`, a boot-time sweep removes Keychain items whose owning
    /// `APIEndpoint` row no longer exists — recovering storage from orphaned
    /// credentials left behind by failed deletions or direct SwiftData wipes.
    ///
    /// Disable only for test harnesses that populate the framework's Keychain
    /// namespace independently and don't want their fixtures reaped.
    public var keychainReaperEnabled: Bool

    /// Host allowlist policy applied to every URLSession created by
    /// ``URLSessionFactory``.
    ///
    /// Defaults to ``.unrestricted``. Set at app startup before making any
    /// network call. See ``NetworkPolicy`` for subdomain semantics.
    public var networkPolicy: NetworkPolicy

    /// Opt-in flag for hardware-backed key wrapping via
    /// ``SecureEnclaveKeyManager``.
    ///
    /// > Important: This flag is currently **inert** — as of this release no
    /// > first-party ManifoldKit code path reads it, so setting it has no
    /// > behavioural effect on its own. It is reserved for future framework
    /// > wiring and for host apps that key their own SE-backed flows off a
    /// > single setting. Apps that want SE-wrapped storage today must call
    /// > ``SecureEnclaveKeyManager/shared`` directly and gate on this flag
    /// > themselves.
    ///
    /// The SE is only available on physical devices; on simulators and
    /// environments where the SE is unavailable,
    /// ``SecureEnclaveKeyManager/isAvailable`` returns `false` and operations
    /// gracefully throw ``SecureEnclaveError/notAvailable`` rather than
    /// crashing.
    ///
    /// Defaults to `false` for conservative rollout.
    public var useSecureEnclave: Bool

    /// Maximum UTF-8 byte length of a user message. Messages exceeding this are rejected
    /// before SwiftData insertion to prevent OOM on constrained iOS devices.
    public var maxUserMessageBytes: Int = 500_000        // 500 KB

    /// Maximum UTF-8 byte length of the RAG query string passed to the embedding backend.
    /// Truncated (not rejected) to avoid embedding runaway on long messages.
    public var maxRAGQueryBytes: Int = 8_000             // 8 KB

    /// Maximum HTTP request body size accepted by ManifoldServer.
    public var maxServerRequestBodyBytes: Int = 4_194_304 // 4 MB

    /// Maximum byte length (UTF-8) for an MCP tool name parsed from a server's
    /// `tools/list` response. Names exceeding this limit are truncated at a UTF-8
    /// code-unit boundary and a warning is logged. Defends against servers that
    /// send pathologically long names. (SEC-10)
    public var maxMCPToolNameBytes: Int = 256

    /// Maximum byte length (UTF-8) for an MCP tool description parsed from a
    /// server's `tools/list` response. Descriptions exceeding this limit are
    /// truncated at a UTF-8 code-unit boundary and a warning is logged. (SEC-10)
    public var maxMCPToolDescriptionBytes: Int = 4_096

    /// Controls how ``PinnedSessionDelegate`` treats custom hosts that have no
    /// pins configured in ``PinnedSessionDelegate/pinnedHosts``.
    ///
    /// - ``CustomHostTrustPolicy/platformDefault`` *(default)*: unknown hosts
    ///   fall back to the OS trust evaluation, matching pre-existing behaviour.
    /// - ``CustomHostTrustPolicy/requireExplicitPins``: connections to any
    ///   non-localhost host without configured pins are **rejected** (fail-closed).
    ///   Use this in security-sensitive deployments where all remote hosts must
    ///   be explicitly allowlisted via `PinnedSessionDelegate.pinnedHosts`.
    ///
    /// Known production hosts (`api.openai.com`, `api.anthropic.com`) always
    /// fail-closed regardless of this setting.
    public var customHostTrustPolicy: CustomHostTrustPolicy

    /// When `false` (default), credentialed cloud requests to non-loopback hosts
    /// require a non-empty SPKI pin set in ``PinnedSessionDelegate/pinnedHosts``.
    ///
    /// Fail-closed here closes the residual DNS-rebinding window where
    /// ``ConnectAddressPinningDelegate`` can only detect a private connect
    /// address *after* URLSession may already have sent `Authorization` under
    /// platform trust. Pinned hosts fail TLS (and never send the HTTP request)
    /// if the rebound peer cannot present a matching certificate chain.
    ///
    /// Set `true` only for trusted custom endpoints you cannot pin yet — you
    /// accept residual credential exposure if DNS rebinds to a private peer that
    /// completes TLS under platform trust.
    ///
    /// Loopback URLs and RFC 6761 special-use test hosts (`.test`, `.localhost`)
    /// are always exempt so unit tests and local servers keep working.
    public var allowUnpinnedCredentialedHosts: Bool

    /// The framework's fallback ``bundleIdentifier``. Host apps that surface
    /// this value back to the user (e.g. as part of a default-path
    /// derivation) can compare against it to detect when the host forgot to
    /// install a real configuration.
    public static let frameworkDefaultBundleIdentifier = "com.manifoldkit"

    public init(
        appName: String = "ManifoldKit",
        bundleIdentifier: String = ManifoldConfiguration.frameworkDefaultBundleIdentifier,
        modelsDirectoryName: String = "Models",
        features: Features = Features(),
        fileProtectionClass: FileProtectionType? = .completeUntilFirstUserAuthentication,
        sseStreamLimits: SSEStreamLimits = .default,
        keychainReaperEnabled: Bool = true,
        customHostTrustPolicy: CustomHostTrustPolicy = .platformDefault,
        allowUnpinnedCredentialedHosts: Bool = false,
        useSecureEnclave: Bool = false,
        networkPolicy: NetworkPolicy = .unrestricted
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.modelsDirectoryName = modelsDirectoryName
        self.features = features
        self.fileProtectionClass = fileProtectionClass
        self.sseStreamLimits = sseStreamLimits
        self.keychainReaperEnabled = keychainReaperEnabled
        self.customHostTrustPolicy = customHostTrustPolicy
        self.allowUnpinnedCredentialedHosts = allowUnpinnedCredentialedHosts
        self.useSecureEnclave = useSecureEnclave
        self.networkPolicy = networkPolicy
    }

    // MARK: - Derived identifiers

    public var logSubsystem: String { bundleIdentifier }
    public var keychainServiceName: String { "\(bundleIdentifier).apikeys" }
    public var downloadSessionIdentifier: String { "\(bundleIdentifier).modeldownload" }
    public var pendingDownloadsKey: String { "\(bundleIdentifier).pendingDownloads" }
    public var memoryPressureQueueLabel: String { "\(bundleIdentifier).memory-pressure" }
}

// MARK: - Features

extension ManifoldConfiguration {

    /// Controls which UI features are available in ManifoldKit views.
    ///
    /// All features default to `true` (enabled). Set individual flags to `false`
    /// to hide features from the interface.
    ///
    /// These flags control *availability* — whether the feature exists in the UI
    /// at all. They are set once at app startup and are not intended to be changed
    /// at runtime.
    ///
    /// ## Example: Minimal offline-only deployment
    /// ```swift
    /// ManifoldConfiguration.shared.features = .init(
    ///     showModelDownload: false,
    ///     showCloudAPIManagement: false,
    ///     showChatExport: false
    /// )
    /// ```
    ///
    /// ## Example: Simplified consumer app
    /// ```swift
    /// ManifoldConfiguration.shared.features = .init(
    ///     showContextIndicator: false,
    ///     showMemoryIndicator: false,
    ///     showAdvancedSettings: false,
    ///     showUpgradeHint: false
    /// )
    /// ```
    public struct Features: Sendable {

        // MARK: - Toolbar

        /// Shows the context window usage gauge (token count) in the chat toolbar.
        ///
        /// Useful for power users who want to see how much of the context window
        /// is consumed. Disable for a cleaner toolbar in consumer apps.
        public var showContextIndicator: Bool

        /// Shows the memory pressure indicator (RAM usage) in the chat toolbar.
        ///
        /// Displays a colored dot and memory stats. Helpful for debugging and
        /// on constrained devices. Disable to reduce visual noise.
        public var showMemoryIndicator: Bool

        /// Shows the chat export button (share icon) in the chat toolbar.
        ///
        /// When enabled, users can export the active conversation as Markdown
        /// or plain text from the toolbar. Per-session export — including
        /// JSON — is also available from the session list's row context menu
        /// regardless of this flag. Disable this flag for locked-down or
        /// single-purpose deployments that want to hide the toolbar
        /// affordance.
        public var showChatExport: Bool

        // MARK: - Model Management

        /// Shows the Download tab in the model management sheet.
        ///
        /// Enables browsing and downloading models from HuggingFace. Disable
        /// for offline-only apps or deployments with pre-loaded models.
        public var showModelDownload: Bool

        /// Shows the Storage tab in the model management sheet.
        ///
        /// Lets users see disk usage and delete downloaded models. Disable for
        /// managed deployments where model lifecycle is controlled by the app.
        public var showStorageTab: Bool

        // MARK: - Settings

        /// Shows the generation settings button (gear icon) in the chat toolbar.
        ///
        /// Opens the settings sheet with temperature, system prompt, and other
        /// controls. Disable to lock down the generation experience entirely.
        public var showGenerationSettings: Bool

        /// Shows the Advanced section inside generation settings.
        ///
        /// Contains Top P, Repeat Penalty, Prompt Template, Sampler Presets,
        /// and Backend Info. Disable to expose only basic settings (temperature
        /// and system prompt).
        public var showAdvancedSettings: Bool

        /// Shows the Cloud API management section in generation settings.
        ///
        /// Lets users add and configure cloud API endpoints (OpenAI, Claude, etc.).
        /// Disable for local-only or offline deployments.
        public var showCloudAPIManagement: Bool

        // MARK: - Banners & Hints

        /// Shows the upgrade hint banner after the first Foundation model response.
        ///
        /// Nudges users to download a local model for longer context. Disable if
        /// your app handles model selection differently or doesn't use Foundation.
        public var showUpgradeHint: Bool

        // MARK: - Composer

        /// Shows the microphone / audio-recording button in the chat composer.
        ///
        /// The button records an audio message attachment on iOS. It is a
        /// permission-gated control: recording invokes `AVAudioSession`, which
        /// hard-crashes the host process (SIGABRT) if the app's Info.plist is
        /// missing `NSMicrophoneUsageDescription`. Set this to `false` to remove
        /// the control entirely for apps that don't ship voice capture.
        ///
        /// > Note: Even when this is `true`, the button is automatically hidden
        /// > when `NSMicrophoneUsageDescription` is absent from the host
        /// > Info.plist, so a missing usage string degrades to a no-op rather
        /// > than a crash. See `<doc:BuildingAChatUI>` / QUICKSTART for the
        /// > required Info.plist keys.
        public var showAudioInput: Bool

        /// Shows image-attachment controls (the built-in file-importer paperclip
        /// in the composer, plus the opt-in `VisionInputButton` /
        /// `PhotoAttachmentButton` composer accessories).
        ///
        /// The photo accessories use `PhotosPicker` (PHPicker), which runs
        /// out-of-process and needs no usage-description string, so they are
        /// gated on this flag alone. Declaring `NSPhotoLibraryUsageDescription`
        /// is still recommended for App Store review. Set this to `false` to
        /// remove image attachment from the interface entirely.
        public var showImageAttachment: Bool

        // MARK: - Init

        public init(
            showContextIndicator: Bool = true,
            showMemoryIndicator: Bool = true,
            showChatExport: Bool = true,
            showModelDownload: Bool = true,
            showStorageTab: Bool = true,
            showGenerationSettings: Bool = true,
            showAdvancedSettings: Bool = true,
            showCloudAPIManagement: Bool = true,
            showUpgradeHint: Bool = true,
            showAudioInput: Bool = true,
            showImageAttachment: Bool = true
        ) {
            self.showContextIndicator = showContextIndicator
            self.showMemoryIndicator = showMemoryIndicator
            self.showChatExport = showChatExport
            self.showModelDownload = showModelDownload
            self.showStorageTab = showStorageTab
            self.showGenerationSettings = showGenerationSettings
            self.showAdvancedSettings = showAdvancedSettings
            self.showCloudAPIManagement = showCloudAPIManagement
            self.showUpgradeHint = showUpgradeHint
            self.showAudioInput = showAudioInput
            self.showImageAttachment = showImageAttachment
        }
    }
}

// MARK: - NetworkPolicy

extension ManifoldConfiguration {

    /// Restricts which remote hosts ManifoldKit sessions are allowed to contact.
    ///
    /// Privacy-forward apps that should only ever reach a known set of servers
    /// (e.g. a single custom endpoint or a closed-garden SaaS provider) can
    /// set this to `.allowlist` at startup. Every URLSession created by
    /// ``URLSessionFactory`` will then reject initial requests **and** redirect
    /// targets whose host is not in the list.
    ///
    /// Subdomain semantics: listing `"huggingface.co"` also permits
    /// `cdn-lfs.huggingface.co` and any other subdomain of that apex.
    ///
    /// Localhost addresses (`localhost`, `127.0.0.1`, `::1`) are always
    /// permitted regardless of policy — they represent locally-served content
    /// under the app's control.
    ///
    /// ## Example: restrict to a single private endpoint
    ///
    /// ```swift
    /// ManifoldConfiguration.shared.networkPolicy = .allowlist(["myapi.example.com"])
    /// ```
    public enum NetworkPolicy: Sendable, Equatable {

        /// No host filtering — all outbound hosts are permitted.
        ///
        /// This is the default. It preserves the behaviour shipped before
        /// this API existed so existing integrations are unaffected.
        case unrestricted

        /// Only hosts that exactly match (or are subdomains of) a listed
        /// apex host are permitted.
        ///
        /// Matching rules:
        /// - `"example.com"` matches `example.com` and `sub.example.com`.
        /// - Comparison is case-insensitive.
        /// - Leading dots in entries are stripped before comparison.
        case allowlist(Set<String>)
    }

}

// MARK: - NetworkPolicyError

/// Thrown when a request targets a host that is not in the configured
/// ``ManifoldConfiguration/NetworkPolicy`` allowlist.
public enum NetworkPolicyError: Error, Sendable, Equatable {

    /// The request's host is not permitted by the active ``ManifoldConfiguration/NetworkPolicy``.
    case hostNotAllowed(host: String)
}

// MARK: - NetworkPolicyGuard

/// Stateless helper that evaluates a URL against the active network policy.
///
/// ``URLSessionFactory`` calls ``check(url:)`` before creating tasks and
/// ``CompositeURLSessionDelegate`` calls it in the redirect callback so
/// both initial requests and redirect targets are covered.
package enum NetworkPolicyGuard {

    /// Throws ``NetworkPolicyError/hostNotAllowed(host:)`` when `url`'s host
    /// is blocked by `policy`.
    ///
    /// - Localhost addresses always pass regardless of the configured policy.
    /// - Host matching is case-insensitive. A listed apex host also permits
    ///   all of its subdomains (`.hasSuffix("." + apexHost)`).
    package static func check(url: URL, policy: ManifoldConfiguration.NetworkPolicy) throws {
        guard case .allowlist(let allowed) = policy else { return }

        // Localhost is always permitted — it is content under the app's control.
        if PrivateIPClassifier.isLocalhostURL(url) { return }

        let rawHost = url.host?.lowercased() ?? ""
        // Strip trailing dot from FQDN if present.
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost

        for entry in allowed {
            let apex = entry.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if host == apex || host.hasSuffix("." + apex) {
                return
            }
        }

        throw NetworkPolicyError.hostNotAllowed(host: host)
    }
}

// MARK: - CustomHostTrustPolicy

extension ManifoldConfiguration {

    /// Determines how ``PinnedSessionDelegate`` handles TLS challenges from
    /// custom hosts that have no pins configured in
    /// ``PinnedSessionDelegate/pinnedHosts``.
    ///
    /// This policy does **not** affect known production hosts
    /// (`api.openai.com`, `api.anthropic.com`) — those always fail-closed
    /// when their pin sets are absent or empty. Localhost addresses
    /// (`localhost`, `127.0.0.1`, `::1`) always bypass pinning entirely.
    public enum CustomHostTrustPolicy: Sendable, Equatable {

        /// Unknown custom hosts fall back to the OS platform trust evaluation
        /// when no pins are configured for them.
        ///
        /// This is the default for TLS evaluation. Credentialed requests to
        /// unpinned non-loopback hosts are still rejected by
        /// ``allowUnpinnedCredentialedHosts`` (default `false`) unless pins
        /// are configured — platform trust alone is not enough for API keys.
        case platformDefault

        /// Connections to custom hosts that have no configured pins are
        /// **rejected** (fail-closed).
        ///
        /// Use this in security-sensitive deployments where every remote host
        /// must be explicitly allowlisted by adding SPKI hashes to
        /// ``PinnedSessionDelegate/pinnedHosts`` before the first request.
        /// Any host without configured pins will have its authentication
        /// challenge cancelled.
        case requireExplicitPins
    }
}
