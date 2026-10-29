import AppKit
import Foundation
import SwiftUI

/// End-to-end checks against the compiled Host, available without Xcode/XCTest.
@main
@MainActor
struct MCPChecks {
    struct Failure: Error { let message: String }
    static var count = 0
    static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
        count += 1
    }

    static func main() async {
        do { try await run() }
        catch { fputs("MCP checks failed after \(count) checks: \(error)\n", stderr); exit(1) }
    }

    static func run() async throws {
        try checkDrafts()
        try checkACPStream()
        try await checkRequestLifetime()
        let repository = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        let host = repository.appendingPathComponent("build/pi-work-agent-host-\(architecture)")
        let bun = repository.appendingPathComponent("build/Bun/\(architecture)/bun")
        let service = AgentHostService(executableURL: host, environment: [
            "PI_WORK_AGENT_DIR": root.path, "PI_CODING_AGENT_DIR": root.path,
            "PI_WORK_AUTH_PATH": root.appendingPathComponent("model-auth.json").path,
            "PI_WORK_SKIP_REQUIRED_EXTENSION_INSTALL": "1"
        ])
        do {
            try await ComputerUseChecks.run(service: service, repository: repository)
            try await RTKChecks.run(service: service, repository: repository)
            let store = MCPStore(service: service)
            await store.load()
            try expect(store.isSupported && store.servers.isEmpty, "MCP handshake or initial list failed")
            let configuration: [String: Any] = [
                "command": bun.path,
                "args": [repository.appendingPathComponent("AgentHost/tests/fixtures/mcp-server.ts").path],
                "env": ["TEST_TOKEN": "synthetic-private-value"], "exposure": "deferred", "timeout": 3
            ]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: configuration), as: UTF8.self)
            let saved = await store.save(MCPSaveParameters(name: "fixture", configurationJSON: json, allowInChat: false, readOnlyTools: []))
            try expect(saved && store.servers.count == 1, "Native save failed: \(store.errorMessage ?? "unexpected server count")")
            try expect(!store.servers[0].configurationJSON.contains("synthetic-private-value"), "Credentials leaked to native settings")
            var edited = MCPServerDraft(server: store.servers[0])
            edited.timeout = "5"
            let editedSaved = await store.save(MCPSaveParameters(name: edited.name,
                configurationJSON: try edited.configurationJSON(), allowInChat: false, readOnlyTools: []))
            try expect(editedSaved, "Structured form could not save through native MCP service")
            let persisted = try String(contentsOf: root.appendingPathComponent("mcp.json"))
            try expect(persisted.contains("synthetic-private-value") && !persisted.contains("<stored-secret>"),
                       "Structured form overwrote saved environment credentials")
            try expect(store.servers[0].status == "connecting" || store.servers[0].status == "connected",
                       "Saving an enabled server did not automatically start a connection check")
            for _ in 0..<100 {
                await store.load()
                if store.servers[0].status != "connecting" { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try expect(store.servers[0].status == "connected", "Compiled Host could not connect to stdio: \(store.servers[0].status), \(store.errorMessage ?? store.servers[0].error ?? "no diagnostic")")
            try expect(store.servers[0].tools.count == 2, "Tool discovery did not reach the native store")
            try expect(store.servers[0].tools[0].callName == "mcp__fixture__read_record", "Tool permission identity changed")

            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let controller = NSHostingController(rootView: MCPSettingsView(store: store))
            for width: CGFloat in [436, 620, 900] {
                let size = controller.sizeThatFits(in: CGSize(width: width, height: 620))
                try expect(size.width <= width, "MCP settings overflow at \(width)")
            }
            for scheme in [ColorScheme.light, .dark] {
                let editor = NSHostingController(rootView: MCPEditorView(store: store, server: store.servers[0])
                    .environment(\.colorScheme, scheme))
                let size = editor.sizeThatFits(in: CGSize(width: 560, height: 780))
                try expect(size.width == 560 && size.height <= 780, "MCP editor overflows its scrollable sheet")
            }
            if let screenshot = ProcessInfo.processInfo.environment["PI_WORK_MCP_SCREENSHOT_PATH"] {
                let view = controller.view
                view.frame = NSRect(x: 0, y: 0, width: 620, height: 620)
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: screenshot))
                }
            }
            try expect(MCPStore.webURL("javascript:alert(1)") == nil, "Unsafe OAuth URL accepted")
            try expect(MCPStore.webURL("https://user:secret@example.com") == nil, "Credential-bearing URL accepted")
            await store.action("disable", server: store.servers[0])
            try expect(!store.servers[0].enabled, "Native disable failed")
            await store.action("enable", server: store.servers[0])
            try expect(store.servers[0].status == "connecting" || store.servers[0].status == "connected",
                       "Enabling a server did not start an automatic check")
            // Open the page with an enabled configuration that has never been
            // checked by this Host, as after launching the application.
            for _ in 0..<100 {
                await store.load()
                if store.servers[0].status != "connecting" { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            _ = try await service.saveMCP(MCPSaveParameters(name: edited.name,
                configurationJSON: try edited.configurationJSON(), allowInChat: false, readOnlyTools: []))
            await store.load()
            try expect(store.servers[0].status == "connecting" || store.servers[0].status == "connected",
                       "Opening MCP settings did not check an enabled configuration")
            await store.action("remove", server: store.servers[0])
            try expect(store.servers.isEmpty, "Native remove failed")
            let imported = await store.importConfiguration("{\"mcpServers\":{\"remote\":{\"url\":\"https://example.com/mcp\"}}}")
            try expect(imported && !store.servers[0].enabled, "Import executed an unreviewed server")
            try expect(store.servers[0].status == "unchecked", "Disabled imported server was automatically executed")
            let invalid = await store.save(MCPSaveParameters(name: "remote", configurationJSON: "{}", allowInChat: false, readOnlyTools: []))
            try expect(!invalid && store.errorMessage != nil && !store.isWorking, "Invalid configuration had no recoverable error")
            await store.load()
            try expect(store.errorMessage == nil && store.servers.count == 1, "Retry did not recover the native settings state")
        } catch { await service.stop(); throw error }
        await service.stop()
        print("MCP native checks: \(count) passed")
    }

    /// Replay the wire format through the production decoder and reducer. A delta
    /// and its final replacement must identify the same assistant text block.
    static func checkACPStream() throws {
        var reducer = SessionStoreReducer()
        reducer.apply(snapshot: AgentHostSessionSnapshotResult(
            session: AgentHostSessionDescriptor(id: "session-one", path: "/tmp/session-one.jsonl", cwd: "/tmp/project", title: "New Session"),
            messages: [], state: .idle, sequence: 0, turnId: nil, model: nil,
            thinkingLevel: .off, availableThinkingLevels: [], accessMode: .ask, pendingApprovals: []
        ), profile: .work, sessionDirectory: nil)
        let lines = [
            #"{"jsonrpc":"2.0","method":"_piWork/session.stateChanged","params":{"sessionId":"session-one","sequence":1,"turnId":"turn-one","state":"running"}}"#,
            #"{"jsonrpc":"2.0","method":"_piWork/session.assistantContent","params":{"sessionId":"session-one","sequence":2,"turnId":"turn-one","generationIndex":3,"contentIndex":0,"contentType":"text","phase":"start"}}"#,
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-one","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello "},"_meta":{"sequence":3,"turnId":"turn-one","generationIndex":3,"contentIndex":0,"phase":"delta"}}}}"#,
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-one","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"world"},"_meta":{"sequence":4,"turnId":"turn-one","generationIndex":3,"contentIndex":0,"phase":"delta"}}}}"#,
            #"{"jsonrpc":"2.0","method":"_piWork/session.assistantContent","params":{"sessionId":"session-one","sequence":5,"turnId":"turn-one","generationIndex":3,"contentIndex":0,"contentType":"text","phase":"end","content":"Hello world"}}"#,
            #"{"jsonrpc":"2.0","method":"_piWork/session.stateChanged","params":{"sessionId":"session-one","sequence":6,"turnId":"turn-one","state":"idle"}}"#,
        ]
        var effects: [SessionStoreEffect] = []
        for line in lines {
            let event = try AgentHostServerEvent.decode(from: Data(line.utf8))
            effects += reducer.receive(event, timestamp: "2026-10-29T00:00:00Z")
        }
        guard let record = reducer.records["session-one"] else { throw Failure(message: "Missing replayed session") }
        let text = record.transcript.flatMap(\.parts).compactMap { part -> String? in
            if case .text(_, let text) = part { return text }; return nil
        }
        try expect(effects.isEmpty && record.lastSequence == 6, "ACP stream gaps triggered a stale snapshot")
        try expect(text == ["Hello world"], "Final ACP content duplicated the streamed answer")
        try expect(record.runState == .idle && record.activeTurnId == nil, "Completed ACP turn stayed running")
    }

    static func checkRequestLifetime() async throws {
        let initialize = #"{"jsonrpc":"2.0","id":"__pi_work_initialize__","result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#
        let script = "read _; printf '%s\\n' '\(initialize)'; cat >/dev/null"
        let client = AgentHostClient(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        _ = try await client.start()
        do {
            let prompt = Task {
                try await client.request(id: "prompt", method: "session/prompt", params: ["sessionId": "one"],
                    timeout: nil, as: AgentHostACPEmptyResult.self)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            prompt.cancel()
            do { _ = try await prompt.value; throw Failure(message: "Prompt cancellation did not finish") }
            catch is CancellationError { count += 1 }
            do {
                let _: AgentHostACPEmptyResult = try await client.request(id: "management", method: "sessions.list",
                    params: ["cwd": "/tmp"], timeout: 0.01, as: AgentHostACPEmptyResult.self)
                throw Failure(message: "Management deadline was removed")
            } catch AgentHostClientError.requestTimedOut("management") { count += 1 }
        } catch { await client.stop(); throw error }
        await client.stop()
    }

    static func checkDrafts() throws {
        let arguments = ["/path with spaces/node", "-y", "a'b", "", #"{"key":"value with spaces"}"#]
        let command = arguments.map(MCPCommandLine.quote).joined(separator: " ")
        try expect(try MCPCommandLine.parse(command) == arguments, "Quoted commands changed argument boundaries")
        try expect(try MCPCommandLine.parse(#"npx -y server "/folder with spaces" ''"#)
            == ["npx", "-y", "server", "/folder with spaces", ""], "Pasted command could not be parsed")
        do { _ = try MCPCommandLine.parse("node 'unterminated"); throw Failure(message: "Unclosed command quote accepted") }
        catch is MCPDraftError { count += 1 }

        var draft = MCPServerDraft()
        draft.name = "docs"
        try draft.applyJSON(#"{"url":"https://example.com/mcp","headers":{"Authorization":"<stored-secret>"},"oauth":{"clientId":"known-client","clientSecret":"<stored-secret>"},"enabled":false,"exposure":"direct","toolExposure":{"read":"deferred"},"timeout":1}"#)
        draft.url = "https://example.com/new-mcp"
        let result = try JSONSerialization.jsonObject(with: Data(draft.configurationJSON().utf8)) as! [String: Any]
        try expect((result["oauth"] as? [String: String])?["clientSecret"] == "<stored-secret>", "Form editing removed saved OAuth configuration")
        try expect((result["headers"] as? [String: String])?["Authorization"] == "<stored-secret>", "Form editing removed stored header placeholder")
        try expect(result["enabled"] as? Bool == false && result["exposure"] as? String == "direct"
                   && (result["toolExposure"] as? [String: String])?["read"] == "deferred", "Form editing discarded advanced server options")
        try expect(result["timeout"] as? Double == 1, "A one-second timeout was mistaken for a Boolean")
        do { try draft.applyJSON(#"{"url":"https://example.com","timeout":true}"#); throw Failure(message: "Boolean timeout accepted") }
        catch is MCPDraftError { count += 1 }

        draft.transport = .stdio
        draft.commandLine = command
        draft.environment = [MCPKeyValue(key: "TOKEN", value: "<stored-secret>"), MCPKeyValue()]
        let local = try JSONSerialization.jsonObject(with: Data(draft.configurationJSON().utf8)) as! [String: Any]
        try expect(local["command"] as? String == arguments[0] && local["args"] as? [String] == Array(arguments.dropFirst()),
                   "Form command changed executable or arguments")
        try expect(local["url"] == nil && local["oauth"] == nil && local["headers"] == nil, "Transport switch retained HTTP credentials in stdio")
        try expect((local["env"] as? [String: String])?.count == 1, "Empty variable row became an environment variable")
        do {
            _ = try MCPServerDraft.dictionary([MCPKeyValue(key: "Authorization", value: "a"), MCPKeyValue(key: "authorization", value: "b")], caseInsensitive: true)
            throw Failure(message: "Duplicate HTTP header names accepted")
        } catch is MCPDraftError { count += 1 }
        let env = try MCPServerDraft.pastedPairs("TOKEN=a=b\n# comment\nMODE='test mode'", headers: false)
        try expect(try MCPServerDraft.dictionary(env) == ["TOKEN": "a=b", "MODE": "test mode"], "Pasted environment values changed")
        let headers = try MCPServerDraft.pastedPairs("Authorization: Bearer test\nX-Trace: one:two", headers: true)
        try expect(try MCPServerDraft.dictionary(headers)["X-Trace"] == "one:two", "Header paste split its value at a colon")
        draft.timeout = "-1"
        try expect(draft.validationError == .invalidTimeout, "Invalid timeout did not block save")
        draft.timeout = ""
        draft.name = "bad name"
        try expect(draft.validationError == .invalidName, "Invalid server name did not block save")
    }
}
