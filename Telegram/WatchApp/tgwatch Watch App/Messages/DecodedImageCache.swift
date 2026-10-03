import Foundation
import ImageIO
import UIKit

/// Decoded images for list rows (photo / video previews, avatars, minithumbnails),
/// keyed by file path or by the bytes of an inline minithumbnail.
///
/// Rows used to call `UIImage(contentsOfFile:)` / `UIImage(data:)` in `body`, which
/// decoded the image on the main thread on every re-render and again each time the
/// lazy stack rebuilt a row while scrolling. This decodes each image once (eagerly,
/// so drawing doesn't decode again) and keeps it while memory allows.
@MainActor
enum DecodedImageCache {
    private static let byPath: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private static let byData: NSCache<NSData, UIImage> = {
        let cache = NSCache<NSData, UIImage>()
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    /// Longest side, in pixels, an image is decoded at. Bubbles and avatars are far
    /// smaller than this on any watch; full-screen viewers decode on their own.
    private static let maxPixelSize = 640

    static func image(atPath path: String) -> UIImage? {
        if let hit = byPath.object(forKey: path as NSString) { return hit }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = decode(source) else { return nil }
        byPath.setObject(image, forKey: path as NSString, cost: cost(of: image))
        return image
    }

    static func image(data: Data) -> UIImage? {
        let key = data as NSData
        if let hit = byData.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithData(key as CFData, nil),
              let image = decode(source) else { return nil }
        byData.setObject(image, forKey: key, cost: cost(of: image))
        return image
    }

    private static func decode(_ source: CGImageSource) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
