import Foundation

#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#elseif os(macOS)
import AppKit
#endif

enum ClipboardWriter {
    #if os(iOS)
    static let expirationInterval: TimeInterval = 120
    #endif

    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]], options: pasteboardOptions())
        #elseif os(macOS)
        // AppKit pasteboard APIs do not expose local-only or expiration controls.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    #if os(iOS)
    static func pasteboardOptions(now: Date = Date()) -> [UIPasteboard.OptionsKey: Any] {
        [
            .localOnly: true,
            .expirationDate: now.addingTimeInterval(expirationInterval),
        ]
    }
    #endif
}
