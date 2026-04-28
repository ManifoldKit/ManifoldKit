import SwiftUI
import BaseChatUI
import BaseChatUIModelManagement

struct MinimalContentView: View {
    @Environment(ChatViewModel.self) private var viewModel
    @Environment(SessionManagerViewModel.self) private var sessionManager

    @State private var isModelManagementPresented = false

    var body: some View {
        NavigationStack {
            ChatView(
                showModelManagement: $isModelManagementPresented,
                apiConfiguration: { APIConfigurationView() }
            )
                .sheet(isPresented: $isModelManagementPresented) {
                    ModelManagementSheet()
                        .environment(viewModel)
                }
        }
        .onAppear {
            viewModel.refreshModels()

            if sessionManager.sessions.isEmpty {
                _ = try? sessionManager.createSession()
            }
        }
    }
}
