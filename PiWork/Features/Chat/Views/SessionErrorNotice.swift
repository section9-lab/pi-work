import SwiftUI

/// Inline failure card shown above the composer. It follows the same notice
/// treatment as the rest of the app: a tinted symbol, a 12pt title, an 11pt
/// explanation, and plain trailing actions on a soft tinted surface.
struct SessionErrorNotice: View {
    let notice: AgentErrorPresentation

    @State private var isShowingDetails = false

    private var shape: AnyShape { adaptiveRoundedShape(cornerRadius: 12) }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: notice.symbolName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(notice.accentColor.opacity(0.9))
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = notice.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let recovery = notice.recovery, !recovery.isEmpty {
                    Text(recovery)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }

                if isShowingDetails, let technical = notice.technicalDetail, !technical.isEmpty {
                    Text(technical)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.42))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5)
                }
            }

            Spacer(minLength: 8)

            if notice.technicalDetail?.isEmpty == false {
                Button(detailsTitle) {
                    isShowingDetails.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))
                .padding(.top, 0.5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(notice.accentColor.opacity(0.08)))
        .overlay(shape.stroke(notice.accentColor.opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-error-notice")
    }

    private var detailsTitle: String {
        L10n.string(
            isShowingDetails ? "chat.error.details.hide" : "chat.error.details.show"
        )
    }
}
