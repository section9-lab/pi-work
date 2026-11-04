#!/usr/bin/env python3
"""Stage an experimental same-binary A/B. Never patch the production source tree."""
import hashlib
import json
import pathlib
import shutil
import sys

source, target = (pathlib.Path(arg).resolve() for arg in sys.argv[1:3])
assert target != source and target.is_relative_to(source / 'build'), 'Use a dedicated build/ scratch directory'
for folder, destination in [('PiWork', 'Sources/PiWork'), ('PiWorkTests', 'Tests/PiWorkTests')]:
    shutil.rmtree(target / destination, ignore_errors=True)
    for original in (source / folder).rglob('*.swift'):
        out = target / destination / original.relative_to(source / folder)
        out.parent.mkdir(parents=True, exist_ok=True)
        text = original.read_text()
        if original.name in ['ContentView.swift', 'UserAccountPopover.swift'] and '\n#Preview' in text:
            text = text.split('\n#Preview', 1)[0] + '\n'
        out.write_text(text.replace('#filePath', json.dumps(str(original))))


def patch(relative, old, new):
    path = target / 'Sources/PiWork' / relative
    text = path.read_text()
    assert text.count(old) == 1, f'Source drift / non-unique patch: {relative}: {old[:80]}'
    path.write_text(text.replace(old, new, 1))


store = 'Core/Agent/SessionStore.swift'
patch(store, '    private let recordUpdatesSubject = PassthroughSubject<Set<String>, Never>()', '''    private let recordUpdatesSubject = PassthroughSubject<Set<String>, Never>()
    private var markdownOnlyTextSincePublish = true
    private(set) var markdownContentOnlySessionIDs: Set<String> = []''')
patch(store, '        let effects = reducer.receive(event, timestamp: Self.timestamp(from: now()))', '''        let textIdentity = MarkdownIsolationConfiguration.isolateText ? event.markdownIsolationTextIdentity : nil
        let previousSignature = textIdentity.flatMap { MarkdownIsolationSignature(reducer.records[$0.sessionID]) }
        let previousSequence = textIdentity.flatMap { reducer.records[$0.sessionID]?.lastSequence }
        let effects = reducer.receive(event, timestamp: Self.timestamp(from: now()))
        if MarkdownIsolationConfiguration.isolateText {
            let nextSignature = textIdentity.flatMap { MarkdownIsolationSignature(reducer.records[$0.sessionID]) }
            let eligible = previousSignature != nil && previousSignature == nextSignature
                && textIdentity?.sequence == previousSequence.map { $0 + 1 }
            // Any mixed/tool/usage/state event conservatively falls back to the parent.
            markdownOnlyTextSincePublish = markdownOnlyTextSincePublish && eligible
        }''')
patch(store, '        if workspaceChanged { objectWillChange.send() }\n        records = next', '''        markdownContentOnlySessionIDs = MarkdownIsolationConfiguration.isolateText
            && markdownOnlyTextSincePublish && !notifyWorkspace && !workspaceChanged ? Set(changedIDs) : []
        markdownOnlyTextSincePublish = true
        if workspaceChanged { objectWillChange.send() }
        records = next''')

nav = 'Features/Chat/TranscriptWindowNavigation.swift'
patch(nav, '    static let maximumCount = batchSize * 3',
      '    static var maximumCount: Int { MarkdownIsolationConfiguration.fixedWindow ? batchSize : batchSize * 3 }')
patch(nav, '        if endID == nil { endID = ids[current.upperBound - 1] }', '''        if MarkdownIsolationConfiguration.fixedWindow {
            let end = current.upperBound - min(MarkdownIsolationConfiguration.shift, current.lowerBound)
            endID = ids[end - 1]
            return
        }
        if endID == nil { endID = ids[current.upperBound - 1] }''')
patch(nav, '        let end = min(ids.count, current.upperBound + Self.batchSize)',
      '        let step = MarkdownIsolationConfiguration.fixedWindow ? MarkdownIsolationConfiguration.shift : Self.batchSize\n        let end = min(ids.count, current.upperBound + step)')
patch(nav, '        let end = min(ids.count, index + 1 + Self.maximumCount - Self.batchSize)',
      '        let ahead = MarkdownIsolationConfiguration.fixedWindow ? Self.batchSize / 2 : Self.maximumCount - Self.batchSize\n        let end = min(ids.count, index + 1 + ahead)')

chat = 'Features/Chat/Views/ChatView.swift'
patch(chat, '    @State private var recordUpdateGeneration = 0', '''    @State private var recordUpdateGeneration = 0
    @StateObject private var markdownWindowCache = MarkdownIsolationWindowCache()''')
patch(chat, '''            if activeSessionId.map(changedIDs.contains) == true
                || presentedSessionID.map(changedIDs.contains) == true {
                recordUpdateGeneration &+= 1
            }''', '''            let relevant = changedIDs.intersection(Set([activeSessionId, presentedSessionID].compactMap { $0 }))
            if !relevant.isEmpty {
                if MarkdownIsolationConfiguration.isolateText,
                   relevant.isSubset(of: sessionStore.markdownContentOnlySessionIDs) {
                    MarkdownIsolationProbe.skippedParentEvents += 1
                } else { recordUpdateGeneration &+= 1 }
            }''')
# Keep the exact original row implementation, including equality and callbacks.
path = target / 'Sources/PiWork' / chat
text = path.read_text()
start = text.index('        ChatMessageRow(\n', text.index('    private func transcriptRow('))
end = text.index('        .background {', start)
original = text[start:end].rstrip()
assert original.endswith('.equatable()')
wrapped = original.replace('message: message,', 'message: liveMessage,', 1)
replacement = '''        Group {
            if MarkdownIsolationConfiguration.isolateText, message.isStreaming,
               let sessionID = presentedSessionID {
                MarkdownIsolatedReply(message: message, store: sessionStore, sessionID: sessionID) { liveMessage in
''' + '\n'.join('            ' + line for line in wrapped.splitlines()) + '''
                }
            } else {
''' + '\n'.join('        ' + line for line in original.splitlines()) + '''
            }
        }
'''
text = text[:start] + replacement + text[end:]
path.write_text(text)
patch(chat, '''        let streamingMessageID = record.activeTurnId.flatMap { turnId in''', '''        let cacheKey = MarkdownIsolationWindowCache.Key(sessionID: record.id,
            generation: recordUpdateGeneration, sourceCount: record.transcript.count,
            navigation: transcriptNavigation, limit: min(transcriptMessageLimit, presentedMessageLimit),
            executing: isExecuting, turnID: record.activeTurnId)
        if MarkdownIsolationConfiguration.isolateText, markdownWindowCache.key == cacheKey,
           let cached = markdownWindowCache.window { return cached }
        let streamingMessageID = record.activeTurnId.flatMap { turnId in''')
patch(chat, '''        return TranscriptWindow(
            messages: AssistantTranscriptPresentation.groupAdjacentTools(in: displayed),''', '''        let result = TranscriptWindow(
            messages: AssistantTranscriptPresentation.groupAdjacentTools(in: displayed),''')
patch(chat, '''            hasCachedEarlierMessages: range.lowerBound > 0
        )
    }''', '''            hasCachedEarlierMessages: range.lowerBound > 0
        )
        if MarkdownIsolationConfiguration.isolateText {
            markdownWindowCache.key = cacheKey; markdownWindowCache.window = result
        }
        return result
    }''')
patch(chat, '        let visibleSource = record.transcript.filter { message in', '''        MarkdownIsolationProbe.projections += 1
        MarkdownIsolationProbe.sourceRows += record.transcript.count
        let visibleSource = record.transcript.filter { message in''')

markdown = 'Features/Chat/Views/AssistantMarkdownView.swift'
patch(markdown, '    private(set) var renderedText: String', '''    private(set) var renderedText: String
    private(set) var markdownBenchmarkRequestedText = ""''')
patch(markdown, '        pendingText = text\n        guard isStreaming else {', '''        markdownBenchmarkRequestedText = text
        pendingText = text
        guard isStreaming else {''')
patch(markdown, '        content = AssistantMarkdownCache.content(for: text)', '''        MarkdownIsolationProbe.markdownInitializations += 1
        if text.hasPrefix("# STREAM-BEGIN:") { MarkdownIsolationProbe.lastMarkdownText = text }
        content = AssistantMarkdownCache.content(for: text)
        MarkdownIsolationProbe.register(self)''')
patch(markdown, '        renderedText = pendingText\n        content = cache', '''        renderedText = pendingText
        MarkdownIsolationProbe.markdownPublishes += 1
        if pendingText.hasPrefix("# STREAM-BEGIN:") { MarkdownIsolationProbe.lastMarkdownText = pendingText }
        content = cache''')

shutil.copy2(source / 'scripts/MarkdownIsolationCandidate.swift', target / 'Sources/PiWork/MarkdownIsolationCandidate.swift')
test = target / 'Tests/PiWorkTests/SessionStoreTests.swift'
test.write_text(test.read_text() + '\n' + (source / 'scripts/MarkdownIsolationPerformance.swift').read_text())
fixture = source / 'PiWorkTests/Fixtures/markdown/performance-complex.md'
shutil.copy2(fixture, target / 'complex.md')
(target / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PiWorkMarkdownIsolation", platforms: [.macOS(.v13)], dependencies: [
 .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
 .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
 .package(url: "https://github.com/mixpanel/mixpanel-swift", revision: "3ad0fb82216978c124b04accac6c9f9eaf848187")
], targets: [
 .executableTarget(name: "PiWork", dependencies: [.product(name: "Sparkle", package: "Sparkle"), .product(name: "MarkdownUI", package: "swift-markdown-ui"), .product(name: "Mixpanel", package: "mixpanel-swift")]),
 .testTarget(name: "PiWorkTests", dependencies: ["PiWork"])
])
''')
files = ['PiWork/Features/Chat/Views/ChatView.swift', 'PiWork/Features/Chat/TranscriptWindowNavigation.swift',
         'PiWork/Core/Agent/SessionStore.swift', 'PiWork/Features/Chat/Views/AssistantMarkdownView.swift',
         'scripts/MarkdownIsolationCandidate.swift', 'scripts/MarkdownIsolationPerformance.swift', str(fixture.relative_to(source))]
(target / 'source-hashes.json').write_text(json.dumps({p: hashlib.sha256((source / p).read_bytes()).hexdigest() for p in files}, indent=2) + '\n')
print(f'Staged isolated A/B at {target}; fixture {len(fixture.read_bytes())} bytes')
