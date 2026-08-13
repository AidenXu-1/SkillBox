import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Central library")
struct LibraryStoreTests {
    @Test("Import copies a verified candidate and persists schema envelopes")
    func importAndReload() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let candidate = try fixture.candidate(name: "demo", body: "original")
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(candidate)

        #expect(FileManager.default.fileExists(atPath: fixture.storeRoot.appendingPathComponent(record.contentRelativePath).appendingPathComponent("SKILL.md").path))
        let catalogData = try Data(contentsOf: fixture.storeRoot.appendingPathComponent("catalog.json"))
        let json = try #require(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 1)

        let reloaded = try LibraryStore(root: fixture.storeRoot)
        #expect(await reloaded.currentSnapshot().skills.count == 1)
    }

    @Test("Blocked candidates never enter the library")
    func blockedImport() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        var candidate = try fixture.candidate(name: "blocked", body: "body")
        candidate.riskReport = RiskReport(scannedFileCount: 1, findings: [.init(severity: .blocked, category: .pathEscape, relativePath: "x", title: "blocked", evidence: "x")])
        let store = try LibraryStore(root: fixture.storeRoot)
        await #expect(throws: LibraryStoreError.self) { try await store.importCandidate(candidate) }
        #expect(await store.currentSnapshot().skills.isEmpty)
    }

    @Test("GitHub-style updates archive the prior central version")
    func updateArchivesOldContent() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let original = try await store.importCandidate(fixture.candidate(name: "demo", body: "v1"))
        try FileManager.default.removeItem(at: fixture.sourceRoot.appendingPathComponent("demo"))
        let updatedCandidate = try fixture.candidate(name: "demo", body: "v2")
        let updated = try await store.updateSkill(id: original.id, with: updatedCandidate)
        #expect(updated.id == original.id)
        #expect(updated.fingerprint != original.fingerprint)
        let archived = fixture.storeRoot.appendingPathComponent("Library/\(original.id.uuidString)/versions/\(original.fingerprint)/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: archived.path))
    }

    @Test("Corrupt metadata is preserved instead of overwritten")
    func corruptMetadataRecovery() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.storeRoot, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fixture.storeRoot.appendingPathComponent("catalog.json"))
        let store = try LibraryStore(root: fixture.storeRoot)
        #expect(await store.currentSnapshot().skills.isEmpty)
        let recoveryWarnings = await store.recoveryWarnings
        #expect(recoveryWarnings.count == 1)
        let recovered = try FileManager.default.contentsOfDirectory(at: fixture.storeRoot.appendingPathComponent("CorruptData"), includingPropertiesForKeys: nil)
        #expect(recovered.contains { $0.lastPathComponent.hasSuffix("catalog.json") })
    }

    @Test("Two desired versions cannot share one Agent destination")
    func duplicateDestination() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let targetID = UUID()
        await #expect(throws: LibraryStoreError.self) {
            try await store.replaceAssignments([
                .init(skillID: UUID(), targetID: targetID, installationDirectoryName: "Demo"),
                .init(skillID: UUID(), targetID: targetID, installationDirectoryName: "demo"),
            ])
        }
    }
}

@Suite("Transactional sync")
struct SyncTests {
    @Test("Plan, execute and undo preserve ownership boundaries")
    func executeAndUndo() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        let targetRoot = fixture.root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let target = AgentTarget(kind: .custom, displayName: "Test", path: targetRoot.path, detectionStatus: .available, writeStatus: .writable, isCustom: true)
        try await store.replaceTargets([target])
        try await store.replaceAssignments([.init(skillID: record.id, targetID: target.id, installationDirectoryName: "demo")])

        let planner = DefaultSyncPlanner()
        let plan = try planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot)
        #expect(plan.actions.map(\.kind) == [.create])
        let executor = TransactionalSyncExecutor()
        let transaction = try await executor.execute(plan: plan, store: store)
        let installed = targetRoot.appendingPathComponent("demo")
        #expect(transaction.status == .succeeded)
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("SKILL.md").path))
        #expect(await store.currentSnapshot().installations.count == 1)

        let undone = try await executor.undo(transactionID: transaction.id, store: store)
        #expect(undone.status == .undone)
        #expect(!FileManager.default.fileExists(atPath: installed.path))
        #expect(await store.currentSnapshot().installations.isEmpty)
    }

    @Test("Unmanaged conflicts and external modifications block writes and undo")
    func conflictsAndDrift() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        let targetRoot = fixture.root.appendingPathComponent("target")
        let destination = try fixture.writeSkill(at: targetRoot.appendingPathComponent("demo"), name: "demo", body: "foreign")
        let target = AgentTarget(kind: .custom, displayName: "Test", path: targetRoot.path, detectionStatus: .available, writeStatus: .writable, isCustom: true)
        try await store.replaceTargets([target])
        try await store.replaceAssignments([.init(skillID: record.id, targetID: target.id, installationDirectoryName: "demo")])
        let planner = DefaultSyncPlanner()
        var plan = try planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot)
        #expect(plan.actions.first?.blockReason == .unmanagedConflict)

        try FileManager.default.removeItem(at: destination)
        plan = try planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot)
        let executor = TransactionalSyncExecutor()
        let transaction = try await executor.execute(plan: plan, store: store)
        try "external".write(to: destination.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: SyncExecutorError.self) { try await executor.undo(transactionID: transaction.id, store: store) }
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("extra.txt").path))

        let driftPlan = try planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot)
        #expect(driftPlan.actions.contains { $0.blockReason == .externalModification })
    }

    @Test("Replacement permission is bound to the previewed fingerprint")
    func replacementAuthorizationExpiresWhenTargetChanges() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        let targetRoot = fixture.root.appendingPathComponent("target")
        let destination = try fixture.writeSkill(at: targetRoot.appendingPathComponent("demo"), name: "demo", body: "foreign-v1")
        let target = AgentTarget(kind: .custom, displayName: "Test", path: targetRoot.path, detectionStatus: .available, writeStatus: .writable, isCustom: true)
        let authorizedFingerprint = try SHA256SkillFingerprinter().fingerprint(directory: destination)
        try await store.replaceTargets([target])
        try await store.replaceAssignments([.init(
            skillID: record.id,
            targetID: target.id,
            installationDirectoryName: "demo",
            allowReplacement: true,
            authorizedDestinationFingerprint: authorizedFingerprint
        )])
        let planner = DefaultSyncPlanner()
        var plan = try planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot)
        #expect(plan.actions.first?.kind == .update)

        try "changed after confirmation".write(to: destination.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        plan = try planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot)
        #expect(plan.actions.first?.kind == .blocked)
        #expect(plan.actions.first?.blockReason == .unmanagedConflict)
    }

    @Test("A mid-transaction failure restores every completed target")
    func injectedFailureRollsBackCompletedTargets() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        var targets: [AgentTarget] = []
        for index in 1...3 {
            let root = fixture.root.appendingPathComponent("target-\(index)")
            targets.append(.init(
                kind: .custom,
                displayName: "Target \(index)",
                path: root.path,
                detectionStatus: .directoryMissing,
                writeStatus: .directoryMissing,
                isCustom: true
            ))
        }
        try await store.replaceTargets(targets)
        try await store.replaceAssignments(targets.map {
            .init(skillID: record.id, targetID: $0.id, installationDirectoryName: "demo")
        })
        let plan = try DefaultSyncPlanner().makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot)
        let executor = TransactionalSyncExecutor(shouldInjectFailure: { $0 == 2 })
        await #expect(throws: SyncExecutorError.self) {
            try await executor.execute(plan: plan, store: store)
        }

        for target in targets {
            #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: target.path).appendingPathComponent("demo").path))
        }
        let snapshot = await store.currentSnapshot()
        #expect(snapshot.installations.isEmpty)
        #expect(snapshot.transactions.first?.status == .rolledBack)
    }
}

private struct SyncFixture {
    let root: URL
    var sourceRoot: URL { root.appendingPathComponent("source") }
    var storeRoot: URL { root.appendingPathComponent("store") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func candidate(name: String, body: String) throws -> SkillCandidate {
        let url = try writeSkill(at: sourceRoot.appendingPathComponent(name), name: name, body: body)
        let risk = try StaticRiskAnalyzer().analyze(skillDirectory: url)
        return SkillCandidate(
            sourceURL: url,
            directoryName: name,
            canonicalName: name,
            displayName: name,
            description: "Test \(name)",
            fingerprint: try SHA256SkillFingerprinter().fingerprint(directory: url),
            source: .init(kind: .localFolder, displayName: "Fixture", locator: url.path),
            riskReport: risk
        )
    }

    func writeSkill(at url: URL, name: String, body: String) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: Test\n---\n\n\(body)\n".write(to: url.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
