import Foundation

@MainActor
enum ToolPresentationChecks {
    static func run() throws {
        let login = try JSONDecoder().decode(AgentHostAuthNotice.self, from: Data(#"{"type":"device_code","userCode":"ABC","verificationUri":"https://example.com/device","openBrowserOnConfirm":false,"copyCodeOnConfirm":false}"#.utf8))
        guard case .deviceCode(_, _, _, _, let browser, let clipboard) = login else { throw MCPChecks.Failure(message: "Device code was lost") }
        try MCPChecks.expect(!browser && !clipboard, "Device-code browser/clipboard policy was discarded")
        let usageData = Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fixture","update":{"sessionUpdate":"usage_update","used":100,"size":500000,"cost":{"amount":0.25,"currency":"USD"},"_meta":{"sequence":1,"piWork":{"costSource":"provider","responseModel":"physical-model"}}}}}"#.utf8)
        let event = try AgentHostServerEvent.decode(from: usageData)
        guard case .sessionUsageChanged(let usage) = event else { throw MCPChecks.Failure(message: "Usage event was lost") }
        try MCPChecks.expect(usage.cost?.source == "provider", "Billing provenance was lost across ACP decoding")
        try MCPChecks.expect(usage.responseModel == "physical-model", "Response model was lost across ACP decoding")
        let snapshot = AgentHostSessionSnapshotResult(session: .init(id: "fixture", path: "", cwd: "/tmp", title: "Fixture"),
            messages: [], state: .idle, sequence: 1, turnId: nil, model: nil, thinkingLevel: .off,
            availableThinkingLevels: [.off], accessMode: .full, pendingApprovals: [],
            usage: .init(used: 100, size: 500000, cost: .init(amount: 0.25, currency: "USD", source: "provider"), responseModel: "physical-model"))
        let restored = SessionStoreReducer.project(snapshot: snapshot, profile: .work, sessionDirectory: nil)
        try MCPChecks.expect(restored.acpState.cost?.source == "provider" && restored.acpState.responseModel == "physical-model",
                             "Restoring a snapshot discarded billing/model metadata")
        let packageData = Data(###"{"source":"npm:fixture","scope":"user","filtered":false,"enabled":true,"version":"1.3.0","updateInfo":{"status":"updated","fromVersion":"1.2.0","toVersion":"1.3.0","changelog":"## 1.3.0\nNew feature"}}"###.utf8)
        let package = try JSONDecoder().decode(AgentHostInstalledExtensionPackage.self, from: packageData)
        try MCPChecks.expect(ExtensionUpdatePresentation.message(package.updateInfo, language: .english) == "Updated 1.2.0 → 1.3.0", "Version transition was lost")
        try MCPChecks.expect(package.updateInfo?.changelog?.contains("New feature") == true, "Package changelog was lost")
        try MCPChecks.expect(ExtensionUpdatePresentation.message(.init(status: "unchanged", fromVersion: "1.3.0", toVersion: "1.3.0", changelog: nil), language: .english) == "No version change (1.3.0)", "Unchanged version was reported as an upgrade")
        let timed = SessionToolRecord(id: "timed", name: "bash", summary: "", rawOutput: .object(["_piWork": .object(["durationMs": .number(1250)])]), state: .completed, isError: false)
        try MCPChecks.expect(timed.durationText == "1.25s", "Recorded tool duration was not presented")
        let cache = ToolInputPresentationCache()
        let input = try JSONDecoder().decode(AgentHostJSONValue.self, from: Data(
            #"{"path":"a.swift","oldText":"old\ncontext","newText":"new\ncontext"}"#.utf8))
        let first = cache.value(for: SessionToolRecord(id: "edit", name: "edit", summary: "", rawInput: input, state: .running, isError: nil))
        let finished = cache.value(for: SessionToolRecord(id: "edit", name: "edit", summary: "", output: "Finished", rawInput: input, state: .completed, isError: false))
        try MCPChecks.expect(first === finished, "Output updates recompute an unchanged tool input")
        try MCPChecks.expect(finished.call.summary == "a.swift", "Cached edit path changed")
        try MCPChecks.expect(finished.edit?.diffSummary.additions == 1 && finished.edit?.diffSummary.deletions == 1,
                             "Cached diff statistics differ from the edit")
        let changed = cache.value(for: SessionToolRecord(id: "read", name: "read", summary: #"{"path":"中文.swift","offset":2,"limit":3}"#, state: .running, isError: nil))
        try MCPChecks.expect(first !== changed, "Changed tool input reused stale presentation")
        try MCPChecks.expect(changed.call.formattedInput == "中文.swift  ·  offset: 2  ·  limit: 3", "Read range formatting regressed")
        let diff = ToolDiffPresentationCache()
        try MCPChecks.expect(diff.value(oldText: "a", newText: "b").additions == 1, "Diff cache changed replacement")
        try MCPChecks.expect(diff.value(oldText: "same", newText: "same").additions == 0, "Diff cache failed to invalidate")
    }
}
