import SwiftUI
import BaseChatUI
import BaseChatUIModelManagement

struct MinimalContentView: View {
    @Environment(ChatViewModel.self) private var viewModel
    @Environment(ModelManagementViewModel.self) private var managementViewModel
    @State private var isModelManagementPresented = false

    var body: some View {
        NavigationStack {
            ChatView(
                showModelManagement: $isModelManagementPresented,
                apiConfiguration: { APIConfigurationView() }
            )
                .sheet(isPresented: $isModelManagementPresented) {
                    ModelManagementSheet(modelRegistry: viewModel.modelRegistry)
                        .environment(managementViewModel)
                }
        }
    }
}
