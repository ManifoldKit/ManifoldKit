import SwiftUI

/// Shared helper for control-visibility tests. Hosts a SwiftUI view in a
/// platform-appropriate hosting controller, triggers layout, then returns
/// the full `Swift.dump()` output for assertion-based inspection.
enum ViewHierarchyDumper {
    @MainActor
    static func dump<V: View>(_ view: V, width: CGFloat = 800, height: CGFloat = 600) -> String {
        #if canImport(AppKit)
        let vc = NSHostingController(rootView: view)
        vc.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        vc.view.layoutSubtreeIfNeeded()
        #elseif canImport(UIKit)
        let vc = UIHostingController(rootView: view)
        vc.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        vc.view.layoutIfNeeded()
        #endif
        var output = ""
        Swift.dump(vc, to: &output)
        return output
    }
}
