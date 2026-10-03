import Foundation
import ImageIO
import SwiftUI
import UIKit

/// Decoded images for list rows (photo / video previews, avatars, minithumbnails),
/// keyed by file path (and decode size) or by the bytes of an inline minithumbnail.
///
/// Rows used to call `UIImage(contentsOfFile:)` / `UIImage(data:)` in `body`, which
/// decoded the image on the main thread on every re-render and again each time the
/// lazy stack rebuilt a row while scrolling. This decodes each image once (eagerly,
/// so drawing doesn't decode again) and keeps it while memory allows. Files decode
/// off the main thread (see `DecodedFileImage`); minithumbnails are tiny and decode
/// in place.
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
    /// Decodes running now, so rows asking for the same file share one.
    private static var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Longest side, in pixels, minithumbnails are decoded at (they're ~40px anyway).
    private static let miniMaxPixelSize = 640

    /// The file's image if it's already decoded at this size; never decodes.
    static func cachedImage(atPath path: String, maxPixelSize: Int) -> UIImage? {
        byPath.object(forKey: key(path, maxPixelSize) as NSString)
    }

    /// Decodes the file off the main thread (once per path and size) and caches it.
    static func loadImage(atPath path: String, maxPixelSize: Int) async -> UIImage? {
        let key = key(path, maxPixelSize)
        if let hit = byPath.object(forKey: key as NSString) { return hit }
        if let running = inFlight[key] { return await running.value }
        let task = Task.detached(priority: .userInitiated) {
            decodeFile(atPath: path, maxPixelSize: maxPixelSize)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            byPath.setObject(image, forKey: key as NSString, cost: cost(of: image))
        }
        return image
    }

    static func image(data: Data) -> UIImage? {
        let key = data as NSData
        if let hit = byData.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithData(key as CFData, nil),
              let image = decode(source, maxPixelSize: miniMaxPixelSize) else { return nil }
        byData.setObject(image, forKey: key, cost: cost(of: image))
        return image
    }

    private static func key(_ path: String, _ maxPixelSize: Int) -> String {
        "\(maxPixelSize)|\(path)"
    }

    private nonisolated static func decodeFile(atPath path: String, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }
        return decode(source, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func decode(_ source: CGImageSource, maxPixelSize: Int) -> UIImage? {
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

/// Decode sizes (longest side, pixels) for the places images are shown: a little over
/// twice the largest point size there, for the watch's 2x screens.
enum DecodeSize {
    /// Photo / video / video-note bubbles (at most ~192 x 213pt on the 46mm watch).
    static let bubble = 440
    /// Chat avatars (36-50pt).
    static let avatar = 120
}

/// The image file at `path`, filled into its frame. Shows `placeholder` until the file
/// has decoded off the main thread; an image already in the cache shows at once, so a
/// row rebuilt by the lazy stack doesn't flash its placeholder.
struct DecodedFileImage<Placeholder: View>: View {
    let path: String?
    let maxPixelSize: Int
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var loaded: (path: String, image: UIImage)?

    var body: some View {
        Group {
            if let image = shownImage {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: path) {
            guard let path, shownImage == nil else { return }
            if let image = await DecodedImageCache.loadImage(atPath: path, maxPixelSize: maxPixelSize) {
                loaded = (path, image)
            }
        }
    }

    private var shownImage: UIImage? {
        guard let path else { return nil }
        if let loaded, loaded.path == path { return loaded.image }
        return DecodedImageCache.cachedImage(atPath: path, maxPixelSize: maxPixelSize)
    }
}
