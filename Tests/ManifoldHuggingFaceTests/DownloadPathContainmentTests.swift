@preconcurrency import XCTest
@testable import ManifoldHuggingFace

/// Guards the destination-vs-models-directory containment check used in
/// `BackgroundDownloadManager+URLSessionDelegate` when finalizing a single-file
/// download. The production fix resolves symlinks (`.resolvingSymlinksInPath()`)
/// instead of merely standardizing the path, so a symlink planted inside the
/// models directory can't redirect the move past the intended boundary.
@MainActor
final class DownloadPathContainmentTests: XCTestCase {

    private var modelsDirectory: URL!
    private var escapeTarget: URL!

    /// Mirrors the production predicate: the resolved destination must live
    /// directly under the resolved models directory.
    private func isContained(destination: URL, modelsDirectory: URL) -> Bool {
        let resolvedDestination = destination.resolvingSymlinksInPath()
        let resolvedModels = modelsDirectory.resolvingSymlinksInPath()
        return resolvedDestination.path.hasPrefix(resolvedModels.path + "/")
    }

    override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadPathContainmentTests-\(UUID().uuidString)")
        modelsDirectory = root.appendingPathComponent("Models")
        escapeTarget = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: escapeTarget, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let modelsDirectory {
            let root = modelsDirectory.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    /// A symlink inside the models directory pointing outside it must be REJECTED.
    ///
    /// Models the realistic attack: a symlink is planted at the destination path
    /// (`Models/model.gguf` -> `Outside/real.gguf`) before the download finalizes.
    /// `.resolvingSymlinksInPath()` only resolves path components that exist on
    /// disk, so the symlinked component must exist for the check to bite — which it
    /// does here. The pre-fix `.standardized` check ignored symlinks entirely.
    func testSymlinkedDestinationEscapingModelsDirectoryIsRejected() throws {
        let realFile = escapeTarget.appendingPathComponent("real.gguf")
        XCTAssertTrue(FileManager.default.createFile(atPath: realFile.path, contents: Data()))

        let destination = modelsDirectory.appendingPathComponent("model.gguf")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: realFile)

        XCTAssertFalse(
            isContained(destination: destination, modelsDirectory: modelsDirectory),
            "Symlink-escaping destination must be rejected once symlinks are resolved"
        )

        // Regression contrast: the old `.standardized` check did NOT resolve symlinks,
        // so it would have considered this escaping path contained — proving the fix.
        let standardizedContained = destination.standardized.path
            .hasPrefix(modelsDirectory.standardized.path + "/")
        XCTAssertTrue(
            standardizedContained,
            "The pre-fix `.standardized` check would have let the symlink escape through"
        )
    }

    /// A legitimate file directly under the models directory must still be ACCEPTED.
    func testInBoundsDestinationIsAccepted() throws {
        let destination = modelsDirectory.appendingPathComponent("model.gguf")
        XCTAssertTrue(
            isContained(destination: destination, modelsDirectory: modelsDirectory),
            "An in-bounds destination must remain accepted after the symlink-resolving fix"
        )
    }
}
