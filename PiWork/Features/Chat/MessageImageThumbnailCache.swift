import AppKit
import ImageIO

/// Decodes an attachment once per identity/size and keeps only a downsampled
/// image. Decoding the full-size `Data` inside `ChatMessageRow.body` re-ran on
/// every streaming publication and retained full-resolution pixels for every
/// scrolled row.
@MainActor
enum MessageImageThumbnailCache {
    private final class Entry {
        let image: NSImage
        init(_ image: NSImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 64
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func image(for attachment: PiChatImageAttachment, maxPixelSize: Int) -> NSImage? {
        let key = "\(attachment.id)#\(maxPixelSize)" as NSString
        if let entry = cache.object(forKey: key) { return entry.image }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(
            attachment.data as CFData,
            sourceOptions
        ) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        cache.setObject(
            Entry(image),
            forKey: key,
            cost: max(1, cgImage.bytesPerRow * cgImage.height)
        )
        return image
    }

    static func clear() {
        cache.removeAllObjects()
    }
}
