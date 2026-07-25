# Root causes — 02-swiftui-chat v0.73.0 live (2026-07-25)

Cross-run causal grouping. Individual friction lives in `run-{1,2,3}/FRICTION.md`.

## RC-A — Split / contradictory load story (M1, M2, M3)

**Symptom**: Apps boot with a polished multi-session UI but an inert composer, or docs disagree on whether load is automatic.

**Cause**: Three partially overlapping stories:

1. `quickStart()` auto-load policy (multi-session §2 — Foundation-first / cloud endpoint)
2. Explicit post-seed triad in QUICKSTART (Ollama + Foundation)
3. Manual §6 recipe that inserts endpoints without selecting/loading them, and no relaunch re-bind for the manual path

**Runtime truth this iteration**: Explicit load wins. Auto-load claims for Foundation and for post-return Ollama seed are overstated relative to what agents observed.

**Fix surface**: Docs first (single authoritative matrix: path × first launch × relaunch × backend). Optionally runtime: make manual restore re-select last endpoint so §6 matches QUICKSTART's relaunch claim.

## RC-B — Umbrella vs model-management surface (M4, Entry model-mgmt)

**Symptom**: `.environment(\.endpointStore, …)` and `APIConfigurationView` / `ModelManagementSheet` fail or surprise under `import ManifoldKit` alone.

**Cause**: Intentional product split (`ManifoldUIModelManagement` opt-in) is real and mostly documented in §5, but snippets in the multi-session "full recipe" and AGENTS bootstrap still show the env injection without the second product/import.

**Fix surface**: Every snippet that uses `endpointStore` / API config UI must `import ManifoldUIModelManagement` and declare the product.

## RC-C — Foundation session-load coupling (M5)

**Symptom**: After creating/switching sessions, UI says loaded; inference says no model.

**Cause**: Load state on `ChatViewModel` can desync from the engine after session churn on Foundation; docs promise load-on-`switchToSession` without caveats for this backend.

**Fix surface**: Either re-dispatch Foundation load on session switch when needed, or surface an honest "engine not ready" state; document re-seed after session mint for Foundation hosts.

## RC-D — Consumer host shape (M6, M7)

**Symptom**: tools-version / platform enum mismatch; bare `swift run` SwiftUI apps crash or don't activate.

**Cause**: Docs assume Xcode app targets for GUI; DX harness and "minimal Package.swift" evaluators use executables. Platform enum `v26` requires PackageDescription 6.2 while general docs still say 6.1+.

**Fix surface**: Document SwiftPM executable limits; align tools-version guidance with macOS 26; optional MinimalExample remains Xcode-primary.

## RC-E — Positive: persistence + drop-in UI (no open issue)

Session restore, SwiftData Application Support store keyed by `bundleIdentifier`, and drop-in `ChatView`/`SessionListView` are solid across all three paths. Do not "fix" this layer for the load-story issues above — they are orthogonal.
