import Foundation
import SkillBoxCore
import Testing
@testable import SkillBoxApp

@MainActor
@Suite("Skill removal flow")
struct SkillRemovalFlowTests {
    @Test("Uninstall-all prepares the existing transaction preview without deleting the central Skill")
    func uninstallAllWaitsForConfirmedPlan() async throws {
        let fixture = try await makeManagedSkill()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = AppModel(
            libraryRoot: fixture.root.appendingPathComponent("store"),
            store: fixture.store,
            homeDirectory: fixture.root.appendingPathComponent("home"),
            startBootstrap: false
        )
        await model.reload()

        let shouldPreview = await model.prepareUninstallEverywhere(fixture.record, deletingAfterwards: true)
        let hasRemovalAction = model.syncPlan?.actions.contains {
            $0.skillID == fixture.record.id && $0.kind == .remove
        } == true

        #expect(shouldPreview)
        #expect(model.pendingDeletionAfterSyncSkillID == fixture.record.id)
        #expect(hasRemovalAction)
        #expect(await fixture.store.currentSnapshot().skills.map(\.id) == [fixture.record.id])
        #expect(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test("Confirmed uninstall-all clears the central Skill only after managed copies are removed")
    func confirmedUninstallAllCompletesDeletion() async throws {
        let fixture = try await makeManagedSkill()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = AppModel(
            libraryRoot: fixture.root.appendingPathComponent("store"),
            store: fixture.store,
            homeDirectory: fixture.root.appendingPathComponent("home"),
            startBootstrap: false
        )
        await model.reload()
        let prepared = await model.prepareUninstallEverywhere(fixture.record, deletingAfterwards: true)
        #expect(prepared)
        #expect(await fixture.store.currentSnapshot().skills.map(\.id) == [fixture.record.id])

        await model.executePlan()

        let snapshot = await fixture.store.currentSnapshot()
        #expect(snapshot.skills.isEmpty)
        #expect(snapshot.installations.isEmpty)
        #expect(snapshot.assignments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(model.pendingDeletionAfterSyncSkillID == nil)
        #expect(model.lastDeletedSkill?.record.id == fixture.record.id)
    }

    @Test("Central-only removal clears a stale row without touching its same-name replacement")
    func centralOnlyRemovalClearsStaleSameNameRow() async throws {
        let fixture = try await makeManagedSkill()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(
            at: await fixture.store.contentURL(for: fixture.record).deletingLastPathComponent()
        )
        let replacementSource = fixture.root.appendingPathComponent("source/demo", isDirectory: true)
        try writeSkill(at: replacementSource, body: "replacement")
        let replacement = try await fixture.store.importCandidate(SkillCandidate(
            sourceURL: replacementSource,
            directoryName: "demo",
            canonicalName: "demo",
            displayName: "Demo",
            description: "Test demo",
            fingerprint: try SHA256SkillFingerprinter().fingerprint(directory: replacementSource),
            source: .init(kind: .localFolder, displayName: "Replacement", locator: replacementSource.path),
            riskReport: try StaticRiskAnalyzer().analyze(skillDirectory: replacementSource)
        ))
        let model = AppModel(
            libraryRoot: fixture.root.appendingPathComponent("store"),
            store: fixture.store,
            homeDirectory: fixture.root.appendingPathComponent("home"),
            startBootstrap: false
        )
        await model.reload()

        let deleted = await model.deleteSkill(fixture.record, preservingInstalledCopies: true)

        let snapshot = await fixture.store.currentSnapshot()
        let replacementContent = await fixture.store.contentURL(for: replacement)
        #expect(deleted)
        #expect(model.snapshot.skills.map(\.id) == [replacement.id])
        #expect(snapshot.skills.map(\.id) == [replacement.id])
        #expect(snapshot.installations.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: replacementContent.appendingPathComponent("SKILL.md").path))
        #expect(model.lastDeletedSkill == nil)
        #expect(model.statusMessage.contains("失效记录"))
    }

    private func makeManagedSkill() async throws -> (
        root: URL,
        store: LibraryStore,
        record: SkillRecord,
        destination: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBoxRemovalFlowTests-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source/demo", isDirectory: true)
        let targetRoot = root.appendingPathComponent("target", isDirectory: true)
        let destination = targetRoot.appendingPathComponent("demo", isDirectory: true)
        try writeSkill(at: source, body: "central")
        try writeSkill(at: destination, body: "central")

        let fingerprinter = SHA256SkillFingerprinter()
        let store = try LibraryStore(root: root.appendingPathComponent("store"))
        let record = try await store.importCandidate(SkillCandidate(
            sourceURL: source,
            directoryName: "demo",
            canonicalName: "demo",
            displayName: "Demo",
            description: "Test demo",
            fingerprint: try fingerprinter.fingerprint(directory: source),
            source: .init(kind: .localFolder, displayName: "Fixture", locator: source.path),
            riskReport: try StaticRiskAnalyzer().analyze(skillDirectory: source)
        ))
        let target = AgentTarget(
            kind: .custom,
            displayName: "Test App",
            path: targetRoot.path,
            detectionStatus: .available,
            writeStatus: .writable,
            isCustom: true
        )
        try await store.replaceTargets([target])
        try await store.replaceAssignments([
            .init(skillID: record.id, targetID: target.id, installationDirectoryName: "demo"),
        ])
        try await store.replaceInstallations([
            .init(
                skillID: record.id,
                targetID: target.id,
                destinationPath: destination.path,
                deployedFingerprint: try fingerprinter.fingerprint(directory: destination),
                transactionID: UUID()
            ),
        ])
        return (root, store, record, destination)
    }

    private func writeSkill(at url: URL, body: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Test\n---\n\n\(body)\n"
            .write(to: url.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }
}
