import XCTest
@testable import PiWork

final class LocalizationTests: XCTestCase {
    @MainActor
    func testEnglishIsTheDefaultAndLanguageChoicePersists() throws {
        let suiteName = "LocalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = LanguageStore(defaults: defaults)

        XCTAssertEqual(store.language, .english)
        XCTAssertEqual(
            AppLanguage.allCases.map(\.rawValue),
            ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es"]
        )

        store.language = .japanese

        XCTAssertEqual(LanguageStore(defaults: defaults).language, .japanese)
    }

    func testEverySupportedLanguageContainsTheCompleteEnglishCatalog() throws {
        let english = try localizationEntries(languageCode: "en")

        XCTAssertGreaterThanOrEqual(english.count, 120)
        XCTAssertEqual(english["settings.title"], "Settings")

        for language in ["zh-Hans", "zh-Hant", "ja", "ko", "es"] {
            let localized = try localizationEntries(languageCode: language)
            XCTAssertEqual(
                Set(localized.keys),
                Set(english.keys),
                "\(language) must contain exactly the English catalog keys"
            )
        }
    }

    func testRuntimeLookupUsesTheRequestedLanguage() {
        XCTAssertEqual(L10n.string("settings.title", language: .english), "Settings")
        XCTAssertEqual(L10n.string("settings.title", language: .simplifiedChinese), "设置")
        XCTAssertEqual(L10n.string("settings.title", language: .japanese), "設定")
    }

    func testLocalizedViewContentIsRecomputedAfterLanguageChanges() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chatSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Chat/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Auth/Views/ModelProviderSettingsView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(chatSource.contains("static var defaults"))
        XCTAssertTrue(
            settingsSource.contains(
                "SettingsSidebar(selection: $selection, language: languageStore.language)"
            )
        )
        XCTAssertTrue(settingsSource.contains("let language: AppLanguage"))
        XCTAssertTrue(chatSource.contains(".lineLimit(3)"))
    }

    func testSettingsSidebarIncludesExperimentsDestination() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Auth/Views/ModelProviderSettingsView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("case experiments"))
        XCTAssertTrue(source.contains("case .experiments: return \"flask\""))
        XCTAssertTrue(source.contains(".modelsAndAuthentication"))
        XCTAssertTrue(source.contains(".experiments"))
        XCTAssertTrue(source.contains("ExperimentsSettingsView()"))
    }

    func testSettingsSidebarIncludesGlobalPersonalPreferencesDestination() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Auth/Views/ModelProviderSettingsView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("case personalPreferences"))
        XCTAssertTrue(source.contains("settings.sidebar.personal_preferences"))
        XCTAssertTrue(source.contains("GlobalAgentInstructionsSettingsView()"))
        XCTAssertTrue(source.contains("AlignedPlaceholderTextEditor("))
        XCTAssertTrue(source.contains("settings.personal_preferences.changes_apply"))
    }

    func testComputerUseExperimentIsComingSoonAndCannotBeEnabled() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Features/Auth/Views/ModelProviderSettingsView.swift"
            ),
            encoding: .utf8
        )
        let experimentsView = try XCTUnwrap(
            source.components(separatedBy: "private struct ExperimentsSettingsView: View {").last?
                .components(separatedBy: "private struct GeneralSettingsView: View {").first
        )

        XCTAssertTrue(experimentsView.contains("settings.experiments.computer_use.title"))
        XCTAssertTrue(experimentsView.contains("settings.experiments.coming_soon"))
        XCTAssertTrue(experimentsView.contains("Toggle(isOn: .constant(false))"))
        XCTAssertTrue(experimentsView.contains(".disabled(true)"))
    }

    func testEveryReferencedLocalizationKeyExistsInTheCatalog() throws {
        let english = try localizationEntries(languageCode: "en")
        let source = try productionSwiftSource()
        let expression = try NSRegularExpression(
            pattern: #"L10n\.(?:string|format)\(\s*\"([^\"]+)\""#
        )
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let referencedKeys = Set<String>(expression.matches(in: source, range: range).compactMap { match in
            guard let keyRange = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[keyRange])
        })

        XCTAssertFalse(referencedKeys.isEmpty)
        XCTAssertEqual(referencedKeys.subtracting(english.keys), Set<String>())
    }

    func testLocalizedFormatPlaceholdersMatchEnglish() throws {
        let english = try localizationEntries(languageCode: "en")
        let expression = try NSRegularExpression(pattern: #"%(?:@|ld|%)"#)

        for language in ["zh-Hans", "zh-Hant", "ja", "ko", "es"] {
            let localized = try localizationEntries(languageCode: language)
            for (key, englishValue) in english {
                XCTAssertEqual(
                    placeholders(in: localized[key] ?? "", using: expression),
                    placeholders(in: englishValue, using: expression),
                    "\(language).lproj has incompatible placeholders for \(key)"
                )
            }
        }
    }

    func testEveryLanguageExplainsTheCompleteAuthenticationJourney() throws {
        let requiredKeys = Set([
            "auth.method.choose",
            "auth.browser.help",
            "auth.browser.open_failed",
            "auth.device.help",
            "auth.device.copied",
            "auth.device.expires_minutes",
            "auth.credentials.title",
            "auth.credentials.help",
            "auth.credentials.open_help",
            "auth.credentials.storage",
            "auth.retry",
            "auth.github.host.title",
            "auth.github.host.help",
            "auth.github.host.github_com",
            "auth.github.host.enterprise",
            "auth.github.host.enterprise_help",
            "auth.github.host.enterprise_label",
            "auth.github.host.enterprise_continue",
            "auth.start_failed",
            "auth.response_failed",
            "auth.cancel_failed",
            "auth.host_restarted",
            "auth.credentials_saved",
            "auth.prompt.api_key",
            "auth.prompt.manual_code",
            "auth.prompt.method",
            "auth.prompt.azure.endpoint",
            "auth.prompt.bedrock.method",
            "auth.prompt.bedrock.profile",
            "auth.prompt.bedrock.configured",
            "auth.prompt.vertex.method",
            "auth.prompt.vertex.credentials_file",
            "auth.prompt.vertex.project",
            "auth.prompt.vertex.location",
            "auth.prompt.cloudflare.account",
            "auth.prompt.cloudflare.gateway",
            "auth.option.browser",
            "auth.option.manual_code",
            "auth.option.bearer_token",
            "auth.option.aws_profile",
            "auth.option.credential_chain",
            "auth.option.oauth",
            "auth.option.api_key",
            "auth.option.adc",
            "auth.option.service_account",
            "providers.status.signed_in",
            "providers.status.credentials_saved",
            "providers.status.not_verified",
            "providers.models_supported",
            "providers.manage",
        ])

        for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es"] {
            let localized = try localizationEntries(languageCode: language)
            XCTAssertTrue(
                requiredKeys.isSubset(of: localized.keys),
                "\(language) is missing authentication guidance"
            )
        }
    }

    func testProductionSwiftDoesNotContainHardcodedCJKUserFacingStrings() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = repositoryRoot.appendingPathComponent("PiWork")
        let files = try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            .filter { $0.hasSuffix(".swift") && $0 != "Core/UI/AppLanguage.swift" }
        let expression = try NSRegularExpression(
            pattern: #"\"[^\"\n]*[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}][^\"\n]*\""#
        )
        var violations: [String] = []

        for relativePath in files {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            if expression.firstMatch(in: source, range: range) != nil {
                violations.append(relativePath)
            }
        }

        XCTAssertEqual(violations, [], "Move user-facing text into localization resources")
    }

    private func localizationEntries(languageCode: String) throws -> [String: String] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("PiWork/Resources/\(languageCode).lproj")
            .appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: url)
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(propertyList as? [String: String])
    }

    private func productionSwiftSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = repositoryRoot.appendingPathComponent("PiWork")
        return try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            .filter { $0.hasSuffix(".swift") }
            .map {
                try String(
                    contentsOf: sourceRoot.appendingPathComponent($0),
                    encoding: .utf8
                )
            }
            .joined(separator: "\n")
    }

    private func placeholders(
        in value: String,
        using expression: NSRegularExpression
    ) -> [String] {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let placeholderRange = Range(match.range, in: value) else { return nil }
            return String(value[placeholderRange])
        }
    }
}
