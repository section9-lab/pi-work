import AppKit
import SwiftUI

enum MCPMetrics {
    static let spacing: CGFloat = 16
    static let pagePadding: CGFloat = 24
    static let fieldSpacing: CGFloat = 8
    static let cornerRadius: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let controlHeight: CGFloat = 36
    static let iconSize: CGFloat = 16
}

struct MCPGlyph: View {
    let name: String
    var size: CGFloat = MCPMetrics.iconSize
    private var image: NSImage {
        let resource = "Lucide" + name
        if let image = NSImage(named: resource), image.isValid { return image }
        guard let url = Bundle.main.url(forResource: resource, withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else { return NSImage() }
        image.isTemplate = true
        image.setName(resource)
        return image
    }
    var body: some View {
        Image(nsImage: image)
            .renderingMode(.template).resizable().scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct MCPActionLabel: View {
    let title: String
    let icon: String
    var body: some View { HStack(spacing: MCPMetrics.fieldSpacing) { MCPGlyph(name: icon); Text(title) } }
}

struct MCPField<Content: View>: View {
    let title: String
    var required = false
    var hint: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: MCPMetrics.fieldSpacing) {
            HStack(spacing: 4) {
                Text(title).font(.system(.body, weight: .medium))
                if required { Text("*").foregroundStyle(.red).accessibilityLabel(L10n.string("mcp.required")) }
            }
            content()
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct MCPInput: View {
    let label: String
    var placeholder = ""
    @Binding var text: String
    var secure = false
    @FocusState private var focused: Bool
    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) }
            else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain)
        .focused($focused)
        .padding(.horizontal, 12)
        .frame(minHeight: MCPMetrics.controlHeight)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: MCPMetrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: MCPMetrics.cornerRadius)
            .strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: focused ? 2 : 1))
        .accessibilityLabel(label)
    }
}

struct MCPCommandInput: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        TextField("npx -y @modelcontextprotocol/server-filesystem /path/to/folder", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(3...3)
            .font(.system(.body, design: .monospaced))
            .focused($focused)
            .padding(12)
            .frame(height: 76)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: MCPMetrics.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: MCPMetrics.cornerRadius)
                .strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: focused ? 2 : 1))
            .accessibilityLabel(L10n.string("mcp.command"))
            .accessibilityIdentifier("mcp-command")
    }
}

struct MCPKeyValueEditor: View {
    let title: String
    var isHeaders = false
    @Binding var entries: [MCPKeyValue]
    @State private var pasteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: MCPMetrics.fieldSpacing) {
            HStack {
                Text(title).font(.system(.body, weight: .medium))
                Text(L10n.string("mcp.optional")).foregroundStyle(.secondary)
                Spacer()
                Button {
                    do {
                        let text = NSPasteboard.general.string(forType: .string) ?? ""
                        let pairs = try MCPServerDraft.pastedPairs(text, headers: isHeaders)
                        let combined = entries.filter { !$0.key.isEmpty || !$0.value.isEmpty } + pairs
                        _ = try MCPServerDraft.dictionary(combined, caseInsensitive: isHeaders)
                        entries = combined
                        pasteError = nil
                    } catch { pasteError = error.localizedDescription }
                } label: { MCPActionLabel(title: L10n.string("mcp.paste"), icon: "Clipboard") }
                .buttonStyle(.borderless)
                .help(L10n.string("mcp.paste_hint"))
                .accessibilityLabel("\(L10n.string("mcp.paste")): \(title)")
            }
            ForEach($entries) { $entry in
                HStack(spacing: MCPMetrics.fieldSpacing) {
                    MCPInput(label: L10n.string("mcp.key"), placeholder: isHeaders ? "Authorization" : "API_KEY", text: $entry.key)
                    MCPInput(label: L10n.string("mcp.value"), placeholder: L10n.string("mcp.value"), text: $entry.value, secure: true)
                    Button {
                        entries.removeAll { $0.id == entry.id }
                        if entries.isEmpty { entries = [MCPKeyValue()] }
                    } label: { MCPGlyph(name: "X") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(L10n.string("mcp.remove_entry"))
                    .accessibilityLabel("\(L10n.string("mcp.remove_entry")): \(entry.key)")
                }
            }
            if entries.contains(where: { $0.value == "<stored-secret>" }) {
                Text(L10n.string("mcp.stored_secret")).font(.caption).foregroundStyle(.secondary)
            }
            if let pasteError { Text(pasteError).font(.caption).foregroundStyle(.red) }
            Button {
                entries.append(MCPKeyValue())
            } label: {
                MCPActionLabel(title: L10n.string(isHeaders ? "mcp.add_header" : "mcp.add_variable"), icon: "Plus")
            }
            .buttonStyle(.borderless).padding(.top, 4)
        }
    }
}

struct MCPPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MCPPrimaryButtonBody(configuration: configuration)
    }
}

private struct MCPPrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovered = false
    var body: some View {
        configuration.label
            .font(.system(.body, weight: .medium))
            .padding(.horizontal, MCPMetrics.spacing)
            .frame(minHeight: MCPMetrics.controlHeight)
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .background(Color.primary.opacity(enabled ? (configuration.isPressed ? 0.75 : hovered ? 0.88 : 1) : 0.3),
                        in: RoundedRectangle(cornerRadius: MCPMetrics.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: MCPMetrics.cornerRadius)
                .strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: MCPMetrics.cornerRadius))
            .onHover { hovered = $0 }
    }
}

struct MCPCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().padding(MCPMetrics.spacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: MCPMetrics.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: MCPMetrics.cardRadius).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
