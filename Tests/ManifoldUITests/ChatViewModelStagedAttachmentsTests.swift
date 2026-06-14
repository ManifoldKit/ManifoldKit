@preconcurrency import XCTest
import Foundation
@testable import ManifoldUI
@testable import ManifoldInference
import ManifoldTestSupport
// BackendInternals SPI: seam published for the companion split (#1749).
@_spi(BackendInternals) import ManifoldHardware
@_spi(BackendInternals) import ManifoldUI

/// Coverage for the public staged-attachment API on `ChatViewModel` introduced
/// in issue #1302. Verifies that consumers building custom composers reach the
/// same internal path the bundled `ChatInputBar` uses.
@MainActor
final class ChatViewModelStagedAttachmentsTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    private func makeViewModel() -> ChatViewModel {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "StagedAttachmentsMock")
        return ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
    }

    private func textPart(_ text: String) -> MessagePart { .text(text) }
    private func imagePart(_ byte: UInt8) -> MessagePart {
        // Distinct payloads keep `Hashable` ordering stable across the test.
        .image(data: Data([byte, byte, byte, byte]), mimeType: "image/png")
    }

    // MARK: - Append / read

    func test_stageAttachment_appendsToStagedList() {
        let vm = makeViewModel()
        XCTAssertTrue(vm.stagedAttachments.isEmpty)

        vm.stageAttachment(textPart("hello"))

        XCTAssertEqual(vm.stagedAttachments.count, 1)
    }

    func test_stagedAttachments_reflectsAppendsInOrder() {
        let vm = makeViewModel()

        let a = textPart("a")
        let b = textPart("b")
        let c = textPart("c")
        vm.stageAttachment(a)
        vm.stageAttachment(b)
        vm.stageAttachment(c)

        XCTAssertEqual(vm.stagedAttachments, [a, b, c])
    }

    // MARK: - Remove

    func test_removeStagedAttachment_atValidIndex_removes() {
        let vm = makeViewModel()
        let a = textPart("a")
        let b = textPart("b")
        let c = textPart("c")
        vm.stageAttachment(a)
        vm.stageAttachment(b)
        vm.stageAttachment(c)

        vm.removeStagedAttachment(at: 1)

        XCTAssertEqual(vm.stagedAttachments, [a, c])
    }

    func test_removeStagedAttachment_outOfRange_isNoOp() {
        let vm = makeViewModel()
        vm.stageAttachment(textPart("only"))
        let before = vm.stagedAttachments

        // Both upper-bound and far-out indices should be silent no-ops.
        vm.removeStagedAttachment(at: 5)
        vm.removeStagedAttachment(at: 1)
        vm.removeStagedAttachment(at: Int.max)

        XCTAssertEqual(vm.stagedAttachments, before)
    }

    // MARK: - Clear

    func test_clearStagedAttachments_empties() {
        let vm = makeViewModel()
        vm.stageAttachment(textPart("a"))
        vm.stageAttachment(textPart("b"))
        XCTAssertFalse(vm.stagedAttachments.isEmpty)

        vm.clearStagedAttachments()

        XCTAssertTrue(vm.stagedAttachments.isEmpty)
    }

    // MARK: - Parity with the internal ChatInputBar path

    /// `ChatInputBar` stages images by calling `stageDraftAttachment(_:)`,
    /// which routes the part through `generatingImagePlaceholderIfNeeded()`
    /// to assign a stable placeholder hash. The public API must produce the
    /// same enriched part, not the caller's raw input — otherwise hosts
    /// building a custom composer would lose the placeholder rendering the
    /// bundled UI relies on.
    func test_stageAttachment_publicPath_matchesInternalChatInputBarBehavior() {
        // A minimal valid 1x1 PNG so `ImagePlaceholderHash.generate` returns a
        // hash. Without a decodable image, the placeholder helper short-circuits
        // to nil on both paths and the parity check would be trivially true.
        let onePixelPNG = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ])
        let rawImage = MessagePart.image(
            data: onePixelPNG,
            mimeType: "image/png",
            placeholderHash: nil
        )

        let viaPublic = makeViewModel()
        viaPublic.stageAttachment(rawImage)
        let viaInternal = makeViewModel()
        viaInternal.stageDraftAttachment(rawImage)

        // Whatever side effect the bundled ChatInputBar path produces (today:
        // placeholder-hash generation via generatingImagePlaceholderIfNeeded),
        // the public surface must produce the *same* staged part.
        XCTAssertEqual(
            viaPublic.stagedAttachments,
            viaInternal.stagedAttachments,
            "Public stageAttachment must route through the same internal path as ChatInputBar (stageDraftAttachment) so future side effects added there fire for host composers too"
        )

        // And the shared path must actually be doing the placeholder work,
        // not handing the raw input through unchanged.
        XCTAssertNotEqual(
            viaPublic.stagedAttachments.first,
            rawImage,
            "Staged image must be enriched (placeholder hash) — if equal to raw input, both paths are bypassing generatingImagePlaceholderIfNeeded"
        )
    }

    // MARK: - attachImage convenience (#1298)

    func test_attachImage_stagesImagePart() {
        let vm = makeViewModel()
        XCTAssertTrue(vm.stagedAttachments.isEmpty)

        vm.attachImage(Data([1, 2, 3, 4]), mimeType: "image/png")

        XCTAssertEqual(vm.stagedAttachments.count, 1)
        guard case .image(_, let mime, _)? = vm.stagedAttachments.first else {
            return XCTFail("attachImage must stage a MessagePart.image")
        }
        XCTAssertEqual(mime, "image/png")
    }

    /// `attachImage(_:mimeType:)` must route through the SAME internal path the
    /// bundled composer uses (`stageDraftAttachment`), so placeholder-hash
    /// generation and any future side effects fire identically. We compare a
    /// decodable PNG through both surfaces.
    func test_attachImage_matchesInternalChatInputBarBehavior() {
        let onePixelPNG = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ])

        let viaConvenience = makeViewModel()
        viaConvenience.attachImage(onePixelPNG, mimeType: "image/png")

        let viaInternal = makeViewModel()
        viaInternal.stageDraftAttachment(.image(data: onePixelPNG, mimeType: "image/png"))

        XCTAssertEqual(
            viaConvenience.stagedAttachments,
            viaInternal.stagedAttachments,
            "attachImage must route through stageDraftAttachment so it stays in parity with the bundled composer"
        )

        // And it must actually enrich the part (placeholder hash), not stage the
        // raw bytes unchanged.
        XCTAssertNotEqual(
            viaConvenience.stagedAttachments.first,
            .image(data: onePixelPNG, mimeType: "image/png", placeholderHash: nil),
            "attachImage must enrich the staged image; equality with the raw part means the internal path was bypassed"
        )
    }
}
