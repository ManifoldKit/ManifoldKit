import CoreGraphics
import Foundation
import ImageIO

/// Compact color-field placeholder for image attachments.
///
/// The value is intentionally small and dependency-free: a tiny RGB grid plus
/// the source image aspect ratio. It gives SwiftUI enough information to draw a
/// blurred color field while the full attachment bytes decode.
public struct ImagePlaceholderHash: Codable, Hashable, Sendable {
    public static let algorithm = "bck-color-grid-v1"

    public let value: String

    public init(value: String) {
        self.value = value
    }

    public static func generate(from imageData: Data, gridWidth: Int = 4, gridHeight: Int = 3) -> ImagePlaceholderHash? {
        guard gridWidth > 0, gridHeight > 0 else { return nil }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = gridWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: gridHeight * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: gridWidth,
            height: gridHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight))

        var rgb = Data(capacity: gridWidth * gridHeight * 3)
        for row in 0..<gridHeight {
            for column in 0..<gridWidth {
                let offset = row * bytesPerRow + column * bytesPerPixel
                let alpha = pixels[offset + 3]
                if alpha == 0 {
                    rgb.append(contentsOf: [255, 255, 255])
                } else if alpha == 255 {
                    rgb.append(contentsOf: [pixels[offset], pixels[offset + 1], pixels[offset + 2]])
                } else {
                    let inverse = UInt16(255 - alpha)
                    let red = UInt8(min(255, UInt16(pixels[offset]) + inverse))
                    let green = UInt8(min(255, UInt16(pixels[offset + 1]) + inverse))
                    let blue = UInt8(min(255, UInt16(pixels[offset + 2]) + inverse))
                    rgb.append(contentsOf: [red, green, blue])
                }
            }
        }

        let encoded = rgb.base64URLEncodedString()
        return ImagePlaceholderHash(
            value: "bckg1:\(image.width)x\(image.height):\(gridWidth)x\(gridHeight):\(encoded)"
        )
    }

    public var colorGrid: ColorGrid? {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 4, pieces[0] == "bckg1" else { return nil }
        guard let imageSize = Self.parseSize(pieces[1]), let gridSize = Self.parseSize(pieces[2]) else { return nil }
        guard imageSize.width > 0, imageSize.height > 0, gridSize.width > 0, gridSize.height > 0 else { return nil }
        guard let data = Data(base64URLEncoded: String(pieces[3])) else { return nil }
        guard data.count == gridSize.width * gridSize.height * 3 else { return nil }

        var colors: [RGBColor] = []
        colors.reserveCapacity(gridSize.width * gridSize.height)
        var index = 0
        while index < data.count {
            colors.append(RGBColor(red: data[index], green: data[index + 1], blue: data[index + 2]))
            index += 3
        }
        return ColorGrid(
            imageWidth: imageSize.width,
            imageHeight: imageSize.height,
            width: gridSize.width,
            height: gridSize.height,
            colors: colors
        )
    }

    private static func parseSize(_ raw: Substring) -> (width: Int, height: Int)? {
        let parts = raw.split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
        return (width, height)
    }

    public struct ColorGrid: Hashable, Sendable {
        public let imageWidth: Int
        public let imageHeight: Int
        public let width: Int
        public let height: Int
        public let colors: [RGBColor]

        public var aspectRatio: Double {
            guard imageHeight > 0 else { return 1 }
            return Double(imageWidth) / Double(imageHeight)
        }
    }

    public struct RGBColor: Hashable, Sendable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: base64)
    }
}
