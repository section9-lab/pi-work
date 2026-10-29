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

    func testRateLimitedAPIUsesThePublicReleaseWithoutDownloadingTheDMG() async throws {
        for architecture in [AppArchitecture.arm64, .x86_64] {
            var requests: [URLRequest] = []
            let checker = makeRoutedChecker(currentVersion: "0.1.0", architecture: architecture) { request in
                requests.append(request)
                if request.url?.host == "api.github.com" {
                    return self.response(request.url!, status: 403, headers: ["X-RateLimit-Remaining": "0"])
                }
                if request.url == GitHubReleaseUpdateChecker.publicReleaseURL {
                    return self.response(URL(string: "https://github.com/section9-lab/pi-work/releases/tag/v0.2.0")!)
                }
                return self.response(URL(string: "https://release-assets.githubusercontent.com/installer.dmg")!)
            }

            let result = try await checker.check()

            XCTAssertEqual(result, .updateAvailable(AppUpdate(version: "0.2.0", downloadURL: URL(
                string: "https://github.com/section9-lab/pi-work/releases/download/v0.2.0/PiWork-0.2.0-macos-\(architecture.rawValue).dmg"
            )!)))
            XCTAssertEqual(requests.map(\.httpMethod), ["GET", "HEAD", "HEAD"])
        }
    }

    func testPublicFallbackReportsInstalledVersionAsUpToDate() async throws {
        var requestCount = 0
        let checker = makeRoutedChecker(currentVersion: "0.2.0") { request in
            requestCount += 1
            return self.response(request.url?.host == "api.github.com" ? request.url! : URL(
                string: "https://github.com/section9-lab/pi-work/releases/tag/v0.2.0"
            )!, status: request.url?.host == "api.github.com" ? 429 : 200)
        }

        let result = try await checker.check()

        XCTAssertEqual(result, .upToDate(latestVersion: "0.2.0"))
        XCTAssertEqual(requestCount, 2)
    }

    func testTransportFailureFallsBackToThePublicRelease() async throws {
        let checker = makeRoutedChecker(currentVersion: "0.2.0") { request in
            if request.url?.host == "api.github.com" { throw URLError(.cannotConnectToHost) }
            return self.response(URL(string: "https://github.com/section9-lab/pi-work/releases/tag/v0.2.0")!)
        }

        let result = try await checker.check()

        XCTAssertEqual(result, .upToDate(latestVersion: "0.2.0"))
    }

    func testPublicFallbackRejectsMissingInstallers() async {
        let checker = makeRoutedChecker(currentVersion: "0.1.0") { request in
            if request.url?.host == "api.github.com" { return self.response(request.url!, status: 429) }
            if request.url == GitHubReleaseUpdateChecker.publicReleaseURL {
                return self.response(URL(string: "https://github.com/section9-lab/pi-work/releases/tag/v0.2.0")!)
            }
            return self.response(request.url!, status: 404)
        }

        do {
            _ = try await checker.check()
            XCTFail("Missing installer must not be offered")
        } catch {
            XCTAssertEqual(error as? AppUpdateCheckError, .compatibleAssetNotFound)
        }
    }

    func testPublicFallbackRejectsForeignAndNonAppReleaseRedirects() async {
        for address in [
            "https://github.com/another-owner/pi-work/releases/tag/v0.2.0",
            "https://example.com/section9-lab/pi-work/releases/tag/v0.2.0",
            "http://github.com/section9-lab/pi-work/releases/tag/v0.2.0",
            "https://github.com/section9-lab/pi-work/releases/tag/runtime-v1.0.0",
            "https://github.com/section9-lab/pi-work/releases/latest"
        ] {
            var requests = 0
            let checker = makeRoutedChecker(currentVersion: "0.1.0") { request in
                requests += 1
                return self.response(request.url?.host == "api.github.com" ? request.url! : URL(string: address)!,
                                     status: request.url?.host == "api.github.com" ? 429 : 200)
            }
            do {
                _ = try await checker.check()
                XCTFail("Untrusted redirect must not produce an update: \(address)")
            } catch {
                XCTAssertEqual(error as? AppUpdateCheckError, .rateLimited)
                XCTAssertEqual(requests, 2)
            }
        }
    }

    func testPublicFallbackRejectsUntrustedAssetRedirects() async {
        let checker = makeRoutedChecker(currentVersion: "0.1.0") { request in
            if request.url?.host == "api.github.com" { return self.response(request.url!, status: 429) }
            if request.url == GitHubReleaseUpdateChecker.publicReleaseURL {
                return self.response(URL(string: "https://github.com/section9-lab/pi-work/releases/tag/v0.2.0")!)
            }
            return self.response(URL(string: "https://example.com/installer.dmg")!)
        }

        do {
            _ = try await checker.check()
            XCTFail("Untrusted asset must not be offered")
        } catch {
            XCTAssertEqual(error as? AppUpdateCheckError, .rateLimited)
        }
    }

    func testCancelledRequestDoesNotStartTheFallback() async {
        var requests = 0
        let checker = makeRoutedChecker(currentVersion: "0.1.0") { _ in
            requests += 1
            throw URLError(.cancelled)
        }

        do {
            _ = try await checker.check()
            XCTFail("Cancelled check must stop")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
            XCTAssertEqual(requests, 1)
        }
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
        XCTAssertEqual(controller.failureDescription, AppUpdateCheckError.invalidResponse.localizedDescription)
    }

    @MainActor
    func testControllerShowsTheRateLimitReasonAndCanRetry() async {
        var checks = 0
        let controller = AppUpdateController(currentVersion: "0.1.0", check: {
            checks += 1
            if checks == 1 { throw AppUpdateCheckError.rateLimited }
            return .upToDate(latestVersion: "0.1.0")
        }, openURL: { _ in true })

        await controller.checkForUpdates()
        XCTAssertEqual(controller.failureDescription, L10n.string("update.error.rate_limited"))
        await controller.checkForUpdates()
        XCTAssertEqual(controller.state, .upToDate(latestVersion: "0.1.0"))
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

    private func makeRoutedChecker(
        currentVersion: String,
        architecture: AppArchitecture = .arm64,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> GitHubReleaseUpdateChecker {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateURLProtocolStub.self]
        UpdateURLProtocolStub.requestHandler = handler
        return GitHubReleaseUpdateChecker(currentVersion: currentVersion, architecture: architecture,
                                           session: URLSession(configuration: configuration))
    }

    private func response(_ url: URL, status: Int = 200, headers: [String: String] = [:]) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, Data())
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
