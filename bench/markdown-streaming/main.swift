// Streaming Markdown render benchmark.
//
// Compares three ways of turning a growing Markdown document into SwiftUI views:
//
//   A  whole document   — the shipped path: one `Markdown` view per reply, so
//                         every streaming tick rebuilds and re-lays out the
//                         whole document.
//   B  block memo       — one memoized view per frozen top-level block
//                         (`.equatable()`), active tail last, eager `VStack`.
//   C  block memo lazy  — the same segments in a `LazyVStack`.
//
// A control run (no ingest) reports harness overhead. Segmentation is verified
// against a full parse before any timing is recorded.
//
// Run with `scripts/benchmark-markdown-streaming.sh`.

import AppKit
import Combine
import Foundation
import MarkdownUI
import SwiftUI

// MARK: - Models

/// React.memo equivalent: SwiftUI skips body evaluation while the parsed value
/// is unchanged.
private struct SegmentView: View, Equatable {
  let content: MarkdownContent
  static func == (a: Self, b: Self) -> Bool { a.content == b.content }
  var body: some View {
    Diagnostics.segmentBodies += 1
    return Markdown(content)
  }
}

enum Diagnostics { @MainActor static var segmentBodies = 0 }

@MainActor
final class StreamingDoc: ObservableObject {
  enum Strategy { case wholeDocument, blockMemo }

  @Published private(set) var content = MarkdownContent("")
  @Published private(set) var segments: [StreamingMarkdownSegment] = []
  @Published private(set) var revision = 0

  private let strategy: Strategy
  private var accumulator = StreamingMarkdownAccumulator()
  /// Shipped product type, compiled from
  /// `PiWork/Features/Chat/StreamingMarkdownAccumulator.swift`.
  private var segmenter = StreamingMarkdownSegmenter()

  init(strategy: Strategy) { self.strategy = strategy }

  func touch() { revision &+= 1 }

  func ingest(_ text: String) {
    switch strategy {
    case .wholeDocument:
      content = accumulator.content(for: text)
    case .blockMemo:
      segments = segmenter.segments(for: text)
    }
  }
}

// MARK: - Views

private struct WholeDocumentView: View {
  @ObservedObject var doc: StreamingDoc
  var body: some View {
    let _ = doc.revision
    ScrollView {
      Markdown(doc.content)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
    .defaultScrollAnchor(.bottom)
    .markdownTheme(.gitHub)
  }
}

private struct BlockMemoView: View {
  @ObservedObject var doc: StreamingDoc
  let lazy: Bool
  var body: some View {
    let _ = doc.revision
    ScrollView {
      Group {
        if lazy {
          LazyVStack(alignment: .leading, spacing: 0) { rows }
        } else {
          VStack(alignment: .leading, spacing: 0) { rows }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
    }
    .defaultScrollAnchor(.bottom)
    .markdownTheme(.gitHub)
  }

  private var rows: some View {
    ForEach(Array(doc.segments.enumerated()), id: \.element.id) { index, segment in
      SegmentView(content: segment.content)
        .equatable()
        .padding(.top, index == 0 ? 0 : gap(before: index))
    }
  }

  /// Same rule the product view uses: `max(previous.bottom, next.top)`.
  private func gap(before index: Int) -> CGFloat {
    guard index > 0, index < doc.segments.count else { return 0 }
    return max(doc.segments[index - 1].trailingMargin, doc.segments[index].leadingMargin)
  }
}

/// Variant D: eager stack, but only the newest N blocks stay mounted; older
/// blocks become fixed-height placeholders whose height was measured while they
/// were visible. This is the block-level version of the transcript's existing
/// row virtualization, so document geometry stays exact (no lazy estimates).
private struct BlockWindowView: View {
  @ObservedObject var doc: StreamingDoc
  @State private var heights: [Int: CGFloat] = [:]
  static let mountedWindow = 6

  var body: some View {
    let _ = doc.revision
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(doc.segments.enumerated()), id: \.element.id) { index, segment in
          if index < doc.segments.count - Self.mountedWindow, let height = heights[segment.id] {
            Color.clear
              .frame(height: height)
              .padding(.top, index == 0 ? 0 : gap(before: index))
          } else {
            SegmentView(content: segment.content)
              .equatable()
              .background(
                GeometryReader { proxy in
                  Color.clear.preference(
                    key: BlockHeightKey.self, value: [segment.id: proxy.size.height])
                }
              )
              .padding(.top, index == 0 ? 0 : gap(before: index))
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .onPreferenceChange(BlockHeightKey.self) { values in
        for (id, height) in values where height > 0 { heights[id] = height }
      }
    }
    .defaultScrollAnchor(.bottom)
    .markdownTheme(.gitHub)
  }
}

extension BlockWindowView {
  /// Same rule the product view uses: `max(previous.bottom, next.top)`.
  fileprivate func gap(before index: Int) -> CGFloat {
    guard index > 0, index < doc.segments.count else { return 0 }
    return max(doc.segments[index - 1].trailingMargin, doc.segments[index].leadingMargin)
  }
}

private struct BlockHeightKey: PreferenceKey {
  static var defaultValue: [Int: CGFloat] = [:]
  static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
    value.merge(nextValue()) { $1 }
  }
}

// MARK: - Harness

extension NSView {
  func descendants<T: NSView>(of type: T.Type) -> [T] {
    subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + $0.descendants(of: type) }
  }
}

@MainActor
func pump(_ host: NSHostingView<AnyView>) {
  RunLoop.current.run(until: Date())
  host.layoutSubtreeIfNeeded()
}

@MainActor
func makeHost(_ root: AnyView) -> (NSWindow, NSHostingView<AnyView>) {
  let window = NSWindow(
    contentRect: .init(x: 0, y: 0, width: 760, height: 900),
    styleMask: [.borderless], backing: .buffered, defer: false)
  let host = NSHostingView(rootView: root)
  window.contentView = host
  window.orderFrontRegardless()
  host.frame = window.contentView!.bounds
  host.layoutSubtreeIfNeeded()
  return (window, host)
}

@MainActor
func run(
  name: String, text: String, chunkSize: Int,
  strategy: StreamingDoc.Strategy, lazy: Bool = false, windowed: Bool = false, noOp: Bool = false
) {
  let doc = StreamingDoc(strategy: strategy)
  let root: AnyView = windowed
    ? AnyView(BlockWindowView(doc: doc))
    : (strategy == .wholeDocument
      ? AnyView(WholeDocumentView(doc: doc))
      : AnyView(BlockMemoView(doc: doc, lazy: lazy)))
  let (window, host) = makeHost(root)

  var slices: [String] = []
  var index = text.startIndex
  while index < text.endIndex {
    let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
    slices.append(String(text[text.startIndex..<end]))
    index = end
  }

  Diagnostics.segmentBodies = 0
  var ticks: [Double] = []
  let total0 = DispatchTime.now().uptimeNanoseconds
  for slice in slices {
    let t0 = DispatchTime.now().uptimeNanoseconds
    if !noOp { doc.ingest(slice) }
    pump(host)
    ticks.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
  }
  let total = Double(DispatchTime.now().uptimeNanoseconds - total0) / 1e6
  window.orderOut(nil)

  if ProcessInfo.processInfo.environment["BENCH_TRACE"] != nil {
    let worst = ticks.enumerated().sorted { $0.element > $1.element }.prefix(5)
    print("    slowest ticks: " + worst.map { String(format: "#%d=%.1fms", $0.offset, $0.element) }.joined(separator: " "))
  }
  let sorted = ticks.sorted()
  func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
  print(String(
    format: "  %@ | ticks=%3d | median=%7.2f ms | p90=%7.2f ms | total=%8.0f ms | bodies=%3d",
    name.padding(toLength: 24, withPad: " ", startingAt: 0), ticks.count,
    pct(0.5), pct(0.9), total, Diagnostics.segmentBodies))
}

/// Confirms per-segment parsing reproduces the full document's block structure.
func verify(_ text: String, label: String) {
  var parts: [String] = []
  var offset = 0
  for boundary in StreamingMarkdownBoundary.safeBlockBoundaries(in: text) {
    let end = text.distance(from: text.startIndex, to: boundary)
    guard end > offset else { continue }
    let start = text.index(text.startIndex, offsetBy: offset)
    parts.append(String(text[start..<text.index(text.startIndex, offsetBy: end)]))
    offset = end
  }
  let start = text.index(text.startIndex, offsetBy: offset)
  parts.append(String(text[start...]))

  let joined = parts
    .map { MarkdownContent($0).renderMarkdown() }
    .filter { !$0.isEmpty }
    .joined(separator: "\n\n")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let full = MarkdownContent(text).renderMarkdown()
    .trimmingCharacters(in: .whitespacesAndNewlines)
  print("  verify[\(label)] segments=\(parts.count) matchesFullParse=\(joined == full)")
}

/// Geometry probe: the transcript anchor/history math reads row frames in
/// document coordinates. If a layout strategy reports a different document
/// height depending on where the reader is scrolled, those frames drift.
@MainActor
func probeGeometry(name: String, text: String, strategy: StreamingDoc.Strategy,
                   lazy: Bool = false, windowed: Bool = false) {
  let doc = StreamingDoc(strategy: strategy)
  var offset = 0
  while offset < text.count {
    offset = min(text.count, offset + 31)
    doc.ingest(String(text.prefix(offset)))
  }

  let root: AnyView = windowed
    ? AnyView(BlockWindowView(doc: doc))
    : (strategy == .wholeDocument
      ? AnyView(WholeDocumentView(doc: doc))
      : AnyView(BlockMemoView(doc: doc, lazy: lazy)))
  let (window, host) = makeHost(root)
  pump(host)

  guard let scroll = host.descendants(of: NSScrollView.self).first,
        let document = scroll.documentView else {
    print("  \(name): no scroll view"); window.orderOut(nil); return
  }
  func height() -> CGFloat { document.frame.height }
  func scrollTo(_ y: CGFloat) {
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
    pump(host)
  }

  let visible = scroll.contentView.bounds.height
  let atBottom = max(0, height() - visible)
  let hBottomStart = height()
  scrollTo(0)
  let hTop = height()
  scrollTo(atBottom)
  let hBottom = height()
  scrollTo(max(0, (height() - visible) / 2))
  let hMiddle = height()

  // Append more content while sitting mid-document, as a reader would.
  var extended = text
  for _ in 0..<6 {
    extended += "\n\nExtra streamed paragraph with **bold** text."
    doc.ingest(extended)
    pump(host)
  }
  scrollTo(max(0, (height() - visible) / 2))
  let hAfterStream = height()

  let drift = max(abs(hTop - hBottom), abs(hMiddle - hBottom))
  print(String(format: "  %@ | top=%.0f mid=%.0f bottom=%.0f afterStream=%.0f | drift=%.0f pt",
               name.padding(toLength: 24, withPad: " ", startingAt: 0),
               hTop, hMiddle, hBottom, hAfterStream, drift))
  _ = hBottomStart
  window.orderOut(nil)
}

@MainActor
func main() {
  _ = NSApplication.shared
  let args = CommandLine.arguments
  let path = args.count > 1
    ? args[1]
    : "PiWorkTests/Fixtures/markdown/performance-complex.md"
  let base = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
  guard !base.isEmpty else {
    print("Cannot read fixture: \(path)")
    return
  }
  let large = base + "\n\n" + base

  for (label, text) in [("4.6KB", base), ("9.2KB", large)] {
    print("=== \(label) — \(text.count) chars, ~\(text.components(separatedBy: "\n\n").count) blocks ===")
    verify(text, label: "segmentation")
    for strategy in [StreamingDoc.Strategy.wholeDocument, .blockMemo] {
      let warm = StreamingDoc(strategy: strategy)
      for _ in 0..<3 { warm.ingest(text) }
    }
    run(name: "control (no ingest)", text: text, chunkSize: 31,
        strategy: .wholeDocument, noOp: true)
    run(name: "A whole document", text: text, chunkSize: 31, strategy: .wholeDocument)
    run(name: "B block memo + VStack", text: text, chunkSize: 31, strategy: .blockMemo)
    run(name: "C block memo + LazyVStack", text: text, chunkSize: 31, strategy: .blockMemo, lazy: true)
    run(name: "D block memo + window", text: text, chunkSize: 31, strategy: .blockMemo, windowed: true)
    print("  geometry (document height must not depend on scroll position):")
    probeGeometry(name: "A whole document", text: text, strategy: .wholeDocument)
    probeGeometry(name: "B memo + VStack", text: text, strategy: .blockMemo)
    probeGeometry(name: "C memo + LazyVStack", text: text, strategy: .blockMemo, lazy: true)
    probeGeometry(name: "D memo + window", text: text, strategy: .blockMemo, windowed: true)
    print("")
  }
}

MainActor.assumeIsolated { main() }
