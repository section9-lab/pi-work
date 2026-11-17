import Foundation
import OSLog

enum SessionOpenPerformanceStage: String, Equatable {
    case requested
    case draftRequested = "draft_requested"
    case hostReady = "host_ready"
    case cacheHit = "cache_hit"
    case openRPCCompleted = "open_rpc_completed"
    case previewCompleted = "preview_completed"
    case draftRPCCompleted = "draft_rpc_completed"
    case snapshotCompleted = "snapshot_completed"
    case projectionCompleted = "projection_completed"
    case storePublished = "store_published"
    case cacheTrimCompleted = "cache_trim_completed"
    case selectionCommitted = "selection_committed"
    case presentationStarted = "presentation_started"
    case presentationReady = "presentation_ready"
    case firstFrame = "first_frame"
    case draftCompleted = "draft_completed"
    case cancelled
    case failed
}

struct SessionOpenPerformanceEvent: Equatable {
    let traceID: UUID
    let sessionID: String
    let profile: AgentHostSessionProfile
    let stage: SessionOpenPerformanceStage
    let elapsedMilliseconds: Double
    let stageMilliseconds: Double
    let messageCount: Int?
    let transcriptCount: Int?
    let hasEarlierMessages: Bool?
}

@MainActor
final class SessionOpenPerformanceTracer {
    private struct Trace {
        let id: UUID
        let sessionID: String
        let profile: AgentHostSessionProfile
        let startedAt: UInt64
        var lastEventAt: UInt64
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.vibevibe.pi-work",
        category: "SessionOpen"
    )

    private let nowNanoseconds: () -> UInt64
    private let sink: (SessionOpenPerformanceEvent) -> Void
    private var tracesByID: [UUID: Trace] = [:]
    private var traceIDBySessionID: [String: UUID] = [:]

    init(
        nowNanoseconds: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sink: ((SessionOpenPerformanceEvent) -> Void)? = nil
    ) {
        self.nowNanoseconds = nowNanoseconds
        self.sink = sink ?? Self.log
    }

    @discardableResult
    func begin(sessionID: String, profile: AgentHostSessionProfile) -> UUID {
        begin(sessionID: sessionID, profile: profile, initialStage: .requested)
    }

    /// A draft has no host session id until `session.createDraft` returns, so
    /// keep the trace under a synthetic id and finish it explicitly.
    @discardableResult
    func beginDraft(profile: AgentHostSessionProfile) -> UUID {
        begin(
            sessionID: "draft-\(UUID().uuidString)",
            profile: profile,
            initialStage: .draftRequested
        )
    }

    private func begin(
        sessionID: String,
        profile: AgentHostSessionProfile,
        initialStage: SessionOpenPerformanceStage
    ) -> UUID {
        if let existingTraceID = traceIDBySessionID[sessionID] {
            end(traceID: existingTraceID, stage: .cancelled)
        }
        let now = nowNanoseconds()
        let trace = Trace(
            id: UUID(),
            sessionID: sessionID,
            profile: profile,
            startedAt: now,
            lastEventAt: now
        )
        tracesByID[trace.id] = trace
        traceIDBySessionID[sessionID] = trace.id
        emit(trace: trace, stage: initialStage, now: now)
        return trace.id
    }

    func mark(
        traceID: UUID,
        stage: SessionOpenPerformanceStage,
        messageCount: Int? = nil,
        transcriptCount: Int? = nil,
        hasEarlierMessages: Bool? = nil
    ) {
        guard var trace = tracesByID[traceID] else { return }
        let now = nowNanoseconds()
        emit(
            trace: trace,
            stage: stage,
            now: now,
            messageCount: messageCount,
            transcriptCount: transcriptCount,
            hasEarlierMessages: hasEarlierMessages
        )
        trace.lastEventAt = now
        tracesByID[traceID] = trace
    }

    func markActive(
        sessionID: String,
        stage: SessionOpenPerformanceStage,
        transcriptCount: Int? = nil
    ) {
        guard let traceID = traceIDBySessionID[sessionID] else { return }
        mark(traceID: traceID, stage: stage, transcriptCount: transcriptCount)
    }

    func finishActive(sessionID: String, transcriptCount: Int? = nil) {
        guard let traceID = traceIDBySessionID[sessionID] else { return }
        end(traceID: traceID, stage: .firstFrame, transcriptCount: transcriptCount)
    }

    func finishDraft(traceID: UUID, transcriptCount: Int? = nil) {
        end(traceID: traceID, stage: .draftCompleted, transcriptCount: transcriptCount)
    }

    func cancel(traceID: UUID) {
        end(traceID: traceID, stage: .cancelled)
    }

    func fail(traceID: UUID) {
        end(traceID: traceID, stage: .failed)
    }

    private func end(
        traceID: UUID,
        stage: SessionOpenPerformanceStage,
        transcriptCount: Int? = nil
    ) {
        guard let trace = tracesByID.removeValue(forKey: traceID) else { return }
        if traceIDBySessionID[trace.sessionID] == traceID {
            traceIDBySessionID.removeValue(forKey: trace.sessionID)
        }
        emit(
            trace: trace,
            stage: stage,
            now: nowNanoseconds(),
            transcriptCount: transcriptCount
        )
    }

    private func emit(
        trace: Trace,
        stage: SessionOpenPerformanceStage,
        now: UInt64,
        messageCount: Int? = nil,
        transcriptCount: Int? = nil,
        hasEarlierMessages: Bool? = nil
    ) {
        sink(SessionOpenPerformanceEvent(
            traceID: trace.id,
            sessionID: trace.sessionID,
            profile: trace.profile,
            stage: stage,
            elapsedMilliseconds: Self.milliseconds(from: trace.startedAt, to: now),
            stageMilliseconds: Self.milliseconds(from: trace.lastEventAt, to: now),
            messageCount: messageCount,
            transcriptCount: transcriptCount,
            hasEarlierMessages: hasEarlierMessages
        ))
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end >= start ? end - start : 0) / 1_000_000
    }

    private static func log(_ event: SessionOpenPerformanceEvent) {
        let messages = event.messageCount.map(String.init) ?? "-"
        let transcript = event.transcriptCount.map(String.init) ?? "-"
        let hasEarlier = event.hasEarlierMessages.map(String.init) ?? "-"
        logger.notice(
            "session_open trace=\(event.traceID.uuidString, privacy: .public) session=\(event.sessionID, privacy: .public) profile=\(String(describing: event.profile), privacy: .public) stage=\(event.stage.rawValue, privacy: .public) total_ms=\(event.elapsedMilliseconds, format: .fixed(precision: 3)) stage_ms=\(event.stageMilliseconds, format: .fixed(precision: 3)) messages=\(messages, privacy: .public) transcript=\(transcript, privacy: .public) has_earlier=\(hasEarlier, privacy: .public)"
        )
    }
}
