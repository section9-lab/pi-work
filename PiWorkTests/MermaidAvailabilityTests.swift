import XCTest
@testable import PiWork

final class MermaidAvailabilityTests: XCTestCase {
    private func version(_ major: Int, _ minor: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
    }

    func testVenturaKeepsTheFeatureOff() {
        XCTAssertFalse(MermaidAvailability.isEnabled(osVersion: version(13, 6)))
    }

    func testSonomaAndLaterEnableTheFeature() {
        for major in [14, 15, 26] {
            XCTAssertTrue(MermaidAvailability.isEnabled(osVersion: version(major)))
        }
    }

    func testPreferenceActsAsAKillSwitch() {
        XCTAssertFalse(MermaidAvailability.isEnabled(osVersion: version(26), preference: false))
    }

    func testFenceLanguageMatching() {
        XCTAssertTrue(MermaidSource.isMermaidFence("mermaid"))
        XCTAssertTrue(MermaidSource.isMermaidFence("Mermaid"))
        XCTAssertTrue(MermaidSource.isMermaidFence("mermaid title=flow"))
        XCTAssertFalse(MermaidSource.isMermaidFence(nil))
        XCTAssertFalse(MermaidSource.isMermaidFence(""))
        XCTAssertFalse(MermaidSource.isMermaidFence("swift"))
        XCTAssertFalse(MermaidSource.isMermaidFence("notmermaid"))
    }

    func testRenderLimits() {
        XCTAssertFalse(MermaidSource.isWithinRenderLimits(""))
        XCTAssertTrue(MermaidSource.isWithinRenderLimits("flowchart LR\n  A --> B"))
        XCTAssertFalse(MermaidSource.isWithinRenderLimits(
            String(repeating: "a", count: MermaidSource.maximumCharacterCount + 1)
        ))
    }

    func testAccessibilityDescriptionDropsHTMLLineBreaks() {
        let generated = "Flowchart with 2 nodes: 桌面端<br/>MCP Server,  第二个<br />节点"
        XCTAssertEqual(
            MermaidSource.accessibilityDescription(generated),
            "Flowchart with 2 nodes: 桌面端 MCP Server, 第二个 节点"
        )
    }
}
