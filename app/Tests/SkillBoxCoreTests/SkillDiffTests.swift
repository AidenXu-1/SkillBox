import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Skill update differences")
struct SkillDiffTests {
    @Test("Update preview lists added, modified and removed files")
    func fileChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxDiffTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = root.appendingPathComponent("before")
        let after = root.appendingPathComponent("after")
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: after, withIntermediateDirectories: true)
        try "old".write(to: before.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "new".write(to: after.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "same".write(to: before.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try "same".write(to: after.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try "removed".write(to: before.appendingPathComponent("removed.sh"), atomically: true, encoding: .utf8)
        try "added".write(to: after.appendingPathComponent("added.md"), atomically: true, encoding: .utf8)

        let changes = try SkillDiffAnalyzer().compare(before: before, after: after)
        #expect(changes == [
            .init(path: "SKILL.md", kind: .modified),
            .init(path: "added.md", kind: .added),
            .init(path: "removed.sh", kind: .removed),
        ])
    }
}
