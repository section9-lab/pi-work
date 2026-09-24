import XCTest
@testable import PiWork

final class AgentHostProtocolTests: XCTestCase {
    func testInstalledPackageVersionChangesAreDecodedWithoutChangingPackageIdentity() throws {
        func package(_ versionField: String) throws -> AgentHostInstalledExtensionPackage {
            let json = #"{"source":"npm:pi-tools","scope":"user","filtered":false,"enabled":true"#
                + versionField + "}"
            return try JSONDecoder().decode(AgentHostInstalledExtensionPackage.self, from: Data(json.utf8))
        }
        let old = try package(#", "version":"1.2.3""#)
        let updated = try package(#", "version":"1.3.0""#)
        XCTAssertNotEqual(old, updated)
        XCTAssertEqual(old.id, updated.id)
        XCTAssertEqual(try package("").source, old.source)
    }

    func testDecodesPiWorkExtensionNotificationWithoutRecursion() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"_piWork/models.changed","params":{"reason":"authentication","providerId":"openai-codex"}}"#.utf8)

        let event = try AgentHostServerEvent.decode(from: data)

        XCTAssertEqual(
            event,
            .modelsChanged(
                AgentHostModelsChangedPayload(
                    reason: .authentication,
                    providerId: "openai-codex"
                )
            )
        )
    }

    func testDecodesStandardNumericJSONRPCErrorCode() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":"request-one","error":{"code":-32601,"message":"Method not found"}}"#.utf8)

        let response = try JSONDecoder().decode(
            AgentHostResponse<AgentHostACPEmptyResult>.self,
            from: data
        )

        XCTAssertEqual(response.error?.code, "-32601")
        XCTAssertEqual(response.error?.message, "Method not found")
    }

    func testInitializeAdvertisesBooleanConfigOptionSupport() throws {
        let request = AgentHostRequest(
            id: "initialize-1",
            method: "initialize",
            params: AgentHostACPInitializeParameters(
                protocolVersion: 1,
                clientInfo: .init(name: "pi-work", version: "0.1.0"),
                clientCapabilities: .piWork
            )
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.encodedLine().dropLast()) as? [String: Any]
        )
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        let capabilities = try XCTUnwrap(params["clientCapabilities"] as? [String: Any])
        let session = try XCTUnwrap(capabilities["session"] as? [String: Any])
        let configOptions = try XCTUnwrap(session["configOptions"] as? [String: Any])
        XCTAssertNotNil(configOptions["boolean"] as? [String: Any])
        let elicitation = try XCTUnwrap(capabilities["elicitation"] as? [String: Any])
        XCTAssertNotNil(elicitation["form"] as? [String: Any])
    }

    func testDecodesStandardACPElicitationFormRequest() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":"elicitation-one","method":"elicitation/create","params":{"mode":"form","sessionId":"session-one","message":"Choose an action","requestedSchema":{"type":"object","properties":{"action":{"type":"string","title":"Action","oneOf":[{"const":"run","title":"Run"},{"const":"stop","title":"Stop"}]},"confirmed":{"type":"boolean","title":"Confirm","default":false}},"required":["action"]}}}"#.utf8)

        XCTAssertEqual(
            try AgentHostServerEvent.decode(from: data),
            .elicitationRequested(
                AgentHostACPElicitationRequest(
                    id: "elicitation-one",
                    sessionId: "session-one",
                    message: "Choose an action",
                    schema: AgentHostACPElicitationSchema(
                        properties: [
                            "action": AgentHostACPElicitationProperty(
                                type: .string,
                                title: "Action",
                                options: [
                                    .init(value: "run", title: "Run"),
                                    .init(value: "stop", title: "Stop")
                                ]
                            ),
                            "confirmed": AgentHostACPElicitationProperty(
                                type: .boolean,
                                title: "Confirm",
                                defaultValue: .boolean(false)
                            )
                        ],
                        required: ["action"]
                    )
                )
            )
        )
    }

    func testDecodesMinimalACPInitializeResponse() throws {
        let data = Data(#"{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true},"sessionCapabilities":{"list":{},"resume":{}}},"authMethods":[{"id":"login","name":"Sign in"}]}"#.utf8)

        let result = try JSONDecoder().decode(
            AgentHostACPInitializeResult.self,
            from: data
        )

        XCTAssertEqual(result.protocolVersion, 1)
        XCTAssertEqual(result.helloPayload.hostVersion, "unknown")
        XCTAssertEqual(result.helloPayload.piVersion, "unknown")
        XCTAssertTrue(result.helloPayload.acpCapabilities.loadSession)
        XCTAssertTrue(result.helloPayload.acpCapabilities.listSessions)
        XCTAssertTrue(result.helloPayload.acpCapabilities.resumeSession)
        XCTAssertTrue(result.helloPayload.acpCapabilities.promptImages)
        XCTAssertEqual(result.helloPayload.authMethods.map(\.id), ["login"])
        XCTAssertFalse(result.helloPayload.supportsPiWorkExtensions)
    }

    func testACPModelProjectionUsesTheAgentImageCapability() {
        let state = AgentHostACPSessionState(
            configOptions: [
                AgentHostACPSetConfigOptionResult.ConfigOption(
                    id: "model",
                    name: "Model",
                    category: "model",
                    type: "select",
                    currentValue: .string("claude/opus"),
                    options: [.init(value: "claude/opus", name: "Opus")]
                )
            ],
            supportsImages: true
        )

        XCTAssertTrue(state.model?.supportsImages == true)
        XCTAssertTrue(state.availableModels.allSatisfy(\.supportsImages))
    }

    func testDecodesThePiWorkExtensionMarkerFromInitialize() throws {
        let data = Data(#"{"protocolVersion":1,"_meta":{"piWork":{"extensions":true}}}"#.utf8)

        let result = try JSONDecoder().decode(
            AgentHostACPInitializeResult.self,
            from: data
        )

        XCTAssertTrue(result.helloPayload.supportsPiWorkExtensions)
        XCTAssertTrue(result.helloPayload.supportsPiWorkCapability(.modelsList))
    }

    func testDecodesGranularPiWorkCapabilitiesFromInitialize() throws {
        let data = Data(#"{"protocolVersion":1,"_meta":{"piWork":{"extensions":true,"capabilities":["models.list","session.snapshot"]}}}"#.utf8)

        let result = try JSONDecoder().decode(
            AgentHostACPInitializeResult.self,
            from: data
        )

        XCTAssertTrue(result.helloPayload.supportsPiWorkCapability(.modelsList))
        XCTAssertTrue(result.helloPayload.supportsPiWorkCapability(.sessionSnapshot))
        XCTAssertFalse(result.helloPayload.supportsPiWorkCapability(.providersList))
    }

    func testDecodesGroupedACPConfigOptions() throws {
        let data = Data(#"{"configOptions":[{"id":"agent-model","name":"Model","category":"model","type":"select","currentValue":"anthropic/opus","options":[{"group":"anthropic","name":"Anthropic","options":[{"value":"anthropic/sonnet","name":"Sonnet"},{"value":"anthropic/opus","name":"Opus"}]}]}]}"#.utf8)

        let result = try JSONDecoder().decode(
            AgentHostACPSetConfigOptionResult.self,
            from: data
        )

        XCTAssertEqual(
            result.acpState.availableModels.map(\.id),
            ["sonnet", "opus"]
        )
        XCTAssertEqual(result.acpState.model?.id, "opus")
    }

    func testExposesOnlyUnclaimedConfigOptionsToTheGenericUI() {
        let state = AgentHostACPSessionState(configOptions: [
            .init(
                id: "agent-model",
                name: "Model",
                category: "model",
                type: "select",
                currentValue: .string("sonnet"),
                options: [.init(value: "sonnet", name: "Sonnet")]
            ),
            .init(
                id: "thought_level",
                name: "Thinking",
                category: "thought_level",
                type: "select",
                currentValue: .string("high"),
                options: [.init(value: "high", name: "High")]
            ),
            .init(
                id: "auto_approve",
                name: "Auto approve",
                category: "behavior",
                type: "boolean",
                currentValue: .boolean(false),
                options: nil
            )
        ])

        XCTAssertEqual(state.genericConfigOptions.map(\.id), ["auto_approve"])
    }

    func testExposesNonPiWorkModesToTheGenericUI() {
        let custom = AgentHostACPSessionState(
            modes: AgentHostACPSessionModeState(
                currentModeId: "plan",
                availableModes: [
                    AgentHostACPSessionMode(id: "plan", name: "Plan", description: nil),
                    AgentHostACPSessionMode(id: "code", name: "Code", description: nil)
                ]
            )
        )
        let bundled = AgentHostACPSessionState(
            modes: AgentHostACPSessionModeState(
                currentModeId: "ask",
                availableModes: [
                    AgentHostACPSessionMode(id: "ask", name: "Ask", description: nil),
                    AgentHostACPSessionMode(id: "full", name: "Full", description: nil)
                ]
            )
        )

        XCTAssertEqual(custom.genericModeState?.currentModeId, "plan")
        XCTAssertNil(bundled.genericModeState)
    }

    func testDecodesACPAgentMessageChunkIntoTheSessionProjection() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-one","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"},"_meta":{"sequence":7,"turnId":"turn-one","phase":"delta","contentIndex":0,"generationIndex":0}}}}"#.utf8)

        XCTAssertEqual(
            try AgentHostServerEvent.decode(from: data),
            .sessionAssistantContent(
                AgentHostSessionAssistantContentPayload(
                    sessionId: "session-one",
                    sequence: 7,
                    turnId: "turn-one",
                    generationIndex: 0,
                    phase: .delta,
                    contentType: .text,
                    contentIndex: 0,
                    delta: "hello",
                    content: nil,
                    toolCall: nil
                )
            )
        )
    }

    func testDecodesACPUserMessageChunkWithItsStandardMessageID() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-one","update":{"sessionUpdate":"user_message_chunk","messageId":"message-one","content":{"type":"text","text":"hello"}}}}"#.utf8)

        XCTAssertEqual(
            try AgentHostServerEvent.decode(from: data),
            .sessionUserContent(
                AgentHostSessionUserContentPayload(
                    sessionId: "session-one",
                    sequence: 0,
                    messageId: "message-one",
                    text: "hello"
                )
            )
        )
    }

    func testDecodesACPToolCallUpdateIntoTheSessionProjection() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-one","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool-one","title":"bash","status":"completed","content":[{"type":"content","content":{"type":"text","text":"done"}}],"rawOutput":{"exitCode":0}}}}"#.utf8)

        XCTAssertEqual(
            try AgentHostServerEvent.decode(from: data),
            .sessionToolCompleted(
                    AgentHostSessionToolCompletedPayload(
                        sessionId: "session-one",
                    sequence: 0,
                    turnId: "",
                    toolCallId: "tool-one",
                    toolName: "bash",
                    output: "done",
                    content: [
                        .content(.text("done"))
                    ],
                    rawOutput: .object(["exitCode": .number(0)]),
                    isError: false
                )
            )
        )
    }

    func testDecodesACPToolCallRawInputWithoutPiWorkSpecificFields() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-one","update":{"sessionUpdate":"tool_call","toolCallId":"tool-one","title":"todo","status":"in_progress","rawInput":{"action":"add","text":"Verify UI"}}}}"#.utf8)

        XCTAssertEqual(
            try AgentHostServerEvent.decode(from: data),
            .sessionToolStarted(
                AgentHostSessionToolStartedPayload(
                    sessionId: "session-one",
                    sequence: 0,
                    turnId: "",
                    toolCallId: "tool-one",
                    toolName: "todo",
                    summary: #"{"action":"add","text":"Verify UI"}"#,
                    rawInput: .object([
                        "action": .string("add"),
                        "text": .string("Verify UI")
                    ])
                )
            )
        )
    }

    func testDecodesPiWorkExtensionStatusSessionUpdate() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-one","update":{"sessionUpdate":"_piWork/extension_status","key":"status-demo","text":"Ready"}}}"#.utf8)

        XCTAssertEqual(
            try AgentHostServerEvent.decode(from: data),
            .sessionExtensionStatusChanged(
                AgentHostSessionExtensionStatusChangedPayload(
                    sessionId: "session-one",
                    sequence: 0,
                    key: "status-demo",
                    text: "Ready"
                )
            )
        )
    }

    func testRecognizesGenericWidgetUpdatesAndRemoval() throws {
        let updates = [
            #"{"sessionUpdate":"_piWork/extension_widget","key":"any-plugin","lines":["☐ Inspect","2 workers running"],"placement":"belowEditor"}"#,
            #"{"sessionUpdate":"_piWork/extension_widget","key":"any-plugin"}"#
        ]
        for (index, update) in updates.enumerated() {
            let data = Data(
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-one","update":\#(update)}}"#.utf8
            )
            XCTAssertEqual(
                try AgentHostServerEvent.decode(from: data),
                .sessionExtensionWidgetChanged(
                    AgentHostSessionExtensionWidgetChangedPayload(
                        sessionId: "session-one",
                        sequence: 0,
                        key: "any-plugin",
                        widget: index == 0 ? AgentHostExtensionWidget(
                            lines: ["☐ Inspect", "2 workers running"],
                            placement: .belowEditor
                        ) : nil
                    )
                )
            )
        }
    }

    func testDecodesStructuredACPToolCallContent() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-one","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool-one","title":"edit","status":"completed","content":[{"type":"diff","path":"/tmp/App.swift","oldText":"old","newText":"new"},{"type":"content","content":{"type":"image","mimeType":"image/png","data":"iVBORw==","uri":"file:///tmp/result.png"}},{"type":"content","content":{"type":"resource_link","name":"Docs","uri":"https://example.com/docs","title":"Reference","description":"API reference","mimeType":"text/html"}},{"type":"content","content":{"type":"resource","resource":{"uri":"file:///tmp/log.txt","mimeType":"text/plain","text":"log output"}}},{"type":"terminal","terminalId":"terminal-one"}]}}}"#.utf8)

        XCTAssertEqual(
            try AgentHostServerEvent.decode(from: data),
            .sessionToolCompleted(
                AgentHostSessionToolCompletedPayload(
                    sessionId: "session-one",
                    sequence: 0,
                    turnId: "",
                    toolCallId: "tool-one",
                    toolName: "edit",
                    content: [
                        .diff(path: "/tmp/App.swift", oldText: "old", newText: "new"),
                        .content(
                            .image(
                                mimeType: "image/png",
                                data: Data([0x89, 0x50, 0x4E, 0x47]),
                                uri: "file:///tmp/result.png"
                            )
                        ),
                        .content(
                            .resourceLink(
                                name: "Docs",
                                uri: "https://example.com/docs",
                                title: "Reference",
                                description: "API reference",
                                mimeType: "text/html"
                            )
                        ),
                        .content(
                            .resource(
                                uri: "file:///tmp/log.txt",
                                mimeType: "text/plain",
                                text: "log output",
                                data: nil
                            )
                        ),
                        .terminal(id: "terminal-one")
                    ],
                    isError: false
                )
            )
        )
    }

    func testDecodesStandardACPSessionStateUpdates() throws {
        let updates = [
            #"{"sessionUpdate":"current_mode_update","currentModeId":"ask"}"#,
            #"{"sessionUpdate":"config_option_update","configOptions":[]}"#,
            #"{"sessionUpdate":"session_info_update","title":"Renamed"}"#,
            #"{"sessionUpdate":"usage_update","used":32,"size":128}"#,
            #"{"sessionUpdate":"available_commands_update","availableCommands":[]}"#,
            #"{"sessionUpdate":"plan","entries":[]}"#
        ]

        for update in updates {
            let data = Data(
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-one","update":\#(update)}}"#.utf8
            )
            let event = try AgentHostServerEvent.decode(from: data)
            let updateType = try XCTUnwrap(
                (JSONSerialization.jsonObject(with: Data(update.utf8)) as? [String: Any])?["sessionUpdate"]
                    as? String
            )
            XCTAssertNotEqual(event, .unknown(name: updateType))
        }
    }

    func testDecodesACPPermissionRequestIntoTheApprovalProjection() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":"permission-1","method":"session/request_permission","params":{"sessionId":"session-one","toolCall":{"toolCallId":"tool-one","title":"bash","rawInput":{"summary":"bun test"},"_meta":{"sequence":9,"turnId":"turn-one"}},"options":[{"optionId":"yes","name":"Allow","kind":"allow_once"},{"optionId":"no","name":"Reject","kind":"reject_once"}]}}"#.utf8)

        XCTAssertEqual(
            try AgentHostServerEvent.decode(from: data),
            .sessionApprovalRequested(
                AgentHostSessionApprovalRequestedPayload(
                    sessionId: "session-one",
                    sequence: 9,
                    turnId: "turn-one",
                    requestId: "permission-1",
                    toolCallId: "tool-one",
                    toolName: "bash",
                    summary: "bun test",
                    allowOptionId: "yes",
                    rejectOptionId: "no",
                    options: [
                        AgentHostApprovalOption(
                            optionId: "yes",
                            name: "Allow",
                            kind: .allowOnce
                        ),
                        AgentHostApprovalOption(
                            optionId: "no",
                            name: "Reject",
                            kind: .rejectOnce
                        )
                    ]
                )
            )
        )
    }

    func testDecodesSchemaDrivenExtensionSettingsWithoutExposingSecrets() throws {
        let data = Data(#"{"extensions":[{"source":"npm:pi-demo","scope":"user","configurable":true,"fields":[{"path":"/enabled","title":"Enabled","kind":"boolean","value":"true","defaultValue":"true","hasValue":false},{"path":"/token","title":"API token","kind":"secure","hasValue":true},{"path":"/mode","title":"Mode","kind":"choice","value":"safe","hasValue":true,"options":[{"value":"safe","label":"Safe"}]}]}]}"#.utf8)

        let result = try JSONDecoder().decode(
            AgentHostExtensionSettingsResult.self,
            from: data
        )

        XCTAssertEqual(result.extensions.count, 1)
        XCTAssertEqual(result.extensions[0].id, "user:npm:pi-demo")
        XCTAssertEqual(result.extensions[0].fields.map(\.kind), [.boolean, .secure, .choice])
        XCTAssertNil(result.extensions[0].fields[1].value)
        XCTAssertTrue(result.extensions[0].fields[1].hasValue)
        XCTAssertEqual(
            result.extensions[0].fields[2].options,
            [AgentHostExtensionSettingOption(value: "safe", label: "Safe")]
        )
    }

    func testEncodesExtensionSettingChangesAsAPluginScopedPatch() throws {
        let request = AgentHostRequest(
            id: "extension-settings-update",
            method: "extensions.settings.update",
            params: AgentHostExtensionSettingsUpdateParameters(
                source: "npm:pi-demo",
                scope: .user,
                changes: [
                    AgentHostExtensionSettingChange(path: "/mode", value: "safe"),
                    AgentHostExtensionSettingChange(removing: "/token")
                ]
            )
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.encodedLine().dropLast()) as? [String: Any]
        )
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        let changes = try XCTUnwrap(params["changes"] as? [[String: Any]])

        XCTAssertEqual(params["source"] as? String, "npm:pi-demo")
        XCTAssertEqual(params["scope"] as? String, "user")
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0]["path"] as? String, "/mode")
        XCTAssertEqual(changes[0]["operation"] as? String, "set")
        XCTAssertEqual(changes[0]["value"] as? String, "safe")
        XCTAssertEqual(changes[1]["path"] as? String, "/token")
        XCTAssertEqual(changes[1]["operation"] as? String, "remove")
        XCTAssertNil(changes[1]["value"])
    }

    func testDecodesHTMLExportResult() throws {
        let exportPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Exports/report.html").path
        let data = try JSONSerialization.data(withJSONObject: [
            "sessionId": "session-one", "path": exportPath
        ])

        let result = try JSONDecoder().decode(
            AgentHostSessionExportHTMLResult.self,
            from: data
        )

        XCTAssertEqual(
            result,
            AgentHostSessionExportHTMLResult(
                sessionId: "session-one",
                path: exportPath
            )
        )
    }

    func testSessionImageContentCarriesOptionalPreviewData() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "PiWork/Core/Agent/AgentHostProtocol.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("case image(mimeType: String, data: Data?)"))
        XCTAssertTrue(source.contains("case data"))
        XCTAssertTrue(source.contains("decodeIfPresent(Data.self, forKey: .data)"))
    }

    func testDecodesGitBranchAvailability() throws {
        let data = Data(#"{"available":true,"currentBranch":"main","branches":["main","feature/session-picker"]}"#.utf8)

        let result = try JSONDecoder().decode(AgentHostGitBranchesResult.self, from: data)

        XCTAssertEqual(
            result,
            AgentHostGitBranchesResult(
                available: true,
                currentBranch: "main",
                branches: ["main", "feature/session-picker"]
            )
        )
    }

    func testDecodesLiveSkillAndExtensionSlashCommands() throws {
        let data = Data(#"{"commands":[{"name":"review","description":"Review the current changes","source":"extension"},{"name":"skill:ego-browser","description":"Browse and interact with websites","source":"skill"}]}"#.utf8)

        let result = try JSONDecoder().decode(AgentHostSlashCommandsResult.self, from: data)

        XCTAssertEqual(
            result.commands,
            [
                AgentHostSlashCommand(
                    name: "review",
                    description: "Review the current changes",
                    source: .extensionCommand
                ),
                AgentHostSlashCommand(
                    name: "skill:ego-browser",
                    description: "Browse and interact with websites",
                    source: .skill
                )
            ]
        )
    }

    func testDecodesCompactSkillUsageInSessionMessages() throws {
        let data = Data(#"{"id":"message-one","role":"user","content":[{"type":"skill","name":"ego-browser"},{"type":"text","text":"使用这个再试试呢"}],"timestamp":"2026-08-09T00:00:00.000Z"}"#.utf8)

        let message = try JSONDecoder().decode(AgentHostSessionMessage.self, from: data)

        XCTAssertEqual(
            message.content,
            [
                .skill(name: "ego-browser"),
                .text("使用这个再试试呢")
            ]
        )
    }

    func testDecodesTruncatedToolOutputMetadata() throws {
        let data = Data(#"{"id":"tool-message","role":"tool","content":[{"type":"text","text":"preview"}],"timestamp":"2026-08-09T00:00:00.000Z","toolCallId":"tool-one","toolName":"bash","isError":false,"toolOutputTruncated":true,"toolOutputBytes":100000}"#.utf8)

        let message = try JSONDecoder().decode(AgentHostSessionMessage.self, from: data)

        XCTAssertEqual(message.toolOutputTruncated, true)
        XCTAssertEqual(message.toolOutputBytes, 100_000)
    }

    func testDecodesNormalizedSessionSnapshot() throws {
        let data = Data(#"{"session":{"id":"session-one","path":"/tmp/session.jsonl","cwd":"/tmp/project","title":"Session integration"},"messages":[{"id":"message-one","role":"user","content":[{"type":"text","text":"Inspect this"},{"type":"image","mimeType":"image/png","data":"iVBORw0KGgo="}],"timestamp":"2026-08-09T00:00:00.000Z"},{"id":"message-two","role":"assistant","content":[{"type":"text","text":"Ready"},{"type":"toolCall","id":"tool-one","name":"read","argumentsSummary":"{\"path\":\"README.md\"}"}],"timestamp":"2026-08-09T00:00:01.000Z","provider":"openai","model":"gpt-test","stopReason":"toolUse"}],"history":{"revision":"revision-one","nextCursor":"cursor-one","hasMore":true},"state":"running","sequence":4,"turnId":"turn-one","gitBranch":"feature/session-picker","model":{"provider":"openai","id":"gpt-test","name":"GPT Test","contextWindow":128000,"maxTokens":16384,"reasoning":true,"supportsImages":true,"supportsFastMode":false},"contextUsage":{"tokens":96000,"contextWindow":128000,"percent":75},"thinkingLevel":"high","availableThinkingLevels":["off","low","medium","high","max"],"modelOptions":{"fastMode":{"supported":true,"enabled":false},"oneMillionContext":{"supported":true,"enabled":true}},"accessMode":"ask","pendingApprovals":[{"id":"approval-one","toolCallId":"tool-one","toolName":"bash","summary":"bun test"}],"extensionStatuses":{"status-demo":"Ready"}}"#.utf8)

        let snapshot = try JSONDecoder().decode(AgentHostSessionSnapshotResult.self, from: data)

        XCTAssertEqual(
            snapshot.session,
            AgentHostSessionDescriptor(
                id: "session-one",
                path: "/tmp/session.jsonl",
                cwd: "/tmp/project",
                title: "Session integration"
            )
        )
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.sequence, 4)
        XCTAssertEqual(snapshot.turnId, "turn-one")
        XCTAssertEqual(snapshot.gitBranch, "feature/session-picker")
        XCTAssertEqual(
            snapshot.history,
            AgentHostSessionHistory(
                revision: "revision-one",
                nextCursor: "cursor-one",
                hasMore: true
            )
        )
        XCTAssertEqual(
            snapshot.contextUsage,
            AgentHostContextUsage(tokens: 96_000, contextWindow: 128_000, percent: 75)
        )
        XCTAssertEqual(snapshot.thinkingLevel, .high)
        XCTAssertEqual(
            snapshot.availableThinkingLevels,
            [.off, .low, .medium, .high, .max]
        )
        XCTAssertEqual(
            snapshot.modelOptions,
            AgentHostModelOptions(
                fastMode: AgentHostModelOptionState(supported: true, enabled: false),
                oneMillionContext: AgentHostModelOptionState(supported: true, enabled: true)
            )
        )
        XCTAssertEqual(snapshot.accessMode, .ask)
        XCTAssertEqual(snapshot.extensionStatuses, ["status-demo": "Ready"])
        XCTAssertEqual(
            snapshot.pendingApprovals,
            [
                AgentHostApprovalRequest(
                    id: "approval-one",
                    toolCallId: "tool-one",
                    toolName: "bash",
                    summary: "bun test"
                )
            ]
        )
        XCTAssertEqual(
            snapshot.messages[0].content,
            [
                .text("Inspect this"),
                .image(
                    mimeType: "image/png",
                    data: Data(base64Encoded: "iVBORw0KGgo=")
                )
            ]
        )
        XCTAssertEqual(
            snapshot.messages[1].content,
            [
                .text("Ready"),
                .toolCall(
                    id: "tool-one",
                    name: "read",
                    argumentsSummary: #"{"path":"README.md"}"#
                )
            ]
        )
        XCTAssertEqual(
            snapshot.model,
            AgentHostModel(
                provider: "openai",
                id: "gpt-test",
                name: "GPT Test",
                contextWindow: 128_000,
                maxTokens: 16_384,
                reasoning: true,
                supportsImages: true
            )
        )
    }

    func testDecodesTranscriptHistoryPage() throws {
        let data = Data(#"{"sessionId":"session-one","messages":[{"id":"message-zero","role":"user","content":[{"type":"text","text":"Earlier"}],"timestamp":"2026-08-08T00:00:00.000Z"}],"revision":"revision-one","nextCursor":null,"hasMore":false}"#.utf8)

        let page = try JSONDecoder().decode(
            AgentHostSessionTranscriptPageResult.self,
            from: data
        )

        XCTAssertEqual(page.sessionId, "session-one")
        XCTAssertEqual(page.messages.map(\.id), ["message-zero"])
        XCTAssertEqual(page.revision, "revision-one")
        XCTAssertNil(page.nextCursor)
        XCTAssertFalse(page.hasMore)
    }

    func testDecodesAvailableModels() throws {
        let data = Data(#"{"models":[{"provider":"anthropic","id":"claude-test","name":"Claude Test","contextWindow":200000,"maxTokens":32000,"reasoning":true,"supportsImages":true,"supportsFastMode":false}]}"#.utf8)

        let result = try JSONDecoder().decode(AgentHostModelListResult.self, from: data)

        XCTAssertEqual(
            result.models,
            [
                AgentHostModel(
                    provider: "anthropic",
                    id: "claude-test",
                    name: "Claude Test",
                    contextWindow: 200_000,
                    maxTokens: 32_000,
                    reasoning: true,
                    supportsImages: true
                )
            ]
        )
    }

    func testDecodesAgentSettings() throws {
        let data = Data(#"{"defaultModel":{"provider":"openai","modelId":"gpt-test"},"defaultThinkingLevel":"high","transport":"sse","compactionEnabled":false,"retryEnabled":true}"#.utf8)

        let settings = try JSONDecoder().decode(AgentHostSettings.self, from: data)

        XCTAssertEqual(
            settings.defaultModel,
            AgentHostDefaultModel(provider: "openai", modelId: "gpt-test")
        )
        XCTAssertEqual(settings.defaultThinkingLevel, .high)
        XCTAssertEqual(settings.transport, .sse)
        XCTAssertFalse(settings.compactionEnabled)
        XCTAssertTrue(settings.retryEnabled)
    }

    func testEncodesOnlyChangedAgentSettings() throws {
        let request = AgentHostRequest(
            id: "settings-update-one",
            method: "settings.update",
            params: AgentHostSettingsUpdateParameters(
                patch: AgentHostSettingsPatch(
                    defaultThinkingLevel: .max,
                    compactionEnabled: false
                )
            )
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.encodedLine().dropLast()) as? [String: Any]
        )
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        let patch = try XCTUnwrap(params["patch"] as? [String: Any])

        XCTAssertEqual(object["method"] as? String, "_piWork/settings/update")
        XCTAssertEqual(patch["defaultThinkingLevel"] as? String, "max")
        XCTAssertEqual(patch["compactionEnabled"] as? Bool, false)
        XCTAssertNil(patch["defaultModel"])
        XCTAssertNil(patch["transport"])
        XCTAssertNil(patch["retryEnabled"])
    }

    func testAvailableModelExposesItsFastModeCapability() throws {
        let data = Data(#"{"models":[{"provider":"openai-codex","id":"gpt-5.6-sol","name":"GPT-5.6 Sol","contextWindow":272000,"maxTokens":128000,"reasoning":true,"supportsImages":true,"supportsFastMode":true}]}"#.utf8)

        let result = try JSONDecoder().decode(AgentHostModelListResult.self, from: data)
        let capability = Mirror(reflecting: try XCTUnwrap(result.models.first))
            .children
            .first { $0.label == "supportsFastMode" }?
            .value as? Bool

        XCTAssertEqual(capability, true)
    }

    func testEncodesTypedModelSelectionRequest() throws {
        let request = AgentHostRequest(
            id: "set-model-one",
            method: "session.setModel",
            params: AgentHostSessionSetModelParameters(
                sessionId: "session-one",
                provider: "openai",
                modelId: "gpt-test"
            )
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.encodedLine().dropLast()) as? [String: Any]
        )
        XCTAssertEqual(object["method"] as? String, "session/set_config_option")
        XCTAssertEqual(
            object["params"] as? [String: String],
            [
                "sessionId": "session-one",
                "configId": "model",
                "value": "openai/gpt-test"
            ]
        )
    }

    func testEncodesTypedThinkingLevelRequest() throws {
        let request = AgentHostRequest(
            id: "set-thinking-one",
            method: "session.setThinkingLevel",
            params: AgentHostSessionSetThinkingLevelParameters(
                sessionId: "session-one",
                thinkingLevel: .max
            )
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.encodedLine().dropLast()) as? [String: Any]
        )
        XCTAssertEqual(object["method"] as? String, "session/set_config_option")
        XCTAssertEqual(
            object["params"] as? [String: String],
            ["sessionId": "session-one", "configId": "thought_level", "value": "max"]
        )
    }

    func testEncodesTypedModelOptionRequest() throws {
        let request = AgentHostRequest(
            id: "set-option-one",
            method: "session.setModelOption",
            params: AgentHostSessionSetModelOptionParameters(
                sessionId: "session-one",
                option: .fastMode,
                enabled: true
            )
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.encodedLine().dropLast()) as? [String: Any]
        )
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "session/set_config_option")
        XCTAssertEqual(params["sessionId"] as? String, "session-one")
        XCTAssertEqual(params["configId"] as? String, "fast_mode")
        XCTAssertEqual(params["type"] as? String, "boolean")
        XCTAssertEqual(params["value"] as? Bool, true)
    }

    func testEncodesTypedAccessModeRequest() throws {
        let request = AgentHostRequest(
            id: "set-access-one",
            method: "session.setAccessMode",
            params: AgentHostSessionSetAccessModeParameters(
                sessionId: "session-one",
                accessMode: .full
            )
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.encodedLine().dropLast()) as? [String: Any]
        )
        XCTAssertEqual(object["method"] as? String, "session/set_mode")
        XCTAssertEqual(
            object["params"] as? [String: String],
            ["sessionId": "session-one", "modeId": "full"]
        )
    }

    func testDecodesSessionStateChangedEvent() throws {
        let data = Data(#"{"version":1,"kind":"event","event":"session.stateChanged","payload":{"sessionId":"session-one","sequence":3,"turnId":"turn-one","state":"running"}}"#.utf8)

        let event = try AgentHostServerEvent.decode(from: data)

        XCTAssertEqual(
            event,
            .sessionStateChanged(
                AgentHostSessionStateChangedPayload(
                    sessionId: "session-one",
                    sequence: 3,
                    turnId: "turn-one",
                    state: .running
                )
            )
        )
    }

    func testDecodesContextUsageWhenSessionBecomesIdle() throws {
        let data = Data(#"{"version":1,"kind":"event","event":"session.stateChanged","payload":{"sessionId":"session-one","sequence":5,"turnId":"turn-one","state":"idle","contextUsage":{"tokens":96000,"contextWindow":128000,"percent":75}}}"#.utf8)

        let event = try AgentHostServerEvent.decode(from: data)

        XCTAssertEqual(
            event,
            .sessionStateChanged(
                AgentHostSessionStateChangedPayload(
                    sessionId: "session-one",
                    sequence: 5,
                    turnId: "turn-one",
                    state: .idle,
                    contextUsage: AgentHostContextUsage(
                        tokens: 96_000,
                        contextWindow: 128_000,
                        percent: 75
                    )
                )
            )
        )
    }

    func testDecodesSessionMessageDeltaEvent() throws {
        let data = Data(#"{"version":1,"kind":"event","event":"session.messageDelta","payload":{"sessionId":"session-one","sequence":4,"turnId":"turn-one","delta":"Hello"}}"#.utf8)

        let event = try AgentHostServerEvent.decode(from: data)

        XCTAssertEqual(
            event,
            .sessionMessageDelta(
                AgentHostSessionMessageDeltaPayload(
                    sessionId: "session-one",
                    sequence: 4,
                    turnId: "turn-one",
                    delta: "Hello"
                )
            )
        )
    }

    func testDecodesSessionToolStartedEvent() throws {
        let data = Data(#"{"version":1,"kind":"event","event":"session.toolStarted","payload":{"sessionId":"session-one","sequence":5,"turnId":"turn-one","toolCallId":"tool-one","toolName":"read","summary":"{\"path\":\"README.md\"}"}}"#.utf8)

        let event = try AgentHostServerEvent.decode(from: data)

        XCTAssertEqual(
            event,
            .sessionToolStarted(
                AgentHostSessionToolStartedPayload(
                    sessionId: "session-one",
                    sequence: 5,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "read",
                    summary: #"{"path":"README.md"}"#
                )
            )
        )
    }

    func testDecodesSessionToolUpdatedEvent() throws {
        let data = Data(#"{"version":1,"kind":"event","event":"session.toolUpdated","payload":{"sessionId":"session-one","sequence":6,"turnId":"turn-one","toolCallId":"tool-one","toolName":"read","output":"First line"}}"#.utf8)

        let event = try AgentHostServerEvent.decode(from: data)

        XCTAssertEqual(
            event,
            .sessionToolUpdated(
                AgentHostSessionToolUpdatedPayload(
                    sessionId: "session-one",
                    sequence: 6,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "read",
                    output: "First line"
                )
            )
        )
    }

    func testDecodesSessionToolCompletedEvent() throws {
        let data = Data(#"{"version":1,"kind":"event","event":"session.toolCompleted","payload":{"sessionId":"session-one","sequence":7,"turnId":"turn-one","toolCallId":"tool-one","toolName":"read","output":"README contents","isError":false}}"#.utf8)

        let event = try AgentHostServerEvent.decode(from: data)

        XCTAssertEqual(
            event,
            .sessionToolCompleted(
                AgentHostSessionToolCompletedPayload(
                    sessionId: "session-one",
                    sequence: 7,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "read",
                    output: "README contents",
                    isError: false
                )
            )
        )
    }

    func testDecodesLegacyToolCompletionWithoutOutput() throws {
        let data = Data(#"{"version":1,"kind":"event","event":"session.toolCompleted","payload":{"sessionId":"session-one","sequence":7,"turnId":"turn-one","toolCallId":"tool-one","toolName":"read","isError":false}}"#.utf8)

        let event = try AgentHostServerEvent.decode(from: data)

        XCTAssertEqual(
            event,
            .sessionToolCompleted(
                AgentHostSessionToolCompletedPayload(
                    sessionId: "session-one",
                    sequence: 7,
                    turnId: "turn-one",
                    toolCallId: "tool-one",
                    toolName: "read",
                    output: "",
                    isError: false
                )
            )
        )
    }

    func testDecodesSessionApprovalRequestedEvent() throws {
        let data = Data(#"{"version":1,"kind":"event","event":"session.approvalRequested","payload":{"sessionId":"session-one","sequence":7,"turnId":"turn-one","requestId":"approval-one","toolCallId":"tool-one","toolName":"bash","summary":"bun test"}}"#.utf8)

        let event = try AgentHostServerEvent.decode(from: data)

        XCTAssertEqual(
            event,
            .sessionApprovalRequested(
                AgentHostSessionApprovalRequestedPayload(
                    sessionId: "session-one",
                    sequence: 7,
                    turnId: "turn-one",
                    requestId: "approval-one",
                    toolCallId: "tool-one",
                    toolName: "bash",
                    summary: "bun test"
                )
            )
        )
    }

    func testDecodesSessionErrorEvent() throws {
        let data = Data(#"{"version":1,"kind":"event","event":"session.error","payload":{"sessionId":"session-one","sequence":7,"turnId":"turn-one","code":"agent_error","message":"Model request failed"}}"#.utf8)

        let event = try AgentHostServerEvent.decode(from: data)

        XCTAssertEqual(
            event,
            .sessionError(
                AgentHostSessionErrorPayload(
                    sessionId: "session-one",
                    sequence: 7,
                    turnId: "turn-one",
                    code: "agent_error",
                    message: "Model request failed"
                )
            )
        )
    }

    func testDecodesHostHelloEvent() throws {
        let data = Data(#"{"version":1,"kind":"event","event":"host.hello","payload":{"hostVersion":"0.1.0","piVersion":"0.83.0","capabilities":["sessions.list"]}}"#.utf8)

        let event = try JSONDecoder().decode(
            AgentHostEvent<AgentHostHelloPayload>.self,
            from: data
        )

        XCTAssertEqual(event.version, 1)
        XCTAssertEqual(event.event, "host.hello")
        XCTAssertEqual(event.payload.hostVersion, "0.1.0")
        XCTAssertEqual(event.payload.piVersion, "0.83.0")
        XCTAssertEqual(event.payload.capabilities, ["sessions.list"])
    }

    func testServerEventDecoderDecodesHostHello() throws {
        let data = Data(#"{"version":1,"kind":"event","event":"host.hello","payload":{"hostVersion":"0.1.0","piVersion":"0.83.0","capabilities":["sessions.list"]}}"#.utf8)

        let event = try AgentHostServerEvent.decode(from: data)

        XCTAssertEqual(
            event,
            .hostHello(
                AgentHostHelloPayload(
                    hostVersion: "0.1.0",
                    piVersion: "0.83.0",
                    capabilities: ["sessions.list"],
                    supportsPiWorkExtensions: true
                )
            )
        )
    }

    func testUnknownEventRemainsForwardCompatible() throws {
        let data = Data(#"{"version":1,"kind":"event","event":"session.future","payload":{"newField":true}}"#.utf8)

        let event = try AgentHostServerEvent.decode(from: data)

        XCTAssertEqual(event, .unknown(name: "session.future"))
    }

    func testDecodesAuthenticationPromptEvent() throws {
        let data = Data(#"{"version":1,"kind":"event","event":"auth.prompt","payload":{"flowId":"flow-one","providerId":"openai-codex","sequence":1,"promptId":"prompt-one","type":"select","message":"Choose login","options":[{"id":"browser","label":"Browser","description":"Use the default browser"}]}}"#.utf8)

        let event = try AgentHostServerEvent.decode(from: data)

        XCTAssertEqual(
            event,
            .authPrompt(
                AgentHostAuthPromptPayload(
                    flowId: "flow-one",
                    providerId: "openai-codex",
                    sequence: 1,
                    promptId: "prompt-one",
                    type: .select,
                    message: "Choose login",
                    placeholder: nil,
                    options: [
                        AgentHostAuthPromptOption(
                            id: "browser",
                            label: "Browser",
                            description: "Use the default browser"
                        )
                    ],
                    allowsEmpty: nil
                )
            )
        )
    }

    func testAuthenticationPromptDecodesEmptyResponsePolicy() throws {
        let data = Data(#"{"version":1,"kind":"event","event":"auth.prompt","payload":{"flowId":"flow-one","providerId":"github-copilot","sequence":1,"promptId":"prompt-one","type":"text","message":"Choose a GitHub host","allowsEmpty":true}}"#.utf8)

        let event = try AgentHostServerEvent.decode(from: data)
        guard case .authPrompt(let payload) = event else {
            return XCTFail("Expected an authentication prompt")
        }

        XCTAssertEqual(payload.allowsEmpty, true)
    }

    func testDecodesProviderAuthenticationSnapshotsWithoutSecrets() throws {
        let data = Data(#"{"providers":[{"id":"openai-codex","name":"OpenAI Codex","methods":[{"type":"oauth","name":"OpenAI Codex OAuth","loginLabel":"Sign in with ChatGPT"},{"type":"api_key","name":"OpenAI API key"}],"status":{"configured":true,"source":"stored","credentialType":"oauth","canDisconnect":true,"label":"OAuth"},"models":{"total":4,"available":4}}]}"#.utf8)

        let result = try JSONDecoder().decode(AgentHostProviderListResult.self, from: data)

        XCTAssertEqual(
            result.providers,
            [
                AgentHostProvider(
                    id: "openai-codex",
                    name: "OpenAI Codex",
                    methods: [
                        AgentHostProviderAuthMethod(
                            type: .oauth,
                            name: "OpenAI Codex OAuth",
                            loginLabel: "Sign in with ChatGPT"
                        ),
                        AgentHostProviderAuthMethod(
                            type: .apiKey,
                            name: "OpenAI API key",
                            loginLabel: nil
                        )
                    ],
                    status: AgentHostProviderAuthStatus(
                        configured: true,
                        source: .stored,
                        credentialType: .oauth,
                        canDisconnect: true,
                        label: "OAuth"
                    ),
                    models: AgentHostProviderModelCounts(total: 4, available: 4)
                )
            ]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["accessToken"])
        XCTAssertNil(object["apiKey"])
    }

    func testDecodesAuthenticationNoticeCompletionAndModelChangeEvents() throws {
        let authURL = try AgentHostServerEvent.decode(
            from: Data(#"{"version":1,"kind":"event","event":"auth.notice","payload":{"flowId":"flow-one","providerId":"openai-codex","sequence":2,"notice":{"type":"auth_url","url":"https://example.com/oauth","instructions":"Continue in your browser"}}}"#.utf8)
        )
        XCTAssertEqual(
            authURL,
            .authNotice(
                AgentHostAuthNoticePayload(
                    flowId: "flow-one",
                    providerId: "openai-codex",
                    sequence: 2,
                    notice: .authURL(
                        url: "https://example.com/oauth",
                        instructions: "Continue in your browser"
                    )
                )
            )
        )

        let deviceCode = try AgentHostServerEvent.decode(
            from: Data(#"{"version":1,"kind":"event","event":"auth.notice","payload":{"flowId":"flow-one","providerId":"openai-codex","sequence":3,"notice":{"type":"device_code","userCode":"ABCD-EFGH","verificationUri":"https://example.com/device","intervalSeconds":5,"expiresInSeconds":900}}}"#.utf8)
        )
        XCTAssertEqual(
            deviceCode,
            .authNotice(
                AgentHostAuthNoticePayload(
                    flowId: "flow-one",
                    providerId: "openai-codex",
                    sequence: 3,
                    notice: .deviceCode(
                        userCode: "ABCD-EFGH",
                        verificationURI: "https://example.com/device",
                        intervalSeconds: 5,
                        expiresInSeconds: 900
                    )
                )
            )
        )

        let finished = try AgentHostServerEvent.decode(
            from: Data(#"{"version":1,"kind":"event","event":"auth.finished","payload":{"flowId":"flow-one","providerId":"openai-codex","sequence":4,"outcome":"succeeded"}}"#.utf8)
        )
        XCTAssertEqual(
            finished,
            .authFinished(
                AgentHostAuthFinishedPayload(
                    flowId: "flow-one",
                    providerId: "openai-codex",
                    sequence: 4,
                    outcome: .succeeded,
                    error: nil
                )
            )
        )

        let modelsChanged = try AgentHostServerEvent.decode(
            from: Data(#"{"version":1,"kind":"event","event":"models.changed","payload":{"reason":"authentication","providerId":"openai-codex"}}"#.utf8)
        )
        XCTAssertEqual(
            modelsChanged,
            .modelsChanged(
                AgentHostModelsChangedPayload(
                    reason: .authentication,
                    providerId: "openai-codex"
                )
            )
        )
    }

    func testEncodesTypedAuthenticationRequests() throws {
        let start = AgentHostRequest(
            id: "start-auth",
            method: "auth.start",
            params: AgentHostAuthStartParameters(
                flowId: "flow-one",
                providerId: "openai-codex",
                method: .oauth
            )
        )
        let startObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: start.encodedLine().dropLast()) as? [String: Any]
        )
        XCTAssertEqual(
            startObject["params"] as? [String: String],
            ["flowId": "flow-one", "providerId": "openai-codex", "method": "oauth"]
        )

        let response = AgentHostRequest(
            id: "respond-auth",
            method: "auth.respond",
            params: AgentHostAuthRespondParameters(
                flowId: "flow-one",
                promptId: "prompt-one",
                value: "browser"
            )
        )
        let responseObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.encodedLine().dropLast()) as? [String: Any]
        )
        XCTAssertEqual(
            responseObject["params"] as? [String: String],
            ["flowId": "flow-one", "promptId": "prompt-one", "value": "browser"]
        )
    }

    func testEncodesRequestAsOneLFDelimitedRecord() throws {
        let request = AgentHostRequest(
            id: "list-1",
            method: "sessions.list",
            params: AgentHostSessionListParameters(
                cwd: "/tmp/project",
                sessionDirectory: "/tmp/sessions"
            )
        )

        let line = try request.encodedLine()
        XCTAssertEqual(line.last, 0x0A)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any]
        )
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object["id"] as? String, "list-1")
        XCTAssertEqual(object["method"] as? String, "session/list")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["cwd"] as? String, "/tmp/project")
        XCTAssertNil(params["sessionDirectory"])
        let metadata = try XCTUnwrap(params["_meta"] as? [String: Any])
        XCTAssertEqual(
            (metadata["piWork"] as? [String: Any])?["sessionDirectory"] as? String,
            "/tmp/sessions"
        )
    }

    func testSessionNewIncludesRequiredACPV1MCPServers() throws {
        let request = AgentHostRequest(
            id: "new-1",
            method: "session.createDraft",
            params: AgentHostSessionCreateDraftParameters(
                cwd: "/tmp/project",
                sessionDirectory: nil,
                profile: .work
            )
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.encodedLine().dropLast()) as? [String: Any]
        )
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "session/new")
        XCTAssertEqual(params["cwd"] as? String, "/tmp/project")
        XCTAssertEqual((params["mcpServers"] as? [Any])?.count, 0)
        let metadata = try XCTUnwrap(params["_meta"] as? [String: Any])
        XCTAssertEqual(Set(metadata.keys), ["piWork"])
        XCTAssertEqual((metadata["piWork"] as? [String: Any])?["profile"] as? String, "work")
    }

    func testSessionResumeUsesOnlyACPV1Fields() throws {
        let request = AgentHostRequest(
            id: "load-1",
            method: "session.open",
            params: AgentHostSessionOpenParameters(
                sessionId: "session-one",
                cwd: "/tmp/project",
                sessionDirectory: nil,
                profile: .work
            )
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.encodedLine().dropLast()) as? [String: Any]
        )
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "session/resume")
        XCTAssertEqual(params["sessionId"] as? String, "session-one")
        XCTAssertEqual(params["cwd"] as? String, "/tmp/project")
        XCTAssertEqual((params["mcpServers"] as? [Any])?.count, 0)
        XCTAssertNil(params["path"])
    }

    func testSessionCancelEncodesACPNotificationWithoutRequestID() throws {
        let notification = AgentHostNotification(
            method: "session.abort",
            params: AgentHostSessionIdentifierParameters(sessionId: "session-one")
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: notification.encodedLine().dropLast())
                as? [String: Any]
        )
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object["method"] as? String, "session/cancel")
        XCTAssertEqual((object["params"] as? [String: Any])?["sessionId"] as? String, "session-one")
        XCTAssertNil(object["id"])
    }

    func testEncodesPromptImagesAsBase64() throws {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let request = AgentHostRequest(
            id: "prompt-one",
            method: "session.prompt",
            params: AgentHostSessionPromptParameters(
                sessionId: "session-one",
                turnId: "turn-one",
                text: "Inspect this",
                images: [
                    AgentHostPromptImage(mimeType: "image/png", data: imageData)
                ]
            )
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.encodedLine().dropLast()) as? [String: Any]
        )
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        let images = try XCTUnwrap(params["prompt"] as? [[String: String]])

        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[0]["type"], "text")
        XCTAssertEqual(images[1], [
            "type": "image",
            "mimeType": "image/png",
            "data": imageData.base64EncodedString()
        ])
        XCTAssertNil(params["_meta"])
    }

    func testDecodesAssistantContentAsARecognizedSessionEvent() throws {
        let data = Data(#"{"version":1,"kind":"event","event":"session.assistantContent","payload":{"sessionId":"session-one","sequence":2,"turnId":"turn-one","generationIndex":0,"phase":"start","contentType":"thinking","contentIndex":0}}"#.utf8)

        let event = try AgentHostServerEvent.decode(from: data)

        XCTAssertEqual(
            event,
            .sessionAssistantContent(
                AgentHostSessionAssistantContentPayload(
                    sessionId: "session-one",
                    sequence: 2,
                    turnId: "turn-one",
                    generationIndex: 0,
                    phase: .start,
                    contentType: .thinking,
                    contentIndex: 0,
                    delta: nil,
                    content: nil,
                    toolCall: nil
                )
            )
        )
    }

    func testDecodesProviderVisibleThinkingText() throws {
        let data = Data(#"{"session":{"id":"session-one","path":"/tmp/session.jsonl","cwd":"/tmp/project","title":"Thinking"},"messages":[{"id":"assistant-one","role":"assistant","content":[{"type":"thinking","thinking":"Visible summary","redacted":false},{"type":"text","text":"Answer"}],"timestamp":"2026-08-09T00:00:01.000Z"}],"state":"idle","sequence":0,"turnId":null,"model":null,"thinkingLevel":"high","availableThinkingLevels":["off","high"],"modelOptions":{"fastMode":{"supported":false,"enabled":false},"oneMillionContext":{"supported":false,"enabled":false}},"accessMode":"ask","pendingApprovals":[]}"#.utf8)

        let snapshot = try JSONDecoder().decode(AgentHostSessionSnapshotResult.self, from: data)

        XCTAssertEqual(
            snapshot.messages.first?.content,
            [.thinking(text: "Visible summary", redacted: false), .text("Answer")]
        )
    }

}
