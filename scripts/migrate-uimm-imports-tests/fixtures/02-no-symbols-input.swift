import SwiftUI
import ManifoldUI

struct ChatScreen: View {
    var body: some View { ChatView(showModelManagement: .constant(false)) { EmptyView() } }
}
