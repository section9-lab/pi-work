import AppKit
import SwiftUI

/// Appearance-aware surfaces for the app's hand-built chrome.
///
/// The design is a custom gradient rather than system materials, so these
/// can't come from `NSColor`'s semantic set — but they still have to follow
/// the effective appearance now that the theme is user-selectable. Each one
/// is a dynamic `NSColor`, which resolves at draw time against the color
/// scheme in the environment, including one forced by
/// `.preferredColorScheme`.
enum AppPalette {
    /// Keep the original near-white / pearl-blue field, with the approved
    /// 45% reference-blue blend fading in toward the bottom in light mode.
    /// The transparent dark stops leave the existing dark appearance intact.
    private static let windowBaseGradient = LinearGradient(
        stops: [
            .init(color: dynamic(light: 0xF7F8FA, dark: 0x1B202A), location: 0.00),
            .init(color: dynamic(light: 0xF2F7FA, dark: 0x202838), location: 0.28),
            .init(color: dynamic(light: 0xE9F2FD, dark: 0x26344A), location: 0.58),
            .init(color: dynamic(light: 0xE0EBFE, dark: 0x2E3F59), location: 1.00)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static var windowGradient: some View {
        windowBaseGradient.overlay {
            LinearGradient(
                stops: [
                    .init(color: dynamic(light: 0xADC3DB, dark: 0x000000, darkAlpha: 0), location: 0),
                    .init(color: dynamic(light: 0x99BEDF, dark: 0x000000, darkAlpha: 0), location: 0.25),
                    .init(color: dynamic(light: 0x80BBE2, dark: 0x000000, darkAlpha: 0), location: 0.50),
                    .init(color: dynamic(light: 0x70C7F5, dark: 0x000000, darkAlpha: 0), location: 0.75),
                    .init(color: dynamic(light: 0x70D0FF, dark: 0x000000, darkAlpha: 0), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(0.45)
            .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
        }
    }

    /// Opaque top edge of the conversation backdrop. The transcript masks
    /// this surface vertically so scrolled content disappears beneath the
    /// floating window controls before fading back into view.
    static let transcriptTopFadeSurface = LinearGradient(
        colors: [
            dynamic(light: 0xF7F8FA, dark: 0x1B202A),
            dynamic(light: 0xF5F6FC, dark: 0x202838)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// The floating sidebar panel, a touch lighter than the content area at
    /// the same height so it reads as sitting above it.
    static let sidebarSurface = LinearGradient(
        colors: [
            dynamic(light: 0xF8F9FA, dark: 0x272B30),
            dynamic(light: 0xEEF5FC, dark: 0x29394C)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Hairline highlight around the sidebar panel.
    static let panelBorder = dynamic(
        light: 0xFFFFFF, lightAlpha: 0.55,
        dark: 0xFFFFFF, darkAlpha: 0.09
    )

    /// Opaque raised card — input pills, floating controls, and the selected
    /// sidebar segment.
    static let raisedSurface = dynamic(light: 0xF9FAFB, dark: 0x30363D)

    /// Semi-transparent raised card — chat bubbles and similar surfaces, which
    /// let a little of the backdrop through.
    static let translucentSurface = dynamic(
        light: 0xF9FAFB, lightAlpha: 0.88,
        dark: 0x30363D, darkAlpha: 0.88
    )

    /// Restrained slate selection that follows the active row in either theme.
    static let selectedRowFill = dynamic(
        light: 0x6B84AA, lightAlpha: 0.14,
        dark: 0x9BA9B8, darkAlpha: 0.14
    )

    /// A lighter slate tint for pointer hover before selection.
    static let hoverRowFill = dynamic(
        light: 0x6B84AA, lightAlpha: 0.08,
        dark: 0x9BA9B8, darkAlpha: 0.08
    )

    /// Track behind the sidebar's segmented tab control.
    static let segmentedTrack = dynamic(
        light: 0x6B84AA, lightAlpha: 0.10,
        dark: 0x000000, darkAlpha: 0.22
    )

    /// Leading accent bar on the welcome screen's suggestion rows.
    static let accentBar = dynamic(light: 0x7896C2, dark: 0x839DC4)

    /// Drop shadow under raised cards. Dark mode needs a much heavier shadow
    /// for the same sense of elevation.
    static let raisedShadow = dynamic(
        light: 0x000000, lightAlpha: 0.10,
        dark: 0x000000, darkAlpha: 0.45
    )

    /// Softer variant for small elements (chat bubbles, the toggle button).
    static let subtleShadow = dynamic(
        light: 0x000000, lightAlpha: 0.08,
        dark: 0x000000, darkAlpha: 0.35
    )

    private static func dynamic(
        light: UInt32,
        lightAlpha: Double = 1,
        dark: UInt32,
        darkAlpha: Double = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: CGFloat(isDark ? darkAlpha : lightAlpha)
            )
        })
    }
}
