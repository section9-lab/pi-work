import AppKit
import SwiftUI

struct SettingsPresentationSequencer {
    static func present(
        dismiss: () -> Void,
        schedule: (@escaping () -> Void) -> Void,
        open: @escaping () -> Void
    ) {
        dismiss()
        schedule(open)
    }
}

struct UserAccountPopover: View {
    @Binding var isPresented: Bool
    let accountName: String
    let accountSubtitle: String
    let accountInitial: String
    var accountAvatarURL: URL? = nil
    /// Local sessions have no account to sign out of, so the last row becomes
    /// the way back into sign-in.
    var isLocalMode: Bool = false
    var onSettings: () -> Void
    var onHelp: () -> Void
    var onSignIn: () -> Void = {}
    var onLogout: () -> Void

    private let contentInset: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            Button {
            } label: {
                HStack(spacing: 12) {
                    avatarView
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(accountName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(accountSubtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }

            Divider()
                .padding(.horizontal, contentInset)

            if #available(macOS 14.0, *) {
                ModernSettingsMenuItem(isPresented: $isPresented)
            } else {
                MenuItem(icon: "gearshape", title: L10n.string("account.settings"), action: {
                    presentSettings(open: onSettings)
                })
            }

            Divider()
                .padding(.horizontal, contentInset)

            ThemeMenuItem()

            Divider()
                .padding(.horizontal, contentInset)

            MenuItem(icon: "questionmark.circle", title: L10n.string("account.help"), hasChevron: true, action: {
                isPresented = false
                onHelp()
            })

            Divider()
                .padding(.horizontal, contentInset)

            if isLocalMode {
                MenuItem(icon: "arrow.right.to.line", title: L10n.string("account.sign_in"), action: {
                    isPresented = false
                    onSignIn()
                })
            } else {
                MenuItem(icon: "arrow.right.square", title: L10n.string("account.sign_out"), isDestructive: true, action: {
                    isPresented = false
                    onLogout()
                })
            }
        }
        .padding(.vertical, 8)
        .background(
            adaptiveRoundedShape(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
        )
        .frame(width: 240)
    }

    @ViewBuilder
    private var avatarView: some View {
        AccountAvatarImage(
            url: accountAvatarURL,
            fallbackInitial: accountInitial,
            fallbackFontSize: 18
        )
    }

    private func presentSettings(open: @escaping () -> Void) {
        SettingsPresentationSequencer.present(
            dismiss: { isPresented = false },
            schedule: { action in
                DispatchQueue.main.async {
                    action()
                }
            },
            open: open
        )
    }
}

@available(macOS 14.0, *)
private struct ModernSettingsMenuItem: View {
    @Binding var isPresented: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuItem(icon: "gearshape", title: L10n.string("account.settings"), action: {
            SettingsPresentationSequencer.present(
                dismiss: { isPresented = false },
                schedule: { action in
                    DispatchQueue.main.async {
                        action()
                    }
                },
                open: {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
            )
        })
    }
}

struct AccountAvatarImage: View {
    let url: URL?
    let fallbackInitial: String
    var fallbackFontSize: CGFloat

    @State private var loadedImage: NSImage?
    @State private var failedURL: URL?

    var body: some View {
        Group {
            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                fallback
            }
        }
        .clipShape(Circle())
        .task(id: url) {
            await loadAvatar()
        }
    }

    private var fallback: some View {
        Circle()
            .fill(Color.gray.opacity(0.3))
            .overlay {
                Text(fallbackInitial)
                    .font(.system(size: fallbackFontSize, weight: .semibold))
                    .foregroundColor(.white)
            }
    }

    private func loadAvatar() async {
        guard let url else {
            loadedImage = nil
            failedURL = nil
            return
        }

        if failedURL == url {
            return
        }

        loadedImage = nil

        for attempt in 0..<3 {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }
                if let image = NSImage(data: data) {
                    loadedImage = image
                    failedURL = nil
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
            }

            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(450))
            }
        }

        failedURL = url
    }
}

/// Shared row chrome for the popover's menu entries, so the theme submenu
/// (which has to be a `Menu` rather than a `Button`) stays pixel-identical
/// to the plain items around it.
private struct MenuItemLabel: View {
    let icon: String
    let title: String
    var hasChevron: Bool = false
    var isDestructive: Bool = false
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .frame(width: 20)
                .foregroundColor(isDestructive ? .red : .primary)

            Text(title)
                .font(.system(size: 14))
                .foregroundColor(isDestructive ? .red : .primary)

            Spacer()

            if hasChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            adaptiveRoundedShape(cornerRadius: 8)
                .fill(isHovered ? Color.primary.opacity(0.055) : Color.clear)
        )
    }
}

/// Appearance picker. The reference design shows an icon *and* a checkmark on
/// each option, flying out to the side — a native `Menu` can't do that, since
/// an `NSMenuItem` has a single image slot that the checkmark takes over, and
/// it would open downward over the account panel. So the flyout is a nested
/// popover anchored to this row's trailing edge.
private struct ThemeMenuItem: View {
    @ObservedObject private var themeStore = ThemeStore.shared
    @State private var isHovered = false
    @State private var isFlyoutPresented = false

    var body: some View {
        Button {
            isFlyoutPresented.toggle()
        } label: {
            MenuItemLabel(
                icon: "paintpalette",
                title: L10n.string("account.theme"),
                hasChevron: true,
                // Keep the row lit while its flyout is up, so the trail back
                // to the parent menu stays obvious.
                isHovered: isHovered || isFlyoutPresented
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .popover(
            isPresented: $isFlyoutPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .trailing
        ) {
            VStack(spacing: 2) {
                ForEach(AppTheme.allCases) { theme in
                    ThemeOptionRow(
                        theme: theme,
                        isSelected: themeStore.theme == theme
                    ) {
                        themeStore.theme = theme
                        isFlyoutPresented = false
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(width: 184)
        }
    }
}

private struct ThemeOptionRow: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Reserved gutter rather than a conditional view, so the
                // labels stay aligned as the selection moves.
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 12)
                    .opacity(isSelected ? 1 : 0)

                Image(systemName: theme.icon)
                    .font(.system(size: 15))
                    .frame(width: 20)

                Text(theme.title)
                    .font(.system(size: 14))

                Spacer(minLength: 0)
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                adaptiveRoundedShape(cornerRadius: 7)
                    .fill(isHovered ? Color.primary.opacity(0.055) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

private struct MenuItem: View {
    let icon: String
    let title: String
    var hasChevron: Bool = false
    var isDestructive: Bool = false
    var action: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        Button {
            action?()
        } label: {
            MenuItemLabel(
                icon: icon,
                title: title,
                hasChevron: hasChevron,
                isDestructive: isDestructive,
                isHovered: isHovered
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

#Preview {
    UserAccountPopover(
        isPresented: .constant(true),
        accountName: "Google User",
        accountSubtitle: L10n.string("account.google"),
        accountInitial: "G",
        onSettings: {},
        onHelp: {},
        onLogout: {}
    )
    .padding()
}
