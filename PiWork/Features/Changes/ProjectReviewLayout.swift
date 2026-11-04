import Foundation

/// Only divides the detail column's existing width. Never changes window or
/// navigation-sidebar constraints to make room for the review pane.
struct ProjectReviewLayout {
    static let minimumContentWidth: CGFloat = 400
    static let minimumReviewWidth: CGFloat = 300
    static let maximumReviewWidth: CGFloat = 2400
    static let dividerWidth: CGFloat = 1

    let contentWidth: CGFloat
    let reviewWidth: CGFloat
    let overlaysContent: Bool

    init(availableWidth: CGFloat, preferredWidth: CGFloat, isPresented: Bool) {
        let available = max(0, availableWidth)
        guard isPresented else {
            contentWidth = available
            reviewWidth = 0
            overlaysContent = false
            return
        }
        let preferred = min(Self.maximumReviewWidth, max(Self.minimumReviewWidth, preferredWidth))
        overlaysContent = false
        let usableWidth = max(0, available - Self.dividerWidth)
        // On narrow windows keep both panes visible instead of covering the composer.
        let contentMinimum = min(Self.minimumContentWidth, usableWidth / 2)
        reviewWidth = min(preferred, usableWidth - contentMinimum)
        contentWidth = usableWidth - reviewWidth
    }
}
