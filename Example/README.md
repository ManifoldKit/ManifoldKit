# ManifoldKit Examples

## Advanced (Full Reference App)

The full-featured demo showing all ManifoldKit capabilities working together. This is also the host for UI tests. Start with `Examples/MinimalExample/` if you're new — open this once the minimal example makes sense.

1. Open `Advanced.xcodeproj` in Xcode
2. The project references `ManifoldKit` as a local package from `../../`
3. Build and run on iOS Simulator or Mac

### UI test debugging

From the repository root, use the fast rerun loop:

```bash
scripts/example-ui-tests.sh build-for-testing
scripts/example-ui-tests.sh test-without-building -only-testing:AdvancedUITests/ChatFlowUITests/testEmptyStateShowsWelcome
```

The helper auto-selects an available simulator destination. If you need to pin one manually, inspect `xcrun simctl list devices available` and pass `--destination 'platform=iOS Simulator,id=<SIMULATOR_ID>'`.

### Running on macOS — unregistered Macs

`--macos` targets a macOS destination directly (`scripts/example-ui-tests.sh build-for-testing --macos`). Out of the box this fails on a Mac that isn't registered under the project's Apple Developer team (`YHX2HHZ52Y`): `CODE_SIGN_STYLE = Automatic` requires a Mac App Development provisioning profile, and `ManifoldDemo.entitlements` declares `com.apple.security.application-groups` (`group.com.manifoldkit.demo`), which can only be satisfied by a provisioning profile — Xcode has no team-less way to grant it.

```
error: No profiles for 'com.manifoldkit.demo' were found: Xcode couldn't find any
Mac App Development provisioning profiles matching 'com.manifoldkit.demo'.
Automatic signing is disabled and unable to generate a profile.
```

There are two ways to unblock a macOS build. Both are legitimate; which one to use is a per-Mac/per-operator call, not something this repo mandates:

1. **Register the Mac under the team** (the "real" path). Add the Mac's UDID to the `YHX2HHZ52Y` Apple Developer account and let Automatic signing generate a Mac App Development profile that includes the App Groups capability. This is the only path that keeps macOS behavior identical to iOS/Release — full App Group handoff, the real provisioning story — but it requires access to the team, and CI runners are never registered this way.
2. **macOS Debug signing flavor** (issue [#2453](https://github.com/ManifoldKit/ManifoldKit/issues/2453) M4, this repo's default for an unregistered Mac). The `Advanced` project's Debug configuration carries `[sdk=macosx*]`-conditioned build-setting overrides that apply **only** when building for macOS, and **only** in Debug — iOS Debug, iOS Simulator, and every Release configuration are untouched. Two targets carry overrides, since both need to be signable for `test-without-building` to launch anything:
   - **`Advanced`** (the app target): `DEVELOPMENT_TEAM[sdk=macosx*] = ""` drops the team requirement; `CODE_SIGN_STYLE[sdk=macosx*] = Manual` + `CODE_SIGN_IDENTITY[sdk=macosx*] = "-"` switches to ad-hoc ("Sign to Run Locally") signing, which needs no provisioning profile; `CODE_SIGN_ENTITLEMENTS[sdk=macosx*] = Advanced/ManifoldDemo-macOS.entitlements` swaps in a macOS-only entitlements file that **drops** `com.apple.security.application-groups`.
   - **`AdvancedUITests`** (the test-runner target): the same `CODE_SIGN_STYLE`/`CODE_SIGN_IDENTITY` override, mirrored (no entitlements override — the UITest bundle carries none) — without this the test runner itself would still need a team to sign.

   `DEVELOPMENT_TEAM` and `CODE_SIGN_STYLE`/`CODE_SIGN_IDENTITY` change together in the same diff, so it isn't isolated which one alone unblocks the provisioning-profile error above — treat "signing plus the entitlement drop, together, unblock it" as the verified claim, not a claim about the entitlement in isolation.

   The App Group has two consumers, not one: the Share/Action Extensions (iOS-only, `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"` — no macOS build, so dropping the entitlement costs nothing there) and `AskManifoldDemoIntent`, an App Intent compiled into the `Advanced` target itself (not an extension) that **does** run on macOS and writes to the App-Group `UserDefaults` before opening `manifolddemo://ingest` for `ManifoldDemoApp.swift`'s `handleOpenURL` to read back. That round trip is expected to keep working without the entitlement — not because `UserDefaults(suiteName:)` returns `nil` and a guard catches it (it doesn't; `init?(suiteName:)` only returns `nil` for the caller's own bundle identifier or the global domain, never for a missing entitlement), but because this app has never enabled App Sandbox (`com.apple.security.app-sandbox` appears nowhere in either entitlements file) — unsandboxed, a named `UserDefaults` suite is an ordinary shared preferences domain regardless of entitlement. See the comment in `ManifoldDemo-macOS.entitlements` for the full reasoning, including what breaks this if App Sandbox is ever turned on for this config.

   **Cost of this flavor beyond the entitlement itself:** the two entitlements files (`ManifoldDemo.entitlements` for iOS/Release, `ManifoldDemo-macOS.entitlements` for macOS Debug) are hand-synced with no tripwire. Add a capability to the iOS file for any reason and macOS Debug silently doesn't get it — an App-Group-shaped reader just `guard`s and returns, so the symptom is a feature that quietly does nothing on macOS Debug, not a build failure. No lane in this repo builds `Advanced` for macOS Release, so nothing would catch the drift either. Keep both files in sync by hand whenever entitlements change.

   With this flavor, `scripts/example-ui-tests.sh build-for-testing --macos` and `test-without-building --macos` run on any Mac, registered or not:

   ```bash
   scripts/example-ui-tests.sh build-for-testing --macos
   scripts/example-ui-tests.sh test-without-building --macos \
     -only-testing:AdvancedUITests/ChatFlowUITests/testEmptyStateShowsWelcome
   ```

   Passing macOS UI-test behavior is not guaranteed by this flavor — it only unblocks signing. Some UI tests assume iOS-only presentation shapes (e.g. `dismissSheet(app:)`'s swipe-to-dismiss fallback assumes a sheet; the model switcher renders as a **popover** on macOS per `.chatModelSwitcher`'s documented platform split) and can fail on macOS destinations for reasons unrelated to signing — that is tracked separately as M4 backlog, not fixed by this flavor.

   `xcodebuild` rewrites `Example/Advanced.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` as a side effect of resolving the local `ManifoldKit` package on every invocation; `git status` after any macOS (or iOS) run and revert that file before committing.

### Visual walkthrough (screenshot evidence for a design pass)

`AdvancedUITests/VisualWalkthroughUITests` drives the demo through the surfaces the 2026 UI refresh restyled — empty state, model switcher, tool-invocation cards, scroll-under-glass, composer, bubble-style presets — and writes a numbered screenshot story for a human comparison against the drawn spec (`docs/design/ui-refresh-2026.html`). Run it by hand whenever the chat surface changes; it is not part of any CI lane:

```bash
scripts/example-ui-tests.sh test -only-testing:AdvancedUITests/VisualWalkthroughUITests
```

Screenshots go to `/private/tmp/manifoldkit-ui-walkthrough` (also attached to the result bundle), and the path is printed at the start of each test. `/private/tmp` is periodically cleared by the system, so copy out anything worth keeping — or point the run somewhere durable:

```bash
TEST_RUNNER_MANIFOLD_WALKTHROUGH_DIR="$HOME/Desktop/walkthrough" \
  scripts/example-ui-tests.sh test -only-testing:AdvancedUITests/VisualWalkthroughUITests
```

Two things about that variable. It must be an **environment assignment before the command**, not a trailing `xcodebuild` argument — in argument position it is read as a build setting and never reaches the runner (the frames then quietly go to the default directory). And the path must be **absolute**: `~` is not expanded there, so use `$HOME`. A relative value fails the run rather than silently writing into the simulator's container.

The suite's finale, `testDefineRealOllamaEndpointAndSendLiveMessage`, is **opt-in and not hermetic**: it launches without `--uitesting` (real backends, real SwiftData store), needs Ollama serving `llama3.1:8b` at `localhost:11434`, and persists an endpoint into the demo's real store. It skips with an explanatory message unless you opt in on the same command line:

```bash
TEST_RUNNER_MANIFOLD_WALKTHROUGH_LIVE=1 scripts/example-ui-tests.sh test \
  -only-testing:AdvancedUITests/VisualWalkthroughUITests/testDefineRealOllamaEndpointAndSendLiveMessage
```

Still tracked as open ([#2376](https://github.com/ManifoldKit/ManifoldKit/issues/2376)): the finale has hung if the model called a tool (second `/api/chat` issued, then silence). Core ships hypothesized mitigations (drain residual stream bytes after `done`, `Connection: close` on Ollama, 300s stream idle timeout, tool-continuation request summary logs) but the original iOS walkthrough path is **not** re-confirmed green. The assertion stays strict — if a hang returns, fail loudly and use the new logs.

(The sibling real-model E2E in `ModelManagementUITests` gates on a `~/.manifoldkit_real_e2e` sentinel file instead. That works because it is documented for a macOS destination, where `HOME` is your home directory; under this suite's default simulator destination `HOME` is the simulator's container, so a sentinel you touched on the host would never be seen.)

### What This Demonstrates

- Configuring `ManifoldConfiguration` at startup
- Composing `ManifoldUI` views (ChatView, SessionListView, ModelManagementSheet)
- Setting up SwiftData with `ModelContainerFactory`
- Wiring view models via `@Environment`
- Cloud API endpoint management
- Multi-session chat with auto-rename
- Model download and storage management
- Share Extension + Action Extension handoff via App Group (see `Extensions/`)

### Share & Action Extensions

The demo includes two iOS app extensions that hand content into a new chat session:

- **ManifoldDemoShareExtension** — activated from the system Share sheet. Accepts text, URLs, and images.
- **ManifoldDemoActionExtension** — activated from the system action row. Accepts text and URLs.

Both extensions write a `PendingSharePayload` to an App Group `UserDefaults` key. The host app drains it on the next foreground transition and calls `ChatViewModel.ingestPendingPayload(_:intent:)` to open a pre-filled session.

See `docs/share-action-extension-recipe.md` for the full integration guide.

## Focused Examples

Small, purpose-built apps that each showcase a single feature. Open `Examples/ManifoldExamples.xcodeproj` in Xcode and select the scheme for the example you want to run.

| Example | Scheme | What It Shows |
|---------|--------|---------------|
| [MinimalExample](Examples/MinimalExample/) | `MinimalExample_iOS` / `MinimalExample_macOS` | Bare-minimum ManifoldKit app (~40 lines) |

More examples ship alongside new features — see each example's README for details.

## Customization

`quickStart()` already folds in the compiled-in default families (Ollama,
CloudSaaS, and Foundation on macOS 26 / iOS 26). To register them yourself on a
manual bootstrap, import the family modules and call each registrar with the
`InferenceService` from your bootstrap result:

```swift
import ManifoldFoundation
import ManifoldOllama
import ManifoldCloudSaaS

let result = try await ManifoldKit.quickStart()
OllamaBackends.register(with: result.bootstrap.inferenceService)
CloudSaaSBackends.register(with: result.bootstrap.inferenceService)
FoundationBackends.register(with: result.bootstrap.inferenceService)
```
