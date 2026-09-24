import SwiftUI
import XCTest
@testable import PiWork

final class AdaptiveCornerShapeTests: XCTestCase {
    @MainActor
    func testInsetShapeResolvesItsCornersFromTheContainingView() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("ConcentricRectangle is only available on macOS 26 or newer")
        }

        let bitmap = try TestViewRenderer.render(
            adaptiveRoundedShape(cornerRadius: 4)
                .fill(.white)
                .padding(14)
                .containerShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
                .background(.black),
            size: CGSize(width: 160, height: 120)
        )

        let corner = try XCTUnwrap(bitmap.colorAt(x: 18, y: 18)?.usingColorSpace(.sRGB))
        let center = try XCTUnwrap(bitmap.colorAt(x: 80, y: 60)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(corner.redComponent, 0.1, "The inset corner should follow the larger containing corner")
        XCTAssertGreaterThan(center.redComponent, 0.9, "The content should remain visible")
    }

    @MainActor
    func testFloatingPanelProvidesItsShapeToInsetContent() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("ConcentricRectangle is only available on macOS 26 or newer")
        }

        let bitmap = try TestViewRenderer.render(
            InWindowFloatingPanel(
                isPresented: .constant(true),
                layout: BoundedFloatingPanelLayout(
                    idealWidth: 160,
                    idealMaximumHeight: 120,
                    inset: 0
                ),
                anchorFrame: nil
            ) {
                adaptiveRoundedShape(cornerRadius: 1)
                    .fill(.white)
                    .padding(4)
                    .background(.black)
            }
            .environment(\.colorScheme, .light),
            size: CGSize(width: 160, height: 120)
        )

        let corner = try XCTUnwrap(bitmap.colorAt(x: 7, y: 7)?.usingColorSpace(.sRGB))
        let center = try XCTUnwrap(bitmap.colorAt(x: 80, y: 60)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(corner.redComponent, 0.1, "Panel content should inherit the panel's rounded boundary")
        XCTAssertGreaterThan(center.redComponent, 0.9)
    }

    func testUsesSystemConcentricGeometryOnMacOS26() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("ConcentricRectangle is only available on macOS 26 or newer")
        }

        let rect = CGRect(x: 0, y: 0, width: 200, height: 120)
        let actual = adaptiveRoundedShape(cornerRadius: 16).path(in: rect).cgPath
        let expected = ConcentricRectangle(
            corners: .concentric(minimum: .fixed(16))
        ).path(in: rect).cgPath

        XCTAssertEqual(actual, expected)
    }
}
