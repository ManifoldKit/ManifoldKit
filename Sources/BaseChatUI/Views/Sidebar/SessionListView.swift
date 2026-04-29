import SwiftUI
import BaseChatCore
import BaseChatInference

/// Displays the list of chat sessions in the sidebar.
///
/// Supports selection, swipe-to-delete, swipe-to-rename, paginated loading,
/// and search across either session titles or persisted message bodies.
public struct SessionListView: View {

    @Environment(SessionManagerViewModel.self) private var sessionManager

    @State private var sessionToDelete: ChatSessionRecord?
    @State private var sessionToRename: ChatSessionRecord?
    @State private var renameText: String = ""
    @State private var errorMessage: String?

    @State private var searchText: String = ""
    @State private var searchScope: SessionSearchScope = .titles
    @State private var debounceTask: Task<Void, Never>?

    public init() {}

    public var body: some View {
        @Bindable var sessionManager = sessionManager

        Group {
            if sessionManager.sessions.isEmpty && searchText.isEmpty {
                ContentUnavailableView {
                    Label("No Chats", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Tap the + button to start a new chat.")
                }
            } else if sessionManager.hasNoSearchResults {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(selection: $sessionManager.activeSession) {
                    ForEach(sessionManager.displayedSessions) { session in
                        rowContent(for: session)
                            .tag(session)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    sessionToDelete = session
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    renameText = session.title
                                    sessionToRename = session
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    renameText = session.title
                                    sessionToRename = session
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }

                                Button(role: .destructive) {
                                    sessionToDelete = session
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .onAppear {
                                // Trigger pagination only for the unfiltered list — search
                                // results already pull from a wider window in the VM.
                                if searchText.isEmpty,
                                   session.id == sessionManager.sessions.last?.id {
                                    Task { await sessionManager.loadNextPage() }
                                }
                            }
                    }
                }
                .accessibilityIdentifier("session-list")
            }
        }
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
            sessionManager.searchScope = newScope
            runSearch(query: searchText, scope: newScope)
        }
        .alert("Rename Chat", isPresented: .init(
            get: { sessionToRename != nil },
            set: { if !$0 { sessionToRename = nil } }
        )) {
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
        .alert("Delete Chat?", isPresented: .init(
            get: { sessionToDelete != nil },
            set: { if !$0 { sessionToDelete = nil } }
        ), presenting: sessionToDelete) { session in
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
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
    }

    @ViewBuilder
    private func rowContent(for session: ChatSessionRecord) -> some View {
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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Mirror the live state into the VM so observers (and tests) see the
        // current query immediately, even before the debounce fires.
        sessionManager.searchQuery = query
        if trimmed.isEmpty {
            sessionManager.clearSearch()
            return
        }
        debounceTask = Task { @MainActor [sessionManager] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            runSearch(query: query, scope: scope, on: sessionManager)
        }
    }

    private func runSearch(query: String, scope: SessionSearchScope) {
        runSearch(query: query, scope: scope, on: sessionManager)
    }

    private func runSearch(query: String, scope: SessionSearchScope, on vm: SessionManagerViewModel) {
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
            Task { await vm.runMessageSearch(query) }
        }
    }
}

#Preview("Empty State") {
    SessionListView()
        .environment(SessionManagerViewModel())
}
