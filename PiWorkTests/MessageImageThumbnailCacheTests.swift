import AppKit
import XCTest
@testable import PiWork

@MainActor
final class MessageImageThumbnailCacheTests: XCTestCase {
    override func tearDown() {
        MessageImageThumbnailCache.clear()
        super.tearDown()
    }

    func testThumbnailIsDownsampledAndReusedForTheSameSize() throws {
        let attachment = PiChatImageAttachment(
            id: "image-one",
            mimeType: "image/png",
            data: try pngData(width: 512, height: 512)
        )

        let first = try XCTUnwrap(
            MessageImageThumbnailCache.image(for: attachment, maxPixelSize: 64)
        )
        let second = try XCTUnwrap(
            MessageImageThumbnailCache.image(for: attachment, maxPixelSize: 64)
        )

        XCTAssertTrue(first === second, "Repeated body passes must reuse the decoded thumbnail")
        XCTAssertLessThanOrEqual(max(first.size.width, first.size.height), 64)

        let larger = try XCTUnwrap(
            MessageImageThumbnailCache.image(for: attachment, maxPixelSize: 128)
        )
        XCTAssertFalse(first === larger, "A different decode size needs its own entry")
        XCTAssertLessThanOrEqual(max(larger.size.width, larger.size.height), 128)
    }

    func testClearDropsDecodedImages() throws {
        let attachment = PiChatImageAttachment(
            id: "image-two",
            mimeType: "image/png",
            data: try pngData(width: 32, height: 32)
        )
        XCTAssertNotNil(MessageImageThumbnailCache.image(for: attachment, maxPixelSize: 32))
        MessageImageThumbnailCache.clear()
        XCTAssertNotNil(MessageImageThumbnailCache.image(for: attachment, maxPixelSize: 32))
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
