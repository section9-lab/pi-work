import Foundation

private let agentHostProtocolVersion = 1

struct AgentHostEvent<Payload: Decodable>: Decodable {
    let version: Int
    let kind: String
    let event: String
    let payload: Payload
}

struct AgentHostWireHeader: Decodable {
    let version: Int
    let kind: String
    let id: String?
    let event: String?
}

struct AgentHostACPCapabilities: Equatable {
    let loadSession: Bool
    let listSessions: Bool
    let deleteSession: Bool
    let resumeSession: Bool
    let closeSession: Bool
    let promptImages: Bool
    let mcpHTTP: Bool
    let mcpSSE: Bool

    static let baseline = AgentHostACPCapabilities(
        loadSession: false,
        listSessions: false,
        deleteSession: false,
        resumeSession: false,
        closeSession: false,
        promptImages: false,
        mcpHTTP: false,
        mcpSSE: false
    )
}

enum AgentHostPiWorkCapability: String, CaseIterable, Decodable, Equatable, Hashable {
    case modelsList = "models.list"
    case providersList = "providers.list"
    case authStart = "auth.start"
    case authRespond = "auth.respond"
    case authCancel = "auth.cancel"
    case authLogout = "auth.logout"
    case settingsGet = "settings.get"
    case settingsUpdate = "settings.update"
    case extensionsListInstalled = "extensions.listInstalled"
    case extensionsInstall = "extensions.install"
    case extensionsSetEnabled = "extensions.setEnabled"
    case extensionsUpdate = "extensions.update"
    case extensionsRemove = "extensions.remove"
    case extensionSettingsList = "extensions.settings.list"
    case extensionSettingsUpdate = "extensions.settings.update"
    case gitBranches = "git.branches"
    case sessionExportHTML = "session.exportHtml"
    case sessionSnapshot = "session.snapshot"
    case sessionTranscriptPage = "session.transcriptPage"
    case sessionToolOutput = "session.toolOutput"
    case sessionCommands = "session.commands"
    case sessionRename = "session.rename"
    case sessionSetGitBranch = "session.setGitBranch"
    case sessionExtensionStatus = "session.extensionStatus"
    case sessionExtensionWidget = "session.extensionWidget"

    static let all = Set(allCases)
}

struct AgentHostACPAuthMethod: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let type: String?
}

struct AgentHostACPAuthenticateParameters: Encodable, Equatable {
    let methodId: String
}

struct AgentHostHelloPayload: Decodable, Equatable {
    let hostVersion: String
    let piVersion: String
    let capabilities: [String]
    let acpCapabilities: AgentHostACPCapabilities
    let authMethods: [AgentHostACPAuthMethod]
    let piWorkCapabilities: Set<AgentHostPiWorkCapability>

    var supportsPiWorkExtensions: Bool { !piWorkCapabilities.isEmpty }

    func supportsPiWorkCapability(_ capability: AgentHostPiWorkCapability) -> Bool {
        piWorkCapabilities.contains(capability)
    }

    private enum CodingKeys: String, CodingKey {
        case hostVersion
        case piVersion
        case capabilities
    }

    init(
        hostVersion: String,
        piVersion: String,
        capabilities: [String],
        acpCapabilities: AgentHostACPCapabilities = .baseline,
        authMethods: [AgentHostACPAuthMethod] = [],
        piWorkCapabilities: Set<AgentHostPiWorkCapability>? = nil,
        supportsPiWorkExtensions: Bool = false
    ) {
        self.hostVersion = hostVersion
        self.piVersion = piVersion
        self.capabilities = capabilities
        self.acpCapabilities = acpCapabilities
        self.authMethods = authMethods
        self.piWorkCapabilities = piWorkCapabilities
            ?? (supportsPiWorkExtensions ? AgentHostPiWorkCapability.all : [])
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hostVersion: try container.decode(String.self, forKey: .hostVersion),
            piVersion: try container.decode(String.self, forKey: .piVersion),
            capabilities: try container.decode([String].self, forKey: .capabilities),
            supportsPiWorkExtensions: true
        )
    }
}

struct AgentHostACPInitializeParameters: Encodable {
    let protocolVersion: Int
    let clientInfo: ClientInfo
    let clientCapabilities: ClientCapabilities

    struct ClientInfo: Encodable {
        let name: String
        let version: String
    }

    struct ClientCapabilities: Encodable {
        let session: SessionCapabilities
        let elicitation: ElicitationCapabilities

        static let piWork = ClientCapabilities(
            session: SessionCapabilities(
                configOptions: ConfigOptionCapabilities(boolean: Supported())
            ),
            elicitation: ElicitationCapabilities(form: Supported())
        )
    }

    struct ElicitationCapabilities: Encodable {
        let form: Supported
    }

    struct SessionCapabilities: Encodable {
        let configOptions: ConfigOptionCapabilities
    }

    struct ConfigOptionCapabilities: Encodable {
        let boolean: Supported
    }

    struct Supported: Encodable {}
}

struct AgentHostACPInitializeResult: Decodable, Equatable {
    let protocolVersion: Int
    let agentInfo: AgentInfo?
    let agentCapabilities: AgentCapabilities?
    let authMethods: [AgentHostACPAuthMethod]?
    let metadata: Metadata?

    struct AgentInfo: Decodable, Equatable {
        let name: String
        let version: String
    }

    struct Metadata: Decodable, Equatable {
        struct PiWork: Decodable, Equatable {
            let extensions: Bool?
            let capabilities: [String]?
        }

        let piVersion: String?
        let capabilities: [String]?
        let piWork: PiWork?
    }

    struct AgentCapabilities: Decodable, Equatable {
        let loadSession: Bool?
        let promptCapabilities: PromptCapabilities?
        let mcpCapabilities: MCPCapabilities?
        let sessionCapabilities: SessionCapabilities?
    }

    struct PromptCapabilities: Decodable, Equatable {
        let image: Bool?
    }

    struct MCPCapabilities: Decodable, Equatable {
        let http: Bool?
        let sse: Bool?
    }

    struct SessionCapabilities: Decodable, Equatable {
        let list: Supported?
        let delete: Supported?
        let resume: Supported?
        let close: Supported?
    }

    struct Supported: Decodable, Equatable {}

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case agentInfo
        case agentCapabilities
        case authMethods
        case metadata = "_meta"
    }

    var helloPayload: AgentHostHelloPayload {
        AgentHostHelloPayload(
            hostVersion: agentInfo?.version ?? "unknown",
            piVersion: metadata?.piVersion ?? "unknown",
            capabilities: metadata?.capabilities ?? [],
            acpCapabilities: AgentHostACPCapabilities(
                loadSession: agentCapabilities?.loadSession == true,
                listSessions: agentCapabilities?.sessionCapabilities?.list != nil,
                deleteSession: agentCapabilities?.sessionCapabilities?.delete != nil,
                resumeSession: agentCapabilities?.sessionCapabilities?.resume != nil,
                closeSession: agentCapabilities?.sessionCapabilities?.close != nil,
                promptImages: agentCapabilities?.promptCapabilities?.image == true,
                mcpHTTP: agentCapabilities?.mcpCapabilities?.http == true,
                mcpSSE: agentCapabilities?.mcpCapabilities?.sse == true
            ),
            authMethods: authMethods ?? [],
            piWorkCapabilities: metadata?.piWork?.capabilities.map {
                Set($0.compactMap(AgentHostPiWorkCapability.init(rawValue:)))
            },
            supportsPiWorkExtensions: metadata?.piWork?.extensions == true
        )
    }
}

enum AgentHostSessionRunState: String, Decodable, Equatable {
    case running
    case idle
}

struct AgentHostContextUsage: Decodable, Equatable {
    let tokens: Int?
    let contextWindow: Int
    let percent: Double?
}

struct AgentHostACPSessionMode: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let description: String?
}

struct AgentHostACPSessionModeState: Decodable, Equatable {
    var currentModeId: String
    let availableModes: [AgentHostACPSessionMode]
}

struct AgentHostACPSessionCost: Decodable, Equatable {
    let amount: Double
    let currency: String
}

struct AgentHostACPAvailableCommand: Decodable, Equatable {
    let name: String
    let description: String
}

enum AgentHostACPPlanPriority: String, Decodable, Equatable {
    case high
    case medium
    case low
}

enum AgentHostACPPlanStatus: String, Decodable, Equatable {
    case pending
    case inProgress = "in_progress"
    case completed
}

struct AgentHostACPPlanEntry: Decodable, Equatable {
    let content: String
    let priority: AgentHostACPPlanPriority
    let status: AgentHostACPPlanStatus
}

struct AgentHostSessionModeChangedPayload: Equatable {
    let sessionId: String
    let sequence: Int
    let currentModeId: String
}

struct AgentHostSessionConfigOptionsChangedPayload: Equatable {
    let sessionId: String
    let sequence: Int
    let configOptions: [AgentHostACPSetConfigOptionResult.ConfigOption]
}

struct AgentHostSessionInfoChangedPayload: Equatable {
    let sessionId: String
    let sequence: Int
    let title: String?
    let updatedAt: String?
}

struct AgentHostSessionUsageChangedPayload: Equatable {
    let sessionId: String
    let sequence: Int
    let used: Int
    let size: Int
    let cost: AgentHostACPSessionCost?
}

struct AgentHostSessionAvailableCommandsChangedPayload: Equatable {
    let sessionId: String
    let sequence: Int
    let availableCommands: [AgentHostACPAvailableCommand]
}

struct AgentHostSessionPlanChangedPayload: Equatable {
    let sessionId: String
    let sequence: Int
    let entries: [AgentHostACPPlanEntry]
}

struct AgentHostSessionStateChangedPayload: Decodable, Equatable {
    let sessionId: String
    let sequence: Int
    let turnId: String
    let state: AgentHostSessionRunState
    let contextUsage: AgentHostContextUsage?

    init(
        sessionId: String,
        sequence: Int,
        turnId: String,
        state: AgentHostSessionRunState,
        contextUsage: AgentHostContextUsage? = nil
    ) {
        self.sessionId = sessionId
        self.sequence = sequence
        self.turnId = turnId
        self.state = state
        self.contextUsage = contextUsage
    }
}

struct AgentHostSessionMessageDeltaPayload: Decodable, Equatable {
    let sessionId: String
    let sequence: Int
    let turnId: String
    let delta: String
}

struct AgentHostSessionUserContentPayload: Equatable {
    let sessionId: String
    let sequence: Int
    let messageId: String
    let text: String
}

enum AgentHostAssistantContentPhase: String, Decodable, Equatable {
    case start
    case delta
    case end
}

enum AgentHostAssistantContentType: String, Decodable, Equatable {
    case text
    case thinking
    case toolCall
}

struct AgentHostAssistantToolCall: Decodable, Equatable {
    let id: String
    let name: String
    let argumentsSummary: String
}

enum AgentHostACPContentBlock: Decodable, Equatable {
    case text(String)
    case image(mimeType: String, data: Data?, uri: String?)
    case audio(mimeType: String, data: Data?)
    case resourceLink(
        name: String,
        uri: String,
        title: String?,
        description: String?,
        mimeType: String?
    )
    case resource(uri: String, mimeType: String?, text: String?, data: Data?)
    case unsupported(type: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case data
        case mimeType
        case uri
        case name
        case title
        case description
        case resource
    }

    private struct EmbeddedResource: Decodable {
        let uri: String
        let mimeType: String?
        let text: String?
        let blob: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image":
            let encodedData = try container.decode(String.self, forKey: .data)
            self = .image(
                mimeType: try container.decode(String.self, forKey: .mimeType),
                data: Data(base64Encoded: encodedData),
                uri: try container.decodeIfPresent(String.self, forKey: .uri)
            )
        case "audio":
            let encodedData = try container.decode(String.self, forKey: .data)
            self = .audio(
                mimeType: try container.decode(String.self, forKey: .mimeType),
                data: Data(base64Encoded: encodedData)
            )
        case "resource_link":
            self = .resourceLink(
                name: try container.decode(String.self, forKey: .name),
                uri: try container.decode(String.self, forKey: .uri),
                title: try container.decodeIfPresent(String.self, forKey: .title),
                description: try container.decodeIfPresent(String.self, forKey: .description),
                mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType)
            )
        case "resource":
            let resource = try container.decode(EmbeddedResource.self, forKey: .resource)
            self = .resource(
                uri: resource.uri,
                mimeType: resource.mimeType,
                text: resource.text,
                data: resource.blob.flatMap { Data(base64Encoded: $0) }
            )
        default:
            self = .unsupported(type: type)
        }
    }
}

enum AgentHostACPToolCallContent: Decodable, Equatable {
    case content(AgentHostACPContentBlock)
    case diff(path: String, oldText: String?, newText: String)
    case terminal(id: String)
    case unsupported(type: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case content
        case path
        case oldText
        case newText
        case terminalId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "content":
            self = .content(
                try container.decode(AgentHostACPContentBlock.self, forKey: .content)
            )
        case "diff":
            self = .diff(
                path: try container.decode(String.self, forKey: .path),
                oldText: try container.decodeIfPresent(String.self, forKey: .oldText),
                newText: try container.decode(String.self, forKey: .newText)
            )
        case "terminal":
            self = .terminal(id: try container.decode(String.self, forKey: .terminalId))
        default:
            self = .unsupported(type: type)
        }
    }
}

indirect enum AgentHostJSONValue: Decodable, Equatable {
    case object([String: AgentHostJSONValue])
    case array([AgentHostJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AgentHostJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([AgentHostJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    var objectValue: [String: AgentHostJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [AgentHostJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self, value.rounded() == value else { return nil }
        return Int(value)
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var foundationValue: Any {
        switch self {
        case .object(let value): return value.mapValues(\.foundationValue)
        case .array(let value): return value.map(\.foundationValue)
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }

    var prettyPrinted: String? {
        let value = foundationValue
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys]
              ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

struct AgentHostSessionAssistantContentPayload: Decodable, Equatable {
    let sessionId: String
    let sequence: Int
    let turnId: String
    let generationIndex: Int
    let phase: AgentHostAssistantContentPhase
    let contentType: AgentHostAssistantContentType
    let contentIndex: Int
    let delta: String?
    let content: String?
    let toolCall: AgentHostAssistantToolCall?
}

struct AgentHostSessionToolStartedPayload: Decodable, Equatable {
    let sessionId: String
    let sequence: Int
    let turnId: String
    let toolCallId: String
    let toolName: String
    let summary: String
    var content: [AgentHostACPToolCallContent]? = nil
    var rawInput: AgentHostJSONValue? = nil
}

struct AgentHostSessionToolUpdatedPayload: Decodable, Equatable {
    let sessionId: String
    let sequence: Int
    let turnId: String
    let toolCallId: String
    let toolName: String
    let output: String
    var content: [AgentHostACPToolCallContent]? = nil
    var rawOutput: AgentHostJSONValue? = nil
}

struct AgentHostSessionToolCompletedPayload: Decodable, Equatable {
    let sessionId: String
    let sequence: Int
    let turnId: String
    let toolCallId: String
    let toolName: String
    let output: String
    let content: [AgentHostACPToolCallContent]?
    let rawOutput: AgentHostJSONValue?
    let isError: Bool

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case sequence
        case turnId
        case toolCallId
        case toolName
        case output
        case content
        case rawOutput
        case isError
    }

    init(
        sessionId: String,
        sequence: Int,
        turnId: String,
        toolCallId: String,
        toolName: String,
        output: String = "",
        content: [AgentHostACPToolCallContent]? = nil,
        rawOutput: AgentHostJSONValue? = nil,
        isError: Bool
    ) {
        self.sessionId = sessionId
        self.sequence = sequence
        self.turnId = turnId
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.output = output
        self.content = content
        self.rawOutput = rawOutput
        self.isError = isError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            sequence: try container.decode(Int.self, forKey: .sequence),
            turnId: try container.decode(String.self, forKey: .turnId),
            toolCallId: try container.decode(String.self, forKey: .toolCallId),
            toolName: try container.decode(String.self, forKey: .toolName),
            output: try container.decodeIfPresent(String.self, forKey: .output) ?? "",
            content: try container.decodeIfPresent(
                [AgentHostACPToolCallContent].self,
                forKey: .content
            ),
            rawOutput: try container.decodeIfPresent(
                AgentHostJSONValue.self,
                forKey: .rawOutput
            ),
            isError: try container.decode(Bool.self, forKey: .isError)
        )
    }
}

struct AgentHostSessionExtensionStatusChangedPayload: Decodable, Equatable {
    let sessionId: String
    let sequence: Int
    let key: String
    let text: String?
}

struct AgentHostExtensionWidget: Decodable, Equatable {
    enum Placement: String, Decodable {
        case aboveEditor
        case belowEditor
    }

    let lines: [String]
    let placement: Placement

    init(lines: [String], placement: Placement = .aboveEditor) {
        self.lines = lines
        self.placement = placement
    }

    private enum CodingKeys: String, CodingKey {
        case lines, placement
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lines = try container.decode([String].self, forKey: .lines)
        placement = try container.decodeIfPresent(Placement.self, forKey: .placement) ?? .aboveEditor
    }
}

struct AgentHostSessionExtensionWidgetChangedPayload: Decodable, Equatable {
    let sessionId: String
    let sequence: Int
    let key: String
    let widget: AgentHostExtensionWidget?
}

enum AgentHostAccessMode: String, Codable, Equatable, CaseIterable, Identifiable {
    case none
    case readOnly
    case ask
    case full

    var id: String { rawValue }
}

enum AgentHostThinkingLevel: String, Codable, Equatable, CaseIterable, Identifiable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }
}

enum AgentHostApprovalDecision: String, Codable, Equatable, Hashable {
    case allowOnce
    case allowAlways
    case deny
    case rejectAlways
}

enum AgentHostACPElicitationValue: Codable, Equatable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case stringArray([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .stringArray(try container.decode([String].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .stringArray(let value): try container.encode(value)
        }
    }
}

struct AgentHostACPElicitationOption: Decodable, Equatable, Identifiable {
    let value: String
    let title: String
    let description: String?

    var id: String { value }

    init(value: String, title: String, description: String? = nil) {
        self.value = value
        self.title = title
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case value = "const"
        case title
        case description
    }
}

enum AgentHostACPElicitationPropertyType: String, Decodable, Equatable {
    case string
    case integer
    case number
    case boolean
    case array
}

enum AgentHostACPStringFormat: String, Decodable, Equatable {
    case email
    case uri
    case date
    case dateTime = "date-time"
}

struct AgentHostACPElicitationProperty: Decodable, Equatable {
    let type: AgentHostACPElicitationPropertyType
    let title: String?
    let description: String?
    let defaultValue: AgentHostACPElicitationValue?
    let options: [AgentHostACPElicitationOption]
    let minimum: Double?
    let maximum: Double?
    let minItems: Int?
    let maxItems: Int?
    let minLength: Int?
    let maxLength: Int?
    let pattern: String?
    let format: AgentHostACPStringFormat?

    init(
        type: AgentHostACPElicitationPropertyType,
        title: String? = nil,
        description: String? = nil,
        defaultValue: AgentHostACPElicitationValue? = nil,
        options: [AgentHostACPElicitationOption] = [],
        minimum: Double? = nil,
        maximum: Double? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        pattern: String? = nil,
        format: AgentHostACPStringFormat? = nil
    ) {
        self.type = type
        self.title = title
        self.description = description
        self.defaultValue = defaultValue
        self.options = options
        self.minimum = minimum
        self.maximum = maximum
        self.minItems = minItems
        self.maxItems = maxItems
        self.minLength = minLength
        self.maxLength = maxLength
        self.pattern = pattern
        self.format = format
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case title
        case description
        case defaultValue = "default"
        case enumValues = "enum"
        case oneOf
        case items
        case minimum
        case maximum
        case minItems
        case maxItems
        case minLength
        case maxLength
        case pattern
        case format
    }

    private struct Items: Decodable {
        let enumValues: [String]?
        let anyOf: [AgentHostACPElicitationOption]?

        private enum CodingKeys: String, CodingKey {
            case enumValues = "enum"
            case anyOf
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let oneOf = try container.decodeIfPresent(
            [AgentHostACPElicitationOption].self,
            forKey: .oneOf
        )
        let enumValues = try container.decodeIfPresent([String].self, forKey: .enumValues)
        let items = try container.decodeIfPresent(Items.self, forKey: .items)
        let options = oneOf
            ?? items?.anyOf
            ?? (enumValues ?? items?.enumValues ?? []).map {
                AgentHostACPElicitationOption(value: $0, title: $0)
            }
        self.init(
            type: try container.decode(AgentHostACPElicitationPropertyType.self, forKey: .type),
            title: try container.decodeIfPresent(String.self, forKey: .title),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            defaultValue: try container.decodeIfPresent(
                AgentHostACPElicitationValue.self,
                forKey: .defaultValue
            ),
            options: options,
            minimum: try container.decodeIfPresent(Double.self, forKey: .minimum),
            maximum: try container.decodeIfPresent(Double.self, forKey: .maximum),
            minItems: try container.decodeIfPresent(Int.self, forKey: .minItems),
            maxItems: try container.decodeIfPresent(Int.self, forKey: .maxItems),
            minLength: try container.decodeIfPresent(Int.self, forKey: .minLength),
            maxLength: try container.decodeIfPresent(Int.self, forKey: .maxLength),
            pattern: try container.decodeIfPresent(String.self, forKey: .pattern),
            format: try container.decodeIfPresent(AgentHostACPStringFormat.self, forKey: .format)
        )
    }
}

struct AgentHostACPElicitationSchema: Decodable, Equatable {
    let properties: [String: AgentHostACPElicitationProperty]
    let required: [String]
    let title: String?
    let description: String?

    init(
        properties: [String: AgentHostACPElicitationProperty],
        required: [String] = [],
        title: String? = nil,
        description: String? = nil
    ) {
        self.properties = properties
        self.required = required
        self.title = title
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case properties
        case required
        case title
        case description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            properties: try container.decodeIfPresent(
                [String: AgentHostACPElicitationProperty].self,
                forKey: .properties
            ) ?? [:],
            required: try container.decodeIfPresent([String].self, forKey: .required) ?? [],
            title: try container.decodeIfPresent(String.self, forKey: .title),
            description: try container.decodeIfPresent(String.self, forKey: .description)
        )
    }
}

struct AgentHostACPElicitationRequest: Equatable, Identifiable {
    let id: String
    let sessionId: String?
    let requestId: String?
    let message: String
    let schema: AgentHostACPElicitationSchema

    init(
        id: String,
        sessionId: String? = nil,
        requestId: String? = nil,
        message: String,
        schema: AgentHostACPElicitationSchema
    ) {
        self.id = id
        self.sessionId = sessionId
        self.requestId = requestId
        self.message = message
        self.schema = schema
    }
}

enum AgentHostACPElicitationResponse: Encodable, Equatable {
    case accept([String: AgentHostACPElicitationValue])
    case decline
    case cancel

    private enum CodingKeys: String, CodingKey {
        case action
        case content
    }

    private enum Action: String, Encodable {
        case accept
        case decline
        case cancel
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accept(let content):
            try container.encode(Action.accept, forKey: .action)
            try container.encode(content, forKey: .content)
        case .decline:
            try container.encode(Action.decline, forKey: .action)
        case .cancel:
            try container.encode(Action.cancel, forKey: .action)
        }
    }
}

enum AgentHostApprovalOptionKind: String, Decodable, Equatable {
    case allowOnce = "allow_once"
    case allowAlways = "allow_always"
    case rejectOnce = "reject_once"
    case rejectAlways = "reject_always"

    var decision: AgentHostApprovalDecision {
        switch self {
        case .allowOnce: .allowOnce
        case .allowAlways: .allowAlways
        case .rejectOnce: .deny
        case .rejectAlways: .rejectAlways
        }
    }

    var isAllow: Bool {
        self == .allowOnce || self == .allowAlways
    }
}

struct AgentHostApprovalOption: Decodable, Equatable, Identifiable {
    let optionId: String
    let name: String
    let kind: AgentHostApprovalOptionKind

    var id: String { optionId }
}

struct AgentHostApprovalRequest: Decodable, Equatable, Identifiable {
    let id: String
    let toolCallId: String
    let toolName: String
    let summary: String
    let options: [AgentHostApprovalOption]

    private enum CodingKeys: String, CodingKey {
        case id
        case toolCallId
        case toolName
        case summary
        case options
    }

    init(
        id: String,
        toolCallId: String,
        toolName: String,
        summary: String,
        options: [AgentHostApprovalOption] = []
    ) {
        self.id = id
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.summary = summary
        self.options = options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            toolCallId: try container.decode(String.self, forKey: .toolCallId),
            toolName: try container.decode(String.self, forKey: .toolName),
            summary: try container.decode(String.self, forKey: .summary),
            options: try container.decodeIfPresent(
                [AgentHostApprovalOption].self,
                forKey: .options
            ) ?? []
        )
    }
}

struct AgentHostSessionApprovalRequestedPayload: Decodable, Equatable {
    let sessionId: String
    let sequence: Int
    let turnId: String
    let requestId: String
    let toolCallId: String
    let toolName: String
    let summary: String
    let allowOptionId: String?
    let rejectOptionId: String?
    let options: [AgentHostApprovalOption]

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case sequence
        case turnId
        case requestId
        case toolCallId
        case toolName
        case summary
        case allowOptionId
        case rejectOptionId
        case options
    }

    init(
        sessionId: String,
        sequence: Int,
        turnId: String,
        requestId: String,
        toolCallId: String,
        toolName: String,
        summary: String,
        allowOptionId: String? = nil,
        rejectOptionId: String? = nil,
        options: [AgentHostApprovalOption] = []
    ) {
        self.sessionId = sessionId
        self.sequence = sequence
        self.turnId = turnId
        self.requestId = requestId
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.summary = summary
        self.allowOptionId = allowOptionId
        self.rejectOptionId = rejectOptionId
        self.options = options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            sequence: try container.decode(Int.self, forKey: .sequence),
            turnId: try container.decode(String.self, forKey: .turnId),
            requestId: try container.decode(String.self, forKey: .requestId),
            toolCallId: try container.decode(String.self, forKey: .toolCallId),
            toolName: try container.decode(String.self, forKey: .toolName),
            summary: try container.decode(String.self, forKey: .summary),
            allowOptionId: try container.decodeIfPresent(String.self, forKey: .allowOptionId),
            rejectOptionId: try container.decodeIfPresent(String.self, forKey: .rejectOptionId),
            options: try container.decodeIfPresent(
                [AgentHostApprovalOption].self,
                forKey: .options
            ) ?? []
        )
    }

    var approval: AgentHostApprovalRequest {
        AgentHostApprovalRequest(
            id: requestId,
            toolCallId: toolCallId,
            toolName: toolName,
            summary: summary,
            options: options
        )
    }
}

struct AgentHostSessionErrorPayload: Decodable, Equatable {
    let sessionId: String
    let sequence: Int
    let turnId: String
    let code: String
    let message: String
}

enum AgentHostAuthPromptType: String, Decodable, Equatable {
    case text
    case secret
    case select
    case manualCode = "manual_code"
}

struct AgentHostAuthPromptOption: Decodable, Equatable, Identifiable {
    let id: String
    let label: String
    let description: String?
}

struct AgentHostAuthPromptPayload: Decodable, Equatable {
    let flowId: String
    let providerId: String
    let sequence: Int
    let promptId: String
    let type: AgentHostAuthPromptType
    let message: String
    let placeholder: String?
    let options: [AgentHostAuthPromptOption]?
    let allowsEmpty: Bool?
}

enum AgentHostAuthMethod: String, Codable, Equatable, CaseIterable, Identifiable {
    case oauth
    case apiKey = "api_key"

    var id: String { rawValue }
}

struct AgentHostProviderAuthMethod: Decodable, Equatable, Identifiable {
    let type: AgentHostAuthMethod
    let name: String
    let loginLabel: String?

    var id: AgentHostAuthMethod { type }
}

enum AgentHostProviderAuthSource: String, Decodable, Equatable {
    case stored
    case runtime
    case environment
    case fallback
    case modelsJSONKey = "models_json_key"
    case modelsJSONCommand = "models_json_command"
}

struct AgentHostProviderAuthStatus: Decodable, Equatable {
    let configured: Bool
    let source: AgentHostProviderAuthSource?
    let credentialType: AgentHostAuthMethod?
    let canDisconnect: Bool
    let label: String?
}

struct AgentHostProviderModelCounts: Decodable, Equatable {
    let total: Int
    let available: Int
}

struct AgentHostProvider: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let methods: [AgentHostProviderAuthMethod]
    let status: AgentHostProviderAuthStatus
    let models: AgentHostProviderModelCounts
}

struct AgentHostProviderListResult: Decodable, Equatable {
    let providers: [AgentHostProvider]
}

struct AgentHostAuthPromptCancelledPayload: Decodable, Equatable {
    let flowId: String
    let providerId: String
    let sequence: Int
    let promptId: String
}

struct AgentHostAuthInfoLink: Decodable, Equatable, Identifiable {
    let url: String
    let label: String?

    var id: String { url }
}

enum AgentHostAuthNotice: Decodable, Equatable {
    case info(message: String, links: [AgentHostAuthInfoLink])
    case authURL(url: String, instructions: String?)
    case deviceCode(
        userCode: String,
        verificationURI: String,
        intervalSeconds: Int?,
        expiresInSeconds: Int?
    )
    case progress(message: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case message
        case links
        case url
        case instructions
        case userCode
        case verificationURI = "verificationUri"
        case intervalSeconds
        case expiresInSeconds
    }

    private enum NoticeType: String, Decodable {
        case info
        case authURL = "auth_url"
        case deviceCode = "device_code"
        case progress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(NoticeType.self, forKey: .type) {
        case .info:
            self = .info(
                message: try container.decode(String.self, forKey: .message),
                links: try container.decodeIfPresent(
                    [AgentHostAuthInfoLink].self,
                    forKey: .links
                ) ?? []
            )
        case .authURL:
            self = .authURL(
                url: try container.decode(String.self, forKey: .url),
                instructions: try container.decodeIfPresent(String.self, forKey: .instructions)
            )
        case .deviceCode:
            self = .deviceCode(
                userCode: try container.decode(String.self, forKey: .userCode),
                verificationURI: try container.decode(String.self, forKey: .verificationURI),
                intervalSeconds: try container.decodeIfPresent(Int.self, forKey: .intervalSeconds),
                expiresInSeconds: try container.decodeIfPresent(Int.self, forKey: .expiresInSeconds)
            )
        case .progress:
            self = .progress(message: try container.decode(String.self, forKey: .message))
        }
    }
}

struct AgentHostAuthNoticePayload: Decodable, Equatable {
    let flowId: String
    let providerId: String
    let sequence: Int
    let notice: AgentHostAuthNotice
}

enum AgentHostAuthOutcome: String, Decodable, Equatable {
    case succeeded
    case cancelled
    case failed
}

struct AgentHostAuthFinishedPayload: Decodable, Equatable {
    let flowId: String
    let providerId: String
    let sequence: Int
    let outcome: AgentHostAuthOutcome
    let error: AgentHostResponseError?
}

enum AgentHostModelsChangeReason: String, Decodable, Equatable {
    case authentication
}

struct AgentHostModelsChangedPayload: Decodable, Equatable {
    let reason: AgentHostModelsChangeReason
    let providerId: String
}

enum AgentHostServerEvent: Equatable {
    case hostHello(AgentHostHelloPayload)
    case sessionStateChanged(AgentHostSessionStateChangedPayload)
    case sessionMessageDelta(AgentHostSessionMessageDeltaPayload)
    case sessionUserContent(AgentHostSessionUserContentPayload)
    case sessionAssistantContent(AgentHostSessionAssistantContentPayload)
    case sessionToolStarted(AgentHostSessionToolStartedPayload)
    case sessionToolUpdated(AgentHostSessionToolUpdatedPayload)
    case sessionToolCompleted(AgentHostSessionToolCompletedPayload)
    case sessionApprovalRequested(AgentHostSessionApprovalRequestedPayload)
    case elicitationRequested(AgentHostACPElicitationRequest)
    case sessionError(AgentHostSessionErrorPayload)
    case sessionModeChanged(AgentHostSessionModeChangedPayload)
    case sessionConfigOptionsChanged(AgentHostSessionConfigOptionsChangedPayload)
    case sessionInfoChanged(AgentHostSessionInfoChangedPayload)
    case sessionUsageChanged(AgentHostSessionUsageChangedPayload)
    case sessionAvailableCommandsChanged(AgentHostSessionAvailableCommandsChangedPayload)
    case sessionPlanChanged(AgentHostSessionPlanChangedPayload)
    case sessionExtensionStatusChanged(AgentHostSessionExtensionStatusChangedPayload)
    case sessionExtensionWidgetChanged(AgentHostSessionExtensionWidgetChangedPayload)
    case authPrompt(AgentHostAuthPromptPayload)
    case authPromptCancelled(AgentHostAuthPromptCancelledPayload)
    case authNotice(AgentHostAuthNoticePayload)
    case authFinished(AgentHostAuthFinishedPayload)
    case modelsChanged(AgentHostModelsChangedPayload)
    case unknown(name: String)

    static func decode(from data: Data) throws -> AgentHostServerEvent {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let method = object["method"] as? String {
            if method == "session/update" {
                return try decodeACPSessionUpdate(object)
            }
            if method == "session/request_permission" {
                return try decodeACPPermissionRequest(object)
            }
            if method == "elicitation/create" {
                return try decodeACPElicitationRequest(object)
            }
            if method.hasPrefix("_piWork/"),
               let params = object["params"] {
                var legacy = object
                legacy["version"] = agentHostProtocolVersion
                legacy["kind"] = "event"
                legacy["event"] = String(method.dropFirst("_piWork/".count))
                legacy["payload"] = params
                legacy.removeValue(forKey: "method")
                let legacyData = try JSONSerialization.data(withJSONObject: legacy)
                return try decode(from: legacyData)
            }
        }

        let decoder = JSONDecoder()
        let header = try decoder.decode(AgentHostWireHeader.self, from: data)
        guard header.version == agentHostProtocolVersion,
              header.kind == "event" else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Unsupported Agent Host event"
                )
            )
        }

        switch header.event {
        case "host.hello":
            let event = try decoder.decode(
                AgentHostEvent<AgentHostHelloPayload>.self,
                from: data
            )
            return .hostHello(event.payload)
        case "session.stateChanged":
            let event = try decoder.decode(
                AgentHostEvent<AgentHostSessionStateChangedPayload>.self,
                from: data
            )
            return .sessionStateChanged(event.payload)
        case "session.messageDelta":
            let event = try decoder.decode(
                AgentHostEvent<AgentHostSessionMessageDeltaPayload>.self,
                from: data
            )
            return .sessionMessageDelta(event.payload)
        case "session.assistantContent":
            let event = try decoder.decode(
                AgentHostEvent<AgentHostSessionAssistantContentPayload>.self,
                from: data
            )
            return .sessionAssistantContent(event.payload)
        case "session.toolStarted":
            let event = try decoder.decode(
                AgentHostEvent<AgentHostSessionToolStartedPayload>.self,
                from: data
            )
            return .sessionToolStarted(event.payload)
        case "session.toolUpdated":
            let event = try decoder.decode(
                AgentHostEvent<AgentHostSessionToolUpdatedPayload>.self,
                from: data
            )
            return .sessionToolUpdated(event.payload)
        case "session.toolCompleted":
            let event = try decoder.decode(
                AgentHostEvent<AgentHostSessionToolCompletedPayload>.self,
                from: data
            )
            return .sessionToolCompleted(event.payload)
        case "session.extensionStatusChanged":
            let event = try decoder.decode(
                AgentHostEvent<AgentHostSessionExtensionStatusChangedPayload>.self,
                from: data
            )
            return .sessionExtensionStatusChanged(event.payload)
        case "session.approvalRequested":
            let event = try decoder.decode(
                AgentHostEvent<AgentHostSessionApprovalRequestedPayload>.self,
                from: data
            )
            return .sessionApprovalRequested(event.payload)
        case "session.error":
            let event = try decoder.decode(
                AgentHostEvent<AgentHostSessionErrorPayload>.self,
                from: data
            )
            return .sessionError(event.payload)
        case "auth.prompt":
            let event = try decoder.decode(
                AgentHostEvent<AgentHostAuthPromptPayload>.self,
                from: data
            )
            return .authPrompt(event.payload)
        case "auth.promptCancelled":
            let event = try decoder.decode(
                AgentHostEvent<AgentHostAuthPromptCancelledPayload>.self,
                from: data
            )
            return .authPromptCancelled(event.payload)
        case "auth.notice":
            let event = try decoder.decode(
                AgentHostEvent<AgentHostAuthNoticePayload>.self,
                from: data
            )
            return .authNotice(event.payload)
        case "auth.finished":
            let event = try decoder.decode(
                AgentHostEvent<AgentHostAuthFinishedPayload>.self,
                from: data
            )
            return .authFinished(event.payload)
        case "models.changed":
            let event = try decoder.decode(
                AgentHostEvent<AgentHostModelsChangedPayload>.self,
                from: data
            )
            return .modelsChanged(event.payload)
        default:
            if let eventName = header.event {
                return .unknown(name: eventName)
            }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Unsupported Agent Host event"
                )
            )
        }
    }

    private static func decodeACPSessionUpdate(
        _ object: [String: Any]
    ) throws -> AgentHostServerEvent {
        guard
            let params = object["params"] as? [String: Any],
            let sessionId = params["sessionId"] as? String,
            let update = params["update"] as? [String: Any],
            let updateType = update["sessionUpdate"] as? String
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Invalid ACP session/update")
            )
        }

        let metadata = update["_meta"] as? [String: Any]
        let sequence = metadata?["sequence"] as? Int ?? 0
        let turnId = metadata?["turnId"] as? String
            ?? update["messageId"] as? String
            ?? ""
        let toolContents = update["content"] as? [[String: Any]]
        let text: String? = {
            if let content = update["content"] as? [String: Any] {
                return content["text"] as? String
            }
            if let toolContents {
                let textBlocks = toolContents.compactMap { item -> String? in
                    if let nested = item["content"] as? [String: Any],
                       let text = nested["text"] as? String {
                        return text
                    }
                    return nil
                }
                return textBlocks.isEmpty ? nil : textBlocks.joined(separator: "\n")
            }
            return nil
        }()
        let base: [String: Any] = [
            "version": agentHostProtocolVersion,
            "kind": "event",
            "payload": [
                "sessionId": sessionId,
                "sequence": sequence,
                "turnId": turnId
            ]
        ]

        switch updateType {
        case "user_message_chunk":
            guard let text else { throw invalidACPSessionUpdate() }
            return .sessionUserContent(
                AgentHostSessionUserContentPayload(
                    sessionId: sessionId,
                    sequence: sequence,
                    messageId: update["messageId"] as? String ?? "",
                    text: text
                )
            )
        case "agent_message_chunk", "agent_thought_chunk":
            var legacy = base
            legacy["event"] = "session.assistantContent"
            var payload = base["payload"] as! [String: Any]
            payload["generationIndex"] = metadata?["generationIndex"] as? Int ?? 0
            payload["phase"] = metadata?["phase"] as? String ?? "delta"
            payload["contentType"] = updateType == "agent_thought_chunk" ? "thinking" : "text"
            payload["contentIndex"] = metadata?["contentIndex"] as? Int ?? 0
            if let text { payload["delta"] = text }
            legacy["payload"] = payload
            return try decode(from: JSONSerialization.data(withJSONObject: legacy))
        case "tool_call":
            var legacy = base
            legacy["event"] = "session.toolStarted"
            var payload = base["payload"] as! [String: Any]
            payload["toolCallId"] = update["toolCallId"] as? String ?? ""
            payload["toolName"] = update["title"] as? String ?? "Tool"
            if let rawInput = update["rawInput"] as? [String: Any] {
                payload["rawInput"] = rawInput
                if let summary = rawInput["summary"] as? String {
                    payload["summary"] = summary
                } else if let data = try? JSONSerialization.data(
                    withJSONObject: rawInput,
                    options: [.sortedKeys]
                ) {
                    payload["summary"] = String(data: data, encoding: .utf8) ?? ""
                }
            } else {
                payload["summary"] = ""
            }
            if let toolContents { payload["content"] = toolContents }
            legacy["payload"] = payload
            return try decode(from: JSONSerialization.data(withJSONObject: legacy))
        case "tool_call_update":
            var legacy = base
            let status = update["status"] as? String
            legacy["event"] = status == "completed" || status == "failed"
                ? "session.toolCompleted"
                : "session.toolUpdated"
            var payload = base["payload"] as! [String: Any]
            payload["toolCallId"] = update["toolCallId"] as? String ?? ""
            payload["toolName"] = update["title"] as? String
                ?? metadata?["toolName"] as? String
                ?? "Tool"
            payload["output"] = text ?? ""
            if let toolContents { payload["content"] = toolContents }
            if let rawOutput = update["rawOutput"] { payload["rawOutput"] = rawOutput }
            payload["isError"] = status == "failed"
            legacy["payload"] = payload
            return try decode(from: JSONSerialization.data(withJSONObject: legacy))
        case "current_mode_update":
            guard let currentModeId = update["currentModeId"] as? String else {
                throw invalidACPSessionUpdate()
            }
            return .sessionModeChanged(
                AgentHostSessionModeChangedPayload(
                    sessionId: sessionId,
                    sequence: sequence,
                    currentModeId: currentModeId
                )
            )
        case "config_option_update":
            return .sessionConfigOptionsChanged(
                AgentHostSessionConfigOptionsChangedPayload(
                    sessionId: sessionId,
                    sequence: sequence,
                    configOptions: try decodeACPValue(
                        update["configOptions"] ?? [],
                        as: [AgentHostACPSetConfigOptionResult.ConfigOption].self
                    )
                )
            )
        case "session_info_update":
            return .sessionInfoChanged(
                AgentHostSessionInfoChangedPayload(
                    sessionId: sessionId,
                    sequence: sequence,
                    title: update["title"] as? String,
                    updatedAt: update["updatedAt"] as? String
                )
            )
        case "usage_update":
            guard let used = update["used"] as? Int,
                  let size = update["size"] as? Int else {
                throw invalidACPSessionUpdate()
            }
            let cost: AgentHostACPSessionCost?
            if let value = update["cost"], !(value is NSNull) {
                cost = try decodeACPValue(value, as: AgentHostACPSessionCost.self)
            } else {
                cost = nil
            }
            return .sessionUsageChanged(
                AgentHostSessionUsageChangedPayload(
                    sessionId: sessionId,
                    sequence: sequence,
                    used: used,
                    size: size,
                    cost: cost
                )
            )
        case "available_commands_update":
            return .sessionAvailableCommandsChanged(
                AgentHostSessionAvailableCommandsChangedPayload(
                    sessionId: sessionId,
                    sequence: sequence,
                    availableCommands: try decodeACPValue(
                        update["availableCommands"] ?? [],
                        as: [AgentHostACPAvailableCommand].self
                    )
                )
            )
        case "plan":
            return .sessionPlanChanged(
                AgentHostSessionPlanChangedPayload(
                    sessionId: sessionId,
                    sequence: sequence,
                    entries: try decodeACPValue(
                        update["entries"] ?? [],
                        as: [AgentHostACPPlanEntry].self
                    )
                )
            )
        case "_piWork/extension_status":
            guard let key = update["key"] as? String else {
                throw invalidACPSessionUpdate()
            }
            return .sessionExtensionStatusChanged(
                AgentHostSessionExtensionStatusChangedPayload(
                    sessionId: sessionId,
                    sequence: sequence,
                    key: key,
                    text: update["text"] as? String
                )
            )
        case "_piWork/extension_widget":
            guard let key = update["key"] as? String else {
                throw invalidACPSessionUpdate()
            }
            return .sessionExtensionWidgetChanged(
                AgentHostSessionExtensionWidgetChangedPayload(
                    sessionId: sessionId,
                    sequence: sequence,
                    key: key,
                    widget: update["lines"] == nil ? nil : try decodeACPValue(
                        update,
                        as: AgentHostExtensionWidget.self
                    )
                )
            )
        default:
            return .unknown(name: updateType)
        }
    }

    private static func decodeACPValue<Value: Decodable>(
        _ value: Any,
        as type: Value.Type
    ) throws -> Value {
        try JSONDecoder().decode(
            type,
            from: JSONSerialization.data(withJSONObject: value)
        )
    }

    private static func invalidACPSessionUpdate() -> DecodingError {
        .dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "Invalid ACP session/update")
        )
    }

    private static func decodeACPPermissionRequest(
        _ object: [String: Any]
    ) throws -> AgentHostServerEvent {
        guard
            let params = object["params"] as? [String: Any],
            let sessionId = params["sessionId"] as? String,
            let toolCall = params["toolCall"] as? [String: Any]
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Invalid ACP permission request")
            )
        }
        let metadata = toolCall["_meta"] as? [String: Any]
        let requestId: String = {
            if let value = object["id"] as? String { return value }
            if let value = object["id"] as? NSNumber { return value.stringValue }
            return ""
        }()
        let options = params["options"] as? [[String: Any]] ?? []
        let allowOptionId = options.first {
            ($0["kind"] as? String)?.hasPrefix("allow_") == true
        }?["optionId"] as? String
        let rejectOptionId = options.first {
            ($0["kind"] as? String)?.hasPrefix("reject_") == true
        }?["optionId"] as? String
        var payload: [String: Any] = [
            "sessionId": sessionId,
            "sequence": metadata?["sequence"] as? Int ?? 0,
            "turnId": metadata?["turnId"] as? String ?? "",
            "requestId": requestId,
            "toolCallId": toolCall["toolCallId"] as? String ?? "",
            "toolName": toolCall["title"] as? String ?? "Tool",
            "summary": (toolCall["rawInput"] as? [String: Any])?["summary"] as? String ?? ""
        ]
        if let allowOptionId { payload["allowOptionId"] = allowOptionId }
        if let rejectOptionId { payload["rejectOptionId"] = rejectOptionId }
        payload["options"] = options
        let legacy: [String: Any] = [
            "version": agentHostProtocolVersion,
            "kind": "event",
            "event": "session.approvalRequested",
            "payload": payload
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        return try decode(from: legacyData)
    }

    private static func decodeACPElicitationRequest(
        _ object: [String: Any]
    ) throws -> AgentHostServerEvent {
        guard
            let params = object["params"] as? [String: Any],
            params["mode"] as? String == "form",
            let message = params["message"] as? String,
            let requestedSchema = params["requestedSchema"]
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Invalid ACP elicitation request")
            )
        }
        let id: String = {
            if let value = object["id"] as? String { return value }
            if let value = object["id"] as? NSNumber { return value.stringValue }
            return ""
        }()
        return .elicitationRequested(
            AgentHostACPElicitationRequest(
                id: id,
                sessionId: params["sessionId"] as? String,
                requestId: params["requestId"] as? String,
                message: message,
                schema: try decodeACPValue(
                    requestedSchema,
                    as: AgentHostACPElicitationSchema.self
                )
            )
        )
    }
}

struct AgentHostRequest<Parameters: Encodable>: Encodable {
    let jsonrpc: String
    let id: String
    let method: String
    let params: Parameters

    init(id: String, method: String, params: Parameters) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    func encodedLine() throws -> Data {
        let encodedParams = try JSONEncoder().encode(params)
        let paramsObject = try JSONSerialization.jsonObject(with: encodedParams)
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": agentHostACPMethod(for: method),
            "params": agentHostACPParameters(
                for: method,
                encodedParams: paramsObject
            )
        ]
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }
}

struct AgentHostNotification<Parameters: Encodable>: Encodable {
    let method: String
    let params: Parameters

    func encodedLine() throws -> Data {
        let encodedParams = try JSONEncoder().encode(params)
        let paramsObject = try JSONSerialization.jsonObject(with: encodedParams)
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "method": agentHostACPMethod(for: method),
            "params": agentHostACPParameters(for: method, encodedParams: paramsObject)
        ]
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }
}

private func agentHostACPMethod(for method: String) -> String {
    switch method {
    case "sessions.list": return "session/list"
    case "session.createDraft": return "session/new"
    case "session.prompt": return "session/prompt"
    case "session.abort": return "session/cancel"
    case "session.close": return "session/close"
    case "session.delete": return "session/delete"
    case "session.setAccessMode": return "session/set_mode"
    case "session.open": return "session/resume"
    case "models.list": return "_piWork/models/list"
    case "providers.list": return "_piWork/providers/list"
    case "auth.start": return "_piWork/auth/start"
    case "auth.respond": return "_piWork/auth/respond"
    case "auth.cancel": return "_piWork/auth/cancel"
    case "auth.logout": return "_piWork/auth/logout"
    case "settings.get": return "_piWork/settings/get"
    case "settings.update": return "_piWork/settings/update"
    case "extensions.listInstalled": return "_piWork/extensions/listInstalled"
    case "extensions.install": return "_piWork/extensions/install"
    case "extensions.setEnabled": return "_piWork/extensions/setEnabled"
    case "extensions.update": return "_piWork/extensions/update"
    case "extensions.remove": return "_piWork/extensions/remove"
    case "extensions.settings.list": return "_piWork/extensions/settings/list"
    case "extensions.settings.update": return "_piWork/extensions/settings/update"
    case "git.branches": return "_piWork/git/branches"
    case "session.exportHtml": return "_piWork/session/exportHtml"
    case "session.snapshot": return "_piWork/session/snapshot"
    case "session.transcriptPage": return "_piWork/session/transcriptPage"
    case "session.toolOutput": return "_piWork/session/toolOutput"
    case "session.commands": return "_piWork/session/commands"
    case "session.rename": return "_piWork/session/rename"
    case "session.setGitBranch": return "_piWork/session/setGitBranch"
    case "session.setModel", "session.setThinkingLevel", "session.setModelOption":
        return "session/set_config_option"
    default: return method
    }
}

private func agentHostACPParameters(for method: String, encodedParams: Any) -> Any {
    guard var params = encodedParams as? [String: Any] else { return encodedParams }
    switch method {
    case "sessions.list":
        if let value = params.removeValue(forKey: "sessionDirectory"), !(value is NSNull) {
            params["_meta"] = ["piWork": ["sessionDirectory": value]]
        }
    case "session.createDraft":
        params["mcpServers"] = []
        var metadata: [String: Any] = [:]
        if let value = params["sessionDirectory"], !(value is NSNull) {
            metadata["sessionDirectory"] = value
        }
        if let value = params["profile"], !(value is NSNull) {
            metadata["profile"] = value
        }
        params.removeValue(forKey: "sessionDirectory")
        params.removeValue(forKey: "profile")
        if !metadata.isEmpty {
            params["_meta"] = ["piWork": metadata]
        }
    case "session.prompt":
        let text = params["text"] as? String ?? ""
        let images = (params["images"] as? [[String: Any]] ?? []).map { image in
            [
                "type": "image",
                "mimeType": image["mimeType"] as? String ?? "image/png",
                "data": image["data"] as? String ?? ""
            ] as [String: Any]
        }
        params["prompt"] = [["type": "text", "text": text] as [String: Any]] + images
        params.removeValue(forKey: "text")
        params.removeValue(forKey: "images")
        params.removeValue(forKey: "turnId")
    case "session.open":
        params["mcpServers"] = []
        var metadata: [String: Any] = [:]
        if let value = params["sessionDirectory"], !(value is NSNull) {
            metadata["sessionDirectory"] = value
        }
        if let value = params["profile"], !(value is NSNull) {
            metadata["profile"] = value
        }
        params.removeValue(forKey: "sessionDirectory")
        params.removeValue(forKey: "profile")
        if !metadata.isEmpty {
            params["_meta"] = ["piWork": metadata]
        }
    case "session.delete":
        var metadata: [String: Any] = [:]
        if let value = params["sessionDirectory"], !(value is NSNull) {
            metadata["sessionDirectory"] = value
        }
        params.removeValue(forKey: "cwd")
        params.removeValue(forKey: "sessionDirectory")
        if !metadata.isEmpty {
            params["_meta"] = ["piWork": metadata]
        }
    case "session.setAccessMode":
        params["modeId"] = params.removeValue(forKey: "accessMode")
    case "session.setModel":
        params["configId"] = "model"
        params["value"] = "\(params["provider"] as? String ?? "")/\(params["modelId"] as? String ?? "")"
        params.removeValue(forKey: "provider")
        params.removeValue(forKey: "modelId")
    case "session.setThinkingLevel":
        params["configId"] = "thought_level"
        params["value"] = params.removeValue(forKey: "thinkingLevel")
    case "session.setModelOption":
        let option = params.removeValue(forKey: "option") as? String
        params["configId"] = option == "oneMillionContext"
            ? "one_million_context"
            : "fast_mode"
        params["type"] = "boolean"
        params["value"] = params.removeValue(forKey: "enabled")
    default:
        break
    }
    return params
}

struct AgentHostSessionListParameters: Codable, Equatable {
    let cwd: String
    let sessionDirectory: String?
}

struct AgentHostAuthStartParameters: Encodable, Equatable {
    let flowId: String
    let providerId: String
    let method: AgentHostAuthMethod
}

struct AgentHostAuthStartResult: Decodable, Equatable {
    let accepted: Bool
    let flowId: String
}

struct AgentHostAuthRespondParameters: Encodable, Equatable {
    let flowId: String
    let promptId: String
    let value: String
}

struct AgentHostAuthAcceptedResult: Decodable, Equatable {
    let accepted: Bool
}

struct AgentHostAuthCancelParameters: Encodable, Equatable {
    let flowId: String
}

struct AgentHostAuthCancelResult: Decodable, Equatable {
    let cancelRequested: Bool
}

struct AgentHostAuthLogoutParameters: Encodable, Equatable {
    let providerId: String
}

struct AgentHostAuthLogoutResult: Decodable, Equatable {
    let removed: Bool
    let provider: AgentHostProvider
}

struct AgentHostEmptyParameters: Encodable, Equatable {}

struct AgentHostDefaultModel: Codable, Equatable, Hashable {
    let provider: String
    let modelId: String
}

enum AgentHostTransport: String, Codable, Equatable, CaseIterable, Identifiable {
    case auto
    case sse
    case websocket
    case websocketCached = "websocket-cached"

    var id: String { rawValue }
}

struct AgentHostSettings: Codable, Equatable {
    let defaultModel: AgentHostDefaultModel?
    let defaultThinkingLevel: AgentHostThinkingLevel
    let transport: AgentHostTransport
    let compactionEnabled: Bool
    let retryEnabled: Bool
}

struct AgentHostSettingsPatch: Encodable, Equatable {
    let defaultModel: AgentHostDefaultModel?
    let defaultThinkingLevel: AgentHostThinkingLevel?
    let transport: AgentHostTransport?
    let compactionEnabled: Bool?
    let retryEnabled: Bool?

    init(
        defaultModel: AgentHostDefaultModel? = nil,
        defaultThinkingLevel: AgentHostThinkingLevel? = nil,
        transport: AgentHostTransport? = nil,
        compactionEnabled: Bool? = nil,
        retryEnabled: Bool? = nil
    ) {
        self.defaultModel = defaultModel
        self.defaultThinkingLevel = defaultThinkingLevel
        self.transport = transport
        self.compactionEnabled = compactionEnabled
        self.retryEnabled = retryEnabled
    }
}

struct AgentHostSettingsUpdateParameters: Encodable, Equatable {
    let patch: AgentHostSettingsPatch
}

enum AgentHostExtensionPackageScope: String, Codable, Equatable {
    case user
    case project
}

struct AgentHostInstalledExtensionPackage: Decodable, Equatable, Identifiable {
    let source: String
    let scope: AgentHostExtensionPackageScope
    let filtered: Bool
    let installedPath: String?
    let enabled: Bool
    let version: String?

    init(
        source: String,
        scope: AgentHostExtensionPackageScope,
        filtered: Bool,
        installedPath: String?,
        enabled: Bool,
        version: String? = nil
    ) {
        self.source = source
        self.scope = scope
        self.filtered = filtered
        self.installedPath = installedPath
        self.enabled = enabled
        self.version = version
    }

    var id: String { "\(scope.rawValue):\(source)" }
}

struct AgentHostInstalledExtensionsResult: Decodable, Equatable {
    let packages: [AgentHostInstalledExtensionPackage]
}

enum AgentHostExtensionSettingFieldKind: String, Decodable, Equatable {
    case boolean
    case choice
    case secure
    case integer
    case number
    case text
    case json
}

struct AgentHostExtensionSettingOption: Decodable, Equatable {
    let value: String
    let label: String
}

struct AgentHostExtensionSettingField: Decodable, Equatable, Identifiable {
    let path: String
    let title: String
    let description: String?
    let kind: AgentHostExtensionSettingFieldKind
    let value: String?
    let defaultValue: String?
    let hasValue: Bool
    let options: [AgentHostExtensionSettingOption]?
    let group: String?
    let required: Bool
    let readOnly: Bool
    let advanced: Bool

    var id: String { path }

    init(
        path: String,
        title: String,
        description: String?,
        kind: AgentHostExtensionSettingFieldKind,
        value: String?,
        defaultValue: String?,
        hasValue: Bool,
        options: [AgentHostExtensionSettingOption]?,
        group: String?,
        required: Bool,
        readOnly: Bool,
        advanced: Bool
    ) {
        self.path = path
        self.title = title
        self.description = description
        self.kind = kind
        self.value = value
        self.defaultValue = defaultValue
        self.hasValue = hasValue
        self.options = options
        self.group = group
        self.required = required
        self.readOnly = readOnly
        self.advanced = advanced
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case title
        case description
        case kind
        case value
        case defaultValue
        case hasValue
        case options
        case group
        case required
        case readOnly
        case advanced
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? Self.fallbackTitle(for: path)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        kind = try container.decode(AgentHostExtensionSettingFieldKind.self, forKey: .kind)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
        hasValue = try container.decodeIfPresent(Bool.self, forKey: .hasValue) ?? false
        options = try container.decodeIfPresent(
            [AgentHostExtensionSettingOption].self,
            forKey: .options
        )
        group = try container.decodeIfPresent(String.self, forKey: .group)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        advanced = try container.decodeIfPresent(Bool.self, forKey: .advanced) ?? false
    }

    private static func fallbackTitle(for path: String) -> String {
        let component = path.split(separator: "/").last.map(String.init) ?? path
        return component
            .replacingOccurrences(of: "~1", with: "/")
            .replacingOccurrences(of: "~0", with: "~")
    }
}

struct AgentHostExtensionSettings: Decodable, Equatable, Identifiable {
    let source: String
    let scope: AgentHostExtensionPackageScope
    let configurable: Bool
    let fields: [AgentHostExtensionSettingField]

    var id: String { "\(scope.rawValue):\(source)" }
}

struct AgentHostExtensionSettingsResult: Decodable, Equatable {
    let extensions: [AgentHostExtensionSettings]
}

enum AgentHostExtensionSettingChangeOperation: String, Encodable, Equatable {
    case set
    case remove
}

struct AgentHostExtensionSettingChange: Encodable, Equatable {
    let path: String
    let operation: AgentHostExtensionSettingChangeOperation
    let value: String?

    init(path: String, value: String) {
        self.path = path
        operation = .set
        self.value = value
    }

    init(removing path: String) {
        self.path = path
        operation = .remove
        value = nil
    }
}

struct AgentHostExtensionSettingsUpdateParameters: Encodable, Equatable {
    let source: String
    let scope: AgentHostExtensionPackageScope
    let changes: [AgentHostExtensionSettingChange]
}

enum AgentHostSlashCommandSource: String, Decodable, Equatable {
    case agent
    case extensionCommand = "extension"
    case skill
}

struct AgentHostSlashCommand: Decodable, Equatable, Identifiable {
    let name: String
    let description: String?
    let source: AgentHostSlashCommandSource

    var id: String { "\(source.rawValue):\(name)" }
}

struct AgentHostSlashCommandsResult: Decodable, Equatable {
    let commands: [AgentHostSlashCommand]
}

struct AgentHostExtensionPackageParameters: Encodable, Equatable {
    let source: String
    let scope: AgentHostExtensionPackageScope
}

struct AgentHostExtensionInstallParameters: Encodable, Equatable {
    let source: String
}

struct AgentHostExtensionEnabledParameters: Encodable, Equatable {
    let source: String
    let scope: AgentHostExtensionPackageScope
    let enabled: Bool
}

enum AgentHostSessionProfile: String, Codable, Equatable {
    case chat
    case work
}

struct AgentHostSessionCreateDraftParameters: Encodable, Equatable {
    let cwd: String
    let sessionDirectory: String?
    let profile: AgentHostSessionProfile

    init(
        cwd: String,
        sessionDirectory: String?,
        profile: AgentHostSessionProfile
    ) {
        self.cwd = cwd
        self.sessionDirectory = sessionDirectory
        self.profile = profile
    }
}

struct AgentHostSessionOpenParameters: Encodable, Equatable {
    let sessionId: String
    let cwd: String
    let sessionDirectory: String?
    let profile: AgentHostSessionProfile

    init(
        sessionId: String,
        cwd: String,
        sessionDirectory: String?,
        profile: AgentHostSessionProfile
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.sessionDirectory = sessionDirectory
        self.profile = profile
    }
}

struct AgentHostACPSessionOpenParameters: Encodable, Equatable {
    struct Metadata: Encodable, Equatable {
        struct PiWork: Encodable, Equatable {
            let sessionDirectory: String?
            let profile: AgentHostSessionProfile
        }

        let piWork: PiWork
    }

    let sessionId: String
    let cwd: String
    let mcpServers: [String]
    let metadata: Metadata

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case cwd
        case mcpServers
        case metadata = "_meta"
    }

    init(
        sessionId: String,
        cwd: String,
        sessionDirectory: String?,
        profile: AgentHostSessionProfile
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        mcpServers = []
        metadata = Metadata(
            piWork: .init(
                sessionDirectory: sessionDirectory,
                profile: profile
            )
        )
    }
}

struct AgentHostSessionExportHTMLParameters: Encodable, Equatable {
    let sessionId: String
    let path: String
    let sessionDirectory: String?
    let profile: AgentHostSessionProfile
    let outputPath: String
}

struct AgentHostSessionIdentifierParameters: Encodable, Equatable {
    let sessionId: String
}

struct AgentHostSessionTranscriptPageParameters: Encodable, Equatable {
    let sessionId: String
    let cursor: String
    let limit: Int
}

struct AgentHostSessionToolOutputParameters: Encodable, Equatable {
    let sessionId: String
    let toolCallId: String
}

struct AgentHostGitBranchesParameters: Encodable, Equatable {
    let cwd: String
}

struct AgentHostGitBranchesResult: Decodable, Equatable {
    let available: Bool
    let currentBranch: String?
    let branches: [String]

    static let unavailable = AgentHostGitBranchesResult(
        available: false,
        currentBranch: nil,
        branches: []
    )
}

struct AgentHostSessionSetGitBranchParameters: Encodable, Equatable {
    let sessionId: String
    let branch: String
}

struct AgentHostSessionSetGitBranchResult: Decodable, Equatable {
    let sessionId: String
    let branch: String
}

struct AgentHostSessionDeleteParameters: Encodable, Equatable {
    let sessionId: String
    let cwd: String
    let sessionDirectory: String?
}

struct AgentHostSessionRenameParameters: Encodable, Equatable {
    let sessionId: String
    let title: String
}

struct AgentHostPromptImage: Encodable, Equatable {
    let mimeType: String
    let data: Data
}

struct AgentHostSessionPromptParameters: Encodable, Equatable {
    let sessionId: String
    let turnId: String
    let text: String
    let images: [AgentHostPromptImage]

    init(
        sessionId: String,
        turnId: String,
        text: String,
        images: [AgentHostPromptImage] = []
    ) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.text = text
        self.images = images
    }
}

struct AgentHostResponseError: Decodable, Equatable {
    let code: String
    let message: String

    init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case data
    }

    private struct ErrorData: Decodable {
        let code: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawCode: String
        if let value = try? container.decode(String.self, forKey: .code) {
            rawCode = value
        } else if let value = try? container.decode(Int.self, forKey: .code) {
            rawCode = String(value)
        } else {
            rawCode = "-32000"
        }
        let data = try container.decodeIfPresent(ErrorData.self, forKey: .data)
        code = data?.code ?? rawCode
        message = try container.decodeIfPresent(String.self, forKey: .message)
            ?? "Agent Host request failed"
    }
}

struct AgentHostResponse<Result: Decodable>: Decodable {
    let jsonrpc: String
    let id: String
    let result: Result?
    let error: AgentHostResponseError?

    var ok: Bool { error == nil }
}

struct AgentHostSessionSummary: Decodable, Equatable, Identifiable {
    let id: String
    let path: String
    let cwd: String
    let title: String
    let firstMessage: String
    let messageCount: Int
    let createdAt: String
    let modifiedAt: String
}

struct AgentHostSessionListResult: Decodable, Equatable {
    let sessions: [AgentHostSessionSummary]
}

struct AgentHostACPSessionListResult: Decodable, Equatable {
    let sessions: [Session]

    struct Session: Decodable, Equatable {
        let sessionId: String
        let cwd: String
        let title: String?
        let updatedAt: String?

        var summary: AgentHostSessionSummary {
            AgentHostSessionSummary(
                id: sessionId,
                path: sessionId,
                cwd: cwd,
                title: title ?? "New Session",
                firstMessage: "",
                messageCount: 0,
                createdAt: updatedAt ?? "",
                modifiedAt: updatedAt ?? ""
            )
        }
    }
}

struct AgentHostSessionCreateDraftResult: Equatable {
    let session: AgentHostSessionSummary
    let acpState: AgentHostACPSessionState
}

struct AgentHostACPSessionNewResult: Decodable, Equatable {
    let sessionId: String
    let modes: AgentHostACPSessionModeState?
    let configOptions: [AgentHostACPSetConfigOptionResult.ConfigOption]?

    var acpState: AgentHostACPSessionState {
        AgentHostACPSessionState(
            modes: modes,
            configOptions: configOptions ?? []
        )
    }
}

struct AgentHostACPSessionResumeResult: Decodable, Equatable {
    let modes: AgentHostACPSessionModeState?
    let configOptions: [AgentHostACPSetConfigOptionResult.ConfigOption]?

    var acpState: AgentHostACPSessionState {
        AgentHostACPSessionState(
            modes: modes,
            configOptions: configOptions ?? []
        )
    }
}

struct AgentHostACPEmptyResult: Decodable, Equatable {}

struct AgentHostACPSetConfigOptionResult: Decodable, Equatable {
    let configOptions: [ConfigOption]

    var acpState: AgentHostACPSessionState {
        AgentHostACPSessionState(configOptions: configOptions)
    }

    struct ConfigOption: Decodable, Equatable {
        enum Value: Decodable, Equatable {
            case string(String)
            case boolean(Bool)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(Bool.self) {
                    self = .boolean(value)
                } else {
                    self = .string(try container.decode(String.self))
                }
            }
        }

        struct Choice: Decodable, Equatable {
            let value: String
            let name: String
        }

        private struct Group: Decodable {
            let options: [Choice]
        }

        let id: String
        let name: String
        let category: String?
        let type: String
        let currentValue: Value
        let options: [Choice]?

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case category
            case type
            case currentValue
            case options
        }

        init(
            id: String,
            name: String,
            category: String?,
            type: String,
            currentValue: Value,
            options: [Choice]?
        ) {
            self.id = id
            self.name = name
            self.category = category
            self.type = type
            self.currentValue = currentValue
            self.options = options
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            category = try container.decodeIfPresent(String.self, forKey: .category)
            type = try container.decode(String.self, forKey: .type)
            currentValue = try container.decode(Value.self, forKey: .currentValue)
            if !container.contains(.options) {
                options = nil
            } else if let choices = try? container.decode([Choice].self, forKey: .options) {
                options = choices
            } else {
                options = try container.decode([Group].self, forKey: .options)
                    .flatMap(\.options)
            }
        }
    }
}

struct AgentHostACPSessionState: Equatable {
    var modes: AgentHostACPSessionModeState?
    var configOptions: [AgentHostACPSetConfigOptionResult.ConfigOption]
    var cost: AgentHostACPSessionCost?
    var availableCommands: [AgentHostACPAvailableCommand]?
    var plan: [AgentHostACPPlanEntry]?
    var extensionStatuses: [String: String]
    var extensionWidgets: [String: AgentHostExtensionWidget]
    var updatedAt: String?
    var supportsImages: Bool

    init(
        modes: AgentHostACPSessionModeState? = nil,
        configOptions: [AgentHostACPSetConfigOptionResult.ConfigOption] = [],
        cost: AgentHostACPSessionCost? = nil,
        availableCommands: [AgentHostACPAvailableCommand]? = nil,
        plan: [AgentHostACPPlanEntry]? = nil,
        extensionStatuses: [String: String] = [:],
        extensionWidgets: [String: AgentHostExtensionWidget] = [:],
        updatedAt: String? = nil,
        supportsImages: Bool = false
    ) {
        self.modes = modes
        self.configOptions = configOptions
        self.cost = cost
        self.availableCommands = availableCommands
        self.plan = plan
        self.extensionStatuses = extensionStatuses
        self.extensionWidgets = extensionWidgets
        self.updatedAt = updatedAt
        self.supportsImages = supportsImages
    }

    static let empty = AgentHostACPSessionState()

    var genericConfigOptions: [AgentHostACPSetConfigOptionResult.ConfigOption] {
        let claimedIDs = Set([
            modelConfigOption?.id,
            thinkingConfigOption?.id,
            "fast_mode",
            "one_million_context"
        ].compactMap { $0 })
        return configOptions.filter {
            !claimedIDs.contains($0.id) && ($0.type == "select" || $0.type == "boolean")
        }
    }

    var genericModeState: AgentHostACPSessionModeState? {
        guard let modes,
              modes.availableModes.contains(where: {
                  AgentHostAccessMode(rawValue: $0.id) == nil
              }) else {
            return nil
        }
        return modes
    }
}

struct AgentHostSessionOpenResult: Equatable {
    let sessionId: String
    let path: String
    let cwd: String
    let acpState: AgentHostACPSessionState

    init(
        sessionId: String,
        path: String,
        cwd: String,
        acpState: AgentHostACPSessionState = .empty
    ) {
        self.sessionId = sessionId
        self.path = path
        self.cwd = cwd
        self.acpState = acpState
    }
}

struct AgentHostSessionExportHTMLResult: Decodable, Equatable {
    let sessionId: String
    let path: String
}

struct AgentHostSessionRenameResult: Decodable, Equatable {
    let sessionId: String
    let title: String
}

struct AgentHostSessionPromptResult: Decodable, Equatable {
    let accepted: Bool
    let sessionId: String
    let turnId: String
}

struct AgentHostACPPromptResult: Decodable, Equatable {
    let stopReason: String
}

struct AgentHostSessionAbortResult: Decodable, Equatable {
    let aborted: Bool
    let sessionId: String
}

struct AgentHostSessionCloseResult: Decodable, Equatable {
    let closed: Bool
    let sessionId: String
}

struct AgentHostSessionToolOutputResult: Decodable, Equatable {
    let sessionId: String
    let toolCallId: String
    let output: String
}

struct AgentHostSessionDeleteResult: Decodable, Equatable {
    let deleted: Bool
    let sessionId: String
}

struct AgentHostModel: Decodable, Equatable, Identifiable {
    let provider: String
    let id: String
    let name: String
    let contextWindow: Int
    let maxTokens: Int
    let reasoning: Bool
    let supportsImages: Bool
    let supportsFastMode: Bool

    init(
        provider: String,
        id: String,
        name: String,
        contextWindow: Int,
        maxTokens: Int,
        reasoning: Bool,
        supportsImages: Bool,
        supportsFastMode: Bool = false
    ) {
        self.provider = provider
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.reasoning = reasoning
        self.supportsImages = supportsImages
        self.supportsFastMode = supportsFastMode
    }
}

struct AgentHostModelListResult: Decodable, Equatable {
    let models: [AgentHostModel]
}

enum AgentHostModelOption: String, Codable, Equatable {
    case fastMode
    case oneMillionContext
}

struct AgentHostModelOptionState: Codable, Equatable {
    let supported: Bool
    let enabled: Bool
}

struct AgentHostModelOptions: Codable, Equatable {
    let fastMode: AgentHostModelOptionState
    let oneMillionContext: AgentHostModelOptionState

    static let unsupported = AgentHostModelOptions(
        fastMode: AgentHostModelOptionState(supported: false, enabled: false),
        oneMillionContext: AgentHostModelOptionState(supported: false, enabled: false)
    )
}

struct AgentHostSessionSetModelParameters: Encodable, Equatable {
    let sessionId: String
    let provider: String
    let modelId: String
}

struct AgentHostACPSetStringConfigOptionParameters: Encodable, Equatable {
    let sessionId: String
    let configId: String
    let value: String
}

struct AgentHostACPSetBooleanConfigOptionParameters: Encodable, Equatable {
    let sessionId: String
    let configId: String
    let value: Bool
}

struct AgentHostACPSetModeParameters: Encodable, Equatable {
    let sessionId: String
    let modeId: String
}

struct AgentHostSessionSetModelResult: Decodable, Equatable {
    let sessionId: String
    let model: AgentHostModel
    let contextUsage: AgentHostContextUsage?
    let thinkingLevel: AgentHostThinkingLevel
    let availableThinkingLevels: [AgentHostThinkingLevel]
    let modelOptions: AgentHostModelOptions

    init(
        sessionId: String,
        model: AgentHostModel,
        contextUsage: AgentHostContextUsage? = nil,
        thinkingLevel: AgentHostThinkingLevel,
        availableThinkingLevels: [AgentHostThinkingLevel],
        modelOptions: AgentHostModelOptions = .unsupported
    ) {
        self.sessionId = sessionId
        self.model = model
        self.contextUsage = contextUsage
        self.thinkingLevel = thinkingLevel
        self.availableThinkingLevels = availableThinkingLevels
        self.modelOptions = modelOptions
    }
}

struct AgentHostSessionSetThinkingLevelParameters: Encodable, Equatable {
    let sessionId: String
    let thinkingLevel: AgentHostThinkingLevel
}

struct AgentHostSessionSetThinkingLevelResult: Decodable, Equatable {
    let sessionId: String
    let thinkingLevel: AgentHostThinkingLevel
    let availableThinkingLevels: [AgentHostThinkingLevel]
}

struct AgentHostSessionSetModelOptionParameters: Encodable, Equatable {
    let sessionId: String
    let option: AgentHostModelOption
    let enabled: Bool
}

struct AgentHostSessionSetModelOptionResult: Decodable, Equatable {
    let sessionId: String
    let model: AgentHostModel
    let contextUsage: AgentHostContextUsage?
    let modelOptions: AgentHostModelOptions
}

struct AgentHostSessionSetAccessModeParameters: Encodable, Equatable {
    let sessionId: String
    let accessMode: AgentHostAccessMode
}

struct AgentHostSessionSetAccessModeResult: Decodable, Equatable {
    let sessionId: String
    let accessMode: AgentHostAccessMode
}

struct AgentHostSessionResolveApprovalResult: Decodable, Equatable {
    let sessionId: String
    let requestId: String
    let decision: AgentHostApprovalDecision
}

struct AgentHostSessionDescriptor: Decodable, Equatable, Identifiable {
    let id: String
    let path: String
    let cwd: String
    let title: String
}

enum AgentHostSessionMessageRole: String, Decodable, Equatable {
    case user
    case assistant
    case tool
    case system
}

enum AgentHostSessionMessageContent: Decodable, Equatable {
    case text(String)
    case skill(name: String)
    case thinking(text: String, redacted: Bool)
    case image(mimeType: String, data: Data?)
    case toolCall(id: String, name: String, argumentsSummary: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case name
        case thinking
        case redacted
        case mimeType
        case data
        case id
        case argumentsSummary
    }

    private enum ContentType: String, Decodable {
        case text
        case skill
        case thinking
        case image
        case toolCall
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ContentType.self, forKey: .type) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .skill:
            self = .skill(name: try container.decode(String.self, forKey: .name))
        case .thinking:
            let redacted = try container.decodeIfPresent(Bool.self, forKey: .redacted) ?? false
            self = .thinking(
                text: redacted
                    ? ""
                    : (try container.decodeIfPresent(String.self, forKey: .thinking) ?? ""),
                redacted: redacted
            )
        case .image:
            self = .image(
                mimeType: try container.decode(String.self, forKey: .mimeType),
                data: try container.decodeIfPresent(Data.self, forKey: .data)
            )
        case .toolCall:
            self = .toolCall(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                argumentsSummary: try container.decode(String.self, forKey: .argumentsSummary)
            )
        }
    }
}

struct AgentHostSessionMessage: Decodable, Equatable, Identifiable {
    let id: String
    let role: AgentHostSessionMessageRole
    let content: [AgentHostSessionMessageContent]
    let timestamp: String
    let provider: String?
    let model: String?
    let stopReason: String?
    let errorMessage: String?
    let toolCallId: String?
    let toolName: String?
    let isError: Bool?
    var toolOutputTruncated: Bool? = nil
    var toolOutputBytes: Int? = nil
}

struct AgentHostSessionHistory: Decodable, Equatable {
    let revision: String
    let nextCursor: String?
    let hasMore: Bool
}

struct AgentHostSessionTranscriptPageResult: Decodable, Equatable {
    let sessionId: String
    let messages: [AgentHostSessionMessage]
    let revision: String
    let nextCursor: String?
    let hasMore: Bool
}

struct AgentHostSessionSnapshotResult: Decodable, Equatable {
    let session: AgentHostSessionDescriptor
    let messages: [AgentHostSessionMessage]
    let history: AgentHostSessionHistory?
    let state: AgentHostSessionRunState
    let sequence: Int
    let turnId: String?
    let gitBranch: String?
    let model: AgentHostModel?
    let contextUsage: AgentHostContextUsage?
    let thinkingLevel: AgentHostThinkingLevel
    let availableThinkingLevels: [AgentHostThinkingLevel]
    let modelOptions: AgentHostModelOptions
    let accessMode: AgentHostAccessMode
    let pendingApprovals: [AgentHostApprovalRequest]
    let extensionStatuses: [String: String]?
    let extensionWidgets: [String: AgentHostExtensionWidget]?
    let plan: [AgentHostACPPlanEntry]?

    init(
        session: AgentHostSessionDescriptor,
        messages: [AgentHostSessionMessage],
        history: AgentHostSessionHistory? = nil,
        state: AgentHostSessionRunState,
        sequence: Int,
        turnId: String?,
        gitBranch: String? = nil,
        model: AgentHostModel?,
        contextUsage: AgentHostContextUsage? = nil,
        thinkingLevel: AgentHostThinkingLevel,
        availableThinkingLevels: [AgentHostThinkingLevel],
        modelOptions: AgentHostModelOptions = .unsupported,
        accessMode: AgentHostAccessMode,
        pendingApprovals: [AgentHostApprovalRequest],
        extensionStatuses: [String: String]? = nil,
        extensionWidgets: [String: AgentHostExtensionWidget]? = nil,
        plan: [AgentHostACPPlanEntry]? = nil
    ) {
        self.session = session
        self.messages = messages
        self.history = history
        self.state = state
        self.sequence = sequence
        self.turnId = turnId
        self.gitBranch = gitBranch
        self.model = model
        self.contextUsage = contextUsage
        self.thinkingLevel = thinkingLevel
        self.availableThinkingLevels = availableThinkingLevels
        self.modelOptions = modelOptions
        self.accessMode = accessMode
        self.pendingApprovals = pendingApprovals
        self.extensionStatuses = extensionStatuses
        self.extensionWidgets = extensionWidgets
        self.plan = plan
    }
}
