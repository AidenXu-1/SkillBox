import Foundation
import SkillBoxCore
import Testing
@testable import SkillBoxApp

@MainActor
@Suite("Consumer closure flow")
struct ConsumerClosureFlowTests {
    @Test("Risk acknowledgement survives relaunch and expires when content or evidence changes")
    func riskAcknowledgementFollowsExactContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBoxConsumerClosureTests-\(UUID().uuidString)")
        let suiteName = "SkillBoxConsumerClosureTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let skill = highRiskSkill(fingerprint: "content-v1", evidence: "LaunchAgents")
        let model = AppModel(
            libraryRoot: root,
            homeDirectory: root.appendingPathComponent("home"),
            userDefaults: defaults,
            startBootstrap: false
        )

        #expect(model.needsRiskAcknowledgement(for: skill))
        model.acknowledgeRisk(for: skill)
        #expect(!model.needsRiskAcknowledgement(for: skill))

        let relaunched = AppModel(
            libraryRoot: root,
            homeDirectory: root.appendingPathComponent("home"),
            userDefaults: defaults,
            startBootstrap: false
        )
        #expect(!relaunched.needsRiskAcknowledgement(for: skill))

        let changedContent = highRiskSkill(id: skill.id, fingerprint: "content-v2", evidence: "LaunchAgents")
        #expect(relaunched.needsRiskAcknowledgement(for: changedContent))

        let changedEvidence = highRiskSkill(id: skill.id, fingerprint: "content-v1", evidence: "LaunchDaemons")
        #expect(relaunched.needsRiskAcknowledgement(for: changedEvidence))
    }

    @Test("The bulk-install boundary refuses a high-risk Skill until its current content is acknowledged")
    func installBoundaryRequiresRiskAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBoxRiskInstallBoundaryTests-\(UUID().uuidString)")
        let suiteName = "SkillBoxRiskInstallBoundaryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let skill = highRiskSkill(fingerprint: "content-v1", evidence: "LaunchAgents")
        let targetRoot = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        try writeSkill(at: root.appendingPathComponent(skill.contentRelativePath, isDirectory: true))
        let target = AgentTarget(
            kind: .custom,
            displayName: "Test App",
            path: targetRoot.path,
            detectionStatus: .available,
            writeStatus: .writable,
            isCustom: true
        )
        let model = AppModel(
            libraryRoot: root,
            homeDirectory: root.appendingPathComponent("home"),
            userDefaults: defaults,
            startBootstrap: false
        )
        model.snapshot = LibrarySnapshot(skills: [skill], targets: [target])

        let preparedBeforeAcknowledgement = await model.prepareInstallEverywhere(skill)
        #expect(!preparedBeforeAcknowledgement)
        #expect(model.noticeMessage?.contains("了解") == true)

        model.acknowledgeRisk(for: skill)
        let preparedAfterAcknowledgement = await model.prepareInstallEverywhere(skill)
        #expect(preparedAfterAcknowledgement)
    }

    @Test("Cancelling an install preview leaves saved assignments and app folders unchanged")
    func cancellingInstallPreviewDoesNotPersistDraft() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBoxInstallPreviewTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/demo", isDirectory: true)
        let targetRoot = root.appendingPathComponent("target", isDirectory: true)
        try writeSkill(at: source)
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)

        let store = try LibraryStore(root: root.appendingPathComponent("store"))
        let record = try await store.importCandidate(SkillCandidate(
            sourceURL: source,
            directoryName: "demo",
            canonicalName: "demo",
            displayName: "Demo",
            description: "Test demo",
            fingerprint: try SHA256SkillFingerprinter().fingerprint(directory: source),
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
        let model = AppModel(
            libraryRoot: root.appendingPathComponent("store"),
            store: store,
            homeDirectory: root.appendingPathComponent("home"),
            startBootstrap: false
        )
        await model.reload()

        #expect(await store.currentSnapshot().assignments.isEmpty)
        #expect(await model.prepareInstallEverywhere(record))
        #expect(model.syncPlan?.actions.contains { $0.skillID == record.id && $0.kind == .create } == true)
        #expect(await store.currentSnapshot().assignments.isEmpty)

        model.cancelSyncPreview()

        #expect(await store.currentSnapshot().assignments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: targetRoot.appendingPathComponent("demo").path))
    }

    @Test("Approving a replacement inside preview is also discarded when preview is cancelled")
    func cancellingPreviewDiscardsReplacementAuthorization() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBoxReplacementPreviewTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/demo", isDirectory: true)
        let targetRoot = root.appendingPathComponent("target", isDirectory: true)
        let destination = targetRoot.appendingPathComponent("demo", isDirectory: true)
        try writeSkill(at: source, body: "central")
        try writeSkill(at: destination, body: "foreign")

        let store = try LibraryStore(root: root.appendingPathComponent("store"))
        let record = try await store.importCandidate(SkillCandidate(
            sourceURL: source,
            directoryName: "demo",
            canonicalName: "demo",
            displayName: "Demo",
            description: "Test demo",
            fingerprint: try SHA256SkillFingerprinter().fingerprint(directory: source),
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
        let model = AppModel(
            libraryRoot: root.appendingPathComponent("store"),
            store: store,
            homeDirectory: root.appendingPathComponent("home"),
            startBootstrap: false
        )
        await model.reload()

        #expect(await model.prepareInstallEverywhere(record))
        let blocked = try #require(model.syncPlan?.actions.first { $0.blockReason == .unmanagedConflict })
        await model.authorize(action: blocked, replacement: true)

        #expect(await store.currentSnapshot().assignments.isEmpty)
        #expect(try String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8).contains("foreign"))

        model.cancelSyncPreview()

        #expect(await store.currentSnapshot().assignments.isEmpty)
        #expect(try String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8).contains("foreign"))
    }

    @Test("Opening and cancelling restore preview does not touch files; confirming does")
    func undoRequiresConfirmedPreview() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBoxUndoPreviewTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/demo", isDirectory: true)
        let targetRoot = root.appendingPathComponent("target", isDirectory: true)
        let destination = targetRoot.appendingPathComponent("demo", isDirectory: true)
        let storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try writeSkill(at: source)
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)

        let store = try LibraryStore(root: storeRoot)
        let record = try await store.importCandidate(SkillCandidate(
            sourceURL: source,
            directoryName: "demo",
            canonicalName: "demo",
            displayName: "Demo",
            description: "Test demo",
            fingerprint: try SHA256SkillFingerprinter().fingerprint(directory: source),
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
        let plan = try DefaultSyncPlanner().makePlan(snapshot: await store.currentSnapshot(), libraryRoot: storeRoot)
        let transaction = try await TransactionalSyncExecutor().execute(plan: plan, store: store)
        #expect(FileManager.default.fileExists(atPath: destination.path))

        let model = AppModel(
            libraryRoot: storeRoot,
            store: store,
            homeDirectory: root.appendingPathComponent("home"),
            startBootstrap: false
        )
        await model.reload()

        #expect(model.prepareUndoPreview(transaction))
        #expect(model.pendingUndoTransaction?.id == transaction.id)
        #expect(FileManager.default.fileExists(atPath: destination.path))

        model.cancelUndoPreview()
        #expect(model.pendingUndoTransaction == nil)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(await store.currentSnapshot().transactions.first { $0.id == transaction.id }?.status == .succeeded)

        #expect(model.prepareUndoPreview(transaction))
        await model.confirmPendingUndo()

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(await store.currentSnapshot().transactions.first { $0.id == transaction.id }?.status == .undone)
    }

    private func highRiskSkill(
        id: UUID = UUID(),
        fingerprint: String,
        evidence: String
    ) -> SkillRecord {
        SkillRecord(
            id: id,
            canonicalName: "agent-team",
            displayName: "agent-team",
            description: "Team workflow",
            fingerprint: fingerprint,
            source: .init(kind: .localFolder, displayName: "Fixture", locator: "/fixture"),
            riskReport: .init(
                scannedFileCount: 2,
                findings: [
                    .init(
                        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                        severity: .high,
                        category: .privilege,
                        relativePath: "scripts/scaffold_team.py",
                        title: "Privilege request",
                        evidence: evidence
                    ),
                ]
            ),
            contentRelativePath: "Library/agent-team/content"
        )
    }

    private func writeSkill(at url: URL, body: String = "Demo") throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Test\n---\n\n\(body)\n"
            .write(to: url.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }
}
