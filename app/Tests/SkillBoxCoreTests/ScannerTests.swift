import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Skill scanning and fingerprints")
struct ScannerTests {
    @Test("Identical copies collapse and divergent copies conflict")
    func grouping() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }

        let first = try fixture.makeSkill(root: "codex", directory: "demo", name: "demo", body: "same")
        _ = try fixture.makeSkill(root: "agents", directory: "demo", name: "demo", body: "same")
        _ = try fixture.makeSkill(root: "hana", directory: "demo", name: "demo", body: "different")
        _ = try fixture.makeSkill(root: "codex", directory: "outer", name: "outer", body: "outer", nestedSkill: true)

        let scanner = FileSystemSkillScanner()
        let result = await scanner.scan(
            roots: [
                first.deletingLastPathComponent(),
                fixture.root.appendingPathComponent("agents"),
                fixture.root.appendingPathComponent("hana"),
            ],
            sourceName: { $0.lastPathComponent }
        )

        #expect(result.candidates.filter { $0.canonicalName == "demo" }.count == 3)
        #expect(result.duplicateGroups.contains { $0.canonicalName == "demo" && $0.candidates.count == 2 })
        #expect(result.conflicts.first { $0.canonicalName == "demo" }?.versions.count == 2)
        #expect(result.candidates.filter { $0.canonicalName == "nested" }.isEmpty)
    }

    @Test("Permissions and symlink targets affect fingerprints")
    func fingerprintInputs() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(root: "root", directory: "demo", name: "demo", body: "body")
        let fingerprinter = SHA256SkillFingerprinter()
        let original = try fingerprinter.fingerprint(directory: skill)

        let script = skill.appendingPathComponent("script.sh")
        try "echo ok".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let withScript = try fingerprinter.fingerprint(directory: skill)
        #expect(original != withScript)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        let changedPermission = try fingerprinter.fingerprint(directory: skill)
        #expect(withScript != changedPermission)

        try "hidden".write(to: skill.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        let withHiddenFile = try fingerprinter.fingerprint(directory: skill)
        #expect(changedPermission != withHiddenFile)
    }

    @Test("Scanner remains read only")
    func scannerIsReadOnly() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(root: "codex", directory: "demo", name: "demo", body: "body")
        let before = try directorySnapshot(fixture.root)
        _ = await FileSystemSkillScanner().scan(roots: [skill.deletingLastPathComponent()], sourceName: { _ in "Codex" })
        let after = try directorySnapshot(fixture.root)
        #expect(before == after)
    }

    @Test("Skill directory listing includes every file without following symlinks")
    func directoryListing() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(root: "root", directory: "demo", name: "demo", body: "body")
        let references = skill.appendingPathComponent("references")
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        try "details".write(to: references.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: skill.appendingPathComponent("outside").path, withDestinationPath: "../../outside")

        let entries = try SkillDirectoryReader().entries(at: skill)

        #expect(entries.map(\.relativePath) == ["outside", "references", "references/guide.md", "SKILL.md"])
        #expect(entries.first { $0.relativePath == "references" }?.kind == .directory)
        #expect(entries.first { $0.relativePath == "references/guide.md" }?.depth == 1)
        #expect(entries.first { $0.relativePath == "SKILL.md" }?.kind == .markdown)
        #expect(entries.first { $0.relativePath == "outside" }?.kind == .symbolicLink)
    }
}

@Suite("Skill usage guidance")
struct SkillUsageGuideTests {
    @Test("User-facing metadata and README produce a concise guide")
    func extractsUserFacingGuide() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            root: "root",
            directory: "guided",
            name: "guided",
            body: """
            # Guided Skill

            ## 执行步骤

            ### 1. 安全检查
            这是 Agent 内部规则，不应展示成用户流程。
            """
        )
        let agents = skill.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try """
        interface:
          display_name: "Guided Skill"
          short_description: "帮你在开始前整理好项目基础"
          default_prompt: "帮我为这个新项目做开发前准备。"
        """.write(to: agents.appendingPathComponent("openai.yaml"), atomically: true, encoding: .utf8)
        try """
        # Guided Skill

        ## 适用场景

        适合：

        - 全新的软件项目。
        - 需要长期维护的项目。

        不适合：

        - 已经有代码的老项目。
        """.write(to: skill.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let guide = try #require(SkillUsageGuideExtractor().extract(from: skill))

        #expect(guide.purpose == "帮你在开始前整理好项目基础")
        #expect(guide.useWhen == "全新的软件项目；需要长期维护的项目")
        #expect(guide.avoidWhen == "已经有代码的老项目")
        #expect(guide.starterPrompt == "帮我为这个新项目做开发前准备。")
        #expect(guide.experienceSteps.isEmpty)
    }

    @Test("Only an explicitly user-facing experience section becomes a flow")
    func extractsExplicitExperience() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(root: "root", directory: "experience", name: "experience", body: "# Experience")
        try """
        # Experience

        ## 使用时会发生什么

        1. AI 会先询问必要信息。
        2. 根据回答完成工作。
        3. 给出结果和下一步。
        4. 这一条不应展示。
        """.write(to: skill.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let guide = try #require(SkillUsageGuideExtractor().extract(from: skill))

        #expect(guide.experienceSteps == [
            "AI 会先询问必要信息",
            "根据回答完成工作",
            "给出结果和下一步",
        ])
    }

    @Test("A valid description degrades to a small honest guide without inventing details")
    func degradesToDescription() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(root: "root", directory: "unguided", name: "unguided", body: "# Unguided")

        let guide = try #require(SkillUsageGuideExtractor().extract(from: skill))
        #expect(guide.purpose == "Test unguided")
        #expect(guide.useWhen == nil)
        #expect(guide.starterPrompt == nil)
        #expect(guide.experienceSteps.isEmpty)
    }
}

@Suite("Risk analysis")
struct RiskAnalyzerTests {
    @Test("Documentation commands stay informational")
    func documentationIsNotExecution() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(root: "root", directory: "docs", name: "docs", body: "Run curl https://example.com in a terminal")
        let report = try StaticRiskAnalyzer().analyze(skillDirectory: skill)
        #expect(report.findings.contains { $0.category == .network && $0.severity == .info })
        #expect(!report.isBlocked)
    }

    @Test("Executable scripts and escaping symlinks are surfaced")
    func executableAndEscape() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(root: "root", directory: "danger", name: "danger", body: "body")
        let script = skill.appendingPathComponent("run.sh")
        try "sudo rm -rf /tmp/example".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try FileManager.default.createSymbolicLink(atPath: skill.appendingPathComponent("outside").path, withDestinationPath: "../../secret")

        let report = try StaticRiskAnalyzer().analyze(skillDirectory: skill)
        #expect(report.findings.contains { $0.category == .executableFile })
        #expect(report.findings.contains { $0.category == .privilege && $0.severity == .high })
        #expect(report.findings.contains { $0.category == .pathEscape && $0.severity == .blocked })
        #expect(report.isBlocked)
    }

    @Test("Scoped cleanup commands are cautions and show the matched command")
    func scopedCleanupIsCaution() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(root: "root", directory: "cleanup", name: "cleanup", body: "body")
        let script = skill.appendingPathComponent("verify.sh")
        try #"""
        TMP_ROOT="$(mktemp -d)"
        rm -rf "$TMP_ROOT"
        """#.write(to: script, atomically: true, encoding: .utf8)

        let report = try StaticRiskAnalyzer().analyze(skillDirectory: skill)
        let deletion = try #require(report.findings.first { $0.category == .deletion })
        #expect(deletion.severity == .caution)
        #expect(deletion.title == "包含清理文件的命令")
        #expect(deletion.evidence == #"rm -rf "$TMP_ROOT""#)
    }

    @Test("Deleting a broad system path remains high risk")
    func broadDeletionIsHighRisk() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(root: "root", directory: "dangerous-cleanup", name: "dangerous-cleanup", body: "body")
        try "rm -rf /".write(to: skill.appendingPathComponent("danger.sh"), atomically: true, encoding: .utf8)

        let report = try StaticRiskAnalyzer().analyze(skillDirectory: skill)
        let deletion = try #require(report.findings.first { $0.category == .deletion })
        #expect(deletion.severity == .high)
        #expect(deletion.title == "可能删除宽泛位置的内容")
    }
}

@Suite("Path safety")
struct PathSafetyTests {
    @Test("Broad, missing and central-library targets are rejected")
    func unsafeTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxPathTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let library = home.appendingPathComponent("Library/Application Support/SkillBox")
        let custom = home.appendingPathComponent("Custom/Skills")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        #expect(throws: PathSafetyError.self) { try PathSafety.validateCustomTarget(home, homeDirectory: home, libraryRoot: library) }
        #expect(throws: PathSafetyError.self) { try PathSafety.validateCustomTarget(library.appendingPathComponent("Library"), homeDirectory: home, libraryRoot: library) }
        #expect(throws: PathSafetyError.self) { try PathSafety.validateCustomTarget(home.appendingPathComponent("Missing/Skills"), homeDirectory: home, libraryRoot: library) }
        try PathSafety.validateCustomTarget(custom, homeDirectory: home, libraryRoot: library)
    }
}

private struct TemporaryFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeSkill(root rootName: String, directory: String, name: String, body: String, nestedSkill: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(rootName).appendingPathComponent(directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let text = "---\nname: \(name)\ndescription: Test \(name)\n---\n\n\(body)\n"
        try text.write(to: url.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        if nestedSkill {
            let nested = url.appendingPathComponent("references/nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try "---\nname: nested\ndescription: nested\n---".write(to: nested.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func directorySnapshot(_ root: URL) throws -> [String: String] {
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
    var snapshot: [String: String] = [:]
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        let data = try Data(contentsOf: url)
        snapshot[relative] = data.base64EncodedString()
    }
    return snapshot
}
