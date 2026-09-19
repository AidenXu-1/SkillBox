import Foundation
import SkillBoxCore
import Testing
@testable import SkillBoxApp

@Suite("Installation refresh and responsiveness")
struct InstallationResponsivenessTests {
    @MainActor
    @Test("Update details read destination then central content without changing installation")
    func updateDetailsAreReadOnlyAndDirectional() async throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let skill = try await store.importCandidate(fixture.candidate("comparison"))
        let target = try fixture.target("Example app")
        try await store.replaceTargets([target])
        let destination = URL(fileURLWithPath: target.path).appendingPathComponent(skill.canonicalName)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let old = "---\nname: comparison\ndescription: Old\n---\nOld app content.\n"
        try old.write(to: destination.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let model = AppModel(libraryRoot: fixture.storeRoot, store: store, homeDirectory: fixture.root, startBootstrap: false)
        await model.reload()
        let proposal = try #require(await model.prepareAssignmentProposal(skill: skill, target: target))
        #expect(proposal.hasDifferentExistingContent)
        let snapshot = model.snapshot
        let pair = await model.assignmentMarkdown(proposal)
        #expect(pair.0 == old)
        #expect(pair.1?.contains("Safe text.") == true)
        #expect(model.snapshot.assignments == snapshot.assignments)
        #expect(model.snapshot.installations == snapshot.installations)
        #expect(try String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8) == old)
    }

    @MainActor
    @Test("Startup detects applications without discovering their installed Skill contents")
    func startupDoesNotDiscoverInstalledCopies() async throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let existing = fixture.root.appendingPathComponent(".claude/skills/foreign-skill")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try "---\nname: foreign-skill\ndescription: Existing third party copy\n---\n".write(
            to: existing.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        let model = AppModel(libraryRoot: fixture.storeRoot, homeDirectory: fixture.root, startBootstrap: false)
        await model.bootstrap()
        #expect(model.snapshot.targets.contains { $0.kind == .claudeCode && $0.detectionStatus == .available })
        #expect(model.scanResult?.candidates.isEmpty == true)
        #expect(model.snapshot.skills.isEmpty)
        #expect(model.errorMessage == nil)
        #expect(!model.isBusy)
        #expect(FileManager.default.fileExists(atPath: existing.appendingPathComponent("SKILL.md").path))
    }

    @MainActor
    @Test("Single install and uninstall only compare the selected copy, off the UI thread")
    func singleOperationsStayScopedAndFinish() async throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let skill = try await store.importCandidate(fixture.candidate("selected"))
        let other = try await store.importCandidate(fixture.candidate("unrelated"))
        let target = try fixture.target("Selected app")
        let otherTarget = try fixture.target("Other app")
        try await store.replaceTargets([target, otherTarget])
        let otherAssignment = Assignment(skillID: other.id, targetID: otherTarget.id, installationDirectoryName: other.canonicalName)
        try await store.replaceAssignments([otherAssignment])
        let probe = PlanningProbe()
        let model = AppModel(libraryRoot: fixture.storeRoot, store: store, planner: probe, homeDirectory: fixture.root, startBootstrap: false)
        await model.reload()
        probe.reset()

        let proposal = try #require(await model.prepareAssignmentProposal(skill: skill, target: target))
        #expect(await model.confirmAssignmentProposal(proposal))
        #expect(!model.isBusy)
        let destination = URL(fileURLWithPath: target.path).appendingPathComponent(skill.canonicalName)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("SKILL.md").path))
        #expect(model.snapshot.installations.count == 1)
        #expect(model.snapshot.assignments.contains(otherAssignment))
        #expect(model.syncPlan?.actions.contains { $0.skillID == other.id && $0.kind == .create } == true)
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: otherTarget.path).appendingPathComponent(other.canonicalName).path))

        let removal = try #require(await model.prepareAssignmentProposal(skill: skill, target: target))
        #expect(await model.confirmAssignmentProposal(removal))
        #expect(!model.isBusy)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(model.snapshot.installations.isEmpty)
        #expect(!probe.reads.isEmpty)
        #expect(probe.reads.allSatisfy { !$0.onMainThread && $0.skillIDs.allSatisfy { $0 == skill.id } })
        #expect(model.statusMessage.contains("已从"))
    }

    @MainActor
    @Test("Organizing the list does not compare installed files again")
    func organizingDoesNotReplanInstallations() async throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let skill = try await store.importCandidate(fixture.candidate("demo"))
        let probe = PlanningProbe()
        let model = AppModel(libraryRoot: fixture.storeRoot, store: store, planner: probe, homeDirectory: fixture.root, startBootstrap: false)
        await model.reload()
        probe.reset()
        #expect(await model.createSkillFolder(named: "Writing"))
        let folder = try #require(model.orderedFolders().first)
        await model.moveSkill(skill.id, to: folder.id)
        #expect(model.orderedSkills(in: folder.id).map(\.id) == [skill.id])
        #expect(await store.currentSnapshot().organization == model.snapshot.organization)
        #expect(probe.reads.isEmpty)
    }
}

private final class PlanningProbe: SyncPlanner, @unchecked Sendable {
    struct Read { var skillIDs: [UUID]; var onMainThread: Bool }
    private let lock = NSLock()
    private var recorded: [Read] = []
    var reads: [Read] { lock.withLock { recorded } }
    func reset() { lock.withLock { recorded = [] } }
    func makePlan(snapshot: LibrarySnapshot, libraryRoot: URL) throws -> SyncPlan {
        lock.withLock {
            recorded.append(Read(skillIDs: snapshot.assignments.map(\.skillID) + snapshot.installations.map(\.skillID), onMainThread: Thread.isMainThread))
        }
        return try DefaultSyncPlanner().makePlan(snapshot: snapshot, libraryRoot: libraryRoot)
    }
}

private struct InstallationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxInstallation-\(UUID().uuidString)")
    var storeRoot: URL { root.appendingPathComponent("store") }
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func target(_ name: String) throws -> AgentTarget {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return .init(kind: .custom, displayName: name, path: path.path, detectionStatus: .available, writeStatus: .writable, isCustom: true)
    }
    func candidate(_ name: String) throws -> SkillCandidate {
        let path = root.appendingPathComponent("source/\(name)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: Example\n---\nSafe text.\n".write(to: path.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return .init(sourceURL: path, directoryName: name, canonicalName: name, displayName: name, description: "Example", fingerprint: try SHA256SkillFingerprinter().fingerprint(directory: path), source: .init(kind: .localFolder, displayName: "Fixture", locator: path.path), riskReport: try StaticRiskAnalyzer().analyze(skillDirectory: path))
    }
}
