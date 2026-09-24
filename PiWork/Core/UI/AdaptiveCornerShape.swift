import SwiftUI

enum AppCornerRadius {
    static let card: CGFloat = 16
    static let panel: CGFloat = 20
}

/// Returns the system-concentric rounded rectangle on macOS 26, using the
/// supplied radius as a visual fallback when the view is away from a window
/// corner. Earlier systems keep the continuous rounded rectangle used by the
/// previous macOS design.
func adaptiveRoundedShape(cornerRadius: CGFloat) -> AnyShape {
    if #available(macOS 26, *) {
        return AnyShape(ConcentricRectangle(
            corners: .concentric(minimum: .fixed(cornerRadius))
        ))
    }

    return AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
}

extension View {
    /// Clips this view with an adaptive rounded-rectangle shape. See
    /// `adaptiveRoundedShape(cornerRadius:)` for the macOS 26 upgrade path.
    func adaptiveCornerRadius(_ radius: CGFloat) -> some View {
        clipShape(adaptiveRoundedShape(cornerRadius: radius))
    }
}
