# WWDC 2026 Pre-emptive Trait Stubs

Added 2026-05-31, 8 days before WWDC 2026 (June 8).

## What the two traits represent

**`SystemAIProviderExtension`** — the expected iOS 27 / macOS 27 entrypoint for
third-party apps to plug into Siri and Writing Tools as AI backends. Apple has
described a "system AI provider" extension point in pre-release documentation;
the exact protocol name, entitlement string, and Info.plist key are unconfirmed.

**`CoreAI`** — a rumoured framework that would unify and succeed Core ML,
Create ML, and the lower layers of Foundation Models. Whether it ships as a
distinct framework or as an expansion of an existing one is unknown until the
keynote.

## Why add them pre-WWDC

SwiftPM trait names are consumed at the manifest level, before any source
files compile. If a `#if SystemAIProviderExtension` block is committed to
a source file today, `swift build` will fail until the trait is declared in
`Package.swift`. By landing the trait declarations now:

- Feature branches can use `#if SystemAIProviderExtension` and `#if CoreAI`
  guards today without a blocking manifest change.
- On June 8, wiring in the real implementation requires only source additions
  and a `swiftSettings: [.define(...)]` annotation on the new target — no
  manifest restructuring under time pressure.

## Deferred decision points

These questions must be resolved after WWDC before the traits become real:

1. **Exact framework/protocol names** — the trait names here are best-guess.
   Rename to match Apple's official identifiers if they differ.
2. **Entitlement and capability requirements** — both surfaces will likely
   require a provisioning entitlement; the consumer-manifest documentation
   should reference any required `Info.plist` keys.
3. **OS availability floor** — `SystemAIProviderExtension` is expected iOS 27 /
   macOS 27+; `CoreAI` availability is unknown. Add `@available` guards and
   update the platform policy table in `CLAUDE.md` accordingly.
4. **Associated targets** — add a real `ManifoldSystemAIProvider` or
   `ManifoldCoreAI` source target only once the API surface is confirmed.
   The stub traits intentionally have no targets today.

## How to activate post-WWDC

1. Add the concrete source target(s) with `.define("SystemAIProviderExtension", .when(traits: ["SystemAIProviderExtension"]))` in `swiftSettings`.
2. Remove both trait names from `pendingMapping` in `FeatureMatrixTests.swift` and add the real `ManifoldCapability` cases they unlock.
3. Update this file with the confirmed API surface and availability.
