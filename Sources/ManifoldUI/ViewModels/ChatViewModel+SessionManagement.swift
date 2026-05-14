import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - ChatViewModel + Session Management

extension ChatViewModel {

    /// Switches to a different chat session, loading its messages and settings.
    public func switchToSession(_ session: ChatSessionRecord) async {
        // Drive the UI back to idle synchronously so the toolbar/stop button
        // observes the transition immediately. The runtime handle and queue
        // tear-down are awaited by `sessionManager.teardown` before any
        // backend mutation runs.
        if isGenerating {
            transitionPhase(to: .idle)
        }

        sessionManager.isRestoringSession = true
        defer { sessionManager.isRestoringSession = false }

        // Activate the session record in the controller (sets settings, prompt template,
        // pinned IDs) and capture what model/endpoint was persisted for this session.
        let selectionState = sessionController.activateSession(session)

        // Delegate the teardown sequence to ChatSessionManager:
        // - Discard inference requests for the prior session (load-bearing await:
        //   cancels the dying turn before any KV-cache mutation runs — see #965).
        // - Reset conversation history + KV cache on the active backend.
        // - Cancel the runtime stream handle (closes bookkeeping before the next
        //   send registers a new handle).
        // - Reset tool-approval gate (prevent prior-session approvals from leaking).
        // - Cancel lingering background tasks.
        // - Refresh the available endpoint list (required before resolution).
        // - Resolve the persisted model/endpoint IDs to live registry objects.
        let teardownResult = await sessionManager.teardown(
            sessionID: session.id,
            promptTemplate: sessionController.selectedPromptTemplate,
            selectionState: selectionState
        )

        // Apply the resolved model/endpoint selection (exactly one or neither).
        sessionManager.applySelection(teardownResult)

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
        let key = "\(ManifoldConfiguration.shared.bundleIdentifier).hasCompletedFirstLaunch"
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
