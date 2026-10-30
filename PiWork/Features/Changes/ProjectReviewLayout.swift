import Foundation

/// Only divides the detail column's existing width. Never changes window or
/// navigation-sidebar constraints to make room for the review pane.
struct ProjectReviewLayout {
    static let minimumContentWidth: CGFloat = 400
    static let minimumReviewWidth: CGFloat = 300
    static let maximumReviewWidth: CGFloat = 640
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
        overlaysContent = available < Self.minimumContentWidth + Self.minimumReviewWidth + Self.dividerWidth
        if overlaysContent {
            contentWidth = available
            reviewWidth = min(available, preferred)
        } else {
            reviewWidth = min(preferred, available - Self.minimumContentWidth - Self.dividerWidth)
            contentWidth = available - reviewWidth - Self.dividerWidth
        }
    }
}
