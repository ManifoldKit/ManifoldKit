import SwiftUI
#if Ollama
import ManifoldUI
import ManifoldUIModelManagement
#endif

struct OllamaGated: View {
    var body: some View {
        #if Ollama
        APIEndpointEditorView()
        #else
        EmptyView()
        #endif
    }
}
