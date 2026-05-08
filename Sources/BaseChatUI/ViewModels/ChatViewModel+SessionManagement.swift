import Foundation
import BaseChatRuntime
import BaseChatInference

// MARK: - ChatViewModel + Session Management

extension ChatViewModel {

    /// Switches to a different chat session, loading its messages and settings.
    public func switchToSession(_ session: ChatSessionRecord) async {
        // Drive the UI back to idle synchronously so the toolbar/stop button
        // observes the transition immediately. The runtime handle and queue
        // tear-down are awaited via `discardRequests` below before any
        // backend mutation runs.
        if isGenerating {
            transitionPhase(to: .idle)
        }

        isRestoringSession = true
        defer { isRestoringSession = false }

        let selectionState = sessionController.activateSession(session)

        // Discard any queued requests that belong to a different session.
        // Awaiting here is load-bearing: the call cancels the active turn
        // (when its session ≠ `session.id`) and drives the task's defer
        // block to completion before returning. Running the discard
        // *before* `resetConversation()` / `secureWipe()` keeps those
        // backend KV-cache mutations from racing the dying turn — a race
        // that previously left B's first send to land on a half-torn-down
        // queue and yield zero tokens (issue #965).
        await inferenceService.discardRequests(notMatching: session.id)

        inferenceService.resetConversation()
        inferenceService.secureWipe()
        inferenceService.selectedPromptTemplate = sessionController.selectedPromptTemplate

        // Cancel the runtime's stream handle for the prior session if one is
        // still attached. `discardRequests` made the queue idle; this
        // closes the runtime-level bookkeeping so the next send opens a
        // fresh handle. Awaited inline so the runtime registry is fully
        // torn down before the caller's next send registers a new handle —
        // a fire-and-forget Task here flaked under heavy parallel load
        // (issue #965).
        if let handle = activeConversationStreamHandle {
            await conversationRuntime.cancel(handle)
            activeConversationStreamHandle = nil
        }

        // Clear any still-pending tool approvals and the once-per-session
        // latch so approvals from the prior session do not leak into this one.
        toolApprovalGate?.resetForNewSession()

        // Cancel any in-flight post-generation background tasks from the prior session.
        backgroundTask?.cancel()
        backgroundTask = nil
        backgroundTaskError = nil

        await refreshAvailableEndpointsFromStore()

        let resolvedEndpoint = selectionState.selectedEndpointID.flatMap { endpointID in
            availableEndpoints.first(where: { $0.id == endpointID })
        }
        let resolvedModel = selectionState.selectedModelID.flatMap { modelID in
            availableModels.first(where: { $0.id == modelID })
        }

        if let resolvedEndpoint {
            selectedEndpoint = resolvedEndpoint
        } else if let resolvedModel {
            selectedModel = resolvedModel
        } else {
            selectedModel = nil
            selectedEndpoint = nil
        }

        showUpgradeHint = false
        inputText = ""
        clearDraftAttachments()
        await loadMessages()
        updateContextEstimate()
        Log.ui.info("Switched to session: \(session.title, privacy: .private)")
    }

    /// Saves the current generation settings back to the active session.
    func saveSettingsToSession() async throws {
        try await sessionController.saveSettingsToSession(
            selectedModelID: selectedModel?.id,
            selectedEndpointID: selectedEndpoint?.id
        )
    }

    // MARK: - Model Discovery

    /// Refreshes the model registry and, if a Foundation model is discovered,
    /// selects and begins loading it immediately.
    ///
    /// Call this after setting `foundationModelProvider` — typically once at
    /// app launch on OS versions where Foundation is available:
    ///
    /// ```swift
    /// if #available(macOS 26, iOS 26, *) {
    ///     vm.foundationModelProvider = { FoundationBackend.isAvailable }
    ///     vm.loadFoundationModelIfAvailable()
    /// }
    /// ```
    ///
    /// If no Foundation model is discovered (either because `foundationModelProvider`
    /// is not set, returns `false`, or the OS is unsupported) this method is a no-op.
    /// Unlike ``autoSelectFirstRunModel()``, this method is not gated on a first-launch
    /// flag — call it whenever you want to (re-)enable Foundation as the active backend.
    public func loadFoundationModelIfAvailable() {
        refreshModels()
        guard let foundation = availableModels.first(where: { $0.modelType == .foundation }) else { return }
        selectedModel = foundation
        dispatchSelectedLoad()
    }

    /// Re-scans the models directory and rebuilds `availableModels`.
    ///
    /// Includes the built-in Foundation model when `foundationModelProvider` returns `true`.
    /// Clears `selectedModel` if the previously selected model is no longer on disk.
    ///
    /// Delegates to ``ModelRegistry/refresh()``; the registry surfaces the
    /// same directory-creation error that previously routed through
    /// ``errorMessage``.
    public func refreshModels() {
        do {
            try modelRegistry.refresh()
        } catch {
            errorMessage = "Could not create models directory: \(error.localizedDescription)"
        }
    }

    /// Replaces the in-memory list of selectable cloud endpoints.
    ///
    /// Clears `selectedEndpoint` when that endpoint is no longer available.
    public func setAvailableEndpoints(_ endpoints: [APIEndpointRecord]) {
        availableEndpoints = endpoints.filter(\.isEnabled)
        if let selected = selectedEndpoint,
           !availableEndpoints.contains(where: { $0.id == selected.id }) {
            selectedEndpoint = nil
        }
    }

    func refreshAvailableEndpointsFromStore() async {
        guard let endpointStore else { return }
        do {
            setAvailableEndpoints(try await endpointStore.fetchEndpoints())
        } catch {
            Log.persistence.error("Failed to fetch endpoints: \(error)")
        }
    }

    /// On first launch, runs the `onFirstLaunch` closure if set; otherwise falls
    /// back to auto-selecting the Foundation model and eagerly loading it.
    ///
    /// Apps can customise first-run behaviour by setting `onFirstLaunch` before
    /// calling this method.
    public func autoSelectFirstRunModel() {
        let key = "\(BaseChatConfiguration.shared.bundleIdentifier).hasCompletedFirstLaunch"
        guard !userDefaults.bool(forKey: key) else { return }
        userDefaults.set(true, forKey: key)
        isFirstRun = false

        if let customHandler = onFirstLaunch {
            customHandler()
            return
        }

        // Default behaviour: auto-select Foundation model if available.
        guard let foundation = availableModels.first(where: { $0.modelType == .foundation }) else {
            return
        }

        selectedModel = foundation
        Log.ui.info("Auto-selected Foundation model for first launch")
        // Note: do NOT call loadSelectedModel() here — the selection-change
        // handlers in the view coordinate the load. Calling it here causes a double-load
        // race where the second load unloads the first mid-flight.
    }

    // MARK: - Lifecycle

    /// Saves all pending changes. Called on app background.
    public func saveState() async {
        do {
            try await saveSettingsToSession()
            Log.persistence.info("State saved on background")
        } catch {
            Log.persistence.error("Failed to save state on background: \(error)")
            errorMessage = "Failed to save state: \(error.localizedDescription)"
        }
    }
}
