import Foundation
import XCTest
@testable import PiWork

final class SkillIconIdentityTests: XCTestCase {
    func testOwnerComesFromTheFirstPathSegment() {
        XCTAssertEqual(SkillIconIdentity(source: "mattpocock/skills").owner, "mattpocock")
        XCTAssertEqual(SkillIconIdentity(source: "  vercel-labs/skills  ").owner, "vercel-labs")
    }

    func testSourceWithoutSlashBecomesTheOwner() {
        XCTAssertEqual(SkillIconIdentity(source: "grilling").owner, "grilling")
    }

    func testMonogramUsesTheFirstLetterUppercased() {
        XCTAssertEqual(SkillIconIdentity(source: "vercel-labs/skills").monogram, "V")
        XCTAssertEqual(SkillIconIdentity(source: "@openai/skills").monogram, "O")
    }

    func testMonogramFallsBackWhenTheOwnerHasNoLetters() {
        XCTAssertEqual(SkillIconIdentity(source: "_/skills").monogram, "?")
    }

    func testPaletteIsStableAcrossInstancesAndLaunches() {
        let first = SkillIconIdentity(source: "anthropics/skills")
        let second = SkillIconIdentity(source: "anthropics/skills")

        XCTAssertEqual(first.palette, second.palette)
        XCTAssertEqual(
            first.palette.startHex,
            SkillIconIdentity(source: "ANTHROPICS/skills").palette.startHex
        )
    }

    func testDifferentSourcesSpreadAcrossPalettes() {
        let sources = [
            "anthropics/skills",
            "vercel-labs/skills",
            "mattpocock/skills",
            "hyperframes",
            "openai/skills"
        ]
        let starts = Set(sources.map { SkillIconIdentity(source: $0).palette.startHex })

        XCTAssertGreaterThan(starts.count, 2)
    }

    func testAvatarURLTargetsTheOwnerAtTheRequestedSize() {
        let identity = SkillIconIdentity(source: "mattpocock/skills", avatarPixelSize: 72)

        XCTAssertEqual(
            identity.avatarURL?.absoluteString,
            "https://github.com/mattpocock.png?size=72"
        )
    }

    func testAvatarURLRejectsOwnersThatAreNotGitHubLogins() {
        XCTAssertNil(SkillIconIdentity(source: "no body/skills").avatarURL)
        XCTAssertNil(SkillIconIdentity(source: "🎨/skills").avatarURL)
        XCTAssertNil(SkillIconIdentity(source: "").avatarURL)
    }

    func testCardRendersTheIconTileBesideTheTitle() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cardSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Skills/Views/SkillsCatalogView.swift"
            ),
            encoding: .utf8
        )
        let iconSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Skills/Views/SkillIconView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(cardSource.contains("SkillIconView(source: item.source, size: 32)"))
        // The tile used to sit on its own row above the title, which cost a
        // whole line of vertical space on every card.
        XCTAssertNil(cardSource.range(of: "SkillIconView(source: item.source)\n"))
        XCTAssertTrue(iconSource.contains("struct SkillIconView: View"))
        XCTAssertTrue(iconSource.contains("identity.monogram"))
        XCTAssertTrue(iconSource.contains("SkillIconImageStore.shared.image(for: url)"))
        XCTAssertFalse(iconSource.contains("AsyncImage("))
    }
}
