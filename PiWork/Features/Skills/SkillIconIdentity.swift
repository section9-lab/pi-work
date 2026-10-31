import Foundation

/// Derives the identity tile a catalog card shows for a skill.
///
/// skills.sh publishes `owner/repository` plus a name and install count, but no
/// artwork, so the catalog borrows the owner's GitHub avatar and falls back to
/// a deterministic monogram whenever that avatar is missing. Everything here is
/// pure and hash-stable: the same skill always lands on the same colour, even
/// after a relaunch or a catalog refresh.
struct SkillIconIdentity: Equatable {
    /// Owner segment of `owner/repository`, or the whole source when it has no
    /// slash, so single-name sources still get a stable tile.
    let owner: String

    /// One character standing in for the owner while the avatar loads.
    let monogram: String

    /// Two-stop gradient behind the monogram, chosen from `palettes`.
    let palette: SkillIconPalette

    /// Owner avatar on GitHub, or `nil` when the owner is not a legal login.
    let avatarURL: URL?

    init(source: String, avatarPixelSize: Int = 96) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        let resolvedOwner = owner.isEmpty ? trimmed : owner

        self.owner = resolvedOwner
        monogram = Self.monogram(for: resolvedOwner)
        palette = SkillIconPalette.palette(forHash: Self.hash(resolvedOwner))
        avatarURL = Self.avatarURL(for: resolvedOwner, pixelSize: avatarPixelSize)
    }

    private static func monogram(for text: String) -> String {
        guard let character = text.first(where: { $0.isLetter || $0.isNumber }) else {
            return "?"
        }
        return String(character).uppercased()
    }

    /// FNV-1a over the lowercased owner. Swift's own `hashValue` is seeded per
    /// process, which would repaint every tile on each launch.
    private static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.lowercased().utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return value
    }

    private static func avatarURL(for owner: String, pixelSize: Int) -> URL? {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_."
        )
        guard
            !owner.isEmpty,
            owner.unicodeScalars.allSatisfy(allowed.contains)
        else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(owner).png"
        components.queryItems = [URLQueryItem(name: "size", value: "\(pixelSize)")]
        return components.url
    }
}

/// Fixed duotones for the monogram fallback. A curated set keeps every tile
/// legible under a white glyph instead of following the full colour wheel.
struct SkillIconPalette: Equatable {
    let startHex: UInt32
    let endHex: UInt32

    static let all: [SkillIconPalette] = [
        SkillIconPalette(startHex: 0x6D8AC4, endHex: 0x4A679E),
        SkillIconPalette(startHex: 0x4F9D91, endHex: 0x35796F),
        SkillIconPalette(startHex: 0xB98A5A, endHex: 0x96693C),
        SkillIconPalette(startHex: 0x8E7BC0, endHex: 0x6B5899),
        SkillIconPalette(startHex: 0xC08080, endHex: 0x9C5C5C),
        SkillIconPalette(startHex: 0x7F9A5E, endHex: 0x5E773F),
        SkillIconPalette(startHex: 0x6A9FC0, endHex: 0x487C9C),
        SkillIconPalette(startHex: 0x8A8FA0, endHex: 0x666B7B),
        SkillIconPalette(startHex: 0xB07C9E, endHex: 0x8C5880),
        SkillIconPalette(startHex: 0x8C7B6B, endHex: 0x6A5A4C)
    ]

    static func palette(forHash hash: UInt64) -> SkillIconPalette {
        all[Int(hash % UInt64(all.count))]
    }
}
