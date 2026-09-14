import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Backup maintenance regressions")
struct BackupMaintenanceRegressionTests {
    @Test("Failed recovery keeps rescue data without expiring later successful versions")
    func failedRecoveryDoesNotConsumeSuccessfulSlot() async throws {
        let f = try await BackupMaintenanceFixture.make()
        defer { f.remove() }
        let targetRoot = f.root.appendingPathComponent("Agent")
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let target = AgentTarget(kind: .custom, displayName: "Test Agent", path: targetRoot.path,
                                 detectionStatus: .available, writeStatus: .writable, isCustom: true)
        try await f.store.replaceTargets([target])
        try await f.store.replaceAssignments([.init(skillID: f.record.id, targetID: target.id, installationDirectoryName: "demo")])
        let plan = try DefaultSyncPlanner().makePlan(snapshot: await f.store.currentSnapshot(), libraryRoot: f.storeRoot)
        _ = try await TransactionalSyncExecutor().execute(plan: plan, store: f.store)
        let installed = targetRoot.appendingPathComponent("demo/guide.md")
        let interrupted = TransactionalSyncExecutor(shouldInjectFailure: { _ in
            try? "external edit".write(to: installed, atomically: true, encoding: .utf8)
            return true
        })
        let candidate = try await f.candidate("B")
        await #expect(throws: (any Error).self) {
            _ = try await SkillUpdateCoordinator(executor: interrupted).updateAndDeploy(
                skillID: f.record.id, candidate: candidate, store: f.store
            )
        }
        let failed = try #require(await f.store.currentSnapshot().transactions.first { $0.status == .failed })
        let failedArchive = f.archive(for: try #require(failed.libraryUpdate).previousRecord.fingerprint)
        let rescue = try #require(failed.backups.first?.backupRelativePath)
        let rescueURL = f.storeRoot.appendingPathComponent("Transactions/\(failed.id)/\(rescue)")
        _ = try await f.update("C")
        let latest = try await f.update("D")
        let stored = try #require(await f.store.currentSnapshot().transactions.first { $0.id == latest.id })
        #expect(stored.canRestore())
        #expect(FileManager.default.fileExists(atPath: f.archive(for: try #require(latest.libraryUpdate).previousRecord.fingerprint).path))
        #expect(FileManager.default.fileExists(atPath: failedArchive.path))
        #expect(FileManager.default.fileExists(atPath: rescueURL.path))
        _ = try await TransactionalSyncExecutor().undo(transactionID: latest.id, store: f.store)
        #expect(try String(contentsOf: f.saved.appendingPathComponent("guide.md"), encoding: .utf8) == "C")
    }

    @Test("Running rescue and the last successful destination backup are protected independently")
    func runningOperationDoesNotExpireLastSuccess() {
        let root = URL(fileURLWithPath: "/tmp/retention-running")
        let now = Date()
        let backup = TransactionBackup(destinationPath: "/tmp/test-agent/demo", backupRelativePath: "backups/0-demo",
                                       beforeFingerprint: "before", afterFingerprint: "after", actionKind: .update)
        let succeeded = SyncTransaction(createdAt: now.addingTimeInterval(-60), status: .succeeded, actions: [], backups: [backup])
        let running = SyncTransaction(createdAt: now, status: .running, actions: [], backups: [backup])
        let plan = BackupRetentionPolicy.plan(snapshot: .init(transactions: [succeeded, running]), root: root, now: now)
        #expect(plan.expiredTransactionIDs.isEmpty)
        #expect(plan.removablePaths.isEmpty)
        #expect(plan.retainedPaths.count == 2)
    }

    @Test("Successful updates expose cleanup failures across restart and clear them after retry")
    func cleanupIssueSurvivesRestartUntilSuccessfulRetry() async throws {
        let f = try await BackupMaintenanceFixture.make()
        defer { f.remove() }
        _ = try await f.update("B")
        let outside = f.root.appendingPathComponent("protected-source")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let marker = outside.appendingPathComponent("keep.txt")
        try "keep".write(to: marker, atomically: true, encoding: .utf8)
        let link = f.archive(for: String(repeating: "e", count: 64))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let result = try await f.update("C")
        #expect(result.status == .succeeded)
        #expect(try String(contentsOf: f.saved.appendingPathComponent("guide.md"), encoding: .utf8) == "C")
        let issue = try #require(await f.store.currentBackupMaintenanceIssue())
        #expect(FileManager.default.fileExists(atPath: f.storeRoot.appendingPathComponent("backup-maintenance-issue.json").path))
        let reopened = try LibraryStore(root: f.storeRoot)
        #expect(await reopened.currentBackupMaintenanceIssue() == issue)
        await #expect(throws: (any Error).self) { _ = try await reopened.pruneRollbackBackups() }
        #expect(await reopened.currentBackupMaintenanceIssue() != nil)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
        try FileManager.default.removeItem(at: link)
        _ = try await reopened.pruneRollbackBackups()
        #expect(await reopened.currentBackupMaintenanceIssue() == nil)
        let afterRetry = try LibraryStore(root: f.storeRoot)
        #expect(await afterRetry.currentBackupMaintenanceIssue() == nil)
    }

    @Test("A failure to save the cleanup warning keeps its in-memory message and original error")
    func issueSaveFailureDoesNotHideCleanupFailure() async throws {
        let f = try await BackupMaintenanceFixture.make()
        defer { f.remove() }
        _ = try await f.update("B")
        let link = f.archive(for: String(repeating: "e", count: 64))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.source)
        let store = try LibraryStore(root: f.storeRoot, fileManager: MaintenanceIssueWriteFailingFileManager())
        let candidate = try await f.candidate("C")
        let result = try await SkillUpdateCoordinator().updateCentralOnly(skillID: f.record.id, candidate: candidate, store: store)
        #expect(result.transaction?.status == .succeeded)
        let issue = try #require(await store.currentBackupMaintenanceIssue())
        #expect(issue.contains("暂时无法保存"))
        #expect(!FileManager.default.fileExists(atPath: f.storeRoot.appendingPathComponent("backup-maintenance-issue.json").path))
        do {
            _ = try await store.pruneRollbackBackups()
            Issue.record("The unsafe backup path should still fail cleanup")
        } catch FileOperationError.invalidRelativePath {
            // Keep the original cleanup error, not the warning-storage error.
        } catch {
            Issue.record("Unexpected cleanup error: \(error)")
        }
        #expect(await store.currentBackupMaintenanceIssue() != nil)
    }
}

private final class MaintenanceIssueWriteFailingFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.lastPathComponent == "backup-maintenance-issue.json" {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private struct BackupMaintenanceFixture {
    let root: URL
    let source: URL
    let storeRoot: URL
    let store: LibraryStore
    let record: SkillRecord
    let saved: URL

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxBackupMaintenance-\(UUID())")
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Backup test\n---\nRead guide.md.\n"
            .write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "A".write(to: source.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        let candidate = try #require(try await LocalFolderSourceProvider().preview(locator: source.path).first)
        let storeRoot = root.appendingPathComponent("Store")
        let store = try LibraryStore(root: storeRoot)
        let record = try await store.importCandidate(candidate)
        return .init(root: root, source: source, storeRoot: storeRoot, store: store, record: record,
                     saved: await store.contentURL(for: record))
    }

    func candidate(_ text: String) async throws -> SkillCandidate {
        try text.write(to: source.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        return try #require(try await LocalFolderSourceProvider().preview(locator: source.path).first)
    }

    func update(_ text: String) async throws -> SyncTransaction {
        let candidate = try await candidate(text)
        return try #require(try await SkillUpdateCoordinator().updateCentralOnly(
            skillID: record.id, candidate: candidate, store: store
        ).transaction)
    }

    func archive(for fingerprint: String) -> URL {
        saved.deletingLastPathComponent().appendingPathComponent("versions/\(fingerprint)")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
