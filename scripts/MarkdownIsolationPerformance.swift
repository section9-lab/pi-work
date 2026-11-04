// Appended ONLY to the staged SessionStoreTests.swift; uses its private Host fixture.
import Darwin

extension SessionStoreTests {
    @MainActor
    private struct IsolationSurface {
        let window: NSWindow
        let controller: NSHostingController<AnyView>
        var observer: TranscriptUserScrollObserverView? {
            @MainActor func find(_ view: NSView) -> TranscriptUserScrollObserverView? {
                if let value = view as? TranscriptUserScrollObserverView { return value }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            return find(controller.view)
        }
        var frames: [String: CGRect] { observer?.viewport?.frames ?? [:] }
        var first: Int? { frames.keys.compactMap { Int($0.replacingOccurrences(of: "row-", with: "")) }.min() }
        func close() {
            controller.rootView = AnyView(EmptyView())
            controller.view.layoutSubtreeIfNeeded()
            window.contentViewController = nil
            window.close()
        }
    }
    private func isoNow() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
    private func isoCPU() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
    }
    private func isoText(_ template: String, index: Int, salt: String) -> String {
        template.replacingOccurrences(of: "{{TITLE}}", with: "Render review \(index)")
            .replacingOccurrences(of: "{{INDEX}}", with: String(index))
            .replacingOccurrences(of: "{{SALT}}", with: salt)
    }
    private func isoMessages(_ range: Range<Int>, template: String, salt: String) -> [AgentHostSessionMessage] {
        let dense = ProcessInfo.processInfo.environment["PERF_DENSITY"] == "dense"
        return range.map { index in
            let compact = """
            ## Rendering checkpoint \(index) · \(salt)

            **复用消息身份**，保留 `revision` 与稳定的历史阅读锚点。[说明](#checkpoint)

            - 文本变化更新当前回复
              - 结构变化才重建窗口

            ```swift
            let visible = ids.suffix(100)
            restoreAnchor("row-\(index)")
            ```

            | 事件 | 目标 |
            | --- | --- |
            | text | reply |
            | insert | window |

            > 中文与 English 混排，静态消息仍保持可选择、可复制。
            """
            return AgentHostSessionMessage(id: "row-\(index)", role: index % 5 == 0 ? .user : .assistant,
                content: [.text(index % 5 == 0 ? "复杂文档渲染检查 \(index) · \(salt)" : (dense || index % 10 == 1 ? isoText(template, index: index, salt: salt) : compact))],
                timestamp: "2026-08-09T00:00:00.000Z", provider: nil, model: nil, stopReason: nil,
                errorMessage: nil, toolCallId: nil, toolName: nil, isError: nil)
        }
    }
    private func isoSurface(_ store: SessionStore) -> IsolationSurface {
        let controller = NSHostingController(rootView: AnyView(ChatView(mode: .work, projects: [],
            selectedProject: .constant(PiProject(name: "Project", path: "/tmp/project")),
            sessionStore: store, composerDrafts: SessionComposerDraftStore(), onAddFolder: {})))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 840, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.orderFront(nil); controller.view.layoutSubtreeIfNeeded()
        return IsolationSurface(window: window, controller: controller)
    }
    private func isoWait(_ surface: IsolationSurface, rows: Int, first: Int? = nil) async throws {
        var stable = 0, previous: CGFloat = -1
        let deadline = isoNow() + 120_000
        while isoNow() < deadline {
            surface.controller.view.layoutSubtreeIfNeeded()
            let height = surface.observer?.enclosingScrollView?.documentView?.bounds.height ?? 0
            if surface.frames.count == rows, first == nil || surface.first == first, abs(height - previous) < 0.5 {
                stable += 1; if stable >= 3 { return }
            } else { stable = 0 }
            previous = height
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Layout timeout: expected \(rows) rows / \(first.map(String.init) ?? "any"), got \(surface.frames.count) / \(surface.first.map(String.init) ?? "none")")
        throw NSError(domain: "IsolationBenchmark", code: 1)
    }
    private func isoTop(_ surface: IsolationSurface) throws {
        let observer = try XCTUnwrap(surface.observer), scroll = try XCTUnwrap(observer.enclosingScrollView)
        // Use the transcript gutter: (100,100) may hit a Markdown code block's
        // horizontal NSScrollView, which correctly rejects a history wheel event.
        let point = scroll.convert(CGPoint(x: 5, y: 5), to: nil)
        let original = observer.onUserScroll
        var accepted = false
        observer.onUserScroll = { accepted = true; original() }
        observer.handleScrollWheel(TestPhaseLessScrollWheelEvent(window: surface.window, point: point))
        observer.onUserScroll = original
        guard accepted else {
            XCTFail("Synthetic wheel was intercepted before reaching the transcript")
            throw NSError(domain: "IsolationBenchmarkInput", code: 1)
        }
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    private func isoKeepTailVisible(_ surface: IsolationSurface) {
        guard let scroll = surface.observer?.enclosingScrollView, let document = scroll.documentView else { return }
        let y = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height) : document.bounds.minY
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    private func isoAnchor(_ surface: IsolationSurface, id: String) async throws -> Double {
        let deadline = isoNow() + 10_000
        while abs(surface.frames[id]?.minY ?? 9999) > 2, isoNow() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let drift = Double(abs(surface.frames[id]?.minY ?? 9999))
        XCTAssertLessThanOrEqual(drift, 2, "History anchor must survive window movement")
        return drift
    }
    private func isoLog(_ scenario: String, start: Double, cpu: Double, iteration: Int, extra: [String: Double] = [:]) {
        var row: [String: Any] = MarkdownIsolationProbe.counters
        row.merge(extra.mapValues { $0 as Any }, uniquingKeysWith: { _, new in new })
        row["scenario"] = scenario; row["variant"] = MarkdownIsolationConfiguration.variant
        row["run"] = ProcessInfo.processInfo.environment["PERF_RUN"] ?? "manual"; row["iteration"] = iteration
        row["wall_ms"] = isoNow() - start; row["cpu_ms"] = isoCPU() - cpu
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        row["process_peak_rss_mb"] = Double(usage.ru_maxrss) / (1024 * 1024) // Darwin: bytes; cumulative, not scenario-local
        row["batch"] = TranscriptWindow.batchSize
        row["density"] = ProcessInfo.processInfo.environment["PERF_DENSITY"] ?? "mixed"
        print("ISOLATION_PERF " + String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
    }

    func testMarkdownIsolationEventBoundaries() async throws {
        let host = FakeAgentHost()
        let controlled = SessionStore(service: host)
        try await controlled.openSession(makeSummary(), profile: .work, sessionDirectory: nil)
        var contentOnly: [Int: Bool] = [:]
        let subscription = controlled.recordUpdates.sink { ids in
            guard ids.contains("session-one"), let sequence = controlled.records["session-one"]?.lastSequence else { return }
            contentOnly[sequence] = controlled.markdownContentOnlySessionIDs.contains("session-one")
        }
        @MainActor func send(_ event: AgentHostServerEvent, sequence: Int) async throws {
            await host.emit(event)
            let deadline = isoNow() + 5000
            while (controlled.records["session-one"]?.lastSequence ?? -1) < sequence, isoNow() < deadline {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(controlled.records["session-one"]?.lastSequence, sequence)
        }
        try await send(.sessionStateChanged(.init(sessionId: "session-one", sequence: 1, turnId: "boundaries", state: .running)), sequence: 1)
        for sequence in 2...4 {
            try await send(.sessionAssistantContent(.init(sessionId: "session-one", sequence: sequence,
                turnId: "boundaries", generationIndex: 0, phase: .delta, contentType: .text,
                contentIndex: sequence == 4 ? 1 : 0, delta: "part \(sequence)", content: nil, toolCall: nil)), sequence: sequence)
        }
        XCTAssertEqual(contentOnly[1], false)
        XCTAssertEqual(contentOnly[2], false, "First visible message is structural")
        XCTAssertEqual(contentOnly[3], MarkdownIsolationConfiguration.isolateText)
        XCTAssertEqual(contentOnly[4], false, "New content block must invalidate the parent")
        try await send(.sessionStateChanged(.init(sessionId: "session-one", sequence: 5, turnId: "boundaries", state: .idle)), sequence: 5)
        XCTAssertEqual(contentOnly[5], false, "Completion must flush outside the content-only route")
        subscription.cancel(); await controlled.stop()
    }

    func testMarkdownIsolationVisibleRenderer() async throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["PERF_COMPLEX_FIXTURE"])
        let template = try String(contentsOfFile: path, encoding: .utf8)
        let host = FakeAgentHost()
        await host.setSnapshot(makeStoreSnapshot(messages: (0..<3).map { makeSessionMessage(id: "row-\($0)", text: "Short prompt \($0)") }))
        let store = SessionStore(service: host)
        try await store.openSession(makeSummary(), profile: .work, sessionDirectory: nil)
        let surface = isoSurface(store); try await isoWait(surface, rows: 3)
        let body = "# STREAM-BEGIN:visible\n\n" + isoText(template, index: 1000, salt: "visibility")
            + "\n\n" + isoText(template, index: 1001, salt: "visibility") + "\nSTREAM-FINAL-visible\n"
        let chars = Array(body), width = (chars.count + 149) / 150
        let chunks = stride(from: 0, to: chars.count, by: width).map { String(chars[$0..<min($0 + width, chars.count)]) }
        MarkdownIsolationProbe.reset()
        await host.emit(.sessionStateChanged(.init(sessionId: "session-one", sequence: 1, turnId: "visible", state: .running)))
        let producer = Task.detached {
            for (index, chunk) in chunks.enumerated() {
                await host.emit(.sessionAssistantContent(.init(sessionId: "session-one", sequence: index + 2,
                    turnId: "visible", generationIndex: 0, phase: .delta, contentType: .text,
                    contentIndex: 0, delta: chunk, content: nil, toolCall: nil)))
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            await host.emit(.sessionStateChanged(.init(sessionId: "session-one", sequence: chunks.count + 2, turnId: "visible", state: .idle)))
        }
        let deadline = isoNow() + 30_000
        while isoNow() < deadline {
            surface.controller.view.layoutSubtreeIfNeeded(); isoKeepTailVisible(surface)
            if store.records["session-one"]?.lastSequence == chunks.count + 2,
               MarkdownIsolationProbe.hasRendered(body) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await producer.value
        print("RENDERER_DIAGNOSTICS \(MarkdownIsolationProbe.rendererDiagnostics) store_sequence=\(store.records["session-one"]?.lastSequence ?? -1) expected=\(chunks.count + 2) expected_bytes=\(body.utf8.count)")
        XCTAssertTrue(MarkdownIsolationProbe.hasRendered(body), "Mounted Markdown presentation must contain the final text")
        XCTAssertGreaterThan(MarkdownIsolationProbe.markdownPublishes, 1)
        surface.close(); await store.stop()
    }

    func testMarkdownIsolationNavigationBoundaries() {
        var navigation = TranscriptWindowNavigation()
        var ids = (0..<1000).map(String.init)
        XCTAssertEqual(navigation.range(in: ids), 900..<1000)
        navigation.revealEarlier(in: ids)
        let first = navigation.range(in: ids)
        XCTAssertEqual(first, MarkdownIsolationConfiguration.fixedWindow ? 840..<940 : 800..<1000)
        XCTAssertTrue(first.contains(900), "Keep the old top anchor in the overlap")
        let pinned = Array(ids[first]); ids.append("1000")
        XCTAssertEqual(Array(ids[navigation.range(in: ids)]), pinned)
        for _ in 0..<40 { navigation.revealEarlier(in: ids) }
        XCTAssertEqual(navigation.range(in: ids).lowerBound, 0)
        XCTAssertLessThanOrEqual(navigation.range(in: ids).count, MarkdownIsolationConfiguration.fixedWindow ? 100 : 300)
        for _ in 0..<40 { navigation.revealNewer(in: ids) }
        XCTAssertEqual(navigation.range(in: ids).upperBound, ids.count)
        navigation.jump(to: "150", in: ids)
        XCTAssertTrue(navigation.range(in: ids).contains(150))
        navigation.revealLatest()
        XCTAssertEqual(navigation.range(in: ids).count, 100)
        navigation.revealEarlier(in: [])
        XCTAssertEqual(navigation.range(in: []).count, 0)
    }

    // Diagnostic only: identical input, with optional mounted UI and explicit layout.
    func testMarkdownIsolationLiveDiagnosis() async throws {
        let env = ProcessInfo.processInfo.environment
        let mode = env["PERF_DIAG_MODE"] ?? "mounted"
        let count = Int(env["PERF_DIAG_ROWS"] ?? "1000") ?? 1000
        let path = try XCTUnwrap(env["PERF_COMPLEX_FIXTURE"])
        let template = try String(contentsOfFile: path, encoding: .utf8)
        let host = FakeAgentHost()
        let messages = env["PERF_DIAG_HISTORY_PLAIN"] == "1"
            ? (0..<count).map { makeSessionMessage(id: "row-\($0)", text: "Short prompt \($0)") }
            : isoMessages(0..<count, template: template, salt: "diagnostic")
        await host.setSnapshot(makeStoreSnapshot(messages: messages))
        let store = SessionStore(service: host)
        try await store.openSession(makeSummary(), profile: .work, sessionDirectory: nil)
        let surface: IsolationSurface? = mode == "unmounted" ? nil : isoSurface(store)
        if let surface { try await isoWait(surface, rows: min(count, 100), first: max(0, count - 100)) }
        let body = env["PERF_DIAG_BODY_PLAIN"] == "1"
            ? String(repeating: "Simple plain text for streaming. ", count: 280)
            : "# STREAM-BEGIN:live\n\n" + isoText(template, index: 1000, salt: "diagnostic")
                + "\n\n" + isoText(template, index: 1001, salt: "diagnostic") + "\n\nSTREAM-FINAL-live\n"
        let chars = Array(body), width = (chars.count + 149) / 150
        let chunks = stride(from: 0, to: chars.count, by: width).map { String(chars[$0..<min($0 + width, chars.count)]) }
        MarkdownIsolationProbe.reset()
        await host.emit(.sessionStateChanged(.init(sessionId: "session-one", sequence: 1, turnId: "live", state: .running)))
        try await Task.sleep(nanoseconds: 50_000_000)
        let start = isoNow(), cpu = isoCPU()
        print("LIVE_DIAG_START mode=\(mode) rows=\(count)")
        let producer = Task.detached {
            for (index, chunk) in chunks.enumerated() {
                await host.emit(.sessionAssistantContent(.init(sessionId: "session-one", sequence: index + 2,
                    turnId: "live", generationIndex: 0, phase: .delta, contentType: .text,
                    contentIndex: 0, delta: chunk, content: nil, toolCall: nil)))
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            await host.emit(.sessionStateChanged(.init(sessionId: "session-one", sequence: chunks.count + 2, turnId: "live", state: .idle)))
            return Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
        }
        let deadline = start + (Double(env["PERF_DIAG_TIMEOUT_MS"] ?? "60000") ?? 60_000)
        var storeMS: Double?, renderMS: Double?, gaps: [Double] = [], previous = start
        while true {
            let now = isoNow()
            gaps.append(now - previous); previous = now
            if storeMS == nil && store.records["session-one"]?.lastSequence == chunks.count + 2 &&
                store.records["session-one"]?.runState == .idle { storeMS = now - start }
            if renderMS == nil && MarkdownIsolationProbe.hasRendered(body) { renderMS = now - start }
            if storeMS != nil && (surface == nil || renderMS != nil) || now >= deadline { break }
            if let surface {
                if mode == "forced" || mode == "layout" { surface.controller.view.layoutSubtreeIfNeeded() }
                if mode == "forced" || mode == "scroll" { isoKeepTailVisible(surface) }
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let inputMS = try await producer.value - start
        gaps.sort()
        let record = try XCTUnwrap(store.records["session-one"])
        print("LIVE_DIAG_RESULT mode=\(mode) rows=\(count) input_ms=\(inputMS) store_ms=\(storeMS ?? -1) render_ms=\(renderMS ?? -1) wall_ms=\(isoNow() - start) cpu_ms=\(isoCPU() - cpu) seq=\(record.lastSequence)/\(chunks.count + 2) gap_p95_ms=\(gaps[Int(Double(gaps.count - 1) * 0.95)]) gap_max_ms=\(gaps.last ?? 0)")
        XCTAssertEqual(record.lastSequence, chunks.count + 2)
        XCTAssertEqual(PiChatMessage(message: try XCTUnwrap(record.transcript.last)).text, body)
        if surface != nil { XCTAssertNotNil(renderMS) }
        surface?.close(); await store.stop()
    }

    func testMarkdownIsolationBenchmark() async throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["PERF_COMPLEX_FIXTURE"])
        let template = try String(contentsOfFile: path, encoding: .utf8)
        let iterations = Int(ProcessInfo.processInfo.environment["PERF_ITERATIONS"] ?? "2")!
        let fixed = MarkdownIsolationConfiguration.fixedWindow
        let coldOnly = ProcessInfo.processInfo.environment["PERF_SCOPE"] == "cold-only"
        XCTAssertEqual(TranscriptWindow.batchSize, 100)
        for iteration in 0..<iterations {
            // Exactly the same bytes in both variants; process-local cache starts empty.
            let salt = "complex-case-\(iteration)"
            let messages = isoMessages(0..<1000, template: template, salt: salt)
            let host = FakeAgentHost(); await host.setSnapshot(makeStoreSnapshot(messages: messages))
            var events: [SessionOpenPerformanceEvent] = []
            let tracer = SessionOpenPerformanceTracer(sink: { events.append($0) })
            let store = SessionStore(service: host, performanceTracer: tracer)
            let trace = store.beginSessionOpenPerformanceTrace(sessionID: "session-one", profile: .work)
            MarkdownIsolationProbe.reset()
            var start = isoNow(), cpu = isoCPU()
            try await store.openSession(makeSummary(), profile: .work, sessionDirectory: nil, performanceTraceID: trace)
            let initial = isoSurface(store)
            try await isoWait(initial, rows: 100, first: 900)
            isoLog("open_cold_1000", start: start, cpu: cpu, iteration: iteration, extra: [
                "rows": Double(initial.frames.count), "first_frame_ms": try XCTUnwrap(events.first { $0.stage == .firstFrame }).elapsedMilliseconds,
                "fixture_bytes": Double(template.utf8.count),
                "complex_replies_in_window": ProcessInfo.processInfo.environment["PERF_DENSITY"] == "dense" ? 80 : 10])
            if coldOnly { initial.close(); await store.stop(); continue }

            // Compare BOTH per-action latency and equal historical coverage (300 source rows).
            MarkdownIsolationProbe.reset(); start = isoNow(); cpu = isoCPU()
            let historyStart = start, historyCPU = cpu
            var actions = 0
            while (initial.first ?? 0) > 600 {
                let before = try XCTUnwrap(initial.first)
                let actionStart = isoNow(), actionCPU = isoCPU()
                try isoTop(initial); actions += 1
                let nextFirst = before - (fixed ? 60 : 100)
                let rows = fixed ? 100 : min(100 * (actions + 1), 300)
                try await isoWait(initial, rows: rows, first: nextFirst)
                let drift = try await isoAnchor(initial, id: "row-\(before)")
                if actions <= 3 {
                    isoLog("history_action_\(actions)", start: actionStart, cpu: actionCPU, iteration: iteration,
                        extra: ["rows": Double(rows), "anchor_error_pt": drift])
                }
                XCTAssertLessThanOrEqual(actions, 5)
                try await Task.sleep(nanoseconds: 80_000_000)
            }
            isoLog("history_coverage_300", start: historyStart, cpu: historyCPU, iteration: iteration,
                extra: ["actions": Double(actions), "rows": Double(initial.frames.count), "first": Double(initial.first ?? -1)])
            initial.close(); try await Task.sleep(nanoseconds: 80_000_000)

            MarkdownIsolationProbe.reset(); start = isoNow(); cpu = isoCPU()
            try await store.openSession(makeSummary(), profile: .work, sessionDirectory: nil)
            var live = isoSurface(store)
            try await isoWait(live, rows: 100, first: 900)
            isoLog("open_cached_1000", start: start, cpu: cpu, iteration: iteration)
            let opens = await host.openCount; XCTAssertEqual(opens, 1)
            var sequence = 0
            var expectedFinal = ""
            for readingHistory in [false, true] {
                if readingHistory {
                    try isoTop(live)
                    try await isoWait(live, rows: fixed ? 100 : 200, first: fixed ? 841 : 801)
                    _ = try await isoAnchor(live, id: "row-901")
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                let anchor = live.frames.filter { $0.value.maxY > 0 && $0.value.minY < 300 }
                    .min { $0.value.minY < $1.value.minY }
                let turn = readingHistory ? "history" : "live"
                let body = "# STREAM-BEGIN:\(turn)\n\n" + isoText(template, index: 1000, salt: salt + turn)
                    + "\n\n" + isoText(template, index: 1001, salt: salt + turn)
                    + "\n\nSTREAM-FINAL-\(turn)\n"
                expectedFinal = body
                // Split across headings, tables, nested lists and unclosed fences, not just paragraphs.
                let chars = Array(body), width = (chars.count + 149) / 150
                let chunks = stride(from: 0, to: chars.count, by: width).map { String(chars[$0..<min($0 + width, chars.count)]) }
                let base = sequence
                await host.emit(.sessionStateChanged(.init(sessionId: "session-one", sequence: base + 1, turnId: turn, state: .running)))
                try await Task.sleep(nanoseconds: 50_000_000)
                MarkdownIsolationProbe.reset(); start = isoNow(); cpu = isoCPU()
                let producer = Task.detached {
                    for (index, chunk) in chunks.enumerated() {
                        await host.emit(.sessionAssistantContent(.init(sessionId: "session-one", sequence: base + index + 2,
                            turnId: turn, generationIndex: 0, phase: .delta, contentType: .text, contentIndex: 0,
                            delta: chunk, content: nil, toolCall: nil)))
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                    return Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
                }
                var gaps: [Double] = [], previous = isoNow()
                let sampleMS = Double(chunks.count) * 20 + 200
                while isoNow() - start < sampleMS {
                    try await Task.sleep(nanoseconds: 5_000_000)
                    live.controller.view.layoutSubtreeIfNeeded()
                    if !readingHistory { isoKeepTailVisible(live) }
                    let now = isoNow(); gaps.append(now - previous); previous = now
                }
                let inputFinishedAt = try await producer.value
                sequence = base + chunks.count + 2
                await host.emit(.sessionStateChanged(.init(sessionId: "session-one", sequence: sequence, turnId: turn, state: .idle)))
                let completionDeadline = isoNow() + 10_000
                while isoNow() < completionDeadline {
                    let completed = store.records["session-one"]?.lastSequence == sequence
                        && store.records["session-one"]?.runState == .idle
                    if completed && (readingHistory || MarkdownIsolationProbe.hasRendered(body)) { break }
                    if !readingHistory { isoKeepTailVisible(live) }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                live.controller.view.layoutSubtreeIfNeeded()
                gaps.sort()
                isoLog(readingHistory ? "stream_history" : "stream_live", start: start, cpu: cpu, iteration: iteration, extra: [
                    "rows": Double(live.frames.count), "deltas": Double(chunks.count), "stream_bytes": Double(body.utf8.count),
                    "input_ms": inputFinishedAt - start, "completion_lag_ms": max(0, isoNow() - inputFinishedAt),
                    "final_render_valid": readingHistory || MarkdownIsolationProbe.hasRendered(body) ? 1 : 0,
                    "gap_p95_ms": gaps[Int(Double(gaps.count - 1) * 0.95)], "gap_max_ms": gaps.last!,
                    "gaps_over_16_7_pct": Double(gaps.filter { $0 > 16.7 }.count) / Double(gaps.count) * 100])
                let record = try XCTUnwrap(store.records["session-one"])
                XCTAssertEqual(record.lastSequence, sequence)
                XCTAssertEqual(record.runState, .idle)
                XCTAssertEqual(record.transcript.count, readingHistory ? 1002 : 1001)
                XCTAssertEqual(PiChatMessage(message: try XCTUnwrap(record.transcript.last)).text, body)
                let snapshots = await host.snapshotCount; XCTAssertEqual(snapshots, 1)
                if !readingHistory {
                    let rendered = MarkdownIsolationProbe.hasRendered(body)
                    if MarkdownIsolationConfiguration.isolateText {
                        XCTAssertTrue(rendered, "Candidate must render the final text: \(MarkdownIsolationProbe.rendererDiagnostics)")
                    } else if !rendered {
                        print("RENDERING_VALIDATION_FAILED baseline stream_live: \(MarkdownIsolationProbe.rendererDiagnostics); timing sample is INVALID and must not be used for a speedup ratio")
                    }
                    XCTAssertGreaterThan(MarkdownIsolationProbe.markdownPublishes, 1, "Must display intermediate revisions")
                } else if let anchor {
                    XCTAssertEqual(live.frames[anchor.key]?.minY ?? 9999, anchor.value.minY, accuracy: 2)
                    XCTAssertFalse(live.frames.keys.contains { $0.contains("history") && $0.hasPrefix("turn:") })
                }
                if MarkdownIsolationConfiguration.isolateText {
                    XCTAssertGreaterThan(MarkdownIsolationProbe.skippedParentEvents, 0)
                    if !readingHistory { XCTAssertGreaterThan(MarkdownIsolationProbe.localDeliveries, 0) }
                    else { XCTAssertEqual(MarkdownIsolationProbe.localDeliveries, 0) }
                }
                // Optional post-failure observation, without hiding the deadline failure
                // or switching away from the live reply. Not an acceptance sample.
                let observationMS = Double(ProcessInfo.processInfo.environment["PERF_LIVE_OBSERVE_MS"] ?? "0") ?? 0
                if !readingHistory && observationMS > 0 &&
                    (record.lastSequence != sequence || record.runState != .idle || !MarkdownIsolationProbe.hasRendered(body)) {
                    let observationStart = isoNow(), deadline = isoNow() + observationMS
                    var storeCompleteMS: Double?, renderedMS: Double?
                    while true {
                        let now = isoNow()
                        if storeCompleteMS == nil && store.records["session-one"]?.lastSequence == sequence &&
                            store.records["session-one"]?.runState == .idle { storeCompleteMS = now - observationStart }
                        if renderedMS == nil && MarkdownIsolationProbe.hasRendered(body) { renderedMS = now - observationStart }
                        if (storeCompleteMS != nil && renderedMS != nil) || now >= deadline { break }
                        isoKeepTailVisible(live)
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    let observed = store.records["session-one"]
                    print("LIVE_OBSERVATION elapsed_ms=\(isoNow() - observationStart) sequence=\(observed?.lastSequence ?? -1)/\(sequence) idle=\(observed?.runState == .idle) rendered=\(MarkdownIsolationProbe.hasRendered(body)) store_complete_ms=\(storeCompleteMS ?? -1) rendered_ms=\(renderedMS ?? -1)")
                }
            }
            live.close(); try await Task.sleep(nanoseconds: 80_000_000)
            // Reappearance must render the entire response accumulated off-window.
            MarkdownIsolationProbe.reset(); start = isoNow(); cpu = isoCPU()
            live = isoSurface(store)
            try await isoWait(live, rows: 100, first: 902)
            XCTAssertTrue(MarkdownIsolationProbe.hasRendered(expectedFinal))
            isoLog("resume_latest", start: start, cpu: cpu, iteration: iteration)
            MarkdownIsolationProbe.reset(); start = isoNow(); cpu = isoCPU()
            await host.emit(.sessionStateChanged(.init(sessionId: "session-one", sequence: sequence + 1, turnId: "failed", state: .running)))
            await host.emit(.sessionError(.init(sessionId: "session-one", sequence: sequence + 2, turnId: "failed", code: "benchmark", message: "Recoverable benchmark error")))
            let deadline = isoNow() + 5000
            while store.records["session-one"]?.runState != .failed, isoNow() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(store.records["session-one"]?.runState, .failed)
            try await isoWait(live, rows: 100)
            isoLog("response_failed", start: start, cpu: cpu, iteration: iteration)
            live.close(); await store.stop()

            // Same remote history coverage: both fetch exactly 2 x 100 rows. The
            // fixed-window policy requires additional cached-window navigation.
            let remoteHost = FakeAgentHost()
            await remoteHost.setSnapshot(makeStoreSnapshot(messages: isoMessages(900..<1000, template: template, salt: salt + "remote"),
                history: .init(revision: "complex", nextCursor: "page", hasMore: true)))
            let remoteStore = SessionStore(service: remoteHost)
            try await remoteStore.openSession(makeSummary(), profile: .work, sessionDirectory: nil)
            let remote = isoSurface(remoteStore); try await isoWait(remote, rows: 100, first: 900)
            MarkdownIsolationProbe.reset(); start = isoNow(); cpu = isoCPU(); var moves = 0
            while (remote.first ?? 0) > 700 {
                let requests = await remoteHost.transcriptPageCount
                let lower = requests == 0 ? 800 : 700
                await remoteHost.setTranscriptPage(.init(sessionId: "session-one",
                    messages: isoMessages(lower..<(lower + 100), template: template, salt: salt + "remote"),
                    revision: "complex", nextCursor: requests == 0 ? "page2" : nil, hasMore: requests == 0))
                let before = try XCTUnwrap(remote.first)
                try isoTop(remote); moves += 1
                let cachedLower = remoteStore.records["session-one"]?.transcript.first.flatMap { Int($0.id.dropFirst(4)) } ?? before
                let sourceLower = cachedLower < before ? cachedLower : lower
                // The cached overlap may be consumed before the next Host RPC.
                let shift = fixed ? min(60, before - sourceLower) : 100
                try await isoWait(remote, rows: fixed ? 100 : min((moves + 1) * 100, 300), first: before - shift)
                _ = try await isoAnchor(remote, id: "row-\(before)")
                XCTAssertLessThanOrEqual(moves, 4)
                try await Task.sleep(nanoseconds: 80_000_000)
            }
            isoLog("remote_coverage_200", start: start, cpu: cpu, iteration: iteration, extra: ["actions": Double(moves), "rows": Double(remote.frames.count)])
            let requests = await remoteHost.transcriptPageCount; XCTAssertEqual(requests, 2)
            XCTAssertEqual(remoteStore.records["session-one"]?.transcript.count, 300)
            XCTAssertEqual(remoteStore.records["session-one"]?.hasEarlierMessages, false)
            remote.close(); await remoteStore.stop()
        }
    }
}
