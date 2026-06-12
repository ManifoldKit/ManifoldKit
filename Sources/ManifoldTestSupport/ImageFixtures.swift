import Foundation

/// Shared tiny image fixtures for multimodal and attachment tests.
public enum ImageFixtures {
    /// A valid 1×1 transparent PNG.
    public static let oneByOnePNGData = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7Z0ioAAAAASUVORK5CYII="
    )!

    /// Builds a synthetic JPEG-shaped blob of approximately `approxBytes` bytes.
    ///
    /// Bytes are not a valid decodable JPEG — for size-based tests only. The
    /// blob has a JPEG SOI marker (`0xFFD8`) at the start and an EOI marker
    /// (`0xFFD9`) at the end so anything that sniffs only the leading magic
    /// bytes treats it as a JPEG. The middle is filler bytes (`0xFF`).
    ///
    /// Used by perf-audit tests that need realistic-size attachments without
    /// the cost of actually encoding image data. `approxBytes < 4` is clamped
    /// to a minimal SOI+EOI pair.
    public static func largeJPEG(approxBytes: Int) -> Data {
        let minimum = 4 // SOI (2) + EOI (2)
        let total = max(approxBytes, minimum)
        var data = Data(count: total)
        // SOI
        data[0] = 0xFF
        data[1] = 0xD8
        // Filler — already 0x00 by default; overwrite with 0xFF to look more
        // like real JPEG entropy-coded payload, which tends to be high-bit.
        if total > 4 {
            for index in 2..<(total - 2) {
                data[index] = 0xFF
            }
        }
        // EOI
        data[total - 2] = 0xFF
        data[total - 1] = 0xD9
        return data
    }
}
