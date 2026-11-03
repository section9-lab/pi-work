import AppKit
import SwiftUI
import XCTest
@testable import PiWork

final class AppPaletteBackdropTests: XCTestCase {
    @MainActor
    func testLightBackdropMatchesApproved45PercentPreview() throws {
        let expected = originalBackdrop(dark: false)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: color(0xADC3DB), location: 0),
                        .init(color: color(0x99BEDF), location: 0.25),
                        .init(color: color(0x80BBE2), location: 0.50),
                        .init(color: color(0x70C7F5), location: 0.75),
                        .init(color: color(0x70D0FF), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(0.45)
                .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
            }
        let actualBitmap = try render(AppPalette.windowGradient, dark: false)
        let expectedBitmap = try render(expected, dark: false)
        assertPixelsMatch(actualBitmap, expectedBitmap)
    }

    @MainActor
    func testLightBackdropPreservesNearWhiteTopAndStrengthensBlueAtBottom() throws {
        let actual = try render(AppPalette.windowGradient, dark: false)
        let original = try render(originalBackdrop(dark: false), dark: false)
        let top = pixel(actual, x: 120, y: 0)
        let originalTop = pixel(original, x: 120, y: 0)
        for channel in 0..<3 {
            XCTAssertEqual(Double(top[channel]), Double(originalTop[channel]), accuracy: 1)
        }
        let bottom = pixel(actual, x: 120, y: 319)
        let originalBottom = pixel(original, x: 120, y: 319)
        XCTAssertLessThan(Int(bottom[0]), Int(originalBottom[0]) - 30)
        XCTAssertGreaterThan(bottom[2], bottom[1])
    }

    @MainActor
    func testDarkBackdropRemainsUnchanged() throws {
        let actual = try render(AppPalette.windowGradient, dark: true)
        let original = try render(originalBackdrop(dark: true), dark: true)
        assertPixelsMatch(actual, original)
    }

    private func originalBackdrop(dark: Bool) -> LinearGradient {
        let colors: [UInt32] = dark
            ? [0x1B202A, 0x202838, 0x26344A, 0x2E3F59]
            : [0xF7F8FA, 0xF2F7FA, 0xE9F2FD, 0xE0EBFE]
        return LinearGradient(
            stops: zip(colors, [0.0, 0.28, 0.58, 1.0]).map {
                .init(color: color($0.0), location: $0.1)
            },
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    @MainActor
    private func render<V: View>(_ view: V, dark: Bool) throws -> NSBitmapImageRep {
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view
                .frame(width: 240, height: 320)
                .environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 1
            image = renderer.cgImage
        }
        return NSBitmapImageRep(cgImage: try XCTUnwrap(image))
    }

    private func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> [UInt] {
        var channels = [UInt](repeating: 0, count: 4)
        bitmap.getPixel(&channels, atX: x, y: y)
        return channels
    }

    private func assertPixelsMatch(
        _ actual: NSBitmapImageRep,
        _ expected: NSBitmapImageRep,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for y in stride(from: 0, to: 320, by: 7) {
            for x in [0, 80, 159, 239] {
                let actualPixel = pixel(actual, x: x, y: y)
                let expectedPixel = pixel(expected, x: x, y: y)
                for channel in 0..<3 {
                    XCTAssertEqual(Double(actualPixel[channel]), Double(expectedPixel[channel]),
                                   accuracy: 1, "Pixel (\(x), \(y)), channel \(channel)", file: file, line: line)
                }
            }
        }
    }
}
