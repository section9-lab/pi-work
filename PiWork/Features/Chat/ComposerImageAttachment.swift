import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct ComposerImageSource: Equatable, Sendable {
    let data: Data
}

struct ComposerImageAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let mimeType: String
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int

    init(
        id: UUID = UUID(),
        mimeType: String,
        data: Data,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.id = id
        self.mimeType = mimeType
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    var promptImage: AgentHostPromptImage {
        AgentHostPromptImage(mimeType: mimeType, data: data)
    }
}

enum ComposerImageAttachmentError: Error, Equatable {
    case unsupportedImage
    case sourceTooLarge
    case imageDimensionsTooLarge
    case imageTooLarge
    case tooManyImages
    case totalTooLarge

    var message: String {
        switch self {
        case .unsupportedImage:
            return L10n.string("chat.image.error.unsupported")
        case .sourceTooLarge:
            return L10n.string("chat.image.error.source_too_large")
        case .imageDimensionsTooLarge:
            return L10n.string("chat.image.error.dimensions_too_large")
        case .imageTooLarge:
            return L10n.string("chat.image.error.image_too_large")
        case .tooManyImages:
            return L10n.string("chat.image.error.too_many")
        case .totalTooLarge:
            return L10n.string("chat.image.error.total_too_large")
        }
    }
}

enum ComposerImagePasteboard {
    private static let maximumSourceBytes = 50 * 1_024 * 1_024
    private static let preferredImageTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .init(UTType.jpeg.identifier),
        .tiff
    ]

    static func sources(from pasteboard: NSPasteboard) -> [ComposerImageSource] {
        var seen = Set<Data>()
        var result: [ComposerImageSource] = []

        for item in pasteboard.pasteboardItems ?? [] {
            let data = directImageData(from: item) ?? fileImageData(from: item)
            guard let data, !data.isEmpty else { continue }
            let digest = Data(SHA256.hash(data: data))
            guard seen.insert(digest).inserted else { continue }
            result.append(ComposerImageSource(data: data))
        }

        return result
    }

    private static func directImageData(from item: NSPasteboardItem) -> Data? {
        let remainingImageTypes = item.types.filter { type in
            !preferredImageTypes.contains(type)
                && UTType(type.rawValue)?.conforms(to: .image) == true
        }

        for type in preferredImageTypes + remainingImageTypes {
            if let data = item.data(forType: type), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    private static func fileImageData(from item: NSPasteboardItem) -> Data? {
        guard
            let value = item.string(forType: .fileURL),
            let url = URL(string: value),
            url.isFileURL,
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey]
            ),
            values.isRegularFile == true,
            values.contentType?.conforms(to: .image) == true,
            let fileSize = values.fileSize,
            fileSize <= maximumSourceBytes
        else { return nil }

        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }
}

enum ComposerImageProcessor {
    static let maximumCount = 5
    // Local transport/memory safety bounds, not provider encoding limits.
    // Pi applies the active model's resize profile after receiving these bytes.
    static let maximumImageBytes = 50 * 1_024 * 1_024
    static let maximumTotalBytes = 50 * 1_024 * 1_024

    private static let maximumSourceBytes = 50 * 1_024 * 1_024
    private static let maximumPixelCount = 50_000_000

    static func process(
        _ sources: [ComposerImageSource],
        existingAttachments: [ComposerImageAttachment] = []
    ) throws -> [ComposerImageAttachment] {
        guard existingAttachments.count <= maximumCount else {
            throw ComposerImageAttachmentError.tooManyImages
        }

        var seen = Set(existingAttachments.map { digest(for: $0.data) })
        var totalBytes = existingAttachments.reduce(0) { $0 + $1.data.count }
        guard totalBytes <= maximumTotalBytes else {
            throw ComposerImageAttachmentError.totalTooLarge
        }

        var result: [ComposerImageAttachment] = []
        for source in sources {
            let attachment = try normalize(source)
            let attachmentDigest = digest(for: attachment.data)
            guard seen.insert(attachmentDigest).inserted else { continue }
            guard existingAttachments.count + result.count < maximumCount else {
                throw ComposerImageAttachmentError.tooManyImages
            }
            guard totalBytes + attachment.data.count <= maximumTotalBytes else {
                throw ComposerImageAttachmentError.totalTooLarge
            }
            result.append(attachment)
            totalBytes += attachment.data.count
        }
        return result
    }

    private static func normalize(
        _ source: ComposerImageSource
    ) throws -> ComposerImageAttachment {
        guard source.data.count <= maximumSourceBytes else {
            throw ComposerImageAttachmentError.sourceTooLarge
        }
        guard
            let imageSource = CGImageSourceCreateWithData(source.data as CFData, nil),
            CGImageSourceGetCount(imageSource) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
                as? [CFString: Any],
            let sourceWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let sourceHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            sourceWidth > 0,
            sourceHeight > 0
        else {
            throw ComposerImageAttachmentError.unsupportedImage
        }
        guard
            sourceWidth <= maximumPixelCount / sourceHeight,
            sourceWidth * sourceHeight <= maximumPixelCount
        else {
            throw ComposerImageAttachmentError.imageDimensionsTooLarge
        }

        // Pi supports these formats natively. Preserve original bytes, metadata,
        // dimensions and quality; the SDK owns resizing and provider limits.
        let supportedTypes: [String: String] = [
            UTType.png.identifier: "image/png",
            UTType.jpeg.identifier: "image/jpeg",
            UTType.gif.identifier: "image/gif",
            UTType.webP.identifier: "image/webp"
        ]
        if let type = CGImageSourceGetType(imageSource) as String?,
           let mimeType = supportedTypes[type] {
            return ComposerImageAttachment(
                mimeType: mimeType,
                data: source.data,
                pixelWidth: sourceWidth,
                pixelHeight: sourceHeight
            )
        }

        // Compatibility only: convert TIFF/HEIC clipboard images to lossless PNG
        // at their original resolution, applying orientation without shrinking.
        let thumbnailSize = max(sourceWidth, sourceHeight)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            options as CFDictionary
        ) else {
            throw ComposerImageAttachmentError.unsupportedImage
        }

        let data = try encodePNG(thumbnail)
        guard data.count <= maximumImageBytes else {
            throw ComposerImageAttachmentError.imageTooLarge
        }
        return ComposerImageAttachment(
            mimeType: "image/png",
            data: data,
            pixelWidth: thumbnail.width,
            pixelHeight: thumbnail.height
        )
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ComposerImageAttachmentError.unsupportedImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ComposerImageAttachmentError.unsupportedImage
        }
        return data as Data
    }

    private static func digest(for data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

/// Marks the session composer surface so outside clicks can resign the input.
final class ComposerSurfaceView: NSView {
    private static let surfaces = NSHashTable<ComposerSurfaceView>.weakObjects()

    static var activeSurfaces: [ComposerSurfaceView] {
        surfaces.allObjects
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            Self.surfaces.add(self)
            ComposerFocusDismissal.installIfNeeded()
        } else {
            Self.surfaces.remove(self)
        }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Layout-only marker; never steal clicks from SwiftUI controls.
        nil
    }

    func containsClick(in window: NSWindow, location: NSPoint) -> Bool {
        guard self.window === window, !bounds.isEmpty else { return false }
        return convert(bounds, to: nil).contains(location)
    }
}

/// Resigns the composer text field when the user clicks outside its card.
/// SwiftUI transcript/sidebar content often never becomes first responder, so
/// the caret would otherwise stay in the input after clicking messages.
enum ComposerFocusDismissal {
    private static var monitor: Any?
    private static let lock = NSLock()

    static func installIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            resignComposerFocusIfNeeded(for: event)
            return event
        }
    }

    static func resignComposerFocusIfNeeded(for event: NSEvent) {
        guard let window = event.window else { return }
        guard let composer = focusedComposerTextView(in: window) else { return }

        // Clicks in another window (popover/settings) should not steal caret state.
        guard event.window === composer.window else { return }

        let location = event.locationInWindow
        if ComposerSurfaceView.activeSurfaces.contains(where: {
            $0.containsClick(in: window, location: location)
        }) {
            return
        }

        if let hit = window.contentView?.hitTest(location), isComposerEditorView(hit) {
            return
        }

        window.makeFirstResponder(nil)
    }

    private static func focusedComposerTextView(in window: NSWindow) -> ComposerTextView? {
        if let textView = window.firstResponder as? ComposerTextView {
            return textView
        }
        guard let view = window.firstResponder as? NSView else { return nil }
        var current: NSView? = view
        while let candidate = current {
            if let textView = candidate as? ComposerTextView {
                return textView
            }
            current = candidate.superview
        }
        return nil
    }

    private static func isComposerEditorView(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate is ComposerTextView {
                return true
            }
            if let scrollView = candidate as? NSScrollView,
               scrollView.documentView is ComposerTextView {
                return true
            }
            current = candidate.superview
        }
        return false
    }
}

final class ComposerTextView: NSTextView {
    var onPasteboard: ((NSPasteboard) -> Bool)?
    var onMarkedTextChange: ((Bool) -> Void)?

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        onMarkedTextChange?(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChange?(false)
    }

    override func validateUserInterfaceItem(
        _ item: NSValidatedUserInterfaceItem
    ) -> Bool {
        if
            item.action == #selector(paste(_:)),
            !ComposerImagePasteboard.sources(from: .general).isEmpty
        {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    @discardableResult
    func consumePasteboard(_ pasteboard: NSPasteboard) -> Bool {
        onPasteboard?(pasteboard) == true
    }

    override func paste(_ sender: Any?) {
        guard !consumePasteboard(.general) else { return }
        super.paste(sender)
    }
}
