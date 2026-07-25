# NOTES — 02-swiftui-chat run-1

- **Backend/path**: Documented happy path — `ManifoldKit.quickStart(configuration:)` + multi-session `SessionListView`/`ChatView` + first-launch Ollama seed (`llama3.1:8b` @ localhost:11434). Headless `DXVerify` target for e2e generation/persistence proof.
- **What worked smoothly**: Cold build (~57s cached deps), umbrella import surface, `quickStart` wiring `viewModel` + `sessionManager`, Ollama `loadSelectedEndpoint()`, `sendMessage` returning a real reply, SwiftData session restore across process restarts (same session id; UI showed prior turn). Drop-in `ChatView` + sidebar looks production-ready.
- **Surprising**: `.environment(\.endpointStore, …)` from multi-session docs does **not** compile with umbrella-only (`EnvironmentValues` has no `endpointStore`). Mic banner without Info.plist. Bare SwiftPM executable needs a minimal `.app` wrapper for a reliable macOS window.
- **Impression**: SwiftUI DX is strong once you stitch QUICKSTART + SWIFTUI-MULTI-SESSION; generation and persistence Just Work. The remaining friction is doc/package seams (endpoint env key, first-run Ollama ceremony, consumer packaging), not missing core APIs.
- **Acceptance**: compile ✓, window ✓ (screenshot.png), chat UI ✓, generation ✓ (headless + messages visible in UI), persistence ✓.
