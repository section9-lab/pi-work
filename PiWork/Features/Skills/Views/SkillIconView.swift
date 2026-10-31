import AppKit
import SwiftUI

/// Catalog card identity tile: the owner's GitHub avatar when one loads, else a
/// stable monogram on a duotone gradient. Same footprint either way, so the
/// grid never reflows while artwork streams in.
struct SkillIconView: View {
    let source: String
    var size: CGFloat = 36

    @State private var avatar: NSImage?

    private var identity: SkillIconIdentity {
        SkillIconIdentity(source: source)
    }

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Self.color(identity.palette.startHex),
                    Self.color(identity.palette.endHex)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(avatar == nil ? 1 : 0)

            Text(identity.monogram)
                .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                .opacity(avatar == nil ? 1 : 0)

            if let avatar {
                Image(nsImage: avatar)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(tileShape)
        .overlay(
            tileShape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.18), value: avatar != nil)
        .task(id: identity.avatarURL) {
            await loadAvatar()
        }
        .accessibilityHidden(true)
    }

    private func loadAvatar() async {
        guard let url = identity.avatarURL else { return }
        let image = await SkillIconImageStore.shared.image(for: url)
        guard !Task.isCancelled else { return }
        avatar = image
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Shared avatar cache for the catalog grid. `AsyncImage` would refetch every
/// time a card scrolls back into the lazy grid; this keeps one download per
/// owner and remembers misses so offline launches do not retry a dead host on
/// every card.
@MainActor
final class SkillIconImageStore {
    static let shared = SkillIconImageStore()

    private let images = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<Data?, Never>] = [:]
    private var unavailable: Set<URL> = []

    func image(for url: URL) async -> NSImage? {
        if let cached = images.object(forKey: url as NSURL) {
            return cached
        }
        guard !unavailable.contains(url) else { return nil }

        let data: Data?
        if let existing = inFlight[url] {
            data = await existing.value
        } else {
            let task = Task.detached(priority: .utility) { () -> Data? in
                var request = URLRequest(
                    url: url,
                    cachePolicy: .returnCacheDataElseLoad,
                    timeoutInterval: 12
                )
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                guard
                    let (data, response) = try? await URLSession.shared.data(for: request),
                    let httpResponse = response as? HTTPURLResponse,
                    (200..<300).contains(httpResponse.statusCode)
                else { return nil }
                return data
            }
            inFlight[url] = task
            data = await task.value
            inFlight[url] = nil
        }

        guard let data, let image = NSImage(data: data) else {
            unavailable.insert(url)
            return nil
        }
        images.setObject(image, forKey: url as NSURL)
        return image
    }
}
