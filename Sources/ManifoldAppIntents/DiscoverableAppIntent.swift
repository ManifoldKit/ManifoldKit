import Foundation
import ManifoldInference

#if canImport(AppIntents)
import AppIntents

// MARK: - AppIntentApprovalPolicy

/// Approval policy for AppIntent-backed tools.
///
/// Defined at top level (rather than nested inside the generic
/// ``AppIntentToolExecutor``) so batch-registration call sites — which cannot
/// name a concrete generic argument to access a nested enum — can reference the
/// type directly. ``AppIntentToolExecutor/ApprovalPolicy`` is a typealias that
/// points here, keeping the single-executor API unchanged.
@available(iOS 26, macOS 26, *)
public enum AppIntentApprovalPolicy: Sendable {
    /// Require an explicit ``ToolApprovalGate`` decision per call.
    case requiresUserApproval

    /// Skip approval prompts for read-only intents that are safe to run
    /// without a confirmation step.
    case readOnlyAutoApprove

    // Not public because callers shouldn't hard-code on the Bool shape;
    // `AppIntentToolExecutor` is the single consumer.
    var requiresApproval: Bool {
        switch self {
        case .requiresUserApproval: true
        case .readOnlyAutoApprove: false
        }
    }
}

// MARK: - DiscoverableAppIntent

/// Marker protocol for AppIntents that participate in batch registration.
///
/// Adopt `DiscoverableAppIntent` on any intent you want to hand to
/// ``ToolRegistry/registerAppIntents(_:approvalPolicy:entityResolver:)``.
/// The marker adds nothing over `AppIntent & Decodable` at the type level —
/// it is an explicit declaration of registration intent that lets call sites
/// build typed arrays without casting and lets tooling enumerate the batch
/// surface without scanning every `AppIntent` in the module.
///
/// ### Example
///
/// ```swift
/// struct SearchIntent: DiscoverableAppIntent {
///     static let title: LocalizedStringResource = "Search"
///     @Parameter(title: "Query") var query: String
///     init() {}
///     init(from decoder: Decoder) throws { … }
///     func perform() async throws -> some IntentResult { … }
/// }
///
/// // At app startup — zero boilerplate per intent:
/// toolRegistry.registerAppIntents(
///     [SearchIntent.self, SummarizeIntent.self],
///     entityResolver: MyEntityResolver()
/// )
/// ```
@available(iOS 26, macOS 26, *)
public protocol DiscoverableAppIntent: AppIntent & Decodable {}

// MARK: - ToolRegistry batch-registration extension

@available(iOS 26, macOS 26, *)
public extension ToolRegistry {

    /// Registers multiple `DiscoverableAppIntent` types as tool executors.
    ///
    /// Each metatype in `intentTypes` is opened from its existential shell and
    /// wrapped in a concrete ``AppIntentToolExecutor``, then handed to
    /// ``ToolRegistry/register(_:)`` exactly as the single-executor path does.
    /// A uniform `approvalPolicy` and `entityResolver` are applied to every
    /// intent in the array; supply per-intent configuration by falling back to
    /// individual ``AppIntentToolExecutor`` registrations for those intents.
    ///
    /// - Parameters:
    ///   - intentTypes: Metatypes conforming to ``DiscoverableAppIntent``.
    ///     Array order is preserved for diagnostics but registration is by name.
    ///   - approvalPolicy: Applied uniformly to every intent.
    ///     Defaults to ``AppIntentApprovalPolicy/requiresUserApproval``.
    ///   - entityResolver: Used to resolve `AppEntity`-typed parameters.
    ///     Defaults to ``DefaultAppEntityResolver``.
    func registerAppIntents(
        _ intentTypes: [any DiscoverableAppIntent.Type],
        approvalPolicy: AppIntentApprovalPolicy = .requiresUserApproval,
        entityResolver: any AppEntityResolver = DefaultAppEntityResolver()
    ) {
        for intentType in intentTypes {
            register(_openAndMakeExecutor(intentType, approvalPolicy: approvalPolicy, entityResolver: entityResolver))
        }
    }

    /// Convenience overload for callers that assemble metatype arrays at runtime
    /// and cannot (or choose not to) adopt the ``DiscoverableAppIntent`` marker.
    ///
    /// Behaviour is identical to the ``DiscoverableAppIntent`` overload.
    func registerAppIntents(
        _ intentTypes: [any (AppIntent & Decodable).Type],
        approvalPolicy: AppIntentApprovalPolicy = .requiresUserApproval,
        entityResolver: any AppEntityResolver = DefaultAppEntityResolver()
    ) {
        for intentType in intentTypes {
            register(_openAndMakeExecutor(intentType, approvalPolicy: approvalPolicy, entityResolver: entityResolver))
        }
    }
}

// MARK: - Existential-opening shim

/// Opens the `any (AppIntent & Decodable).Type` existential into a concrete
/// generic function so `AppIntentToolExecutor<I>` can be instantiated.
///
/// Swift generics require that the type parameter be known at compile time.
/// The existential-opening trick (passing to a generic function) is the
/// idiomatic Swift 5.7+ solution and avoids `@_disfavoredOverload` hacks or
/// secondary protocol witnesses. The result is returned as `any ToolExecutor`
/// so the caller can hand it directly to `ToolRegistry.register`.
@available(iOS 26, macOS 26, *)
private func _openAndMakeExecutor(
    _ intentType: any (AppIntent & Decodable).Type,
    approvalPolicy: AppIntentApprovalPolicy,
    entityResolver: any AppEntityResolver
) -> any ToolExecutor {
    func _make<I: AppIntent & Decodable>(_ type: I.Type) -> any ToolExecutor {
        AppIntentToolExecutor(
            type,
            approvalPolicy: approvalPolicy,
            entityResolver: entityResolver
        )
    }
    return _make(intentType)
}

#endif // canImport(AppIntents)
