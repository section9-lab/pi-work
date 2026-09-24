import Darwin
import XCTest
@testable import PiWork

final class AgentHostClientTests: XCTestCase {
    func testClientNegotiatesACPAndPassesPrivateEnvironmentToTheHost() async throws {
        let script = #"read _; printf '{"jsonrpc":"2.0","id":"__pi_work_initialize__","result":{"protocolVersion":1,"agentInfo":{"name":"pi-work-agent-host","version":"%s"},"_meta":{"piVersion":"0.84.1","capabilities":[]}}}\n' "$PI_WORK_AUTH_PATH"; cat >/dev/null"#
        let client = AgentHostClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            environment: ["PI_WORK_AUTH_PATH": "/tmp/pi-work/auth.json"]
        )

        let hello = try await client.start()

        XCTAssertEqual(hello.hostVersion, "/tmp/pi-work/auth.json")
        XCTAssertEqual(hello.piVersion, "0.84.1")
        await client.stop()
    }

    func testClientRemovesTestHarnessConfigurationBeforeACPInitialize() async throws {
        let script = #"read _; printf '{"jsonrpc":"2.0","id":"__pi_work_initialize__","result":{"protocolVersion":1,"agentInfo":{"name":"pi-work-agent-host","version":"%s"},"_meta":{"capabilities":[]}}}\n' "${XCTestConfigurationFilePath:-missing}"; cat >/dev/null"#
        let client = AgentHostClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )

        let hello = try await client.start()

        XCTAssertEqual(hello.hostVersion, "missing")
        await client.stop()
    }

    func testClientCorrelatesJSONRPCResponsesAndACPUpdatesIndependently() async throws {
        let initialize = #"{"jsonrpc":"2.0","id":"__pi_work_initialize__","result":{"protocolVersion":1,"agentInfo":{"name":"pi-work-agent-host","version":"test-host"},"_meta":{"capabilities":["sessions.list"]}}}"#
        let event = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-one","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello"},"_meta":{"sequence":2,"turnId":"turn-one","phase":"delta","contentIndex":0,"generationIndex":0}}}}"#
        let response = #"{"jsonrpc":"2.0","id":"list-1","result":{"sessions":[]}}"#
        let script = "read _; printf '%s\\n' '\(initialize)'; read _; printf '%s\\n' '\(event)'; printf '%s\\n' '\(response)'; cat >/dev/null"
        let client = AgentHostClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )

        _ = try await client.start()
        let events = await client.events()
        let eventTask = Task { () -> AgentHostServerEvent? in
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }
        let result = try await client.request(
            id: "list-1",
            method: "sessions.list",
            params: AgentHostSessionListParameters(cwd: "/tmp/project", sessionDirectory: nil),
            as: AgentHostSessionListResult.self
        )

        XCTAssertEqual(result.sessions, [])
        let receivedEvent = await eventTask.value
        XCTAssertEqual(
            receivedEvent,
            .sessionAssistantContent(
                AgentHostSessionAssistantContentPayload(
                    sessionId: "session-one",
                    sequence: 2,
                    turnId: "turn-one",
                    generationIndex: 0,
                    phase: .delta,
                    contentType: .text,
                    contentIndex: 0,
                    delta: "Hello",
                    content: nil,
                    toolCall: nil
                )
            )
        )
        await client.stop()
    }

    func testClientPreservesACPFailureMessageForDisplay() async throws {
        let initialize = #"{"jsonrpc":"2.0","id":"__pi_work_initialize__","result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#
        let response = #"{"jsonrpc":"2.0","id":"update-1","error":{"code":-32000,"message":"Package update failed: registry unavailable","data":{"code":"invalid_request"}}}"#
        let script = "read _; printf '%s\\n' '\(initialize)'; read _; printf '%s\\n' '\(response)'; cat >/dev/null"
        let client = AgentHostClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )

        _ = try await client.start()
        do {
            let _: AgentHostInstalledExtensionsResult = try await client.request(
                id: "update-1",
                method: "extensions.update",
                params: ["source": "npm:example-extension", "scope": "user"],
                as: AgentHostInstalledExtensionsResult.self
            )
            XCTFail("Expected package update failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Package update failed: registry unavailable")
        }
        await client.stop()
    }

    func testClientReturnsACPRequestTimeoutWhenHostDoesNotRespond() async throws {
        let initialize = #"{"jsonrpc":"2.0","id":"__pi_work_initialize__","result":{"protocolVersion":1,"agentInfo":{"name":"pi-work-agent-host","version":"test-host"},"_meta":{"capabilities":[]}}}"#
        let script = "read _; printf '%s\\n' '\(initialize)'; read _; cat >/dev/null"
        let client = AgentHostClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )

        _ = try await client.start()
        do {
            let _: AgentHostSessionListResult = try await client.request(
                id: "slow-1",
                method: "sessions.list",
                params: AgentHostSessionListParameters(cwd: "/tmp/project", sessionDirectory: nil),
                timeout: 0.05,
                as: AgentHostSessionListResult.self
            )
            XCTFail("Expected request timeout")
        } catch AgentHostClientError.requestTimedOut("slow-1") {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await client.stop()
    }

    func testClientRespondsToACPServerPermissionRequestUsingTheOriginalID() async throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-work-permission-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: markerURL) }
        let initialize = #"{"jsonrpc":"2.0","id":"__pi_work_initialize__","result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#
        let permission = #"{"jsonrpc":"2.0","id":"permission-1","method":"session/request_permission","params":{"sessionId":"session-one","toolCall":{"toolCallId":"tool-one","title":"bash"},"options":[{"optionId":"yes","name":"Allow","kind":"allow_once"},{"optionId":"no","name":"Reject","kind":"reject_once"}]}}"#
        let script = "read _; printf '%s\\n' '\(initialize)'; printf '%s\\n' '\(permission)'; IFS= read -r line; printf '%s\\n' \"$line\" > '\(markerURL.path)'; cat >/dev/null"
        let client = AgentHostClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )

        let events = await client.events()
        var iterator = events.makeAsyncIterator()
        _ = try await client.start()
        guard case .sessionApprovalRequested(let payload) = await iterator.next() else {
            return XCTFail("Expected permission request")
        }
        try await client.respondToPermission(requestId: payload.requestId, optionId: "yes")

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: markerURL.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let response = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL))
            as! [String: Any]
        XCTAssertEqual(response["id"] as? String, "permission-1")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let outcome = try XCTUnwrap(result["outcome"] as? [String: Any])
        XCTAssertEqual(outcome["outcome"] as? String, "selected")
        XCTAssertEqual(outcome["optionId"] as? String, "yes")
        await client.stop()
    }

    func testClientCancelsAnOutstandingACPPermissionRequest() async throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-work-permission-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: markerURL) }
        let initialize = #"{"jsonrpc":"2.0","id":"__pi_work_initialize__","result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#
        let permission = #"{"jsonrpc":"2.0","id":42,"method":"session/request_permission","params":{"sessionId":"session-one","toolCall":{"toolCallId":"tool-one","title":"bash"},"options":[{"optionId":"yes","name":"Allow","kind":"allow_once"}]}}"#
        let script = "read _; printf '%s\\n' '\(initialize)'; printf '%s\\n' '\(permission)'; IFS= read -r line; printf '%s\\n' \"$line\" > '\(markerURL.path)'; cat >/dev/null"
        let client = AgentHostClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )

        let events = await client.events()
        var iterator = events.makeAsyncIterator()
        _ = try await client.start()
        guard case .sessionApprovalRequested(let payload) = await iterator.next() else {
            return XCTFail("Expected permission request")
        }
        try await client.cancelPermission(requestId: payload.requestId)

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: markerURL.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let response = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL))
            as! [String: Any]
        XCTAssertEqual(response["id"] as? Int, 42)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let outcome = try XCTUnwrap(result["outcome"] as? [String: Any])
        XCTAssertEqual(outcome["outcome"] as? String, "cancelled")
        XCTAssertNil(outcome["optionId"])
        await client.stop()
    }

    func testClientRespondsToStandardACPElicitationUsingTheOriginalID() async throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-work-elicitation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: markerURL) }
        let initialize = #"{"jsonrpc":"2.0","id":"__pi_work_initialize__","result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#
        let elicitation = #"{"jsonrpc":"2.0","id":73,"method":"elicitation/create","params":{"mode":"form","sessionId":"session-one","message":"Choose","requestedSchema":{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}}}"#
        let script = "read _; printf '%s\\n' '\(initialize)'; printf '%s\\n' '\(elicitation)'; IFS= read -r line; printf '%s\\n' \"$line\" > '\(markerURL.path)'; cat >/dev/null"
        let client = AgentHostClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )

        let events = await client.events()
        var iterator = events.makeAsyncIterator()
        _ = try await client.start()
        guard case .elicitationRequested(let request) = await iterator.next() else {
            return XCTFail("Expected elicitation request")
        }
        try await client.respondToElicitation(
            requestId: request.id,
            response: .accept(["value": .string("Run")])
        )

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: markerURL.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let response = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL))
            as! [String: Any]
        XCTAssertEqual(response["id"] as? Int, 73)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["action"] as? String, "accept")
        XCTAssertEqual((result["content"] as? [String: Any])?["value"] as? String, "Run")
        await client.stop()
    }

    func testClientFinishesEventsWhenACPHostExits() async throws {
        let initialize = #"{"jsonrpc":"2.0","id":"__pi_work_initialize__","result":{"protocolVersion":1,"agentInfo":{"name":"pi-work-agent-host","version":"test-host"},"_meta":{"capabilities":[]}}}"#
        let script = "read _; printf '%s\\n' '\(initialize)'; sleep 0.05; exit 0"
        let client = AgentHostClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
        let stream = await client.events()
        let finished = expectation(description: "ACP event stream finishes")
        let reader = Task {
            for await _ in stream {}
            finished.fulfill()
        }

        _ = try await client.start()
        await fulfillment(of: [finished], timeout: 1)
        reader.cancel()
        await client.stop()
    }

    func testClientTimesOutWhenACPInitializeIsIgnored() async throws {
        let client = AgentHostClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "cat >/dev/null"],
            handshakeTimeout: 0.05
        )

        do {
            _ = try await client.start()
            XCTFail("Expected ACP handshake timeout")
        } catch AgentHostClientError.handshakeTimedOut {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await client.stop()
    }
}
