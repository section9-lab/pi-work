import Combine
import Foundation

enum AgentHostExecutable {
    static let filename = "pi-work-agent-host"
    static let bunFilename = "bun"
    private static let piCodingAgentVersionFilename = "pi-coding-agent-version"

    #if arch(arm64)
    private static let currentArchitecture = "arm64"
    #elseif arch(x86_64)
    private static let currentArchitecture = "x64"
    #endif

    static func bundledURL() -> URL? {
        resolve(in: Bundle.main.bundleURL, architecture: currentArchitecture)
    }

    static func bundledBunURL() -> URL? {
        resolveBun(in: Bundle.main.bundleURL, architecture: currentArchitecture)
    }

    static func piCodingAgentVersion(
        in appBundleURL: URL = Bundle.main.bundleURL
    ) -> String? {
        let fileURL = appBundleURL.appendingPathComponent(
            "Contents/Resources/AgentHost/\(piCodingAgentVersionFilename)",
            isDirectory: false
        )
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let version = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    static func runtimeVersion(in appBundleURL: URL = Bundle.main.bundleURL) -> String? {
        let file = appBundleURL.appendingPathComponent("Contents/Resources/AgentHost/runtime-version")
        let version = (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return version?.isEmpty == false ? version : nil
    }

    static func authenticationFileURL(
        applicationSupportDirectory: URL
    ) -> URL {
        agentDirectoryURL(applicationSupportDirectory: applicationSupportDirectory)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    static func globalInstructionsFileURL(
        applicationSupportDirectory: URL
    ) -> URL {
        agentDirectoryURL(applicationSupportDirectory: applicationSupportDirectory)
            .appendingPathComponent("AGENTS.md", isDirectory: false)
    }

    static func agentDirectoryURL(
        applicationSupportDirectory: URL
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("pi-work", isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
    }

    static func resolve(
        in appBundleURL: URL,
        architecture: String,
        fileManager: FileManager = .default
    ) -> URL? {
        let candidate = appBundleURL.appendingPathComponent(
            "Contents/Resources/AgentHost/\(architecture)/\(filename)",
            isDirectory: false
        )
        return fileManager.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    static func resolveBun(
        in appBundleURL: URL,
        architecture: String,
        fileManager: FileManager = .default
    ) -> URL? {
        let candidate = appBundleURL.appendingPathComponent(
            "Contents/Helpers/Bun/\(architecture)/\(bunFilename)",
            isDirectory: false
        )
        return fileManager.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }
}

struct GlobalAgentInstructionsDocument {
    let fileURL: URL
    var fileManager = FileManager.default

    func load() throws -> String {
        guard fileManager.fileExists(atPath: fileURL.path) else { return "" }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    func save(_ contents: String) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

@MainActor
final class GlobalAgentInstructionsStore: ObservableObject {
    @Published var draft = "" {
        didSet {
            if draft != oldValue { didSave = false }
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var didSave = false
    @Published private(set) var errorMessage: String?

    private let document: GlobalAgentInstructionsDocument
    private var loadedContents = ""

    var fileURL: URL { document.fileURL }
    var hasUnsavedChanges: Bool { draft != loadedContents }

    init(document: GlobalAgentInstructionsDocument) {
        self.document = document
    }

    static func applicationDefault() -> GlobalAgentInstructionsStore {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return GlobalAgentInstructionsStore(
            document: GlobalAgentInstructionsDocument(
                fileURL: AgentHostExecutable.globalInstructionsFileURL(
                    applicationSupportDirectory: applicationSupport
                )
            )
        )
    }

    func load() {
        isLoading = true
        defer { isLoading = false }
        do {
            replaceLoadedContents(try document.load())
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save() {
        isSaving = true
        defer { isSaving = false }
        do {
            try document.save(draft)
            loadedContents = draft
            didSave = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func replaceLoadedContents(_ contents: String) {
        loadedContents = contents
        draft = contents
        didSave = false
    }

    func revert() {
        draft = loadedContents
    }
}
