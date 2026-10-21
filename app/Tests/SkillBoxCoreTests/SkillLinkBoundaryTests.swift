import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Skill links stay inside the copied content")
struct SkillLinkBoundaryTests {
    @Test("Risk analysis and copying reject the same external target", arguments: ["absolute", "relative", "chain", "cycle"])
    func externalLinksAreRejected(kind: String) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("SkillBoxLink-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let skill = root.appendingPathComponent("skill"), outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: skill, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try "safe".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "protected".write(to: outside.appendingPathComponent("data"), atomically: true, encoding: .utf8)
        let target: String
        if kind == "chain" {
            try fm.createSymbolicLink(atPath: skill.appendingPathComponent("bridge").path, withDestinationPath: outside.path)
            target = "bridge/data"
        } else if kind == "cycle" { target = "link" }
        else { target = kind == "absolute" ? outside.path : "../outside" }
        try fm.createSymbolicLink(atPath: skill.appendingPathComponent("link").path, withDestinationPath: target)
        #expect(try StaticRiskAnalyzer().analyze(skillDirectory: skill).isBlocked)
        let destination = root.appendingPathComponent("destination")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try "existing".write(to: destination.appendingPathComponent("sentinel"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try SafeFileOperations.copyDirectory(from: skill, to: destination) }
        #expect(try String(contentsOf: destination.appendingPathComponent("sentinel"), encoding: .utf8) == "existing")
        #expect(try String(contentsOf: outside.appendingPathComponent("data"), encoding: .utf8) == "protected")
    }

    @Test("Relative internal links remain portable through a directory alias")
    func internalLinkSurvivesCopyThroughAlias() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("SkillBoxInternalLink-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let skill = root.appendingPathComponent("skill")
        try fm.createDirectory(at: skill, withIntermediateDirectories: true)
        try "safe".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: skill.appendingPathComponent("link").path, withDestinationPath: "SKILL.md")
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: skill)
        #expect(try !StaticRiskAnalyzer().analyze(skillDirectory: alias).isBlocked)
        let copy = root.appendingPathComponent("copy")
        try SafeFileOperations.copyDirectory(from: alias, to: copy)
        #expect(try fm.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("link").path) == "SKILL.md")
        #expect(try String(contentsOf: copy.appendingPathComponent("link"), encoding: .utf8) == "safe")
    }

    @Test("An absolute internal link cannot become an external pointer when relocated")
    func absoluteInternalLinkCannotEscapeAfterCopy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("SkillBoxAbsoluteInternal-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let skill = root.appendingPathComponent("skill")
        try fm.createDirectory(at: skill, withIntermediateDirectories: true)
        try "safe".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: skill.appendingPathComponent("link"), withDestinationURL: skill.appendingPathComponent("SKILL.md"))
        let copy = root.appendingPathComponent("copy")
        #expect(throws: (any Error).self) { try SafeFileOperations.copyDirectory(from: skill, to: copy) }
        #expect(!fm.fileExists(atPath: copy.path))
    }

    @Test("A normal local import and deployment preserve a portable internal link")
    func normalLocalFlowPreservesInternalLink() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SkillBoxLocalLinkFlow-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: linked-demo\ndescription: Demo\n---\nRead guide.md.".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "guide".write(to: source.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("guide-link").path, withDestinationPath: "guide.md")
        let original = try SHA256SkillFingerprinter().fingerprint(directory: source)
        let candidate = try #require(try await LocalFolderSourceProvider().preview(locator: source.path).first)
        let resolver = LocalSkillPackageResolver()
        let review = try resolver.review(candidate: candidate, projectRoot: source)
        let package = try await resolver.confirm(review: review, includePaths: review.recommendedIncludePaths)
        defer { if let temporary = package.candidate.temporaryPackageRoot { try? fm.removeItem(at: temporary) } }
        #expect(!package.candidate.riskReport.isBlocked)
        let storeRoot = root.appendingPathComponent("Store")
        let store = try LibraryStore(root: storeRoot)
        let record = try await store.importCandidate(package.candidate)
        let targetRoot = root.appendingPathComponent("Agent")
        try fm.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let target = AgentTarget(kind: .custom, displayName: "Fixture", path: targetRoot.path, detectionStatus: .available, writeStatus: .writable, isCustom: true)
        try await store.replaceTargets([target])
        try await store.replaceAssignments([.init(skillID: record.id, targetID: target.id, installationDirectoryName: "linked-demo")])
        let plan = try DefaultSyncPlanner().makePlan(snapshot: await store.currentSnapshot(), libraryRoot: storeRoot)
        let installed = try await TransactionalSyncExecutor().execute(plan: plan, store: store)
        #expect(installed.status == .succeeded)
        #expect(try String(contentsOf: targetRoot.appendingPathComponent("linked-demo/guide-link"), encoding: .utf8) == "guide")
        #expect(try SHA256SkillFingerprinter().fingerprint(directory: source) == original)
    }
}
