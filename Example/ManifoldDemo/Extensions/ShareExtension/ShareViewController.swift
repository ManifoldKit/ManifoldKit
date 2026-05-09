import UIKit
import UniformTypeIdentifiers

// App Group constants come from `DemoSharedAppGroup` in
// `PendingSharePayload.swift`, which is compiled into both the host app
// and this extension — single source of truth, no string drift.

/// Share Extension principal class.
///
/// Reads the first recognisable item from the extension context
/// (URL > plain text > image), serialises it as a ``PendingSharePayload``
/// into the shared App Group container, and completes the request.
///
/// The host app drains the payload on the next foreground activation —
/// see ``ManifoldDemoApp/checkForPendingSharePayload()``. No inference
/// runs inside the extension; it is a write-only relay.
///
/// ## Memory budget
///
/// This class imports nothing from ManifoldKit. The only non-system
/// dependency is ``PendingSharePayload``, a plain Codable struct.
/// Image payloads are PNG-encoded and stored as `Data` in App Group
/// `UserDefaults`; callers that share large images should be aware of
/// the 4 MB `UserDefaults` write limit. For images larger than that,
/// write the data to a file in the App Group container and store only
/// the path.
class ShareViewController: UIViewController {

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { @MainActor in
            await handleItems()
        }
    }

    private func handleItems() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let payload = await extractPayload(from: items)

        if let payload,
           let defaults = UserDefaults(suiteName: DemoSharedAppGroup.identifier),
           let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: DemoSharedAppGroup.pendingShareKey)
            // Force a flush before the extension is suspended. The host app
            // can wake within milliseconds of `completeRequest`, so we want
            // the write committed before we hand control back.
            defaults.synchronize()
        }

        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Item extraction

    // Tries providers in priority order: URL → plain text → image.
    private func extractPayload(from items: [NSExtensionItem]) async -> PendingSharePayload? {
        for item in items {
            for provider in (item.attachments ?? []) {
                if let payload = await loadURL(from: provider) { return payload }
                if let payload = await loadText(from: provider) { return payload }
                if let payload = await loadImage(from: provider) { return payload }
            }
        }
        return nil
    }

    private func loadURL(from provider: NSItemProvider) async -> PendingSharePayload? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return nil }
        guard let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL else {
            return nil
        }
        return PendingSharePayload(kind: .url, urlString: url.absoluteString, source: "shareExtension")
    }

    private func loadText(from provider: NSItemProvider) async -> PendingSharePayload? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else { return nil }
        guard let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
              !text.isEmpty else { return nil }
        return PendingSharePayload(kind: .text, text: text, source: "shareExtension")
    }

    private func loadImage(from provider: NSItemProvider) async -> PendingSharePayload? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
        guard let image = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier) as? UIImage,
              let data = image.pngData() else { return nil }
        return PendingSharePayload(kind: .image, imageData: data, imageMimeType: "image/png", source: "shareExtension")
    }
}
