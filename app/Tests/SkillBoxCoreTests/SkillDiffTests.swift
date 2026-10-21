import Darwin
import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Skill update differences")
struct SkillDiffTests {
    @Test("Preview covers hidden runtime files, directory changes, types and permissions", arguments: ["hidden", "hiddenAdded", "hiddenRemoved", "emptyDirectory", "removedDirectory", "directoryMode", "fileMode", "fileToDirectory", "fileToLink", "linkMode", "finderFile", "finderDirectory", "finderLink"])
    func completeInstallContentChanges(scenario: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxCompleteDiff-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = root.appendingPathComponent("before"), after = root.appendingPathComponent("after")
        let fm = FileManager.default
        for dir in [before, after] {
            try fm.createDirectory(at: dir.appendingPathComponent(".config"), withIntermediateDirectories: true)
            try "same".write(to: dir.appendingPathComponent(".config/settings.json"), atomically: true, encoding: .utf8)
            try "same".write(to: dir.appendingPathComponent("visible"), atomically: true, encoding: .utf8)
        }
        var expected: [SkillFileChange]
        switch scenario {
        case "hidden":
            try "changed".write(to: after.appendingPathComponent(".config/settings.json"), atomically: true, encoding: .utf8)
            expected = [.init(path: ".config/settings.json", kind: .modified)]
        case "hiddenAdded":
            try "runtime".write(to: after.appendingPathComponent(".runtime"), atomically: true, encoding: .utf8)
            expected = [.init(path: ".runtime", kind: .added)]
        case "hiddenRemoved":
            try fm.removeItem(at: after.appendingPathComponent(".config/settings.json"))
            expected = [.init(path: ".config/settings.json", kind: .removed)]
        case "emptyDirectory":
            try fm.createDirectory(at: after.appendingPathComponent("empty"), withIntermediateDirectories: true)
            expected = [.init(path: "empty", kind: .added)]
        case "removedDirectory":
            try fm.createDirectory(at: before.appendingPathComponent("empty"), withIntermediateDirectories: true)
            expected = [.init(path: "empty", kind: .removed)]
        case "directoryMode":
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: before.appendingPathComponent(".config").path)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: after.appendingPathComponent(".config").path)
            expected = [.init(path: ".config", kind: .modified)]
        case "fileMode":
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: before.appendingPathComponent("visible").path)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: after.appendingPathComponent("visible").path)
            expected = [.init(path: "visible", kind: .modified)]
        case "fileToDirectory":
            try fm.removeItem(at: after.appendingPathComponent("visible"))
            try fm.createDirectory(at: after.appendingPathComponent("visible"), withIntermediateDirectories: true)
            expected = [.init(path: "visible", kind: .modified)]
        case "fileToLink":
            try fm.removeItem(at: after.appendingPathComponent("visible"))
            try fm.createSymbolicLink(atPath: after.appendingPathComponent("visible").path, withDestinationPath: "same")
            expected = [.init(path: "visible", kind: .modified)]
        case "linkMode":
            for dir in [before, after] { try fm.createSymbolicLink(atPath: dir.appendingPathComponent("link").path, withDestinationPath: "visible") }
            #expect(lchmod(after.appendingPathComponent("link").path, 0o700) == 0)
            expected = [.init(path: "link", kind: .modified)]
        case "finderFile":
            try "Finder metadata".write(to: after.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
            expected = []
        case "finderLink":
            try fm.createSymbolicLink(atPath: after.appendingPathComponent(".DS_Store").path, withDestinationPath: "visible")
            expected = [.init(path: ".DS_Store", kind: .added)]
        default:
            try fm.createDirectory(at: after.appendingPathComponent(".DS_Store"), withIntermediateDirectories: true)
            expected = [.init(path: ".DS_Store", kind: .added)]
        }
        let actual = try SkillDiffAnalyzer().compare(before: before, after: after)
        #expect(actual == expected)
    }

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
