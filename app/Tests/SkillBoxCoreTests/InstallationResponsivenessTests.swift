import Foundation
import SkillBoxCore
import Testing
@testable import SkillBoxApp

@Suite("Installation refresh and responsiveness")
struct InstallationResponsivenessTests {
    @MainActor
    @Test("Finder metadata alone never becomes an installation update or conflict")
    func finderMetadataDoesNotBlockManagedCopy() async throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let candidate = try fixture.candidate("finder")
        let skill = try await store.importCandidate(candidate)
        let target = try fixture.target("App")
        try await store.replaceTargets([target])
        let model = AppModel(libraryRoot: fixture.storeRoot, store: store, homeDirectory: fixture.root, startBootstrap: false)
        await model.reload()
        let proposal = try #require(await model.prepareAssignmentProposal(skill: skill, target: target))
        #expect(await model.confirmAssignmentProposal(proposal))
        let destination = URL(fileURLWithPath: target.path).appendingPathComponent(skill.canonicalName)
        try "Finder window state".write(to: destination.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        await model.reload()
        #expect(model.syncPlan?.actions.first?.kind == .noChange)
        #expect(try String(contentsOf: destination.appendingPathComponent(".DS_Store"), encoding: .utf8) == "Finder window state")
        try "Finder changed again after refresh".write(to: destination.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        let second = try #require(await model.prepareAssignmentProposal(skill: skill, target: target))
        #expect(second.action?.kind == .remove)
    }

    @MainActor
    @Test("Edited managed copies can be compared and explicitly replaced", arguments: ["unchanged", "edited", "deleted", "moved"])
    func editedManagedCopyReplacement(changeAfterPreview: String) async throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let skill = try await store.importCandidate(fixture.candidate("edited"))
        let target = try fixture.target("App")
        try await store.replaceTargets([target])
        let model = AppModel(libraryRoot: fixture.storeRoot, store: store, homeDirectory: fixture.root, startBootstrap: false)
        await model.reload()
        let initial = try #require(await model.prepareAssignmentProposal(skill: skill, target: target))
        #expect(await model.confirmAssignmentProposal(initial))
        let destination = URL(fileURLWithPath: target.path).appendingPathComponent(skill.canonicalName).appendingPathComponent("SKILL.md")
        let edited = "Edited locally, keep until explicit confirmation."
        try edited.write(to: destination, atomically: true, encoding: .utf8)
        await model.reload()
        let proposal = try #require(await model.prepareAssignmentProposal(skill: skill, target: target))
        #expect(proposal.hasDifferentExistingContent)
        #expect(proposal.changes.contains { $0.path == "SKILL.md" && $0.kind == .modified })
        #expect(try String(contentsOf: destination, encoding: .utf8) == edited)
        let pair = await model.assignmentMarkdown(proposal)
        #expect(pair.0 == edited && pair.1?.contains("Safe text.") == true)
        if changeAfterPreview == "deleted" || changeAfterPreview == "moved" {
            let directory = destination.deletingLastPathComponent()
            if changeAfterPreview == "deleted" {
                try FileManager.default.removeItem(at: directory)
            } else {
                var movedTarget = target
                movedTarget.path = try fixture.target("Other location").path
                try await store.replaceTargets([movedTarget])
            }
            let transactions = await store.currentSnapshot().transactions
            #expect(await model.confirmAssignmentProposal(proposal) == false)
            #expect(await store.currentSnapshot().transactions == transactions)
            if changeAfterPreview == "deleted" {
                #expect(!FileManager.default.fileExists(atPath: directory.path))
            } else {
                #expect(try String(contentsOf: destination, encoding: .utf8) == edited)
                #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Other location/edited").path))
            }
        } else if changeAfterPreview == "edited" {
            try "Changed again".write(to: destination, atomically: true, encoding: .utf8)
            #expect(await model.confirmAssignmentProposal(proposal) == false)
            #expect(try String(contentsOf: destination, encoding: .utf8) == "Changed again")
        } else {
            #expect(await model.confirmAssignmentProposal(proposal))
            #expect(try String(contentsOf: destination, encoding: .utf8).contains("Safe text."))
            let snapshot = await store.currentSnapshot()
            let transaction = try #require(snapshot.transactions.first { $0.actions.contains { $0.kind == .update } })
            _ = try await TransactionalSyncExecutor().undo(transactionID: transaction.id, store: store)
            #expect(try String(contentsOf: destination, encoding: .utf8) == edited)
            await model.reload()
            #expect(model.syncPlan?.actions.first?.blockReason == .externalModification)
            #expect(model.snapshot.assignments.first?.allowReplacement == false)
        }
    }

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
