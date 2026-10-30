import XCTest
import Sparkle
@testable import PiWork

final class AppUpdateCheckerTests: XCTestCase {
    func testReleaseVersionComparesNumericComponents() throws {
        let older = try XCTUnwrap(ReleaseVersion("v1.9.0"))
        let newer = try XCTUnwrap(ReleaseVersion("1.10.0"))

        XCTAssertLessThan(older, newer)
    }

    func testReleaseVersionTreatsMissingTrailingComponentsAsZero() throws {
        XCTAssertEqual(
            try XCTUnwrap(ReleaseVersion("v1.2")),
            try XCTUnwrap(ReleaseVersion("1.2.0"))
        )
    }

    func testReleaseVersionRejectsNonNumericTags() {
        XCTAssertNil(ReleaseVersion("release-1.2.0"))
    }

    func testUpdateCheckIsExposedInTheApplicationMenuAndGeneralSettings() throws {
        let root = repositoryRoot()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("PiWork/App/PiWorkApp.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent(
                "PiWork/Features/Auth/Views/ModelProviderSettingsView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains("CommandGroup(after: .appInfo)"))
        XCTAssertTrue(appSource.contains("checkForUpdatesAndPresent"))
        XCTAssertTrue(settingsSource.contains("AppUpdateSettingsRow"))
    }

    func testAboutPanelIncludesTheBundledPiCodingAgentVersion() throws {
        let root = repositoryRoot()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("PiWork/App/PiWorkApp.swift"),
            encoding: .utf8
        )
        let configuration = try String(
            contentsOf: root.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains("CommandGroup(replacing: .appInfo)"))
        XCTAssertTrue(appSource.contains("orderFrontStandardAboutPanel"))
        XCTAssertTrue(appSource.contains("currentPiVersion"))
        XCTAssertTrue(configuration.contains("PI_CODING_AGENT_VERSION"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
