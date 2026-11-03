import AppKit
import SwiftUI

enum ToolDetailWrapping {
    case disabled
    case enabled
    case toggleable
}

struct ToolDetailBlock: View {
    let title: String?
    let text: String
    var wrapping: ToolDetailWrapping = .disabled

    @State private var isHovered = false
    @State private var isWrappingEnabled = true
    @State private var measuredHeight: CGFloat?

    private var wrapsText: Bool {
        wrapping != .disabled && isWrappingEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title {
                HStack {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .textCase(.uppercase)

                    Spacer(minLength: 8)
                    controls
                }
            }

            ScrollView(wrapsText ? .vertical : [.horizontal, .vertical], showsIndicators: true) {
                Text(verbatim: text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: !wrapsText, vertical: true)
                    .frame(maxWidth: wrapsText ? .infinity : nil, alignment: .leading)
                    .padding(9)
                    .padding(.trailing, title == nil ? (wrapping == .toggleable ? 44 : 22) : 0)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ToolDetailHeightKey.self, value: geometry.size.height)
                        }
                    }
            }
            .frame(height: contentHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045))
            .adaptiveCornerRadius(8)
            .overlay(alignment: .topTrailing) {
                if title == nil {
                    controls.padding(7)
                }
            }
        }
        .onPreferenceChange(ToolDetailHeightKey.self) { height in
            // Measure the laid-out text, not source newlines: width changes and
            // streaming output can both change the number of visual lines.
            if height > 0 { measuredHeight = ceil(height) }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var contentHeight: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let lineCount = text.components(separatedBy: .newlines).count
        let fallback = CGFloat(lineCount) * lineHeight + 18
        return min(220, wrapping == .disabled ? fallback : (measuredHeight ?? fallback))
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if wrapping == .toggleable {
                Button {
                    isWrappingEnabled.toggle()
                } label: {
                    Image(systemName: "arrow.turn.down.left")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(wrapsText ? Color.accentColor : Color.secondary)
                }
                .help(wrappingActionLabel)
                .accessibilityLabel(wrappingActionLabel)
            }

            Button {
                // Soft wrapping is presentation-only. Copy the exact source.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
            }
            .help(L10n.string("chat.tool.copy"))
            .accessibilityLabel(L10n.string("chat.tool.copy"))
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.secondary)
    }

    private var wrappingActionLabel: String {
        L10n.string(wrapsText ? "chat.tool.wrap.disable" : "chat.tool.wrap.enable")
    }
}

private struct ToolDetailHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
