import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates small + large JPEG thumbnails from arbitrary image bytes using
/// Image I/O. Handles every format macOS knows how to decode — PNG, JPEG,
/// TIFF, HEIC/HEIF, GIF, BMP, WebP.
///
/// Matches the two-size shape Paste itself uses (we keep parity with
/// `previews.thumb_small` / `thumb_large`): 256 px for list previews,
/// 640 px for Retina rendering in the popup strip.
public enum Thumbnailer {
    public static let smallMaxPixel = 256
    public static let largeMaxPixel = 640

    /// Both thumbnail sizes in one pass. Returns `(nil, nil)` if the input
    /// isn't a decodable image, which lets callers treat failure as "skip
    /// preview generation" rather than an error to surface.
    public static func generate(from data: Data) -> (small: Data?, large: Data?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return (nil, nil)
        }
        return (
            small: jpegThumbnail(source: source, maxPixelSize: smallMaxPixel),
            large: jpegThumbnail(source: source, maxPixelSize: largeMaxPixel)
        )
    }

    /// Render a single JPEG thumbnail bounded by `maxPixelSize`. Uses
    /// `kCGImageSourceCreateThumbnailFromImageAlways` so even formats
    /// without an embedded thumbnail get one; applies the orientation
    /// transform so HEIC captures from iOS etc. land upright.
    private static func jpegThumbnail(source: CGImageSource, maxPixelSize: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let jpegOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ]
        CGImageDestinationAddImage(destination, cgImage, jpegOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
