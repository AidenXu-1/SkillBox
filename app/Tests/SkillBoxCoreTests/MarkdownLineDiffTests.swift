import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Continuous Markdown differences")
struct MarkdownLineDiffTests {
    @Test func identicalAndEmpty() {
        for text in ["", "标题\n\n正文\n", "👩‍💻"] {
            let diff = MarkdownLineDiff(before: text, after: text)
            #expect(diff.removed.isEmpty && diff.added.isEmpty)
        }
        #expect(MarkdownLineDiff(before: "", after: "新增").added == [NSRange(location: 0, length: 2)])
        #expect(MarkdownLineDiff(before: "删除", after: "").removed == [NSRange(location: 0, length: 2)])
    }

    @Test func unicodeAndRepeatedLines() {
        let before = "👩‍💻 标题\n相同\n旧内容\n相同\n"
        let after = "👩‍💻 标题\n相同\n新内容🟡\n相同\n"
        let diff = MarkdownLineDiff(before: before, after: after)
        #expect(diff.removed.map { (before as NSString).substring(with: $0) } == ["旧内容"])
        #expect(diff.added.map { (after as NSString).substring(with: $0) } == ["新内容🟡"])
    }

    @Test func insertionDoesNotMarkFollowingLines() {
        let diff = MarkdownLineDiff(before: "甲\n乙\n丙", after: "甲\n新增\n乙\n丙")
        #expect(diff.removed.isEmpty)
        #expect(diff.added == [NSRange(location: 2, length: 2)])
    }

    @Test func blankLinesKeepOffsets() {
        let diff = MarkdownLineDiff(before: "甲\n\n乙\n", after: "甲\n\n丙\n")
        #expect(diff.added == [NSRange(location: 3, length: 1)])
        #expect(diff.removed == diff.added)
    }

    @Test func largeRewritesUseBoundedRegion() {
        let before = "同一标题\n" + (0..<2500).map { "旧\($0)" }.joined(separator: "\n") + "\n相同结尾"
        let after = "同一标题\n" + (0..<2500).map { "新\($0)" }.joined(separator: "\n") + "\n相同结尾"
        let diff = MarkdownLineDiff(before: before, after: after)
        #expect(diff.usesChangedRegion)
        #expect(diff.removed.count == 2500 && diff.added.count == 2500)
        #expect(diff.added.first?.location == "同一标题\n".utf16.count)
    }
}
