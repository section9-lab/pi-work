import XCTest
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

    func testCheckerReturnsTheMatchingArchitectureAssetForANewerRelease() async throws {
        let checker = makeChecker(
            statusCode: 200,
            body: releaseJSON(tag: "v0.2.0"),
            currentVersion: "0.1.0",
            architecture: .arm64
        )

        let result = try await checker.check()

        XCTAssertEqual(
            result,
            .updateAvailable(AppUpdate(
                version: "0.2.0",
                downloadURL: try XCTUnwrap(URL(
                    string: "https://github.com/section9-lab/pi-work/releases/download/v0.2.0/PiWork-0.2.0-macos-arm64.dmg"
                ))
            ))
        )
    }

    func testCheckerReportsUpToDateWhenInstalledVersionMatchesLatestRelease() async throws {
        let checker = makeChecker(
            statusCode: 200,
            body: releaseJSON(tag: "v0.1.0"),
            currentVersion: "0.1.0",
            architecture: .arm64
        )

        let result = try await checker.check()

        XCTAssertEqual(result, .upToDate(latestVersion: "0.1.0"))
    }

    func testCheckerReportsUpToDateWhenInstalledVersionIsNewer() async throws {
        let checker = makeChecker(
            statusCode: 200,
            body: releaseJSON(tag: "v0.1.0"),
            currentVersion: "0.2.0",
            architecture: .arm64
        )

        let result = try await checker.check()

        XCTAssertEqual(result, .upToDate(latestVersion: "0.1.0"))
    }

    func testCheckerSelectsTheIntelAsset() async throws {
        let checker = makeChecker(
            statusCode: 200,
            body: releaseJSON(tag: "v0.2.0"),
            currentVersion: "0.1.0",
            architecture: .x86_64
        )

        let result = try await checker.check()

        guard case let .updateAvailable(update) = result else {
            return XCTFail("Expected an available update")
        }
        XCTAssertTrue(update.downloadURL.lastPathComponent.hasSuffix("-macos-x86_64.dmg"))
    }

    func testCheckerRejectsANewerReleaseWithoutACompatibleDMG() async {
        let body = """
        {
          "tag_name": "v0.2.0",
          "html_url": "https://github.com/section9-lab/pi-work/releases/tag/v0.2.0",
          "assets": []
        }
        """
        let checker = makeChecker(
            statusCode: 200,
            body: body,
            currentVersion: "0.1.0",
            architecture: .arm64
        )

        do {
            _ = try await checker.check()
            XCTFail("Expected a compatible-asset error")
        } catch {
            XCTAssertEqual(error as? AppUpdateCheckError, .compatibleAssetNotFound)
        }
    }

    func testCheckerRejectsAnUnsuccessfulGitHubResponse() async {
        let checker = makeChecker(
            statusCode: 503,
            body: "{}",
            currentVersion: "0.1.0",
            architecture: .arm64
        )

        do {
            _ = try await checker.check()
            XCTFail("Expected an HTTP response error")
        } catch {
            XCTAssertEqual(error as? AppUpdateCheckError, .server(statusCode: 503))
        }
    }

    func testCheckerUsesTheGitHubReleaseAPIHeaders() async throws {
        var receivedRequest: URLRequest?
        let checker = makeChecker(
            statusCode: 200,
            body: releaseJSON(tag: "v0.1.0"),
            currentVersion: "0.1.0",
            architecture: .arm64,
            inspectRequest: { receivedRequest = $0 }
        )

        _ = try await checker.check()

        XCTAssertEqual(receivedRequest?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(receivedRequest?.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
    }

    @MainActor
    func testControllerPublishesAnAvailableUpdateAndOpensItsDownload() async throws {
        let downloadURL = try XCTUnwrap(URL(string: "https://example.com/PiWork.dmg"))
        let update = AppUpdate(
            version: "0.2.0",
            downloadURL: downloadURL
        )
        var openedURL: URL?
        let controller = AppUpdateController(
            currentVersion: "0.1.0",
            check: { .updateAvailable(update) },
            openURL: {
                openedURL = $0
                return true
            }
        )

        await controller.checkForUpdates()

        XCTAssertEqual(controller.state, .updateAvailable(update))
        XCTAssertTrue(controller.openAvailableUpdate())
        XCTAssertEqual(openedURL, downloadURL)
    }

    @MainActor
    func testControllerPublishesFailureWhenCheckingThrows() async {
        let controller = AppUpdateController(
            currentVersion: "0.1.0",
            check: { throw AppUpdateCheckError.invalidResponse },
            openURL: { _ in true }
        )

        await controller.checkForUpdates()

        XCTAssertEqual(controller.state, .failed)
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

    private func makeChecker(
        statusCode: Int,
        body: String,
        currentVersion: String,
        architecture: AppArchitecture,
        inspectRequest: ((URLRequest) -> Void)? = nil
    ) -> GitHubReleaseUpdateChecker {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        UpdateURLProtocolStub.requestHandler = { request in
            inspectRequest?(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(body.utf8))
        }
        return GitHubReleaseUpdateChecker(
            currentVersion: currentVersion,
            architecture: architecture,
            session: session
        )
    }

    private func releaseJSON(tag: String) -> String {
        let version = String(tag.drop(while: { $0 == "v" || $0 == "V" }))
        return """
        {
          "tag_name": "\(tag)",
          "html_url": "https://github.com/section9-lab/pi-work/releases/tag/\(tag)",
          "assets": [
            {
              "name": "PiWork-\(version)-macos-arm64.dmg",
              "browser_download_url": "https://github.com/section9-lab/pi-work/releases/download/\(tag)/PiWork-\(version)-macos-arm64.dmg"
            },
            {
              "name": "PiWork-\(version)-macos-x86_64.dmg",
              "browser_download_url": "https://github.com/section9-lab/pi-work/releases/download/\(tag)/PiWork-\(version)-macos-x86_64.dmg"
            }
          ]
        }
        """
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class UpdateURLProtocolStub: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.requestHandler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
