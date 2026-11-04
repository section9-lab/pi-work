#!/usr/bin/env python3
"""Freeze actual production before/after sources; add read-only Release probes.

The baseline directory must contain the pre-change PiWork/ source snapshot.
Unrelated current production files are identical in every build. `before` is the
unmodified transcript implementation. `reference` shares the corrected production
row/parser delivery but retains original projection, parent invalidations and
100..300 navigation, allowing a complete-render performance comparison. No old
experimental candidate or runtime implementation switch is used.
"""
import hashlib
import json
import pathlib
import shutil
import sys

source, baseline, root = (pathlib.Path(x).resolve() for x in sys.argv[1:4])
assert root.is_relative_to(source / 'build') and root != source
changed = [
    'Core/Agent/SessionStore.swift', 'Features/Chat/ChatPresentation.swift',
    'Features/Chat/TranscriptWindowNavigation.swift', 'Features/Chat/Views/ChatView.swift',
    'Features/Chat/Views/AssistantMarkdownView.swift',
]
new = ['Core/Agent/SessionTranscriptUpdates.swift', 'Features/Chat/TranscriptPresentation.swift']
assert all((baseline / 'PiWork' / name).is_file() for name in changed)
fixture = source / 'PiWorkTests/Fixtures/markdown/performance-complex.md'
markdown = (source / 'PiWork/Features/Chat/Views/AssistantMarkdownView.swift').read_text()
diagnostics = '#if DEBUG || TRANSCRIPT_ACCEPTANCE\n/// Read-only acceptance instrumentation.' + markdown.split('#if DEBUG || TRANSCRIPT_ACCEPTANCE\n/// Read-only acceptance instrumentation.', 1)[1]
helper = (source / 'scripts/MarkdownIsolationPerformance.swift').read_text()
a = helper.index('    func testMarkdownIsolationEventBoundaries()')
b = helper.index('    func testMarkdownIsolationVisibleRenderer()')
helper = helper[:a] + helper[b:]
a = helper.index('    func testMarkdownIsolationNavigationBoundaries()')
b = helper.index('    func testMarkdownIsolationLiveDiagnosis()')
helper = helper[:a] + helper[b:]
helper = helper.replace('MarkdownIsolation', 'TranscriptAcceptance')
helper = helper.replace('fixed ? 60 : 100', 'fixed ? 80 : 100').replace('fixed ? 841 : 801', 'fixed ? 821 : 801')
helper = helper.replace('fixed ? min(60, before - sourceLower)', 'fixed ? min(80, before - sourceLower)')
helper = helper.replace('                if TranscriptAcceptanceConfiguration.isolateText {\n                    XCTAssertGreaterThan(TranscriptAcceptanceProbe.skippedParentEvents, 0)\n                    if !readingHistory { XCTAssertGreaterThan(TranscriptAcceptanceProbe.localDeliveries, 0) }\n                    else { XCTAssertEqual(TranscriptAcceptanceProbe.localDeliveries, 0) }\n                }\n', '')
helper = helper.replace('    private struct IsolationSurface {', '    private final class AcceptanceAnchor { var offset: CGFloat = 0 }\n    @MainActor private struct IsolationSurface {\n        let anchor = AcceptanceAnchor()')
helper = helper.replace('        let observer = try XCTUnwrap(surface.observer), scroll = try XCTUnwrap(observer.enclosingScrollView)\n', '        let observer = try XCTUnwrap(surface.observer), scroll = try XCTUnwrap(observer.enclosingScrollView)\n        let before = surface.first\n')
helper = helper.replace('        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)\n    }\n    private func isoKeepTailVisible', '        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)\n        surface.anchor.offset = TranscriptAcceptanceConfiguration.fixedWindow ? before.flatMap { surface.frames["row-\\($0)"]?.minY } ?? 0 : 0\n    }\n    private func isoKeepTailVisible')
helper = helper.replace('abs(surface.frames[id]?.minY ?? 9999)', 'abs((surface.frames[id]?.minY ?? 9999) - surface.anchor.offset)')
helper = helper.replace('"actions": Double(actions), "rows": Double(initial.frames.count)', '"covered_sources": Double(900 - (initial.first ?? 900)), "actions": Double(actions), "rows": Double(initial.frames.count)')
# Both page responses are ready before navigation; this is necessary to test a
# real prefetch, rather than changing a fake response after each foreground move.
a = helper.index('                let requests = await remoteHost.transcriptPageCount\n', helper.index('while (remote.first'))
b = helper.index('                let before = try XCTUnwrap(remote.first)', a)
helper = helper[:a] + '                let lower = await remoteHost.transcriptPageCount == 0 ? 800 : 700\n' + helper[b:]
needle = '            let remoteStore = SessionStore(service: remoteHost)'
helper = helper.replace(needle, '''            await remoteHost.setTranscriptPagesByCursor([
                "page": .init(sessionId: "session-one", messages: isoMessages(800..<900, template: template, salt: salt + "remote"), revision: "complex", nextCursor: "page2", hasMore: true),
                "page2": .init(sessionId: "session-one", messages: isoMessages(700..<800, template: template, salt: salt + "remote"), revision: "complex", nextCursor: nil, hasMore: false)
            ])
''' + needle)
helper = helper.replace('let deadline = isoNow() + 120_000', 'let deadline = isoNow() + (Double(ProcessInfo.processInfo.environment["PERF_LAYOUT_TIMEOUT_MS"] ?? "120000") ?? 120_000)')
helper = helper.replace('ISOLATION_PERF ', 'TRANSCRIPT_ACCEPTANCE_PERF ')

probe = '''import Foundation
@MainActor enum TranscriptAcceptanceConfiguration {
    static var variant: String { ProcessInfo.processInfo.environment["PERF_VARIANT"]! }
    static var fixedWindow: Bool { variant == "after" }
    static var isolateText: Bool { fixedWindow }
}
@MainActor enum TranscriptAcceptanceProbe {
    static var markdownPublishes = 0
    static var checkpoint: UInt64 = 0
    static var counters: [String: Any] { ["markdown_publishes": markdownPublishes] }
    static var rendererDiagnostics: String { "weak mounted renderer check; checkpoint=\\(checkpoint)" }
    static func reset() { markdownPublishes = 0; checkpoint = AssistantMarkdownDiagnostics.checkpoint }
    static func hasRendered(_ text: String) -> Bool { AssistantMarkdownDiagnostics.hasRendered(text, after: checkpoint) }
}
'''
manifest = '''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PiWorkTranscriptAcceptance", platforms: [.macOS(.v13)], dependencies: [
 .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
 .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
 .package(url: "https://github.com/mixpanel/mixpanel-swift", revision: "3ad0fb82216978c124b04accac6c9f9eaf848187")
], targets: [
 .executableTarget(name: "PiWork", dependencies: [.product(name: "Sparkle", package: "Sparkle"), .product(name: "MarkdownUI", package: "swift-markdown-ui"), .product(name: "Mixpanel", package: "mixpanel-swift")], swiftSettings: [.define("TRANSCRIPT_ACCEPTANCE")]),
 .testTarget(name: "PiWorkTests", dependencies: ["PiWork"])
])
'''
variants = sys.argv[4:] or ['before', 'reference', 'after']
for variant in variants:
    assert variant in ['before', 'after', 'reference']
    legacy = variant != 'after'
    target = root / variant
    for folder in ['Sources', 'Tests']:
        shutil.rmtree(target / folder, ignore_errors=True)
    hashes = {}
    for original in (source / 'PiWork').rglob('*.swift'):
        relative = str(original.relative_to(source / 'PiWork'))
        if variant == 'before' and relative in new:
            continue
        reference_shared = ['Core/Agent/SessionStore.swift', 'Features/Chat/ChatPresentation.swift', 'Features/Chat/Views/AssistantMarkdownView.swift']
        use_baseline = relative in changed and (variant == 'before' or (variant == 'reference' and relative not in reference_shared))
        selected = baseline / 'PiWork' / relative if use_baseline else original
        text = selected.read_text()
        if variant == 'reference' and relative == 'Features/Chat/Views/ChatView.swift':
            needle = '        .onReceive(sessionStore.recordUpdates)'
            assert text.count(needle) == 1
            # Consume the State value in a real modifier; a discarded read can
            # disappear under -O and fail to register a SwiftUI dependency.
            text = text.replace(needle, '        .onChange(of: recordUpdateGeneration) { _ in }\n' + needle, 1)
            # Share the corrected row -> parser delivery with production, but
            # retain original whole-parent updates, projection and 100..300 window.
            start = text.index('        ChatMessageRow(\n', text.index('    private func transcriptRow('))
            end = text.index('        .background {', start)
            row = text[start:end].rstrip()
            assert row.endswith('.equatable()')
            row = row.replace('message: message,', 'message: snapshot,', 1)
            wrapped = '''        let sessionID = presentedSessionID ?? activeSessionId ?? ""
        let hasTools = message.parts.contains { if case .tool = $0 { return true }; return false }
        let rawIDs = hasTools ? Set(sessionStore.records[sessionID]?.transcript.first { $0.id == message.id }?.parts.map(\\.id) ?? []) : []
        let grouped = hasTools && message.parts.contains { !rawIDs.contains($0.id) }
        return TranscriptMessageSnapshotView(fallback: message, store: sessionStore, sessionID: sessionID, isGrouped: grouped) { snapshot in
''' + '\n'.join('    ' + line for line in row.splitlines()) + '\n        }\n'
            text = text[:start] + wrapped + text[end:]
            needle = 'AssistantMarkdownView(text: text, isStreaming: message.isStreaming)'
            assert text.count(needle) == 1
            text = text.replace(needle, 'AssistantMarkdownView(text: text, isStreaming: message.isStreaming, blockID: id)')
        hashes[relative] = hashlib.sha256(text.encode()).hexdigest()
        if original.name in ['ContentView.swift', 'UserAccountPopover.swift'] and '\n#Preview' in text:
            text = text.split('\n#Preview', 1)[0] + '\n'
        text = text.replace('#filePath', json.dumps(str(original)))
        if relative == 'Features/Chat/Views/AssistantMarkdownView.swift':
            if variant == 'before':
                needle = '        content = AssistantMarkdownCache.content(for: text)'
                assert text.count(needle) == 1
                text = text.replace(needle, needle + '\n        AssistantMarkdownDiagnostics.register(self)', 1) + '\n' + diagnostics
            needle = '        renderedText = pendingText\n'
            assert text.count(needle) == 1
            text = text.replace(needle, needle + '        TranscriptAcceptanceProbe.markdownPublishes += 1\n')
        out = target / 'Sources/PiWork' / relative
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
    (target / 'Sources/PiWork/TranscriptAcceptanceProbe.swift').write_text(probe)
    tests = target / 'Tests/PiWorkTests'; tests.mkdir(parents=True)
    for name in ['SessionStoreTests.swift', 'TranscriptInputTestEvents.swift', 'TranscriptScrollObserverTests.swift']:
        original = source / 'PiWorkTests' / name
        text = original.read_text().replace('#filePath', json.dumps(str(original)))
        if name == 'SessionStoreTests.swift':
            if legacy:
                text += '\nextension TranscriptViewport { func currentFrame(for id: String) -> CGRect? { frames[id] } }\n'
            text += '\n' + helper
        (tests / name).write_text(text)
    shutil.copy2(fixture, target / 'complex.md')
    (target / 'Package.swift').write_text(manifest)
    (target / 'source-hashes.json').write_text(json.dumps(hashes, indent=2) + '\n')
    compiled = {str(p.relative_to(target)): hashlib.sha256(p.read_bytes()).hexdigest()
                for folder in ['Sources', 'Tests'] for p in (target / folder).rglob('*.swift')}
    (target / 'instrumented-hashes.json').write_text(json.dumps(compiled, indent=2) + '\n')
    cache = source / 'build/MarkdownIsolationBenchmark'
    if (cache / '.build/checkouts').is_dir() and not (target / '.build/checkouts').exists():
        (target / '.build').mkdir(parents=True, exist_ok=True)
        for name in ['checkouts', 'repositories', 'workspace-state.json']:
            shutil.copytree(cache / '.build' / name, target / '.build' / name) if (cache / '.build' / name).is_dir() else shutil.copy2(cache / '.build' / name, target / '.build' / name)
        shutil.copy2(cache / 'Package.resolved', target / 'Package.resolved')
print(root)
