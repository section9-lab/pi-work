import MermaidLayout
import MermaidRender
import XCTest
@testable import PiWork

/// Rendering tests must not use `ImageRenderer`/`NSHostingView`: the Intel CI
/// runner has no Metal device, and SwiftUI's renderer aborts asynchronously
/// while loading its shader archive. CoreGraphics image rendering is safe.
@MainActor
final class MermaidRenderingTests: XCTestCase {
    /// Representative of the replies that prompted this feature: subgraph with
    /// a Chinese title, `<br/>` breaks, CJK labels and a wide edge label.
    private let flowchart = """
    flowchart TB
      subgraph EDGE["① 端层 · 眼睛和手脚"]
        direction LR
        E1["桌面端<br/>MCP Server + manifest"]
        E2["浏览器扩展"]
      end
      GW["接入网关 Gateway<br/>设备码鉴权 · 去重 · 背压"]
      EDGE --> GW
    """

    /// Deliberately wider than the transcript column, mirroring the connector
    /// flowchart from the original report. `MermaidView` scales it down; the
    /// full-size sheet exists because that scale is unreadable.
    private let wideFlowchart = """
    flowchart LR
      A["模型发起 tool call"] --> B{"Tool Router 三判据<br/>① 是否幂等 ② 凭证在哪侧 ③ 端是否在线"}
      B --> C["① CLI 层（Sandbox 内 bash）<br/>gh · gcloud · aws · stripe · vercel · psql"]
      C --> D["② 云连接器（内核侧 MCP）<br/>Google Workspace · Notion · Slack · Jira"]
      D --> E["③ 端连接器（设备侧 MCP）<br/>Apple：EventKit · Contacts/Photos · JXA"]
      E --> F["工具定义/执行：官方 MCP 优先<br/>Composio / Arcade 兜底 · n8n / Activepieces"]
    """

    private let sequence = """
    sequenceDiagram
      participant U as 用户
      participant K as Kernel
      U->>K: 上行音频
      K-->>U: 下行音频
    """

    private func requireSonoma() throws {
        guard #available(macOS 14, *) else {
            throw XCTSkip("Native Mermaid rendering is gated to macOS 14+")
        }
    }

    func testRendererDrawsFlowchartAndSequenceDiagrams() throws {
        try requireSonoma()
        for source in [flowchart, sequence] {
            XCTAssertNotNil(MermaidParser.parse(source), "fixture should parse")
            let image = try XCTUnwrap(MermaidRenderer.image(source: source, theme: .init(prefersDark: false)))
            XCTAssertGreaterThan(image.size.width, 10)
            XCTAssertGreaterThan(image.size.height, 10)
            XCTAssertFalse(MermaidRenderer.altText(source: source)?.isEmpty ?? true)
        }
    }

    func testFactoryOnlyAcceptsMermaidFences() throws {
        try requireSonoma()
        XCTAssertNotNil(MermaidDiagramFactory.makeBlock(language: "mermaid", source: flowchart))
        XCTAssertNil(MermaidDiagramFactory.makeBlock(language: "swift", source: flowchart))
        XCTAssertNil(MermaidDiagramFactory.makeBlock(language: nil, source: flowchart))
    }

    func testFactoryFallsBackForSourcesTheRendererRejects() throws {
        try requireSonoma()
        XCTAssertNil(MermaidDiagramFactory.makeBlock(language: "mermaid", source: "flowchart TB\n  subgraph"))
        XCTAssertNil(MermaidDiagramFactory.makeBlock(language: "mermaid", source: ""))
        XCTAssertNil(MermaidDiagramFactory.makeBlock(
            language: "mermaid",
            source: String(repeating: "a", count: MermaidSource.maximumCharacterCount + 1)
        ))
    }

    /// The wide fixture is why the block opens a scrollable sheet: at the
    /// 694pt transcript column the diagram is scaled down, never up.
    func testWideFixtureExceedsTheTranscriptColumn() throws {
        try requireSonoma()
        let column: CGFloat = 694
        let natural = try XCTUnwrap(
            MermaidRenderer.image(source: wideFlowchart, theme: .init(prefersDark: false))
        )
        XCTAssertGreaterThan(natural.size.width, column)
        XCTAssertNotNil(MermaidDiagramFactory.makeBlock(language: "mermaid", source: wideFlowchart))
    }
}
