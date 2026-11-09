import MermaidLayout
import MermaidRender
import SwiftUI

/// Bridges the markdown theme to the macOS-14-only diagram view.
///
/// No MermaidKit API is reached unless the OS gate passes, so macOS 13 keeps
/// rendering the fence as a plain code block without ever calling into the
/// linked library.
enum MermaidDiagramFactory {
    private static let parseGate = MermaidParseGate()

    /// `nil` means "render the plain code block": not a mermaid fence, this Mac
    /// is below macOS 14, the source exceeds the renderer's bound, or the
    /// source does not parse. Anything the user wrote stays visible either way.
    static func makeBlock(language: String?, source: String) -> AnyView? {
        guard MermaidAvailability.isEnabledOnThisMac,
              MermaidSource.isMermaidFence(language),
              MermaidSource.isWithinRenderLimits(source)
        else { return nil }

        guard #available(macOS 14, *) else { return nil }
        guard parseGate.isRenderable(source) else { return nil }
        return AnyView(MermaidDiagramBlock(source: source))
    }
}

/// Parse results are memoized because the markdown view re-evaluates the theme
/// while a response streams, and `MermaidView` parses again to draw. A cold
/// parse of a dense diagram costs a few milliseconds.
///
/// `NSCache` is documented thread-safe; the wrapper only carries that promise
/// across concurrency checking.
private final class MermaidParseGate: @unchecked Sendable {
    private let cache = NSCache<NSString, NSNumber>()

    init() {
        cache.countLimit = 128
    }

    func isRenderable(_ source: String) -> Bool {
        let key = source as NSString
        if let cached = cache.object(forKey: key) { return cached.boolValue }
        let renderable = MermaidParser.parse(source) != nil
        cache.setObject(NSNumber(value: renderable), forKey: key)
        return renderable
    }
}
