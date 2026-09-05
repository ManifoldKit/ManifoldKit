import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// Displays the list of chat sessions in the sidebar.
///
/// Supports selection, swipe-to-delete, swipe-to-rename, paginated loading,
/// and search across either session titles or persisted message bodies.
public struct SessionListView: View {

    @Environment(SessionManagerViewModel.self) private var sessionManager
    @Environment(\.manifoldTheme) private var theme

    @State private var sessionToDelete: ChatSession?
    @State private var sessionToRename: ChatSession?
    @State private var renameText: String = ""
    @State private var sessionToExport: ChatSession?
    @State private var errorMessage: String?

    @State private var searchText: String = ""
    @State private var searchScope: SessionSearchScope = .titles
    @State private var debounceTask: Task<Void, Never>?

    // Mirrors the accessor pattern used elsewhere in ManifoldUI (e.g. ChatView,
    // ChatInputBar) — reads the live global configuration rather than
    // threading a `features` init parameter through every view.
    private var features: ManifoldConfiguration.Features { ManifoldConfiguration.shared.features }

    public init() {}

    public var body: some View {
        mainContent
        .animation(.default, value: sessionManager.sessions.isEmpty)
        .task {
            // Hosts that configure with `autoLoad: false` (notably tests, but
            // any caller that wants control of bootstrap timing) rely on this
            // first-appear load. The `isEmpty` guard makes it a no-op when
            // `configure(runtime:)` (or `autoLoad: true`) already populated
            // the list — `.task` fires once per identity and is cancelled on
            // teardown, which is the behaviour we want for either path.
            if sessionManager.sessions.isEmpty {
                await sessionManager.loadSessions()
            }
            guard !Task.isCancelled else { return }
            resumeRetainedSearchIfNeeded()
        }
        .searchable(text: $searchText, prompt: "Search chats")
        .searchScopes($searchScope) {
            Text("Titles").tag(SessionSearchScope.titles)
            Text("Messages").tag(SessionSearchScope.messages)
        }
        .onChange(of: searchText) { _, newValue in
            scheduleSearch(query: newValue, scope: searchScope)
        }
        .onChange(of: searchScope) { _, newScope in
            // Re-run immediately on scope change so the user sees a result swap
            // without the 200ms typing debounce — they didn't type anything.
            debounceTask?.cancel()
            sessionManager.invalidateMessageSearch()
            sessionManager.searchScope = newScope
            let query = searchText
            debounceTask = Task { @MainActor [sessionManager] in
                await Self.runSearch(query: query, scope: newScope, on: sessionManager)
            }
        }
        .onDisappear {
            debounceTask?.cancel()
            sessionManager.invalidateMessageSearch()
        }
        .alert("Rename Chat", isPresented: isRenamePresented) {
            TextField("Chat title", text: $renameText)
            Button("Cancel", role: .cancel) { sessionToRename = nil }
            Button("Rename") {
                if let session = sessionToRename {
                    let newTitle = renameText
                    Task {
                        do {
                            try await sessionManager.renameSession(session, title: newTitle)
                        } catch {
                            errorMessage = "Failed to rename session: \(error.localizedDescription)"
                        }
                    }
                }
                sessionToRename = nil
            }
        }
        .alert("Delete Chat?", isPresented: isDeletePresented, presenting: sessionToDelete) { session in
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await sessionManager.deleteSession(session)
                    } catch {
                        errorMessage = "Failed to delete session: \(error.localizedDescription)"
                    }
                }
                sessionToDelete = nil
            }
            Button("Cancel", role: .cancel) { sessionToDelete = nil }
        } message: { session in
            Text("This will permanently delete \"\(session.title)\" and all its messages.")
        }
        .alert("Error", isPresented: isErrorPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
        .sheet(item: $sessionToExport) { session in
            SessionExportSheet(session: session)
        }
    }

    // MARK: - Subtrees
    //
    // Each subtree is a separate declaration so the type checker solves it
    // independently — the monolithic `body` expression previously took >200ms
    // to type-check (see -warn-long-function-bodies).

    @ViewBuilder
    private var mainContent: some View {
        if sessionManager.sessions.isEmpty && searchText.isEmpty {
            ContentUnavailableView {
                Label("No Chats", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Tap the + button to start a new chat.")
            }
        } else if sessionManager.hasNoSearchResults {
            ContentUnavailableView.search(text: searchText)
        } else {
            sessionList
        }
    }

    private var sessionList: some View {
        @Bindable var sessionManager = sessionManager
        return List(selection: $sessionManager.activeSession) {
            let pinned = sessionManager.pinnedSessions
            let unpinned = unpinnedSessions(excluding: pinned)

            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { session in
                        pinnedRow(for: session)
                    }
                }
            }

            Section(pinned.isEmpty ? "" : "Chats") {
                ForEach(unpinned) { session in
                    unpinnedRow(for: session)
                }
            }
        }
        .accessibilityIdentifier("session-list")
    }

    private func unpinnedSessions(excluding pinned: [ChatSession]) -> [ChatSession] {
        let trimmed = sessionManager.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return sessionManager.displayedSessions }
        let pinnedIDs = Set(pinned.map(\.id))
        return sessionManager.sessions.filter { !pinnedIDs.contains($0.id) }
    }

    private func pinnedRow(for session: ChatSession) -> some View {
        rowContent(for: session)
            .tag(session)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                deleteButton(for: session)
            }
            .swipeActions(edge: .leading) {
                unpinButton(for: session)
                    .tint(.orange)
                renameButton(for: session)
                    .tint(theme.accent)
            }
            .contextMenu {
                unpinButton(for: session)
                renameButton(for: session)
                exportButton(for: session)
                deleteButton(for: session)
            }
    }

    private func unpinnedRow(for session: ChatSession) -> some View {
        rowContent(for: session)
            .tag(session)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                deleteButton(for: session)
            }
            .swipeActions(edge: .leading) {
                pinButton(for: session)
                    .tint(theme.statusWarn)
                renameButton(for: session)
                    .tint(theme.accent)
            }
            .contextMenu {
                pinButton(for: session)
                renameButton(for: session)
                exportButton(for: session)
                deleteButton(for: session)
            }
            .onAppear {
                // Trigger pagination only for the unfiltered list — search
                // results already pull from a wider window in the VM.
                if sessionManager.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   session.id == sessionManager.sessions.last?.id {
                    Task { await sessionManager.loadNextPage() }
                }
            }
    }

    // MARK: - Row actions

    private func deleteButton(for session: ChatSession) -> some View {
        Button(role: .destructive) {
            sessionToDelete = session
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func renameButton(for session: ChatSession) -> some View {
        Button {
            renameText = session.title
            sessionToRename = session
        } label: {
            Label("Rename", systemImage: "pencil")
        }
    }

    private func pinButton(for session: ChatSession) -> some View {
        Button {
            Task {
                do {
                    try await sessionManager.pinSession(session)
                } catch {
                    errorMessage = "Failed to pin session: \(error.localizedDescription)"
                }
            }
        } label: {
            Label("Pin", systemImage: "pin")
        }
    }

    // `internal` (not `private`) so `@testable import ManifoldUI` can dump
    // this view in isolation — `.contextMenu` content closures are evaluated
    // lazily by SwiftUI (on long-press/right-click), so they never appear in
    // ViewHierarchyDumper's static NSHostingController snapshot of the full
    // row; testing the gate requires calling this builder directly.
    @ViewBuilder
    func exportButton(for session: ChatSession) -> some View {
        // Honors `showChatExport` the same way the chat toolbar's export
        // button does (ChatShellViews.swift) — hosts that lock export down
        // for this flag must not have it leak back in via the sidebar.
        if features.showChatExport {
            Button {
                sessionToExport = session
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func unpinButton(for session: ChatSession) -> some View {
        Button {
            Task {
                do {
                    try await sessionManager.unpinSession(session)
                } catch {
                    errorMessage = "Failed to unpin session: \(error.localizedDescription)"
                }
            }
        } label: {
            Label("Unpin", systemImage: "pin.slash")
        }
    }

    // MARK: - Alert bindings

    private var isRenamePresented: Binding<Bool> {
        Binding(
            get: { sessionToRename != nil },
            set: { if !$0 { sessionToRename = nil } }
        )
    }

    private var isDeletePresented: Binding<Bool> {
        Binding(
            get: { sessionToDelete != nil },
            set: { if !$0 { sessionToDelete = nil } }
        )
    }

    private var isErrorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    @ViewBuilder
    private func rowContent(for session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SessionRowView(session: session)

            if searchScope == .messages,
               !searchText.isEmpty,
               let hits = sessionManager.messageHitsBySession[session.id],
               let firstHit = hits.first {
                Text(highlightedSnippet(for: firstHit, query: searchText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("session-search-snippet")
            }
        }
    }

    /// Builds an `AttributedString` with the query term emphasised.
    private func highlightedSnippet(for hit: MessageSearchHit, query: String) -> AttributedString {
        var attributed = AttributedString(hit.snippet)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let range = attributed.range(of: trimmed, options: .caseInsensitive) else {
            return attributed
        }
        attributed[range].font = .caption.bold()
        attributed[range].foregroundColor = .primary
        return attributed
    }

    private func scheduleSearch(query: String, scope: SessionSearchScope) {
        debounceTask?.cancel()
        sessionManager.invalidateMessageSearch()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Mirror the live state into the VM so observers (and tests) see the
        // current query immediately, even before the debounce fires.
        sessionManager.searchQuery = query
        if trimmed.isEmpty {
            sessionManager.clearSearch()
            return
        }
        debounceTask = Task { @MainActor [sessionManager] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch is CancellationError {
                return
            } catch {
                Log.persistence.error("SessionListView: search debounce failed: \(error)")
                return
            }
            if Task.isCancelled { return }
            await Self.runSearch(query: query, scope: scope, on: sessionManager)
        }
    }

    /// Restarts a retained query after the view returns to the hierarchy. The
    /// work remains tracked so disappearance can cancel the provider scan.
    private func resumeRetainedSearchIfNeeded() {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        debounceTask?.cancel()
        sessionManager.invalidateMessageSearch()
        let query = searchText
        let scope = searchScope
        debounceTask = Task { @MainActor [sessionManager] in
            await Self.runSearch(query: query, scope: scope, on: sessionManager)
        }
    }

    static func runSearch(query: String, scope: SessionSearchScope, on vm: SessionManagerViewModel) async {
        guard !Task.isCancelled else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        vm.searchQuery = query
        vm.searchScope = scope
        if trimmed.isEmpty {
            vm.clearSearch()
            return
        }
        switch scope {
        case .titles:
            vm.runTitleSearch(query)
        case .messages:
            await vm.runMessageSearch(query)
        }
    }
}

#Preview("Empty State") {
    SessionListView()
        .environment(SessionManagerViewModel())
}
