import Foundation

/// Prompt rail regression checks that also run on Command Line Tools-only hosts.
/// The rail's whole job is spacing and ordering, so that is what gets pinned.
@MainActor
enum PromptRailChecks {
    static func run() throws {
        let expect = MCPChecks.expect

        let messages = [
            PiChatMessage(id: "u1", role: .user, text: "  看一下这个是什么问题？\n  ", timestamp: nil, isStreaming: false),
            PiChatMessage(id: "a1", role: .assistant, text: "好的", timestamp: nil, isStreaming: false),
            PiChatMessage(id: "u2", role: .user, parts: [
                .text(id: "u2:t", text: "截图在这里"),
                .image(id: "u2:i", mimeType: "image/png", data: Data([1, 2, 3]))
            ], timestamp: nil, isStreaming: false),
            PiChatMessage(id: "u3", role: .user, parts: [
                .image(id: "u3:i", mimeType: "image/png", data: Data([4, 5, 6]))
            ], timestamp: nil, isStreaming: false),
            PiChatMessage(id: "s1", role: .system, text: "系统提示", timestamp: nil, isStreaming: false)
        ]

        let entries = PromptRailPresentation.entries(from: messages)
        try expect(entries.count == 3, "Only user turns belong on the rail")
        try expect(entries.map(\.id) == ["u1", "u2", "u3"], "Rail order must follow the transcript")
        try expect(entries.map(\.index) == [1, 2, 3], "Rail indices must be 1-based and gapless")
        try expect(entries[0].text == "看一下这个是什么问题？", "Preview must collapse surrounding whitespace")
        try expect(entries[1].imageCount == 1, "Image attachments were dropped from the entry")
        try expect(entries[2].hasText == false, "Image-only turn must not fake a text preview")
        try expect(entries[2].imageCount == 1, "Image-only turn lost its attachment count")

        let long = PiChatMessage(id: "long", role: .user, text: String(repeating: "长", count: 400), timestamp: nil, isStreaming: false)
        let longPreview = PromptRailPresentation.previewText(for: long)
        try expect(longPreview.count == PromptRailPresentation.previewLimit + 1, "Long previews must be clipped with a single ellipsis")
        try expect(longPreview.hasSuffix("…"), "Clipped preview lost its ellipsis")

        try expect(PromptRailLayout.tickCenters(count: 0, height: 200).isEmpty, "Empty rail must have no marks")
        try expect(PromptRailLayout.tickCenters(count: 1, height: 200) == [100], "A single mark belongs in the middle")

        let few = PromptRailLayout.tickCenters(count: 5, height: 200)
        try expect(few.count == 5, "Mark count drifted from entry count")
        try expect(zip(few, few.dropFirst()).allSatisfy { $0 < $1 }, "Marks must be strictly ordered")
        try expect(few.first! >= 0 && few.last! <= 200, "Marks escaped the rail")

        let many = PromptRailLayout.tickCenters(count: 80, height: 200)
        let manyStep = PromptRailLayout.step(for: many)
        try expect(manyStep >= PromptRailLayout.tickHeight, "Compressed marks must not overlap")
        try expect(many.first! >= 0 && many.last! <= 200, "Compressed block must stay inside the rail")

        let tall = PromptRailLayout.tickCenters(count: 3, height: 460)
        try expect(PromptRailLayout.step(for: tall) > few[1] - few[0], "A taller rail must spread the marks out")

        guard let nearest = PromptRailLayout.index(atY: few[2] + 1, centers: few) else {
            throw MCPChecks.Failure(message: "Pointing beside a mark missed it")
        }
        try expect(nearest == 2, "Hover resolved to the wrong mark")
        try expect(PromptRailLayout.index(atY: -60, centers: few) == nil, "Hover outside the rail must not stick")

        try expect(
            PromptRailLayout.railHeight(count: 4, available: 900) < PromptRailLayout.railHeight(count: 20, available: 900),
            "More turns must earn a taller rail"
        )
        try expect(
            PromptRailLayout.railHeight(count: 200, available: 300) <= 300,
            "The rail must never outgrow the transcript"
        )

        let frames: [String: CGRect] = [
            "u1": CGRect(x: 0, y: 40, width: 100, height: 30),
            "u2": CGRect(x: 0, y: 320, width: 100, height: 30),
            "u3": CGRect(x: 0, y: 700, width: 100, height: 30)
        ]
        let rail = PromptRailPresentation.entries(from: messages)
        try expect(
            PromptRailPresentation.currentPromptID(in: rail, frames: frames, readingLine: 88) == "u1",
            "The marker must stay on the turn being read"
        )
        try expect(
            PromptRailPresentation.currentPromptID(in: rail, frames: frames, readingLine: 400) == "u2",
            "The marker must follow the reading position down"
        )
        try expect(
            PromptRailPresentation.currentPromptID(in: rail, frames: [:], readingLine: 400) == "u1",
            "Unmeasured turns must fall back to the first entry"
        )

        print("Prompt rail native checks passed: entry projection, preview clipping, spacing, hover resolution and current-turn tracking.")
    }
}
