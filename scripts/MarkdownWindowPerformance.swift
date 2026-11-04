// Appended to SessionStoreTests.swift ONLY in the isolated benchmark package.
// This intentionally reuses that file's private deterministic AgentHost fixture.
// No production instrumentation or window-size preference is installed.
import Darwin

extension SessionStoreTests {
    @MainActor
    private struct PerfSurface {
        let window: NSWindow
        let controller: NSHostingController<AnyView>
        func close() {
            // Closing an NSWindow alone can leave its retained SwiftUI tree observing
            // the store. Explicitly unmount it so later samples measure ONE chat.
            controller.rootView = AnyView(EmptyView())
            controller.view.layoutSubtreeIfNeeded()
            window.contentViewController = nil
            window.close()
        }
        var observer: TranscriptUserScrollObserverView? {
            @MainActor func find(_ view: NSView) -> TranscriptUserScrollObserverView? {
                if let result = view as? TranscriptUserScrollObserverView { return result }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            return find(controller.view)
        }
        var frames: [String: CGRect] { observer?.viewport?.frames ?? [:] }
    }

    private func perfCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
    }

    private func perfNow() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

    private func perfLog(_ scenario: String, _ values: [String: Double], iteration: Int) {
        var record: [String: Any] = values
        record["scenario"] = scenario
        record["batch"] = TranscriptWindow.batchSize
        record["iteration"] = iteration
        record["run"] = ProcessInfo.processInfo.environment["PERF_RUN"] ?? "manual"
        let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("MARKDOWN_PERF " + String(decoding: data, as: UTF8.self))
    }

    private func perfMessages(_ range: Range<Int>, salt: String) -> [AgentHostSessionMessage] {
        range.map { index in
            let markdown = """
            ## Analysis \(index) · \(salt)

            A **Markdown** response with `inline code`, [a link](https://example.invalid), 中文增量渲染与历史加载。

            - First item with **emphasis**
            - Second item with `value_\(index)`
              - Nested explanation

            | Window | State | Result |
            | --- | --- | --- |
            | \(index) | streaming | ready |
            | history | cached | stable |

            ```swift
            func render_\(index)(_ value: String) -> String {
                // \(salt)
                return "Result: " + value
            }
            ```

            > Preserve the reading anchor while new tokens arrive.

            \(String(repeating: "Rendering and layout must stay responsive. 实时输出不应打断历史阅读。 ", count: 4))
            """
            return AgentHostSessionMessage(
                id: "row-\(index)", role: index % 5 == 0 ? .user : .assistant,
                content: [.text(index % 5 == 0 ? "Question \(index) · \(salt)" : markdown)],
                timestamp: "2026-08-09T00:00:00.000Z", provider: nil, model: nil,
                stopReason: nil, errorMessage: nil, toolCallId: nil, toolName: nil, isError: nil
            )
        }
    }

    private func perfSurface(_ store: SessionStore) -> PerfSurface {
        let controller = NSHostingController(rootView: AnyView(ChatView(
            mode: .work, projects: [],
            selectedProject: .constant(PiProject(name: "Project", path: "/tmp/project")),
            sessionStore: store, composerDrafts: SessionComposerDraftStore(), onAddFolder: {}
        )))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 840, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        return PerfSurface(window: window, controller: controller)
    }

    // The completion condition is actual row geometry, NOT a fixed sleep.
    // Three stable samples add a common ~30 ms observation floor to layout times.
    private func perfWait(_ surface: PerfSurface, rows: Int, first: String? = nil) async throws {
        let deadline = perfNow() + 30_000
        var stable = 0
        var previousHeight: CGFloat = -1
        while perfNow() < deadline {
            surface.controller.view.layoutSubtreeIfNeeded()
            let height = surface.observer?.enclosingScrollView?.documentView?.bounds.height ?? 0
            if surface.frames.count == rows, first == nil || surface.frames[first!] != nil,
               abs(height - previousHeight) < 0.5 {
                stable += 1
                if stable >= 3 { return }
            } else { stable = 0 }
            previousHeight = height
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(rows) rows / \(first ?? "any"); got \(surface.frames.count)")
        throw NSError(domain: "MarkdownWindowPerformance", code: 1)
    }

    private func perfTop(_ surface: PerfSurface) throws {
        let observer = try XCTUnwrap(surface.observer)
        let scroll = try XCTUnwrap(observer.enclosingScrollView)
        let point = scroll.convert(CGPoint(x: 100, y: 100), to: nil)
        observer.handleScrollWheel(TestPhaseLessScrollWheelEvent(window: surface.window, point: point))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    func testMarkdownWindowPerformance() async throws {
        let iterations = Int(ProcessInfo.processInfo.environment["PERF_ITERATIONS"] ?? "2")!
        let batch = TranscriptWindow.batchSize
        for iteration in 0..<iterations {
            // Unique content per iteration avoids accidentally calling a hot parse cache cold.
            let salt = "\(ProcessInfo.processInfo.environment["PERF_RUN"] ?? "run")-\(iteration)"
            let host = FakeAgentHost()
            let messages = perfMessages(0..<1000, salt: salt)
            await host.setSnapshot(makeStoreSnapshot(messages: messages))
            var traceEvents: [SessionOpenPerformanceEvent] = []
            let tracer = SessionOpenPerformanceTracer(sink: { traceEvents.append($0) })
            let store = SessionStore(service: host, performanceTracer: tracer)
            let trace = store.beginSessionOpenPerformanceTrace(sessionID: "session-one", profile: .work)
            var start = perfNow(), cpu = perfCPU()
            try await store.openSession(makeSummary(), profile: .work, sessionDirectory: nil, performanceTraceID: trace)
            let surface = perfSurface(store)
            try await perfWait(surface, rows: batch, first: "row-\(1000 - batch)")
            perfLog("open_cold_1000", ["wall_ms": perfNow() - start, "cpu_ms": perfCPU() - cpu,
                "first_frame_ms": try XCTUnwrap(traceEvents.first { $0.stage == .firstFrame }).elapsedMilliseconds,
                "rows": Double(surface.frames.count)], iteration: iteration)

            // Expand 1x -> 2x -> 3x, then slide the bounded 3x history window.
            for step in 1...3 {
                let oldFirst = try XCTUnwrap(surface.frames.keys.compactMap { Int($0.dropFirst(4)) }.min())
                start = perfNow(); cpu = perfCPU()
                try perfTop(surface)
                let expectedFirst = 1000 - batch * (step + 1)
                try await perfWait(surface, rows: min(step + 1, 3) * batch, first: "row-\(expectedFirst)")
                // Anchor restoration is asynchronous; wait for its observable result.
                let deadline = perfNow() + 5000
                while abs(surface.frames["row-\(oldFirst)"]?.minY ?? 9999) > 2, perfNow() < deadline {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                let drift = abs(surface.frames["row-\(oldFirst)"]?.minY ?? 9999)
                XCTAssertLessThanOrEqual(drift, 2)
                perfLog("history_cached_\(step)", ["wall_ms": perfNow() - start, "cpu_ms": perfCPU() - cpu,
                    "rows": Double(surface.frames.count), "anchor_error_pt": drift], iteration: iteration)
            }
            surface.close()
            try await Task.sleep(nanoseconds: 50_000_000)

            // Same session re-mounted: persistent store + shared Markdown cache.
            start = perfNow(); cpu = perfCPU()
            try await store.openSession(makeSummary(), profile: .work, sessionDirectory: nil)
            let live = perfSurface(store)
            try await perfWait(live, rows: batch, first: "row-\(1000 - batch)")
            perfLog("open_warm_1000", ["wall_ms": perfNow() - start, "cpu_ms": perfCPU() - cpu], iteration: iteration)
            let opens = await host.openCount
            XCTAssertEqual(opens, 1, "Cached session must not make another open RPC")

            // Real event -> reducer -> ChatView -> AssistantMarkdownView, 50 Hz.
            // Producer is detached so main-thread stalls cannot reduce offered load.
            for paused in [false, true] {
                if paused {
                    try perfTop(live)
                    try await perfWait(live, rows: batch * 2, first: "row-\(1001 - batch * 2)")
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                let anchor = live.frames.filter { $0.value.maxY > 0 && $0.value.minY < 300 }
                    .min { $0.value.minY < $1.value.minY }
                let base = paused ? 102 : 0
                let turn = paused ? "paused" : "live"
                await host.emit(.sessionStateChanged(.init(sessionId: "session-one", sequence: base + 1, turnId: turn, state: .running)))
                try await Task.sleep(nanoseconds: 30_000_000)
                start = perfNow(); cpu = perfCPU()
                let producer = Task.detached {
                    for index in 0..<100 {
                        await host.emit(.sessionMessageDelta(.init(sessionId: "session-one", sequence: base + index + 2,
                            turnId: turn, delta: "\n\n**Token \(index)** `code` 中文输出 with a growing Markdown paragraph.")))
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                }
                var gaps: [Double] = []
                var previous = perfNow()
                // Sample main-actor responsiveness; these are scheduling gaps, NOT GPU FPS.
                while perfNow() - start < 2200 {
                    try await Task.sleep(nanoseconds: 5_000_000)
                    live.controller.view.layoutSubtreeIfNeeded()
                    let now = perfNow(); gaps.append(now - previous); previous = now
                }
                try await producer.value
                await host.emit(.sessionStateChanged(.init(sessionId: "session-one", sequence: base + 102, turnId: turn, state: .idle)))
                try await Task.sleep(nanoseconds: 250_000_000)
                XCTAssertEqual(store.records["session-one"]?.runState, .idle)
                XCTAssertEqual(store.records["session-one"]?.lastSequence, base + 102)
                XCTAssertEqual(store.records["session-one"]?.transcript.count, paused ? 1002 : 1001)
                XCTAssertTrue(store.records["session-one"]?.transcript.last?.id.contains(turn) == true)
                let snapshots = await host.snapshotCount
                XCTAssertEqual(snapshots, 1, "Streaming must not trigger sequence-gap snapshot repair")
                XCTAssertTrue(store.records["session-one"]?.transcript.last?.parts.contains {
                    if case .text(_, let text) = $0 { return text.contains("Token 99") }; return false
                } == true, "The final streamed delta must not be dropped")
                if paused, let anchor {
                    XCTAssertEqual(live.frames[anchor.key]?.minY ?? 9999, anchor.value.minY, accuracy: 2)
                    XCTAssertFalse(live.frames.keys.contains { $0.contains("paused") })
                }
                gaps.sort()
                perfLog(paused ? "stream_reading_history" : "stream_follow_tail", [
                    "wall_ms": perfNow() - start, "cpu_ms": perfCPU() - cpu,
                    "gap_p95_ms": gaps[Int(Double(gaps.count - 1) * 0.95)], "gap_max_ms": gaps.last!,
                    "gaps_over_16_7_pct": Double(gaps.filter { $0 > 16.7 }.count) / Double(gaps.count) * 100
                ], iteration: iteration)
            }
            // Actual cached session selection on the SAME mounted ChatView.
            let otherMessages = perfMessages(1000..<2000, salt: salt + "other")
            await host.setSnapshot(.init(session: .init(id: "session-two", path: "/tmp/session-two.jsonl",
                cwd: "/tmp/project", title: "Other session"), messages: otherMessages, state: .idle,
                sequence: 0, turnId: nil, model: nil, thinkingLevel: .high,
                availableThinkingLevels: [.high], accessMode: .none, pendingApprovals: []))
            try await store.openSession(makeSummary(id: "session-two"), profile: .work, sessionDirectory: nil, selectSession: false)
            for (id, first) in [("session-two", 2000 - batch), ("session-one", 1002 - batch)] {
                start = perfNow(); cpu = perfCPU()
                try store.selectOpenSession(sessionId: id, profile: .work, cwd: "/tmp/project")
                try await perfWait(live, rows: batch, first: "row-\(first)")
                perfLog(id == "session-two" ? "switch_cached_other" : "switch_cached_back",
                    ["wall_ms": perfNow() - start, "cpu_ms": perfCPU() - cpu], iteration: iteration)
            }
            // Failed response retains content and shows a recoverable notice.
            start = perfNow(); cpu = perfCPU()
            await host.emit(.sessionStateChanged(.init(sessionId: "session-one", sequence: 205, turnId: "failure-turn", state: .running)))
            await host.emit(.sessionError(.init(sessionId: "session-one", sequence: 206, turnId: "failure-turn",
                code: "benchmark_error", message: "Deterministic benchmark failure")))
            let failureDeadline = perfNow() + 5000
            while store.records["session-one"]?.runState != .failed, perfNow() < failureDeadline {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(store.records["session-one"]?.runState, .failed)
            try await perfWait(live, rows: batch)
            perfLog("response_failed", ["wall_ms": perfNow() - start, "cpu_ms": perfCPU() - cpu], iteration: iteration)
            live.close()
            await store.stop()

            // Remote pages: same deterministic host, no disk/network/provider latency.
            let remoteHost = FakeAgentHost()
            await remoteHost.setSnapshot(makeStoreSnapshot(messages: perfMessages((1000 - batch)..<1000, salt: salt + "remote"),
                history: .init(revision: "perf", nextCursor: "page", hasMore: true)))
            let remoteStore = SessionStore(service: remoteHost)
            try await remoteStore.openSession(makeSummary(), profile: .work, sessionDirectory: nil)
            let remote = perfSurface(remoteStore)
            try await perfWait(remote, rows: batch)
            for step in 1...2 {
                await remoteHost.setTranscriptPage(.init(sessionId: "session-one",
                    messages: perfMessages((1000 - (step + 1) * batch)..<(1000 - step * batch), salt: salt + "remote"),
                    revision: "perf", nextCursor: step == 2 ? nil : "page2", hasMore: step != 2))
                start = perfNow(); cpu = perfCPU()
                try perfTop(remote)
                try await perfWait(remote, rows: (step + 1) * batch, first: "row-\(1000 - (step + 1) * batch)")
                perfLog("history_remote_\(step)", ["wall_ms": perfNow() - start, "cpu_ms": perfCPU() - cpu], iteration: iteration)
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            let pages = await remoteHost.transcriptPageCount
            XCTAssertEqual(pages, 2)
            XCTAssertEqual(remoteStore.records["session-one"]?.hasEarlierMessages, false)
            remote.close()
            await remoteStore.stop()

            // Controls: empty and short sessions must not pay a 40/100-row layout cost.
            for count in [0, 10] {
                let controlHost = FakeAgentHost()
                await controlHost.setSnapshot(makeStoreSnapshot(messages: perfMessages(0..<count, salt: salt)))
                let controlStore = SessionStore(service: controlHost)
                start = perfNow(); cpu = perfCPU()
                try await controlStore.openSession(makeSummary(), profile: .work, sessionDirectory: nil)
                let control = perfSurface(controlStore)
                if count > 0 { try await perfWait(control, rows: count) }
                else { try await Task.sleep(nanoseconds: 100_000_000); XCTAssertTrue(control.frames.isEmpty) }
                perfLog("open_\(count)", ["wall_ms": perfNow() - start, "cpu_ms": perfCPU() - cpu], iteration: iteration)
                control.close()
                await controlStore.stop()
            }
        }
    }
}
