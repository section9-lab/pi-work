import XCTest
@testable import PiWork

final class AgentHostExecutableTests: XCTestCase {
    func testAgentSettingsDirectoryLivesInPiWorkApplicationSupport() {
        let applicationSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)

        let result = AgentHostExecutable.agentDirectoryURL(
            applicationSupportDirectory: applicationSupport
        )

        XCTAssertEqual(
            result.path,
            applicationSupport.appendingPathComponent("pi-work/Agent").path
        )
        XCTAssertFalse(result.path.contains("/.pi/"))
    }

    func testAuthenticationFileLivesInPiWorkApplicationSupport() {
        let applicationSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)

        let result = AgentHostExecutable.authenticationFileURL(
            applicationSupportDirectory: applicationSupport
        )

        XCTAssertEqual(
            result.path,
            applicationSupport.appendingPathComponent("pi-work/Agent/auth.json").path
        )
        XCTAssertFalse(result.path.contains("/.pi/"))
    }

    func testGlobalInstructionsFileLivesInTheIsolatedAgentDirectory() {
        let applicationSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)

        let result = AgentHostExecutable.globalInstructionsFileURL(
            applicationSupportDirectory: applicationSupport
        )

        XCTAssertEqual(
            result.path,
            applicationSupport.appendingPathComponent("pi-work/Agent/AGENTS.md").path
        )
        XCTAssertFalse(result.path.contains("/.pi/"))
    }

    func testGlobalInstructionsDocumentTreatsAMissingFileAsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("Agent/AGENTS.md")
        defer { try? FileManager.default.removeItem(at: root) }

        let document = GlobalAgentInstructionsDocument(fileURL: fileURL)

        XCTAssertEqual(try document.load(), "")
    }

    func testGlobalInstructionsDocumentCreatesItsDirectoryAndSavesAtomically() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("Agent/AGENTS.md")
        defer { try? FileManager.default.removeItem(at: root) }
        let document = GlobalAgentInstructionsDocument(fileURL: fileURL)
        let instructions = "# Personal preferences\n\nKeep answers concise.\n"

        try document.save(instructions)

        XCTAssertEqual(try document.load(), instructions)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testGlobalInstructionsStoreTracksChangesAndCanRevert() {
        let document = GlobalAgentInstructionsDocument(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("AGENTS.md")
        )
        let store = GlobalAgentInstructionsStore(document: document)

        store.replaceLoadedContents("Original")
        XCTAssertFalse(store.hasUnsavedChanges)

        store.draft = "Updated"
        XCTAssertTrue(store.hasUnsavedChanges)

        store.revert()
        XCTAssertEqual(store.draft, "Original")
        XCTAssertFalse(store.hasUnsavedChanges)
    }

    func testBundledHostSharesItsIsolatedAgentDirectoryWithExtensions() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Core/Agent/AgentHostService.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("\"PI_CODING_AGENT_DIR\": agentDirectory.path"))
    }

    func testBuildStagesTheSelfContainedAgentHostAndBunPackageManager() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configuration = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(configuration.contains("Stage bundled agent host"))
        XCTAssertTrue(configuration.contains("Stage bundled Bun package manager"))
        XCTAssertTrue(configuration.contains("scripts/fetch-bun-binary.sh"))
        XCTAssertFalse(configuration.contains("Stage bundled pi agent binary"))
    }

    func testBuildStagesNativeHTMLExportAssetsBesideEachAgentHost() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configuration = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(configuration.contains("dist/core/export-html"))
        XCTAssertTrue(configuration.contains("$HOST_DESTINATION_DIR/export-html"))
        XCTAssertTrue(configuration.contains("cp -R \"$HOST_EXPORT_ASSETS_SOURCE/.\""))
    }

    func testBuildStagesNativeThemeAssetsBesideEachAgentHost() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configuration = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(configuration.contains("dist/modes/interactive/theme"))
        XCTAssertTrue(configuration.contains("$HOST_DESTINATION_DIR/theme"))
        XCTAssertTrue(configuration.contains("cp -R \"$HOST_THEME_ASSETS_SOURCE/.\""))
    }

    func testPiCodingAgentVersionIsReadFromTheBundledHostMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = root.appendingPathComponent("PiWork.app", isDirectory: true)
        let versionURL = appURL.appendingPathComponent(
            "Contents/Helpers/AgentHost/pi-coding-agent-version",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: versionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "0.84.1\n".write(to: versionURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(AgentHostExecutable.piCodingAgentVersion(in: appURL), "0.84.1")
    }

    func testPiCodingAgentVersionIsNilWhenBundledMetadataIsMissing() {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("PiWork.app", isDirectory: true)

        XCTAssertNil(AgentHostExecutable.piCodingAgentVersion(in: appURL))
    }

    func testResolveFindsOnlyAnExecutableInContentsHelpers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = root.appendingPathComponent("PiWork.app", isDirectory: true)
        let helperURL = appURL.appendingPathComponent(
            "Contents/Helpers/AgentHost/arm64/pi-work-agent-host",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: helperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: helperURL)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(AgentHostExecutable.resolve(in: appURL, architecture: "arm64"))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperURL.path
        )

        XCTAssertEqual(
            AgentHostExecutable.resolve(in: appURL, architecture: "arm64"),
            helperURL
        )
    }

    func testResolveBunFindsOnlyAnExecutableInContentsHelpers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = root.appendingPathComponent("PiWork.app", isDirectory: true)
        let bunURL = appURL.appendingPathComponent(
            "Contents/Helpers/Bun/arm64/bun",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: bunURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: bunURL)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(AgentHostExecutable.resolveBun(in: appURL, architecture: "arm64"))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bunURL.path
        )

        XCTAssertEqual(
            AgentHostExecutable.resolveBun(in: appURL, architecture: "arm64"),
            bunURL
        )
    }

    func testBundledExecutablesResolveAfterAppIsMoved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("PiWork.app", isDirectory: true)
        let movedAppURL = root.appendingPathComponent("移动后的 App.app", isDirectory: true)
        let hostPath = "Contents/Helpers/AgentHost/arm64/pi-work-agent-host"
        let bunPath = "Contents/Helpers/Bun/arm64/bun"
        for path in [hostPath, bunPath] {
            let helperURL = appURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: helperURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: helperURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: helperURL.path
            )
        }

        try FileManager.default.moveItem(at: appURL, to: movedAppURL)

        XCTAssertEqual(
            AgentHostExecutable.resolve(in: movedAppURL, architecture: "arm64"),
            movedAppURL.appendingPathComponent(hostPath)
        )
        XCTAssertEqual(
            AgentHostExecutable.resolveBun(in: movedAppURL, architecture: "arm64"),
            movedAppURL.appendingPathComponent(bunPath)
        )
        XCTAssertNil(AgentHostExecutable.resolve(in: appURL, architecture: "arm64"))
        XCTAssertNil(AgentHostExecutable.resolveBun(in: appURL, architecture: "arm64"))
    }
}
