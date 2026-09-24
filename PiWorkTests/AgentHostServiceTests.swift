import XCTest
@testable import PiWork

final class AgentHostServiceTests: XCTestCase {
    func testCoreCapabilitiesDoNotRequirePiWorkExtensions() {
        XCTAssertTrue(AgentHostService.coreCapabilities.isEmpty)
    }

    func testBundledServiceStartsStagedAgentHost() async throws {
        let service = try AgentHostService.bundled()
        let hello = try await service.start()
        XCTAssertEqual(hello.hostVersion, "0.1.9")
        XCTAssertTrue(Set(hello.capabilities).isSuperset(of: AgentHostService.coreCapabilities))
        XCTAssertTrue(hello.supportsPiWorkExtensions)
        await service.stop()
    }

    func testSessionListUsesACPMethodAndResultEnvelope() async throws {
        let markerURL = temporaryURL("acp-session-list")
        let initResponse = acpInitializeResponse(capabilities: ["sessions.list"])
        let response = #"{"jsonrpc":"2.0","id":"list-one","result":{"sessions":[{"sessionId":"session-one","cwd":"/tmp/project","title":"ACP session","updatedAt":"2026-08-28T08:00:00Z"}]}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; IFS= read -r line; printf '%s\\n' \"$line\" > '\(markerURL.path)'; printf '%s\\n' '\(response)'; cat >/dev/null"
        let service = AgentHostService(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], requiredCapabilities: ["sessions.list"])
        defer { Task { await service.stop() }; try? FileManager.default.removeItem(at: markerURL) }

        let sessions = try await service.listSessions(cwd: "/tmp/project", sessionDirectory: "/tmp/sessions", requestID: "list-one")
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "session-one")
        XCTAssertEqual(sessions.first?.path, "session-one")
        XCTAssertEqual(sessions.first?.cwd, "/tmp/project")
        XCTAssertEqual(sessions.first?.title, "ACP session")
        XCTAssertEqual(sessions.first?.modifiedAt, "2026-08-28T08:00:00Z")
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as! [String: Any]
        XCTAssertEqual(request["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(request["method"] as? String, "session/list")
        XCTAssertEqual((request["params"] as? [String: Any])?["cwd"] as? String, "/tmp/project")
    }

    func testSessionNewUsesACPResultAndBuildsLocalSummary() async throws {
        let markerURL = temporaryURL("acp-session-new")
        let initResponse = acpInitializeResponse(capabilities: [])
        let response = #"{"jsonrpc":"2.0","id":"new-one","result":{"sessionId":"session-one"}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; IFS= read -r line; printf '%s\\n' \"$line\" > '\(markerURL.path)'; printf '%s\\n' '\(response)'; cat >/dev/null"
        let service = AgentHostService(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        defer { Task { await service.stop() }; try? FileManager.default.removeItem(at: markerURL) }

        let result = try await service.createDraft(
            cwd: "/tmp/project",
            sessionDirectory: nil,
            profile: .work,
            requestID: "new-one"
        )
        let summary = result.session

        XCTAssertEqual(summary.id, "session-one")
        XCTAssertEqual(summary.path, "session-one")
        XCTAssertEqual(summary.cwd, "/tmp/project")
        XCTAssertEqual(summary.title, "New Session")
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as! [String: Any]
        XCTAssertEqual(request["method"] as? String, "session/new")
        XCTAssertEqual(((request["params"] as? [String: Any])?["mcpServers"] as? [Any])?.count, 0)
    }

    func testSessionNewConfiguresSubsequentModelSelectionWithTheAgentConfigID() async throws {
        let markerURL = temporaryURL("acp-session-model-config-id")
        let initResponse = acpInitializeResponse(capabilities: [])
        let newResponse = #"{"jsonrpc":"2.0","id":"new-one","result":{"sessionId":"session-one","configOptions":[{"id":"agent-model","name":"Model","category":"model","type":"select","currentValue":"sonnet","options":[{"value":"sonnet","name":"Sonnet"},{"value":"opus","name":"Opus"}]}]}}"#
        let configResponse = #"{"jsonrpc":"2.0","id":"model-one","result":{"configOptions":[{"id":"agent-model","name":"Model","category":"model","type":"select","currentValue":"opus","options":[{"value":"sonnet","name":"Sonnet"},{"value":"opus","name":"Opus"}]}]}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; IFS= read -r new; printf '%s\\n' '\(newResponse)'; IFS= read -r model; printf '%s\\n%s\\n' \"$new\" \"$model\" > '\(markerURL.path)'; printf '%s\\n' '\(configResponse)'; cat >/dev/null"
        let service = AgentHostService(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
        defer { Task { await service.stop() }; try? FileManager.default.removeItem(at: markerURL) }

        _ = try await service.createDraft(
            cwd: "/tmp/project",
            sessionDirectory: nil,
            profile: .work,
            requestID: "new-one"
        )
        _ = try await service.setModel(
            sessionId: "session-one",
            provider: "",
            modelId: "opus",
            requestID: "model-one"
        )

        let requests = try String(contentsOf: markerURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let params = try XCTUnwrap(requests.last?["params"] as? [String: Any])
        XCTAssertEqual(params["configId"] as? String, "agent-model")
        XCTAssertEqual(params["value"] as? String, "opus")
    }

    func testOpenUsesSessionLoadWhenTheAgentAdvertisesIt() async throws {
        let markerURL = temporaryURL("acp-session-load")
        let initResponse = #"{"jsonrpc":"2.0","id":"__pi_work_initialize__","result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}}"#
        let response = #"{"jsonrpc":"2.0","id":"open-one","result":{}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; IFS= read -r line; printf '%s\\n' \"$line\" > '\(markerURL.path)'; printf '%s\\n' '\(response)'; cat >/dev/null"
        let service = AgentHostService(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
        defer { Task { await service.stop() }; try? FileManager.default.removeItem(at: markerURL) }

        _ = try await service.openSession(
            sessionId: "session-one",
            cwd: "/tmp/project",
            sessionDirectory: nil,
            profile: .chat,
            requestID: "open-one"
        )

        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL))
            as! [String: Any]
        XCTAssertEqual(request["method"] as? String, "session/load")
    }

    func testPromptUsesACPContentBlocks() async throws {
        let markerURL = temporaryURL("acp-session-prompt")
        let initResponse = acpInitializeResponse(capabilities: ["session.prompt"])
        let response = #"{"jsonrpc":"2.0","id":"prompt-one","result":{"stopReason":"end_turn"}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; IFS= read -r line; printf '%s\\n' \"$line\" > '\(markerURL.path)'; printf '%s\\n' '\(response)'; cat >/dev/null"
        let service = AgentHostService(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], requiredCapabilities: ["session.prompt"])
        defer { Task { await service.stop() }; try? FileManager.default.removeItem(at: markerURL) }

        _ = try await service.prompt(sessionId: "session-one", turnId: "turn-one", text: "Inspect this", images: [AgentHostPromptImage(mimeType: "image/png", data: Data([0x89, 0x50]))], requestID: "prompt-one")
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as! [String: Any]
        XCTAssertEqual(request["method"] as? String, "session/prompt")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["sessionId"] as? String, "session-one")
        let content = try XCTUnwrap(params["prompt"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertEqual(content.first?["text"] as? String, "Inspect this")
        XCTAssertEqual(content.last?["type"] as? String, "image")
    }

    func testStandardACPUpdatesAreCorrelatedWithoutPrivateMetadata() async throws {
        let initResponse = acpInitializeResponse(capabilities: [])
        let update = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-one","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}}"#
        let response = #"{"jsonrpc":"2.0","id":"prompt-one","result":{"stopReason":"end_turn"}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; IFS= read -r _; printf '%s\\n' '\(update)'; printf '%s\\n' '\(response)'; cat >/dev/null"
        let service = AgentHostService(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
        defer { Task { await service.stop() } }

        let events = await service.events()
        let eventTask = Task { () -> AgentHostServerEvent? in
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }
        _ = try await service.prompt(
            sessionId: "session-one",
            turnId: "turn-one",
            text: "Hello",
            requestID: "prompt-one"
        )
        guard case .sessionAssistantContent(let payload) = await eventTask.value else {
            return XCTFail("Expected assistant content")
        }
        XCTAssertEqual(payload.sequence, 1)
        XCTAssertEqual(payload.turnId, "turn-one")
    }

    func testWidgetUpdatesReceiveLocalSequenceNumbers() async throws {
        let initResponse = acpInitializeResponse(capabilities: [])
        let update = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-one","update":{"sessionUpdate":"_piWork/extension_widget","key":"any-plugin","lines":["2 workers running"],"placement":"aboveEditor"}}}"#
        let response = #"{"jsonrpc":"2.0","id":"prompt-one","result":{"stopReason":"end_turn"}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; IFS= read -r _; printf '%s\\n' '\(update)'; printf '%s\\n' '\(response)'; cat >/dev/null"
        let service = AgentHostService(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        defer { Task { await service.stop() } }
        let events = await service.events()
        let eventTask = Task { () -> AgentHostServerEvent? in
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }
        _ = try await service.prompt(sessionId: "session-one", turnId: "turn-one", text: "Hello", requestID: "prompt-one")
        guard case .sessionExtensionWidgetChanged(let payload) = await eventTask.value else {
            return XCTFail("Expected a widget update")
        }
        XCTAssertEqual(payload.sequence, 1)
        XCTAssertEqual(payload.key, "any-plugin")
        XCTAssertEqual(payload.widget, AgentHostExtensionWidget(lines: ["2 workers running"]))
    }

    func testACPSessionUpdateIsForwardedAsDomainEvent() async throws {
        let markerURL = temporaryURL("acp-session-event")
        let initResponse = acpInitializeResponse(capabilities: ["sessions.list"])
        let update = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-one","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"},"_meta":{"sequence":7,"turnId":"turn-one","phase":"delta","contentIndex":0,"generationIndex":0}}}}"#
        let response = #"{"jsonrpc":"2.0","id":"list-one","result":{"sessions":[]}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; IFS= read -r line; printf '%s\\n' \"$line\" > '\(markerURL.path)'; printf '%s\\n' '\(update)'; printf '%s\\n' '\(response)'; cat >/dev/null"
        let service = AgentHostService(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], requiredCapabilities: ["sessions.list"])
        defer { Task { await service.stop() }; try? FileManager.default.removeItem(at: markerURL) }

        let events = await service.events()
        let eventTask = Task { () -> AgentHostServerEvent? in
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }
        _ = try await service.listSessions(cwd: "/tmp/project", sessionDirectory: nil, requestID: "list-one")
        guard let event = await eventTask.value else {
            return XCTFail("Expected an ACP session update event")
        }
        guard case .sessionAssistantContent(let payload) = event else {
            return XCTFail("Expected assistant content event, got \(String(describing: event))")
        }
        XCTAssertEqual(payload.delta, "hello")
        XCTAssertEqual(payload.sequence, 7)
        XCTAssertEqual(payload.turnId, "turn-one")
    }

    func testPermissionDecisionRespondsToTheACPServerRequest() async throws {
        let markerURL = temporaryURL("acp-permission-response")
        let initResponse = acpInitializeResponse(capabilities: [])
        let permission = #"{"jsonrpc":"2.0","id":"permission-one","method":"session/request_permission","params":{"sessionId":"session-one","toolCall":{"toolCallId":"tool-one","title":"bash"},"options":[{"optionId":"yes","name":"Allow once","kind":"allow_once"},{"optionId":"always","name":"Always allow","kind":"allow_always"},{"optionId":"no","name":"Reject","kind":"reject_once"}]}}"#
        let legacyResponse = #"{"jsonrpc":"2.0","id":"resolve-one","result":{"sessionId":"session-one","requestId":"permission-one","decision":"allowAlways"}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; sleep 0.1; printf '%s\\n' '\(permission)'; IFS= read -r line; printf '%s\\n' \"$line\" > '\(markerURL.path)'; printf '%s\\n' '\(legacyResponse)'; cat >/dev/null"
        let service = AgentHostService(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
        defer { Task { await service.stop() }; try? FileManager.default.removeItem(at: markerURL) }

        let events = await service.events()
        var iterator = events.makeAsyncIterator()
        _ = try await service.start()
        guard case .sessionApprovalRequested(let payload) = await iterator.next() else {
            return XCTFail("Expected permission request")
        }
        _ = try await service.resolveApproval(
            sessionId: payload.sessionId,
            requestId: payload.requestId,
            decision: .allowAlways,
            requestID: "resolve-one"
        )

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: markerURL.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let response = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL))
            as! [String: Any]
        XCTAssertEqual(response["id"] as? String, "permission-one")
        XCTAssertNil(response["method"])
        let outcome = ((response["result"] as? [String: Any])?["outcome"]
            as? [String: Any])
        XCTAssertEqual(outcome?["optionId"] as? String, "always")
    }

    func testElicitationResponseIsSentToTheACPServerRequest() async throws {
        let markerURL = temporaryURL("acp-elicitation-response")
        let initResponse = acpInitializeResponse(capabilities: [])
        let elicitation = #"{"jsonrpc":"2.0","id":"elicitation-one","method":"elicitation/create","params":{"mode":"form","sessionId":"session-one","message":"Choose","requestedSchema":{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; sleep 0.1; printf '%s\\n' '\(elicitation)'; IFS= read -r line; printf '%s\\n' \"$line\" > '\(markerURL.path)'; cat >/dev/null"
        let service = AgentHostService(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
        defer { Task { await service.stop() }; try? FileManager.default.removeItem(at: markerURL) }

        let events = await service.events()
        var iterator = events.makeAsyncIterator()
        _ = try await service.start()
        guard case .elicitationRequested(let request) = await iterator.next() else {
            return XCTFail("Expected elicitation request")
        }

        try await service.resolveElicitation(
            sessionId: "session-one",
            requestId: request.id,
            response: .accept(["value": .string("Run")]),
            requestID: "resolve-one"
        )

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: markerURL.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let response = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL))
            as! [String: Any]
        XCTAssertEqual(response["id"] as? String, "elicitation-one")
        XCTAssertEqual((response["result"] as? [String: Any])?["action"] as? String, "accept")
        XCTAssertEqual(
            ((response["result"] as? [String: Any])?["content"] as? [String: Any])?["value"] as? String,
            "Run"
        )
    }

    func testSessionCancelAlsoCancelsOutstandingACPPermissionRequests() async throws {
        let markerURL = temporaryURL("acp-permission-cancel")
        let initResponse = acpInitializeResponse(capabilities: [])
        let permission = #"{"jsonrpc":"2.0","id":"permission-one","method":"session/request_permission","params":{"sessionId":"session-one","toolCall":{"toolCallId":"tool-one","title":"bash"},"options":[{"optionId":"yes","name":"Allow","kind":"allow_once"}]}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; sleep 0.1; printf '%s\\n' '\(permission)'; IFS= read -r response; IFS= read -r notification; printf '%s\\n%s\\n' \"$response\" \"$notification\" > '\(markerURL.path)'; cat >/dev/null"
        let service = AgentHostService(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
        defer { Task { await service.stop() }; try? FileManager.default.removeItem(at: markerURL) }

        let events = await service.events()
        var iterator = events.makeAsyncIterator()
        _ = try await service.start()
        guard case .sessionApprovalRequested = await iterator.next() else {
            return XCTFail("Expected permission request")
        }
        _ = try await service.abort(sessionId: "session-one")

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: markerURL.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let records = try String(contentsOf: markerURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["id"] as? String, "permission-one")
        let outcome = ((records[0]["result"] as? [String: Any])?["outcome"]
            as? [String: Any])
        XCTAssertEqual(outcome?["outcome"] as? String, "cancelled")
        XCTAssertEqual(records[1]["method"] as? String, "session/cancel")
    }

    func testSessionCloseAcceptsTheACPEmptyResult() async throws {
        let markerURL = temporaryURL("acp-session-close")
        let initResponse = acpInitializeResponse(capabilities: [])
        let response = #"{"jsonrpc":"2.0","id":"close-one","result":{}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; IFS= read -r line; printf '%s\\n' \"$line\" > '\(markerURL.path)'; printf '%s\\n' '\(response)'; cat >/dev/null"
        let service = AgentHostService(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
        defer { Task { await service.stop() }; try? FileManager.default.removeItem(at: markerURL) }

        let result = try await service.closeSession(
            sessionId: "session-one",
            requestID: "close-one"
        )

        XCTAssertTrue(result.closed)
        XCTAssertEqual(result.sessionId, "session-one")
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL))
            as! [String: Any]
        XCTAssertEqual(request["method"] as? String, "session/close")
    }

    func testStandardACPAgentAuthenticationAndLogoutUseStandardMethods() async throws {
        let markerURL = temporaryURL("acp-agent-auth")
        let initResponse = #"{"jsonrpc":"2.0","id":"__pi_work_initialize__","result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[{"id":"browser","name":"Sign in","description":"Open browser"},{"id":"terminal","name":"Terminal","type":"terminal","args":["login"]}]}}"#
        let authenticateResponse = #"{"jsonrpc":"2.0","id":"auth-one","result":{}}"#
        let logoutResponse = #"{"jsonrpc":"2.0","id":"logout-one","result":{}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; IFS= read -r auth; printf '%s\\n' \"$auth\" > '\(markerURL.path)'; printf '%s\\n' '\(authenticateResponse)'; IFS= read -r logout; printf '%s\\n' \"$logout\" >> '\(markerURL.path)'; printf '%s\\n' '\(logoutResponse)'; cat >/dev/null"
        let service = AgentHostService(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
        defer { Task { await service.stop() }; try? FileManager.default.removeItem(at: markerURL) }

        let methods = try await service.agentAuthenticationMethods()
        XCTAssertEqual(methods.map(\.id), ["browser"])
        try await service.authenticateAgent(methodId: "browser", requestID: "auth-one")
        try await service.logoutAgent(requestID: "logout-one")

        let requests = try String(contentsOf: markerURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0]["method"] as? String, "authenticate")
        XCTAssertEqual(
            requests[0]["params"] as? [String: String],
            ["methodId": "browser"]
        )
        XCTAssertEqual(requests[1]["method"] as? String, "logout")
    }

    func testThinkingLevelUsesOnlyTheACPConfigOptionResponse() async throws {
        let markerURL = temporaryURL("acp-thinking-config")
        let initResponse = acpInitializeResponse(capabilities: [])
        let configResponse = #"{"jsonrpc":"2.0","id":"thinking-one","result":{"configOptions":[{"id":"thought_level","name":"Thinking level","type":"select","currentValue":"high","options":[{"value":"off","name":"off"},{"value":"high","name":"high"}]}]}}"#
        let unexpectedSnapshotResponse = #"{"jsonrpc":"2.0","id":"thinking-one-snapshot","error":{"code":-32601,"message":"Method not found"}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; IFS= read -r config; printf '%s\\n' \"$config\" > '\(markerURL.path)'; printf '%s\\n' '\(configResponse)'; if IFS= read -r snapshot; then printf '%s\\n' \"$snapshot\" >> '\(markerURL.path)'; printf '%s\\n' '\(unexpectedSnapshotResponse)'; fi; cat >/dev/null"
        let service = AgentHostService(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
        defer { Task { await service.stop() }; try? FileManager.default.removeItem(at: markerURL) }

        let result = try await service.setThinkingLevel(
            sessionId: "session-one",
            thinkingLevel: .high,
            requestID: "thinking-one"
        )

        XCTAssertEqual(result.thinkingLevel, .high)
        XCTAssertEqual(result.availableThinkingLevels, [.off, .high])
        let requests = try String(contentsOf: markerURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0]["method"] as? String, "session/set_config_option")
        let params = requests[0]["params"] as? [String: Any]
        XCTAssertEqual(params?["configId"] as? String, "thought_level")
        XCTAssertEqual(params?["value"] as? String, "high")
    }

    func testModelSelectionUsesOnlyTheACPConfigOptionResponse() async throws {
        let markerURL = temporaryURL("acp-model-config")
        let initResponse = acpInitializeResponse(capabilities: [])
        let configResponse = #"{"jsonrpc":"2.0","id":"model-one","result":{"configOptions":[{"id":"model","name":"Model","type":"select","currentValue":"openai/gpt-test","options":[{"value":"openai/gpt-test","name":"GPT Test"}]},{"id":"thought_level","name":"Thinking level","type":"select","currentValue":"high","options":[{"value":"off","name":"off"},{"value":"high","name":"high"}]},{"id":"fast_mode","name":"Fast mode","type":"boolean","currentValue":true}]}}"#
        let unexpectedSnapshotResponse = #"{"jsonrpc":"2.0","id":"model-one-snapshot","error":{"code":-32601,"message":"Method not found"}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; IFS= read -r config; printf '%s\\n' \"$config\" > '\(markerURL.path)'; printf '%s\\n' '\(configResponse)'; if IFS= read -r snapshot; then printf '%s\\n' \"$snapshot\" >> '\(markerURL.path)'; printf '%s\\n' '\(unexpectedSnapshotResponse)'; fi; cat >/dev/null"
        let service = AgentHostService(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
        defer { Task { await service.stop() }; try? FileManager.default.removeItem(at: markerURL) }

        let result = try await service.setModel(
            sessionId: "session-one",
            provider: "openai",
            modelId: "gpt-test",
            requestID: "model-one"
        )

        XCTAssertEqual(result.model.provider, "openai")
        XCTAssertEqual(result.model.id, "gpt-test")
        XCTAssertEqual(result.model.name, "GPT Test")
        XCTAssertEqual(result.thinkingLevel, .high)
        XCTAssertEqual(result.availableThinkingLevels, [.off, .high])
        XCTAssertTrue(result.modelOptions.fastMode.supported)
        XCTAssertTrue(result.modelOptions.fastMode.enabled)
        let requests = try String(contentsOf: markerURL, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(requests.count, 1)
    }

    func testModelOptionUsesOnlyTheACPConfigOptionResponse() async throws {
        let markerURL = temporaryURL("acp-boolean-config")
        let initResponse = acpInitializeResponse(capabilities: [])
        let configResponse = #"{"jsonrpc":"2.0","id":"option-one","result":{"configOptions":[{"id":"model","name":"Model","type":"select","currentValue":"openai/gpt-test","options":[{"value":"openai/gpt-test","name":"GPT Test"}]},{"id":"fast_mode","name":"Fast mode","type":"boolean","currentValue":true}]}}"#
        let unexpectedSnapshotResponse = #"{"jsonrpc":"2.0","id":"option-one-snapshot","error":{"code":-32601,"message":"Method not found"}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; IFS= read -r config; printf '%s\\n' \"$config\" > '\(markerURL.path)'; printf '%s\\n' '\(configResponse)'; if IFS= read -r snapshot; then printf '%s\\n' \"$snapshot\" >> '\(markerURL.path)'; printf '%s\\n' '\(unexpectedSnapshotResponse)'; fi; cat >/dev/null"
        let service = AgentHostService(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
        defer { Task { await service.stop() }; try? FileManager.default.removeItem(at: markerURL) }

        let result = try await service.setModelOption(
            sessionId: "session-one",
            option: .fastMode,
            enabled: true,
            requestID: "option-one"
        )

        XCTAssertEqual(result.model.id, "gpt-test")
        XCTAssertTrue(result.modelOptions.fastMode.supported)
        XCTAssertTrue(result.modelOptions.fastMode.enabled)
        let requests = try String(contentsOf: markerURL, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(requests.count, 1)
    }

    func testSetsAnArbitraryACPConfigOption() async throws {
        let markerURL = temporaryURL("acp-generic-config")
        let initResponse = acpInitializeResponse(capabilities: [])
        let response = #"{"jsonrpc":"2.0","id":"config-one","result":{"configOptions":[{"id":"auto_approve","name":"Auto approve","type":"boolean","currentValue":true}]}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; IFS= read -r line; printf '%s\\n' \"$line\" > '\(markerURL.path)'; printf '%s\\n' '\(response)'; cat >/dev/null"
        let service = AgentHostService(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
        defer { Task { await service.stop() }; try? FileManager.default.removeItem(at: markerURL) }

        let result = try await service.setConfigOption(
            sessionId: "session-one",
            configId: "auto_approve",
            value: .boolean(true),
            requestID: "config-one"
        )

        XCTAssertEqual(result.configOptions.first?.currentValue, .boolean(true))
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL))
            as! [String: Any]
        XCTAssertEqual(request["method"] as? String, "session/set_config_option")
        let params = request["params"] as? [String: Any]
        XCTAssertEqual(params?["configId"] as? String, "auto_approve")
        XCTAssertEqual(params?["value"] as? Bool, true)
    }

    func testSetsAnArbitraryACPMode() async throws {
        let markerURL = temporaryURL("acp-generic-mode")
        let initResponse = acpInitializeResponse(capabilities: [])
        let response = #"{"jsonrpc":"2.0","id":"mode-one","result":{}}"#
        let script = "printf '%s\\n' '\(initResponse)'; IFS= read -r _; IFS= read -r line; printf '%s\\n' \"$line\" > '\(markerURL.path)'; printf '%s\\n' '\(response)'; cat >/dev/null"
        let service = AgentHostService(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
        defer { Task { await service.stop() }; try? FileManager.default.removeItem(at: markerURL) }

        try await service.setSessionMode(
            sessionId: "session-one",
            modeId: "plan",
            requestID: "mode-one"
        )

        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL))
            as! [String: Any]
        XCTAssertEqual(request["method"] as? String, "session/set_mode")
        XCTAssertEqual(
            request["params"] as? [String: String],
            ["sessionId": "session-one", "modeId": "plan"]
        )
    }

    func testACPInitializeDoesNotRequirePiWorkExtensionCapabilities() async throws {
        let initResponse = #"{"jsonrpc":"2.0","id":"__pi_work_initialize__","result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#
        let script = "printf '%s\\n' '\(initResponse)'; cat >/dev/null"
        let service = AgentHostService(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], handshakeTimeout: 1)

        let hello = try await service.start()

        XCTAssertEqual(hello.hostVersion, "unknown")
        await service.stop()
    }

    func testPrivateRequestIsRejectedBeforeWritingWhenCapabilityIsNotAdvertised() async throws {
        let markerURL = temporaryURL("private-capability-marker")
        let initResponse = #"{"jsonrpc":"2.0","id":"__pi_work_initialize__","result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#
        let script = "IFS= read -r _; printf '%s\\n' '\(initResponse)'; cat > '\(markerURL.path)'"
        let service = AgentHostService(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            handshakeTimeout: 1
        )

        _ = try await service.start()
        do {
            _ = try await service.listModels(requestID: "models-one")
            XCTFail("Expected an undeclared PiWork capability to be rejected")
        } catch AgentHostServiceError.missingPiWorkCapability(let capability) {
            XCTAssertEqual(capability, .modelsList)
        }
        await service.stop()

        let written = (try? String(contentsOf: markerURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(written.isEmpty)
    }

    private func temporaryURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pi-work-\(prefix)-\(UUID().uuidString)")
    }

    private func acpInitializeResponse(capabilities: [String]) -> String {
        let capabilitiesJSON = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"jsonrpc\":\"2.0\",\"id\":\"__pi_work_initialize__\",\"result\":{\"protocolVersion\":1,\"agentInfo\":{\"name\":\"test-host\",\"version\":\"test-host\"},\"agentCapabilities\":{\"loadSession\":true,\"promptCapabilities\":{\"image\":true}},\"authMethods\":[],\"_meta\":{\"piVersion\":\"0.84.1\",\"piWorkExtensions\":true,\"capabilities\":[\(capabilitiesJSON)]}}}"
    }
}
