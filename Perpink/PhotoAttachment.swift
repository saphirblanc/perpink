import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Photos going out with a question, prepared for Hermes.
///
/// Hermes takes images inline, as base64 `data:` URLs inside the request, and
/// refuses a request over 10 MB. A photo straight off the camera is several
/// megabytes on its own, so each one is scaled down to what a vision model
/// actually looks at and re-encoded as JPEG, stepping the quality down until it
/// fits its share of the budget.
enum PhotoAttachment {
    /// At most this many photos per question.
    static let maxCount = 4

    /// Longest side, in pixels. Vision models downsample past roughly this anyway.
    private static let maxDimension = 1600

    /// Per photo, before base64 (which adds a third): four of them stay well
    /// under Hermes's 10 MB request limit.
    private static let maxBytes = 1_500_000

    /// A JPEG ready to send, or nil if the data isn't an image.
    nonisolated static func prepare(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let scaled = downscaled(source)
        else { return nil }
        for quality in [0.75, 0.6, 0.45, 0.3] {
            if let jpeg = jpeg(scaled, quality: quality), jpeg.count <= maxBytes {
                return jpeg
            }
        }
        return jpeg(scaled, quality: 0.2)
    }

    /// Decodes straight to the target size, never the full-resolution bitmap,
    /// and bakes in the EXIF orientation so the photo arrives the right way up.
    private nonisolated static func downscaled(_ source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

#if os(iOS)
extension PhotoAttachment {
    /// A camera capture: its orientation lives on the `UIImage`, not in any
    /// file, so it is drawn upright, already at size, before ImageIO encodes it.
    nonisolated static func prepare(_ image: UIImage) -> Data? {
        let size = image.size
        let scale = min(1, CGFloat(maxDimension) / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return upright.jpegData(compressionQuality: 0.95).flatMap(prepare)
    }
}

/// The system camera, for taking a photo to send.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif
