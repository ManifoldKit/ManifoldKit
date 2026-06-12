import Foundation
import ManifoldInference

// MARK: - Downloaded-file Data Protection

/// Applies the iOS Data Protection class to model files once they land in their
/// final location under Application Support / Models.
///
/// Mirrors `ModelContainerFactory.applyProtection()` in
/// `ManifoldPersistenceSwiftData`: best-effort hardening that keeps downloaded
/// model weights unreadable until the user first unlocks the device after
/// reboot, while still allowing background tasks to read them. A missing
/// protection attribute must never fail or roll back a completed download, so
/// failures are logged and swallowed — never thrown. No-op on macOS / Mac
/// Catalyst, where at-rest protection is handled by FileVault.
enum DownloadedFileProtection {

    /// The Data Protection class applied to downloaded model files.
    ///
    /// `.completeUntilFirstUserAuthentication` matches the SwiftData store
    /// protection in `ModelContainerFactory`: readable while the device is
    /// unlocked at least once after boot, so background downloads and load
    /// paths keep working without prompting for the passcode.
    static func protect(_ url: URL) {
        #if (os(iOS) || os(tvOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        } catch {
            Log.download.warning(
                "Failed to apply file protection to downloaded model at \(url.path, privacy: .private): \(error.localizedDescription)"
            )
        }
        #endif
    }
}
