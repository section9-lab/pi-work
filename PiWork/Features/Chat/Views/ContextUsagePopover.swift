import AppKit
import SwiftUI

/// The hover card behind the composer's context ring: headline usage, a stacked
/// bar, and — when the host could attribute it — the per-category split.
struct ContextUsagePopover: View {
    let presentation: ContextUsagePresentation?
    let cost: AgentHostACPSessionCost?

    private var segments: [ContextUsagePresentation.Segment] {
        presentation?.segments ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("context.title"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.45))

            if let presentation {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(presentation.headlinePercentText)
                        .font(.system(size: 21, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary.opacity(0.88))

                    Text(presentation.detailText)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary.opacity(0.5))
                        .lineLimit(1)
                }

                stackedBar
                    .padding(.top, 1)

                if !segments.isEmpty {
                    legend
                        .padding(.top, 1)
                }
            } else {
                Text(L10n.string("context.recalculating"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.5))
            }

            if let costText {
                Divider()
                    .padding(.top, 1)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(L10n.string("chat.session_cost"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.45))

                    Spacer(minLength: 8)

                    Text(costText)
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 264, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var stackedBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))

                HStack(spacing: 2) {
                    ForEach(segments) { segment in
                        Capsule()
                            .fill(ContextSegmentColor.color(for: segment.id))
                            .frame(width: width(of: segment, in: proxy.size.width))
                    }
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private var legend: some View {
        VStack(spacing: 7) {
            ForEach(segments) { segment in
                HStack(spacing: 8) {
                    Circle()
                        .fill(ContextSegmentColor.color(for: segment.id))
                        .frame(width: 6, height: 6)

                    Text(segment.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.primary.opacity(0.78))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(segment.tokenText)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary.opacity(0.32))

                    Text(segment.percentText)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary.opacity(0.5))
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    /// Even 0.1% stays visible, and the gaps between slices come out of the
    /// track rather than pushing the bar past its container.
    private func width(of segment: ContextUsagePresentation.Segment, in total: CGFloat) -> CGFloat {
        let gaps = CGFloat(max(segments.count - 1, 0)) * 2
        let available = max(total - gaps, 0)
        let ideal = available * segment.fraction
        return min(max(ideal, segment.fraction > 0 ? 1.5 : 0), available)
    }

    private var accessibilityLabel: String {
        [presentation?.accessibilityLabel, costText.map { "\(L10n.string("chat.session_cost")): \($0)" }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private var costText: String? {
        guard let cost else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = L10n.currentLanguage.locale
        formatter.currencyCode = cost.currency.uppercased()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSNumber(value: cost.amount))
            ?? "\(cost.amount) \(cost.currency.uppercased())"
    }
}

/// Muted hues for the breakdown. They stay legible in both appearances and sit
/// inside the app's blue-slate palette instead of pulling in a second accent.
private enum ContextSegmentColor {
    static func color(for id: String) -> Color {
        switch id {
        case "tools":
            return dynamic(light: 0x4F9C92, dark: 0x6FC0B4)
        case "messages":
            return dynamic(light: 0xD79A55, dark: 0xE3B278)
        case "mcp":
            return dynamic(light: 0x8B7BC0, dark: 0xAB9DD8)
        case "skills":
            return dynamic(light: 0xC97F94, dark: 0xD79BAB)
        case "context":
            return dynamic(light: 0x8A94A3, dark: 0xA3ADBB)
        default:
            return dynamic(light: 0x6F86B8, dark: 0x93A9D4)
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
