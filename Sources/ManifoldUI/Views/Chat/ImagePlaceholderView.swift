import SwiftUI
import ManifoldInference

struct ImageAttachmentView: View {
    let data: Data
    let placeholderHash: ImagePlaceholderHash?

    @State private var decodedImage: PlatformImage?
    @State private var decodeAttempted = false

    var body: some View {
        ZStack {
            ImagePlaceholderView(placeholderHash: placeholderHash)
                .opacity(decodedImage == nil ? 1 : 0)

            if let decodedImage {
                platformImage(decodedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .opacity(1)
                    .transition(.opacity)
            } else if decodeAttempted {
                missingImagePlaceholder
            }
        }
        .task(id: data) {
            decodedImage = nil
            decodeAttempted = false
            await Task.yield()
            let image = Self.decodeImage(from: data)
            withAnimation(.easeInOut(duration: 0.18)) {
                decodedImage = image
                decodeAttempted = true
            }
        }
    }

    private var missingImagePlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.15))
            .overlay {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
    }

    #if os(iOS)
    typealias PlatformImage = UIImage

    private static func decodeImage(from data: Data) -> UIImage? {
        UIImage(data: data)
    }

    private func platformImage(_ image: UIImage) -> Image {
        Image(uiImage: image)
    }
    #elseif os(macOS)
    typealias PlatformImage = NSImage

    private static func decodeImage(from data: Data) -> NSImage? {
        NSImage(data: data)
    }

    private func platformImage(_ image: NSImage) -> Image {
        Image(nsImage: image)
    }
    #endif
}

struct ImagePlaceholderView: View {
    let placeholderHash: ImagePlaceholderHash?

    var body: some View {
        if let grid = placeholderHash?.colorGrid {
            GeometryReader { proxy in
                colorGrid(grid)
                    .blur(radius: max(8, min(proxy.size.width, proxy.size.height) * 0.08))
                    .scaleEffect(1.08)
                    .clipped()
            }
            .aspectRatio(grid.aspectRatio, contentMode: .fit)
            .frame(maxWidth: 320, maxHeight: 200)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.15))
                .frame(maxWidth: 320)
                .frame(height: 160)
                .accessibilityHidden(true)
        }
    }

    private func colorGrid(_ grid: ImagePlaceholderHash.ColorGrid) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<grid.height, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<grid.width, id: \.self) { column in
                        Rectangle()
                            .fill(color(for: grid.colors[row * grid.width + column]))
                    }
                }
            }
        }
    }

    private func color(for rgb: ImagePlaceholderHash.RGBColor) -> Color {
        Color(
            red: Double(rgb.red) / 255.0,
            green: Double(rgb.green) / 255.0,
            blue: Double(rgb.blue) / 255.0
        )
    }
}
