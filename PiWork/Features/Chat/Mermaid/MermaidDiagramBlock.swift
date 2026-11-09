import MermaidRender
import SwiftUI

/// Native Mermaid rendering for macOS 14+.
///
/// Instances are only created by `MermaidDiagramFactory`, which owns the OS
/// gate; macOS 13 keeps rendering these fences as code blocks. The diagram is
/// an image, so the whole block doubles as a button that opens a scrollable
/// full-size view — `MermaidView` scales down to fit the transcript column and
/// never up, which makes wide flowcharts unreadable at 700pt.
@available(macOS 14, *)
struct MermaidDiagramBlock: View {
    let source: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var isExpanded = false
    @State private var isHovered = false

    var body: some View {
        Button {
            isExpanded = true
        } label: {
            MermaidView(source, theme: theme)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topTrailing) { expandBadge }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(L10n.string("chat.mermaid.expand"))
        .accessibilityLabel(Text(accessibilityDescription))
        .accessibilityHint(Text(L10n.string("chat.mermaid.expand")))
        .sheet(isPresented: $isExpanded) { expandedDiagram }
    }

    private var theme: DiagramTheme {
        DiagramTheme(prefersDark: colorScheme == .dark)
    }

    private var accessibilityDescription: String {
        guard let generated = MermaidRenderer.altText(source: source) else {
            return L10n.string("chat.mermaid.diagram")
        }
        let cleaned = MermaidSource.accessibilityDescription(generated)
        return cleaned.isEmpty ? L10n.string("chat.mermaid.diagram") : cleaned
    }

    private var expandBadge: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.7))
            .frame(width: 26, height: 26)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            .padding(8)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var expandedDiagram: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("chat.mermaid.diagram"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                Spacer()
                Button(L10n.string("common.done")) { isExpanded = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(.bar)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                MermaidView(source, theme: theme)
                    .padding(24)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 640)
        .accessibilityLabel(Text(accessibilityDescription))
    }
}
