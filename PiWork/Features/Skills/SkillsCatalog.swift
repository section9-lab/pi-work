import Foundation
import Combine
import AppKit

struct SkillsCatalogItem: Codable, Equatable, Identifiable {
    let source: String
    let slug: String
    let name: String
    let installs: Int
    let isOfficial: Bool
    let summary: String?

    /// Set once the skill page answered without a usable summary — a missing
    /// section, a 404, or a body we cannot parse. Persisted with the snapshot so
    /// a relaunch does not spend another round trip on a page that will never
    /// produce a description.
    let summaryUnavailable: Bool

    init(
        source: String,
        slug: String,
        name: String,
        installs: Int,
        isOfficial: Bool,
        summary: String? = nil,
        summaryUnavailable: Bool = false
    ) {
        self.source = source
        self.slug = slug
        self.name = name
        self.installs = installs
        self.isOfficial = isOfficial
        self.summary = summary
        self.summaryUnavailable = summaryUnavailable
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case slug
        case name
        case installs
        case isOfficial
        case summary
        case summaryUnavailable
    }

    /// Snapshots written before the flag existed must still decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        slug = try container.decode(String.self, forKey: .slug)
        name = try container.decode(String.self, forKey: .name)
        installs = try container.decode(Int.self, forKey: .installs)
        isOfficial = try container.decode(Bool.self, forKey: .isOfficial)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        summaryUnavailable = try container.decodeIfPresent(
            Bool.self,
            forKey: .summaryUnavailable
        ) ?? false
    }

    var id: String { "\(source)/\(slug)" }

    /// Whether the card should still ask the site for a description.
    var needsSummary: Bool { summary == nil && !summaryUnavailable }

    var pageURL: URL? {
        let path = source.contains("/") ? id : "site/\(id)"
        return URL(string: "https://skills.sh/\(path)")
    }

    func withSummary(_ summary: String) -> SkillsCatalogItem {
        SkillsCatalogItem(
            source: source,
            slug: slug,
            name: name,
            installs: installs,
            isOfficial: isOfficial,
            summary: summary
        )
    }

    func withSummaryUnavailable() -> SkillsCatalogItem {
        SkillsCatalogItem(
            source: source,
            slug: slug,
            name: name,
            installs: installs,
            isOfficial: isOfficial,
            summary: nil,
            summaryUnavailable: true
        )
    }

    /// Forgets a "no description" verdict so the card asks the site again.
    func withSummaryReload() -> SkillsCatalogItem {
        SkillsCatalogItem(
            source: source,
            slug: slug,
            name: name,
            installs: installs,
            isOfficial: isOfficial,
            summary: summary,
            summaryUnavailable: false
        )
    }
}

struct SkillsCLIInstallCommand: Equatable {
    let executableName = "npx"
    let arguments: [String]

    init(item: SkillsCatalogItem) {
        arguments = [
            "-y", "skills", "add", item.source,
            "--skill", item.slug,
            "--global", "--agent", "pi", "--yes"
        ]
    }
}

enum SkillsCatalogCategory: String, CaseIterable, Codable {
    case all
    case official
    case development
    case design
    case testing
    case data
    case marketing
    case productivity

    var title: String {
        switch self {
        case .all: return L10n.string("skills.category.all")
        case .official: return L10n.string("skills.category.official")
        case .development: return L10n.string("skills.category.development")
        case .design: return L10n.string("skills.category.design")
        case .testing: return L10n.string("skills.category.testing")
        case .data: return L10n.string("skills.category.data")
        case .marketing: return L10n.string("skills.category.marketing")
        case .productivity: return L10n.string("skills.category.productivity")
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .official: return "checkmark.seal"
        case .development: return "hammer"
        case .design: return "paintbrush"
        case .testing: return "checkmark.circle"
        case .data: return "cylinder.split.1x2"
        case .marketing: return "megaphone"
        case .productivity: return "bolt"
        }
    }

    func includes(_ item: SkillsCatalogItem) -> Bool {
        switch self {
        case .all:
            return true
        case .official:
            return item.isOfficial
        default:
            return Self.inferred(for: item) == self
        }
    }

    static func inferred(for item: SkillsCatalogItem) -> SkillsCatalogCategory {
        let text = "\(item.name) \(item.slug) \(item.source)".lowercased()
        let tokens = Set(
            text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        )
        let rules: [(SkillsCatalogCategory, [String])] = [
            (.design, ["design", "ui", "ux", "figma", "typography", "color", "animation"]),
            (.testing, ["test", "testing", "tdd", "playwright", "cypress", "vitest", "jest", "qa"]),
            (.data, ["data", "database", "sql", "postgres", "supabase", "firebase", "neon", "analytics"]),
            (.marketing, ["marketing", "seo", "content", "copywriting", "sales", "social", "growth"]),
            (.development, [
                "build", "code", "codebase", "frontend", "backend", "react", "swift", "nextjs", "vue",
                "typescript", "javascript", "python", "golang", "rust", "api", "mobile", "ios", "android"
            ])
        ]

        for (category, keywords) in rules where keywords.contains(where: tokens.contains) {
            return category
        }
        return .productivity
    }
}

struct SkillsCatalogPageParser {
    func parse(_ data: Data) throws -> [SkillsCatalogItem] {
        guard let html = String(data: data, encoding: .utf8) else {
            throw SkillsCatalogParsingError.invalidEncoding
        }

        let payload = try decodedFlightPayload(from: html)
        let objectExpression = try NSRegularExpression(
            pattern: #"\{"source":"(?:\\.|[^"])*","skillId":"(?:\\.|[^"])*","name":"(?:\\.|[^"])*","installs":\d+[^{}]*\}"#
        )
        let range = NSRange(payload.startIndex..<payload.endIndex, in: payload)
        var seenIDs: Set<String> = []
        var items: [SkillsCatalogItem] = []

        for match in objectExpression.matches(in: payload, range: range) {
            guard
                let objectRange = Range(match.range, in: payload),
                let objectData = payload[objectRange].data(using: .utf8),
                let rawSkill = try? JSONDecoder().decode(RawSkill.self, from: objectData)
            else { continue }

            let item = SkillsCatalogItem(
                source: rawSkill.source,
                slug: rawSkill.skillId,
                name: rawSkill.name,
                installs: rawSkill.installs,
                isOfficial: rawSkill.isOfficial ?? false
            )
            guard seenIDs.insert(item.id).inserted else { continue }
            items.append(item)
        }

        guard !items.isEmpty else { throw SkillsCatalogParsingError.noSkills }
        return items
    }

    private func decodedFlightPayload(from html: String) throws -> String {
        let flightExpression = try NSRegularExpression(
            pattern: #"self\.__next_f\.push\((\[[\s\S]*?\])\)</script>"#
        )
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let payloads = flightExpression.matches(in: html, range: range).compactMap { match -> String? in
            guard
                let jsonRange = Range(match.range(at: 1), in: html),
                let jsonData = html[jsonRange].data(using: .utf8),
                let array = try? JSONSerialization.jsonObject(with: jsonData) as? [Any],
                array.count > 1
            else { return nil }
            return array[1] as? String
        }

        return payloads.isEmpty ? html : payloads.joined()
    }
}

struct SkillsCatalogSearchParser {
    func parse(_ data: Data) throws -> [SkillsCatalogItem] {
        let response = try JSONDecoder().decode(RawSearchResponse.self, from: data)
        return response.skills.map { skill in
            SkillsCatalogItem(
                source: skill.source,
                slug: skill.skillId,
                name: skill.name,
                installs: skill.installs,
                isOfficial: skill.isOfficial ?? false
            )
        }
    }
}

struct SkillsSummaryPageParser {
    /// Skill pages publish their description in one of two places: a rendered
    /// `Summary` block, or — for pages without that block — the document's
    /// `description` meta tag, which every skill page carries. Reading only the
    /// first form left most of the catalog looking undescribed.
    func parse(_ data: Data) throws -> String {
        guard let html = String(data: data, encoding: .utf8) else {
            throw SkillsCatalogParsingError.invalidEncoding
        }

        if let summary = summarySection(in: html) {
            return summary
        }
        if let description = metaDescription(in: html) {
            return description
        }
        throw SkillsCatalogParsingError.noSummary
    }

    private func summarySection(in html: String) -> String? {
        guard
            let headerExpression = try? NSRegularExpression(
                pattern: #">\s*Summary\s*</div>"#,
                options: .caseInsensitive
            ),
            let headerMatch = headerExpression.firstMatch(
                in: html,
                range: NSRange(html.startIndex..<html.endIndex, in: html)
            ),
            let headerRange = Range(headerMatch.range, in: html)
        else { return nil }

        let section = String(html[headerRange.upperBound...])
        guard
            let paragraphExpression = try? NSRegularExpression(
                pattern: #"<p(?:\s[^>]*)?>([\s\S]*?)</p>"#,
                options: .caseInsensitive
            ),
            let paragraphMatch = paragraphExpression.firstMatch(
                in: section,
                range: NSRange(section.startIndex..<section.endIndex, in: section)
            ),
            let paragraphRange = Range(paragraphMatch.range(at: 1), in: section)
        else { return nil }

        let stripped = String(section[paragraphRange]).strippingHTMLTags()
        let normalized = normalize(stripped)
        guard !normalized.isEmpty, !isPlaceholder(normalized) else { return nil }
        return firstSentence(in: normalized)
    }

    /// Falls back to `<meta name="description">` (or its Open Graph and Twitter
    /// twins). Skill pages that publish nothing real fill this tag with a
    /// generated "… — an installable skill for AI agents" sentence, so that
    /// wording is treated as absent rather than shown as content.
    private func metaDescription(in html: String) -> String? {
        guard
            let tagExpression = try? NSRegularExpression(
                pattern: #"<meta\b[^>]*>"#,
                options: .caseInsensitive
            )
        else { return nil }

        var candidates: [String: String] = [:]
        let matches = tagExpression.matches(
            in: html,
            range: NSRange(html.startIndex..<html.endIndex, in: html)
        )
        for match in matches {
            guard
                let tagRange = Range(match.range, in: html),
                let attributes = metaAttributes(in: String(html[tagRange])),
                let key = (attributes["name"] ?? attributes["property"])?.lowercased(),
                descriptionKeys.contains(key),
                let content = attributes["content"]
            else { continue }
            candidates[key] = content
        }

        for key in ["description", "og:description", "twitter:description"] {
            guard let content = candidates[key] else { continue }
            let normalized = normalize(decodeHTMLEntities(in: content))
            guard !normalized.isEmpty, !isPlaceholder(normalized) else { continue }
            return normalized
        }
        return nil
    }

    private var descriptionKeys: Set<String> {
        ["description", "og:description", "twitter:description"]
    }

    private func metaAttributes(in tag: String) -> [String: String]? {
        guard
            let expression = try? NSRegularExpression(
                pattern: #"([a-zA-Z:-]+)\s*=\s*"([^"]*)""#
            )
        else { return nil }

        var attributes: [String: String] = [:]
        for match in expression.matches(
            in: tag,
            range: NSRange(tag.startIndex..<tag.endIndex, in: tag)
        ) {
            guard
                let nameRange = Range(match.range(at: 1), in: tag),
                let valueRange = Range(match.range(at: 2), in: tag)
            else { continue }
            attributes[String(tag[nameRange]).lowercased()] = String(tag[valueRange])
        }
        return attributes.isEmpty ? nil : attributes
    }

    /// skill.sh generates two flavours of filler for pages that publish no real
    /// description — one in the meta tag, one in the Summary block. Neither is
    /// content, so the card should say the description is missing instead of
    /// showing generated boilerplate.
    private func isPlaceholder(_ text: String) -> Bool {
        if text.contains("an installable skill for AI agents") {
            return true
        }
        guard
            let expression = try? NSRegularExpression(
                pattern: #"^Install the .{0,80} skill for your AI agent"#,
                options: .caseInsensitive
            )
        else { return false }
        return expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) != nil
    }

    private func normalize(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func firstSentence(in text: String) -> String {
        let terminators = CharacterSet(charactersIn: ".!?。！？")
        for index in text.indices where text[index].unicodeScalars.allSatisfy(terminators.contains) {
            let nextIndex = text.index(after: index)
            if nextIndex == text.endIndex || text[nextIndex].isWhitespace {
                return String(text[...index])
            }
        }
        return text
    }

    private func decodeHTMLEntities(in text: String) -> String {
        [
            ("&nbsp;", " "),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&#x27;", "'"),
            ("&apos;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&amp;", "&")
        ].reduce(text) { result, entity in
            result.replacingOccurrences(of: entity.0, with: entity.1)
        }
    }
}

private extension String {
    func strippingHTMLTags() -> String {
        guard
            let expression = try? NSRegularExpression(pattern: #"<[^>]+>"#)
        else { return self }
        return expression.stringByReplacingMatches(
            in: self,
            range: NSRange(startIndex..<endIndex, in: self),
            withTemplate: ""
        )
    }
}

struct SkillsCatalogFilter {
    let query: String
    let category: SkillsCatalogCategory

    func apply(to items: [SkillsCatalogItem]) -> [SkillsCatalogItem] {
        let terms = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \Character.isWhitespace)

        return items.filter { item in
            guard category.includes(item) else { return false }
            guard !terms.isEmpty else { return true }
            let searchableText = "\(item.name) \(item.slug) \(item.source)".lowercased()
            return terms.allSatisfy { searchableText.contains($0) }
        }
    }
}

struct SkillsCatalogCachePolicy {
    let maxAge: TimeInterval

    init(maxAge: TimeInterval = 6 * 60 * 60) {
        self.maxAge = maxAge
    }

    func shouldRefresh(_ snapshot: SkillsCatalogSnapshot?, now: Date) -> Bool {
        guard let snapshot, !snapshot.items.isEmpty else { return true }
        return now.timeIntervalSince(snapshot.fetchedAt) >= maxAge
    }
}

struct SkillsCatalogSnapshot: Codable, Equatable {
    /// Bumped whenever the description reader learns a new place to look. A
    /// snapshot written by an older reader cannot be trusted to declare a skill
    /// undescribed, so those verdicts are dropped when it loads.
    static let currentSummaryVersion = 1

    let items: [SkillsCatalogItem]
    let fetchedAt: Date
    let summaryVersion: Int

    init(
        items: [SkillsCatalogItem],
        fetchedAt: Date,
        summaryVersion: Int = SkillsCatalogSnapshot.currentSummaryVersion
    ) {
        self.items = items
        self.fetchedAt = fetchedAt
        self.summaryVersion = summaryVersion
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case fetchedAt
        case summaryVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([SkillsCatalogItem].self, forKey: .items)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        summaryVersion = try container.decodeIfPresent(Int.self, forKey: .summaryVersion) ?? 0
    }

    /// Re-asks for descriptions that a previous build gave up on.
    func withCurrentSummaryVersion() -> SkillsCatalogSnapshot {
        guard summaryVersion < Self.currentSummaryVersion else { return self }
        return SkillsCatalogSnapshot(
            items: items.map { $0.withSummaryReload() },
            fetchedAt: fetchedAt
        )
    }
}

private struct RawSkill: Decodable {
    let source: String
    let skillId: String
    let name: String
    let installs: Int
    let isOfficial: Bool?
}

private struct RawSearchResponse: Decodable {
    let skills: [RawSkill]
}

enum SkillsCatalogParsingError: LocalizedError {
    case invalidEncoding
    case noSkills
    case noSummary

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return L10n.string("skills.error.unreadable_response")
        case .noSkills:
            return L10n.string("skills.error.catalog_parse")
        case .noSummary:
            return L10n.string("skills.error.summary_parse")
        }
    }
}

protocol SkillsCatalogFetching {
    func fetchSkills(ignoringCache: Bool) async throws -> [SkillsCatalogItem]
}

protocol SkillsCatalogSearching {
    func searchSkills(query: String) async throws -> [SkillsCatalogItem]
}

protocol SkillsSummaryFetching {
    func fetchSummary(for item: SkillsCatalogItem) async throws -> String
}

protocol SkillsCatalogCaching {
    func load() throws -> SkillsCatalogSnapshot?
    func save(_ snapshot: SkillsCatalogSnapshot) throws
}

struct RemoteSkillsCatalogClient: SkillsCatalogFetching {
    let session: URLSession
    let parser: SkillsCatalogPageParser

    init(
        session: URLSession = .shared,
        parser: SkillsCatalogPageParser = SkillsCatalogPageParser()
    ) {
        self.session = session
        self.parser = parser
    }

    func fetchSkills(ignoringCache: Bool) async throws -> [SkillsCatalogItem] {
        guard let url = URL(string: "https://skills.sh/") else {
            throw SkillsCatalogNetworkError.invalidURL
        }
        var request = URLRequest(
            url: url,
            cachePolicy: ignoringCache ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy,
            timeoutInterval: 30
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            throw SkillsCatalogNetworkError.invalidResponse
        }
        return try parser.parse(data)
    }
}

struct RemoteSkillsCatalogSearchClient: SkillsCatalogSearching {
    let session: URLSession
    let parser: SkillsCatalogSearchParser

    init(
        session: URLSession = .shared,
        parser: SkillsCatalogSearchParser = SkillsCatalogSearchParser()
    ) {
        self.session = session
        self.parser = parser
    }

    func searchSkills(query: String) async throws -> [SkillsCatalogItem] {
        guard let url = Self.searchURL(query: query) else {
            throw SkillsCatalogNetworkError.invalidURL
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: 30
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            throw SkillsCatalogNetworkError.invalidResponse
        }
        return try parser.parse(data)
    }

    static func searchURL(query: String) -> URL? {
        var components = URLComponents(string: "https://www.skills.sh/api/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "100")
        ]
        return components?.url
    }
}

struct RemoteSkillsSummaryClient: SkillsSummaryFetching {
    let session: URLSession
    let parser: SkillsSummaryPageParser

    init(
        session: URLSession = .shared,
        parser: SkillsSummaryPageParser = SkillsSummaryPageParser()
    ) {
        self.session = session
        self.parser = parser
    }

    func fetchSummary(for item: SkillsCatalogItem) async throws -> String {
        guard let url = item.pageURL else {
            throw SkillsCatalogNetworkError.invalidURL
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .useProtocolCachePolicy,
            // A page that has not answered in twelve seconds is not worth
            // holding a grid slot for; the card falls back and the next visit
            // retries it.
            timeoutInterval: 12
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SkillsCatalogNetworkError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SkillsCatalogNetworkError.httpStatus(httpResponse.statusCode)
        }
        return try parser.parse(data)
    }
}

struct DiskSkillsCatalogCache: SkillsCatalogCaching {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> SkillsCatalogSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(
            SkillsCatalogSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
    }

    func save(_ snapshot: SkillsCatalogSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }

    private static var defaultFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pi-work/Cache/skills-catalog-v1.json")
    }
}

/// Caps how many skill pages are open at once. Descriptions only exist on the
/// per-skill page, so a grid of 120 cards used to open 120 HTML requests and
/// the ones the reader was actually looking at had to queue behind the rest.
actor SkillsSummaryGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        active += 1
    }

    func release() {
        guard active > 0 else { return }
        active -= 1
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}

@MainActor
final class SkillsCatalogStore: ObservableObject {
    @Published private(set) var items: [SkillsCatalogItem] = []
    @Published private(set) var searchResults: [SkillsCatalogItem] = []
    @Published private(set) var searchQuery = ""
    @Published private(set) var isInitialLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var searchErrorMessage: String?
    @Published private(set) var lastUpdated: Date?

    private let client: SkillsCatalogFetching
    private let searchClient: SkillsCatalogSearching
    private let summaryClient: SkillsSummaryFetching
    private let cache: SkillsCatalogCaching
    private let cachePolicy: SkillsCatalogCachePolicy
    private let summaryGate = SkillsSummaryGate(limit: 4)
    private var didLoad = false
    private var loadingSummaryIDs: Set<String> = []
    private var searchCache: [String: [SkillsCatalogItem]] = [:]
    /// Descriptions keyed by slug. The same skill is republished under several
    /// owners, and some of those publishers ship an empty page, so a card with
    /// nothing of its own borrows from a sibling that already has the text.
    private var summariesBySlug: [String: String] = [:]

    init(
        client: SkillsCatalogFetching = RemoteSkillsCatalogClient(),
        searchClient: SkillsCatalogSearching = RemoteSkillsCatalogSearchClient(),
        summaryClient: SkillsSummaryFetching = RemoteSkillsSummaryClient(),
        cache: SkillsCatalogCaching = DiskSkillsCatalogCache(),
        cachePolicy: SkillsCatalogCachePolicy = SkillsCatalogCachePolicy()
    ) {
        self.client = client
        self.searchClient = searchClient
        self.summaryClient = summaryClient
        self.cache = cache
        self.cachePolicy = cachePolicy
    }

    func loadIfNeeded(now: Date = Date()) async {
        guard !didLoad else { return }
        didLoad = true

        let snapshot = try? cache.load()
        if let snapshot {
            let current = snapshot.withCurrentSummaryVersion()
            items = current.items
            lastUpdated = current.fetchedAt
            rememberLoadedSummaries()
            if current != snapshot {
                try? cache.save(current)
            }
        }

        guard cachePolicy.shouldRefresh(snapshot, now: now) else { return }
        let completed = await fetch(ignoringCache: false, now: now)
        if !completed { didLoad = false }
    }

    func refresh(now: Date = Date()) async {
        _ = await fetch(ignoringCache: true, now: now)
    }

    func search(_ rawQuery: String) async {
        let query = rawQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !query.isEmpty else {
            clearSearch()
            return
        }

        searchQuery = query
        searchErrorMessage = nil
        if let cachedResults = searchCache[query] {
            searchResults = mergingCatalogMetadata(into: cachedResults)
            isSearching = false
            return
        }

        isSearching = true
        do {
            let fetchedResults = try await searchClient.searchSkills(query: query)
            guard searchQuery == query else { return }
            guard !Task.isCancelled else {
                isSearching = false
                return
            }

            let results = mergingCatalogMetadata(into: fetchedResults)
            searchCache[query] = results
            searchResults = results
            searchErrorMessage = nil
            isSearching = false
        } catch {
            guard searchQuery == query else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                isSearching = false
                return
            }

            searchResults = SkillsCatalogFilter(query: query, category: .all).apply(to: items)
            searchErrorMessage = error.localizedDescription
            isSearching = false
        }
    }

    func clearSearch() {
        searchQuery = ""
        searchResults = []
        searchErrorMessage = nil
        isSearching = false
    }

    func loadSummary(for id: String) async {
        guard
            let item = items.first(where: { $0.id == id })
                ?? searchResults.first(where: { $0.id == id }),
            item.summary == nil,
            loadingSummaryIDs.insert(id).inserted
        else { return }
        defer { loadingSummaryIDs.remove(id) }

        // Another publisher of the same skill may have answered already.
        if let known = summariesBySlug[item.slug] {
            storeSummaryAcrossCatalog(known, slug: item.slug)
            return
        }
        // Written off earlier and no sibling to borrow from.
        guard item.needsSummary else { return }

        await summaryGate.acquire()
        let outcome = await resolveSummary(for: item)
        await summaryGate.release()

        switch outcome {
        case .cancelled:
            return
        case .summary(let summary):
            summariesBySlug[item.slug] = summary
            storeSummaryAcrossCatalog(summary, slug: item.slug)
        case .missing:
            if let known = summariesBySlug[item.slug] {
                // This publisher shipped an empty page, but the same skill is
                // described elsewhere in the catalog.
                storeSummaryAcrossCatalog(known, slug: item.slug)
            } else {
                // The page answered and had nothing to say. Remember that so
                // the grid stops asking.
                storeSummaryChange(id: id) { $0.withSummaryUnavailable() }
            }
        case .failed:
            // A timeout or a dropped connection says nothing about the page.
            // Leave the card retryable; it fills in on the next visit.
            return
        }
    }

    private func rememberLoadedSummaries() {
        for item in items {
            guard let summary = item.summary else { continue }
            summariesBySlug[item.slug] = summary
        }
    }

    /// Fills in the other entries for the same skill, including ones already
    /// written off as undescribed.
    private func storeSummaryAcrossCatalog(_ summary: String, slug: String) {
        var updatedCatalog = false
        for index in items.indices where items[index].slug == slug && items[index].summary == nil {
            items[index] = items[index].withSummary(summary)
            updatedCatalog = true
        }
        for index in searchResults.indices
        where searchResults[index].slug == slug && searchResults[index].summary == nil {
            searchResults[index] = searchResults[index].withSummary(summary)
        }
        for query in Array(searchCache.keys) {
            guard var cachedResults = searchCache[query] else { continue }
            var changed = false
            for index in cachedResults.indices
            where cachedResults[index].slug == slug && cachedResults[index].summary == nil {
                cachedResults[index] = cachedResults[index].withSummary(summary)
                changed = true
            }
            if changed {
                searchCache[query] = cachedResults
            }
        }

        guard updatedCatalog, let lastUpdated else { return }
        try? cache.save(SkillsCatalogSnapshot(items: items, fetchedAt: lastUpdated))
    }

    private enum SummaryOutcome {
        case summary(String)
        /// The page loaded but published no description.
        case missing
        /// The request never produced a verdict.
        case failed
        case cancelled
    }

    private func resolveSummary(for item: SkillsCatalogItem) async -> SummaryOutcome {
        for attempt in 0..<2 {
            do {
                let summary = try await summaryClient.fetchSummary(for: item)
                return Task.isCancelled ? .cancelled : .summary(summary)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return .cancelled
                }
                if error is SkillsCatalogParsingError {
                    return .missing
                }
                if case .httpStatus(let status) = error as? SkillsCatalogNetworkError {
                    // A page that does not exist will not grow a description.
                    // Rate limits and server errors say nothing about the page.
                    let isPermanent = (400..<500).contains(status)
                        && status != 408
                        && status != 429
                    return isPermanent ? .missing : .failed
                }
                // Only a transport hiccup deserves a second try. A page that
                // answered without a summary will answer the same way again.
                if error is URLError, attempt == 0 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if Task.isCancelled { return .cancelled }
                    continue
                }
                return .failed
            }
        }
        return .failed
    }

    /// Writes the resolved description into the catalog, live search results and
    /// cached queries, then persists it so the next launch starts warm.
    private func storeSummaryChange(
        id: String,
        transform: (SkillsCatalogItem) -> SkillsCatalogItem
    ) {
        var updatedCatalog = false
        if let index = items.firstIndex(where: { $0.id == id }), items[index].needsSummary {
            items[index] = transform(items[index])
            updatedCatalog = true
        }
        if let index = searchResults.firstIndex(where: { $0.id == id }),
           searchResults[index].needsSummary {
            searchResults[index] = transform(searchResults[index])
        }
        for query in Array(searchCache.keys) {
            guard
                var cachedResults = searchCache[query],
                let index = cachedResults.firstIndex(where: { $0.id == id }),
                cachedResults[index].needsSummary
            else { continue }
            cachedResults[index] = transform(cachedResults[index])
            searchCache[query] = cachedResults
        }

        guard updatedCatalog, let lastUpdated else { return }
        try? cache.save(SkillsCatalogSnapshot(items: items, fetchedAt: lastUpdated))
    }

    private func fetch(ignoringCache: Bool, now: Date) async -> Bool {
        guard !isInitialLoading, !isRefreshing else { return true }
        let hasVisibleItems = !items.isEmpty
        isInitialLoading = !hasVisibleItems
        isRefreshing = hasVisibleItems
        defer {
            isInitialLoading = false
            isRefreshing = false
        }

        do {
            let fetchedItems = try await client.fetchSkills(ignoringCache: ignoringCache)
            guard !fetchedItems.isEmpty else { throw SkillsCatalogParsingError.noSkills }

            let snapshot = SkillsCatalogSnapshot(items: fetchedItems, fetchedAt: now)
            items = fetchedItems
            searchResults = mergingCatalogMetadata(into: searchResults)
            lastUpdated = now
            errorMessage = nil
            rememberLoadedSummaries()
            try? cache.save(snapshot)
            return true
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return false
            }
            errorMessage = error.localizedDescription
            return true
        }
    }

    private func mergingCatalogMetadata(
        into searchItems: [SkillsCatalogItem]
    ) -> [SkillsCatalogItem] {
        let catalogItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return searchItems.map { searchItem in
            guard let catalogItem = catalogItems[searchItem.id] else { return searchItem }
            return SkillsCatalogItem(
                source: searchItem.source,
                slug: searchItem.slug,
                name: searchItem.name,
                installs: searchItem.installs,
                isOfficial: searchItem.isOfficial || catalogItem.isOfficial,
                summary: searchItem.summary ?? catalogItem.summary
            )
        }
    }
}

enum SkillsCatalogNetworkError: LocalizedError {
    case invalidURL
    case invalidResponse
    /// The server answered, but not with a page — kept apart from a transport
    /// failure so the caller can tell "nothing here" from "try again later".
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L10n.string("skills.error.invalid_url")
        case .invalidResponse, .httpStatus:
            return L10n.string("skills.error.unavailable")
        }
    }
}

protocol SkillsInstalling {
    func install(_ item: SkillsCatalogItem) async throws
}

struct NpxSkillsInstaller: SkillsInstalling {
    func install(_ item: SkillsCatalogItem) async throws {
        let executableURL = try Self.findNpxExecutable()
        let command = SkillsCLIInstallCommand(item: item)
        try await Self.run(
            executableURL: executableURL,
            arguments: command.arguments
        )
    }

    private static func findNpxExecutable(
        fileManager: FileManager = .default
    ) throws -> URL {
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("npx") }
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/npx"),
            URL(fileURLWithPath: "/usr/local/bin/npx"),
            home.appendingPathComponent(".volta/bin/npx")
        ])
        candidates.append(contentsOf: versionedExecutables(
            below: home.appendingPathComponent(".nvm/versions/node"),
            relativePath: "bin/npx",
            fileManager: fileManager
        ))
        candidates.append(contentsOf: versionedExecutables(
            below: home.appendingPathComponent(".fnm/node-versions"),
            relativePath: "installation/bin/npx",
            fileManager: fileManager
        ))

        var seen: Set<String> = []
        if let executable = candidates.first(where: { candidate in
            let path = candidate.standardizedFileURL.path
            return seen.insert(path).inserted && fileManager.isExecutableFile(atPath: path)
        }) {
            return executable
        }
        throw SkillsInstallationError.npxUnavailable
    }

    private static func versionedExecutables(
        below root: URL,
        relativePath: String,
        fileManager: FileManager
    ) -> [URL] {
        let versions = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return versions
            .sorted { $0.lastPathComponent.compare(
                $1.lastPathComponent,
                options: .numeric
            ) == .orderedDescending }
            .map { $0.appendingPathComponent(relativePath) }
    }

    private static func run(
        executableURL: URL,
        arguments: [String]
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = output
                var environment = ProcessInfo.processInfo.environment
                environment["DISABLE_TELEMETRY"] = "1"
                let executableDirectory = executableURL.deletingLastPathComponent().path
                let currentPath = environment["PATH"] ?? ""
                environment["PATH"] = currentPath.isEmpty
                    ? executableDirectory
                    : "\(executableDirectory):\(currentPath)"
                process.environment = environment

                do {
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let message = String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        throw SkillsInstallationError.commandFailed(message)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum SkillsInstallationError: LocalizedError {
    case npxUnavailable
    case commandFailed(String?)
    case invalidInstallationPath

    var errorDescription: String? {
        switch self {
        case .npxUnavailable:
            return L10n.string("skills.install.error.npx_missing")
        case let .commandFailed(message):
            guard let message, !message.isEmpty else {
                return L10n.string("skills.install.error.failed")
            }
            return L10n.format("skills.install.error.failed_detail", message)
        case .invalidInstallationPath:
            return L10n.string("skills.install.error.invalid_path")
        }
    }
}

enum InstalledSkillSource: String, Hashable {
    case piAgent
    case sharedAgents
}

struct InstalledSkillInstallation: Hashable {
    let source: InstalledSkillSource
    let url: URL
    var isEnabled: Bool

    init(
        source: InstalledSkillSource,
        url: URL,
        isEnabled: Bool = true
    ) {
        self.source = source
        self.url = url
        self.isEnabled = isEnabled
    }
}

struct InstalledSkill: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String?
    let fileURL: URL
    var installations: [InstalledSkillInstallation]

    var isEnabled: Bool {
        installations.contains(where: \.isEnabled)
    }
}

protocol InstalledSkillEnablementManaging {
    func disabledPatterns() throws -> [InstalledSkillSource: Set<String>]
    func isEnabled(_ installation: InstalledSkillInstallation) throws -> Bool
    func setEnabled(
        _ enabled: Bool,
        for installations: [InstalledSkillInstallation]
    ) throws
}

struct ManagedInstalledSkillEnablement: InstalledSkillEnablementManaging {
    private static let beginMarker = "# pi-work disabled skills — begin"
    private static let endMarker = "# pi-work disabled skills — end"

    private let piSkillsDirectory: URL
    private let sharedSkillsDirectory: URL
    private let fileManager: FileManager

    init(
        piSkillsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/skills"),
        sharedSkillsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/skills"),
        fileManager: FileManager = .default
    ) {
        self.piSkillsDirectory = piSkillsDirectory
        self.sharedSkillsDirectory = sharedSkillsDirectory
        self.fileManager = fileManager
    }

    func disabledPatterns() throws -> [InstalledSkillSource: Set<String>] {
        var result: [InstalledSkillSource: Set<String>] = [:]
        for source in [InstalledSkillSource.piAgent, .sharedAgents] {
            let patterns = try managedContents(at: ignoreFileURL(for: source)).patterns
            if !patterns.isEmpty {
                result[source] = patterns
            }
        }
        return result
    }

    func isEnabled(_ installation: InstalledSkillInstallation) throws -> Bool {
        let patterns = try managedContents(
            at: ignoreFileURL(for: installation.source)
        ).patterns
        return !patterns.contains(try pattern(for: installation))
    }

    func setEnabled(
        _ enabled: Bool,
        for installations: [InstalledSkillInstallation]
    ) throws {
        let grouped = Dictionary(grouping: installations, by: \.source)
        for (source, sourceInstallations) in grouped {
            let fileURL = ignoreFileURL(for: source)
            var contents = try managedContents(at: fileURL)
            for installation in sourceInstallations {
                let value = try pattern(for: installation)
                if enabled {
                    contents.patterns.remove(value)
                } else {
                    contents.patterns.insert(value)
                }
            }
            try write(contents, to: fileURL)
        }
    }

    private func rootURL(for source: InstalledSkillSource) -> URL {
        switch source {
        case .piAgent: return piSkillsDirectory
        case .sharedAgents: return sharedSkillsDirectory
        }
    }

    private func ignoreFileURL(for source: InstalledSkillSource) -> URL {
        rootURL(for: source).appendingPathComponent(".ignore")
    }

    private func pattern(for installation: InstalledSkillInstallation) throws -> String {
        let rootPath = rootURL(for: installation.source).standardizedFileURL.path
        let installationURL = installation.url.standardizedFileURL
        let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        guard installationURL.path.hasPrefix(prefix) else {
            throw SkillsInstallationError.invalidInstallationPath
        }
        let relativePath = String(installationURL.path.dropFirst(prefix.count))
        guard !relativePath.isEmpty else {
            throw SkillsInstallationError.invalidInstallationPath
        }
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(
            atPath: installationURL.path,
            isDirectory: &isDirectory
        )
        return "/\(relativePath)\(exists && isDirectory.boolValue ? "/" : "")"
    }

    private func managedContents(at fileURL: URL) throws -> ManagedIgnoreContents {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ManagedIgnoreContents(baseLines: [], patterns: [])
        }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        var baseLines: [String] = []
        var patterns: Set<String> = []
        var isInsideManagedBlock = false

        for line in lines {
            if line == Self.beginMarker {
                isInsideManagedBlock = true
            } else if line == Self.endMarker, isInsideManagedBlock {
                isInsideManagedBlock = false
            } else if isInsideManagedBlock {
                if !line.isEmpty { patterns.insert(line) }
            } else {
                baseLines.append(line)
            }
        }
        return ManagedIgnoreContents(baseLines: baseLines, patterns: patterns)
    }

    private func write(_ contents: ManagedIgnoreContents, to fileURL: URL) throws {
        var baseLines = contents.baseLines
        while baseLines.last == "", baseLines.count > 1, baseLines[baseLines.count - 2].isEmpty {
            baseLines.removeLast()
        }
        var text = baseLines.joined(separator: "\n")
        if !contents.patterns.isEmpty {
            if !text.isEmpty, !text.hasSuffix("\n") { text.append("\n") }
            text.append(Self.beginMarker)
            text.append("\n")
            text.append(contents.patterns.sorted().joined(separator: "\n"))
            text.append("\n")
            text.append(Self.endMarker)
            text.append("\n")
        }

        if text.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            return
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private struct ManagedIgnoreContents {
        var baseLines: [String]
        var patterns: Set<String>
    }
}

protocol InstalledSkillsScanning {
    func scan() throws -> [InstalledSkill]
}

struct InstalledSkillsScanner: InstalledSkillsScanning {
    private let piSkillsDirectory: URL
    private let sharedSkillsDirectory: URL
    private let fileManager: FileManager
    private let enablementManager: any InstalledSkillEnablementManaging

    init(
        piSkillsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/skills"),
        sharedSkillsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/skills"),
        fileManager: FileManager = .default,
        enablementManager: (any InstalledSkillEnablementManaging)? = nil
    ) {
        self.piSkillsDirectory = piSkillsDirectory
        self.sharedSkillsDirectory = sharedSkillsDirectory
        self.fileManager = fileManager
        self.enablementManager = enablementManager ?? ManagedInstalledSkillEnablement(
            piSkillsDirectory: piSkillsDirectory,
            sharedSkillsDirectory: sharedSkillsDirectory,
            fileManager: fileManager
        )
    }

    func scan() throws -> [InstalledSkill] {
        let roots: [(URL, InstalledSkillSource, Bool)] = [
            (piSkillsDirectory, .piAgent, true),
            (sharedSkillsDirectory, .sharedAgents, false)
        ]
        var skillsByID: [String: InstalledSkill] = [:]

        for (root, source, includesRootMarkdown) in roots {
            for candidate in try candidates(
                in: root,
                source: source,
                includesRootMarkdown: includesRootMarkdown
            ) {
                var installation = candidate.installation
                installation.isEnabled = (try? enablementManager.isEnabled(installation)) ?? true
                let resolvedFileURL = candidate.fileURL
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                guard fileManager.fileExists(atPath: resolvedFileURL.path) else { continue }

                let id = resolvedFileURL.path
                if var existing = skillsByID[id] {
                    if !existing.installations.contains(installation) {
                        existing.installations.append(installation)
                        skillsByID[id] = existing
                    }
                    continue
                }

                let metadata = metadata(
                    at: resolvedFileURL,
                    fallbackName: candidate.fallbackName
                )
                skillsByID[id] = InstalledSkill(
                    id: id,
                    name: metadata.name,
                    description: metadata.description,
                    fileURL: resolvedFileURL,
                    installations: [installation]
                )
            }
        }

        return skillsByID.values.sorted { lhs, rhs in
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }

    private func candidates(
        in root: URL,
        source: InstalledSkillSource,
        includesRootMarkdown: Bool
    ) throws -> [Candidate] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        var visitedDirectories: Set<String> = []
        return try candidates(
            in: root,
            root: root,
            source: source,
            includesRootMarkdown: includesRootMarkdown,
            visitedDirectories: &visitedDirectories
        )
    }

    private func candidates(
        in directory: URL,
        root: URL,
        source: InstalledSkillSource,
        includesRootMarkdown: Bool,
        visitedDirectories: inout Set<String>
    ) throws -> [Candidate] {
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        guard visitedDirectories.insert(resolvedDirectory.path).inserted else { return [] }

        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).sorted { $0.path < $1.path }
        var result: [Candidate] = []

        for child in children {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                let skillFile = child.appendingPathComponent("SKILL.md")
                if fileManager.fileExists(atPath: skillFile.path) {
                    result.append(Candidate(
                        fileURL: skillFile,
                        fallbackName: child.lastPathComponent,
                        installation: InstalledSkillInstallation(
                            source: source,
                            url: child.standardizedFileURL
                        )
                    ))
                } else {
                    result.append(contentsOf: try candidates(
                        in: child,
                        root: root,
                        source: source,
                        includesRootMarkdown: includesRootMarkdown,
                        visitedDirectories: &visitedDirectories
                    ))
                }
            } else if includesRootMarkdown,
                      directory.standardizedFileURL == root.standardizedFileURL,
                      child.pathExtension.lowercased() == "md" {
                result.append(Candidate(
                    fileURL: child,
                    fallbackName: child.deletingPathExtension().lastPathComponent,
                    installation: InstalledSkillInstallation(
                        source: source,
                        url: child.standardizedFileURL
                    )
                ))
            }
        }

        return result
    }

    private func metadata(at fileURL: URL, fallbackName: String) -> Metadata {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return Metadata(name: fallbackName, description: nil)
        }
        let lines = contents.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closingIndex = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            return Metadata(name: fallbackName, description: nil)
        }

        let frontmatter = Array(lines[1..<closingIndex])
        return Metadata(
            name: frontmatterValue(named: "name", in: frontmatter) ?? fallbackName,
            description: frontmatterValue(named: "description", in: frontmatter)
        )
    }

    private func frontmatterValue(named key: String, in lines: [String]) -> String? {
        guard let index = lines.firstIndex(where: { line in
            guard line.first?.isWhitespace != true else { return false }
            return line.hasPrefix("\(key):")
        }) else { return nil }

        let line = lines[index]
        let valueStart = line.index(line.startIndex, offsetBy: key.count + 1)
        let rawValue = line[valueStart...].trimmingCharacters(in: .whitespaces)

        if rawValue == ">" || rawValue == "|" {
            var values: [String] = []
            for continuation in lines.dropFirst(index + 1) {
                guard continuation.isEmpty || continuation.first?.isWhitespace == true else {
                    break
                }
                let trimmed = continuation.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { values.append(trimmed) }
            }
            let separator = rawValue == ">" ? " " : "\n"
            let value = values.joined(separator: separator)
            return value.isEmpty ? nil : value
        }

        guard !rawValue.isEmpty else { return nil }
        if rawValue.count >= 2,
           let first = rawValue.first,
           let last = rawValue.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(rawValue.dropFirst().dropLast())
        }
        return rawValue
    }

    private struct Candidate {
        let fileURL: URL
        let fallbackName: String
        let installation: InstalledSkillInstallation
    }

    private struct Metadata {
        let name: String
        let description: String?
    }
}

protocol InstalledSkillRemoving {
    func remove(_ skill: InstalledSkill) async throws
}

struct TrashInstalledSkillRemover: InstalledSkillRemoving {
    private let recycle: ([URL]) async throws -> Void

    init() {
        recycle = Self.recycleWithWorkspace
    }

    init(recycle: @escaping ([URL]) async throws -> Void) {
        self.recycle = recycle
    }

    func remove(_ skill: InstalledSkill) async throws {
        var seenPaths: Set<String> = []
        let installationURLs = skill.installations.compactMap { installation -> URL? in
            let url = installation.url.standardizedFileURL
            return seenPaths.insert(url.path).inserted ? url : nil
        }
        guard !installationURLs.isEmpty else { return }
        try await recycle(installationURLs)
    }

    private static func recycleWithWorkspace(_ urls: [URL]) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle(urls) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

@MainActor
final class InstalledSkillsStore: ObservableObject {
    @Published private(set) var skills: [InstalledSkill] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var installingSkillID: String?
    @Published private(set) var removingSkillID: String?
    @Published private(set) var activeSkillIDs: Set<String> = []

    private let scanner: any InstalledSkillsScanning
    private let installer: any SkillsInstalling
    private let enablementManager: any InstalledSkillEnablementManaging
    private let remover: any InstalledSkillRemoving

    init(
        scanner: any InstalledSkillsScanning = InstalledSkillsScanner(),
        installer: any SkillsInstalling = NpxSkillsInstaller(),
        enablementManager: any InstalledSkillEnablementManaging = ManagedInstalledSkillEnablement(),
        remover: any InstalledSkillRemoving = TrashInstalledSkillRemover()
    ) {
        self.scanner = scanner
        self.installer = installer
        self.enablementManager = enablementManager
        self.remover = remover
    }

    func reload() {
        do {
            skills = try scanner.scan()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func install(_ item: SkillsCatalogItem) async {
        guard installingSkillID == nil, !isInstalled(item) else { return }
        installingSkillID = item.id
        defer { installingSkillID = nil }

        do {
            try await installer.install(item)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isInstalled(_ item: SkillsCatalogItem) -> Bool {
        let names = Set([item.slug, item.name].map(Self.normalizedSkillName))
        return skills.contains { skill in
            names.contains(Self.normalizedSkillName(skill.name))
                || Self.normalizedSkillName(skill.fileURL.deletingLastPathComponent().lastPathComponent)
                    == Self.normalizedSkillName(item.slug)
        }
    }

    func isWorking(on skill: InstalledSkill) -> Bool {
        activeSkillIDs.contains(skill.id) || removingSkillID == skill.id
    }

    func setEnabled(_ enabled: Bool, for skill: InstalledSkill) async {
        guard let index = skills.firstIndex(where: { $0.id == skill.id }),
              activeSkillIDs.insert(skill.id).inserted else { return }
        defer { activeSkillIDs.remove(skill.id) }

        let previousInstallations = skills[index].installations
        skills[index].installations = previousInstallations.map { installation in
            var updated = installation
            updated.isEnabled = enabled
            return updated
        }
        do {
            try enablementManager.setEnabled(enabled, for: previousInstallations)
            errorMessage = nil
        } catch {
            if let currentIndex = skills.firstIndex(where: { $0.id == skill.id }) {
                skills[currentIndex].installations = previousInstallations
            }
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ skill: InstalledSkill) async {
        guard removingSkillID == nil, !activeSkillIDs.contains(skill.id) else { return }
        removingSkillID = skill.id
        defer { removingSkillID = nil }

        let wasDisabled = !skill.isEnabled
        do {
            if wasDisabled {
                try enablementManager.setEnabled(true, for: skill.installations)
            }
            do {
                try await remover.remove(skill)
            } catch {
                if wasDisabled {
                    try? enablementManager.setEnabled(false, for: skill.installations)
                }
                throw error
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func normalizedSkillName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
