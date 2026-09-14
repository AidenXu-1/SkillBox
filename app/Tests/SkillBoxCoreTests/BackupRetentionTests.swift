import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Rollback backup retention")
struct BackupRetentionTests {
    @Test("Successive updates keep only one previous central version and expire older undo records")
    func onlyPreviousVersionRemains() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        let first = try await update(f, text: "version two")
        let second = try await update(f, text: "version three")
        let snapshot = await f.store.currentSnapshot()
        #expect(snapshot.transactions.first { $0.id == first.id }?.backupsExpiredAt != nil)
        #expect(snapshot.transactions.first { $0.id == second.id }?.backupsExpiredAt == nil)
        let versions = f.saved.deletingLastPathComponent().appendingPathComponent("versions")
        #expect(try FileManager.default.contentsOfDirectory(atPath: versions.path) == [second.libraryUpdate!.previousRecord.fingerprint])
        #expect(try String(contentsOf: f.saved.appendingPathComponent("guide.md"), encoding: .utf8) == "version three")
        #expect(try String(contentsOf: f.installed.appendingPathComponent("guide.md"), encoding: .utf8) == "original runtime")
    }

    @Test("The retained previous version expires at seven days and cannot alter current files through undo")
    func expiryRemovesBackupButKeepsCurrent() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        let transaction = try await update(f, text: "version two")
        #expect(transaction.canRestore(at: transaction.createdAt.addingTimeInterval(BackupRetentionPolicy.lifetime - 1)))
        #expect(!transaction.canRestore(at: transaction.createdAt.addingTimeInterval(BackupRetentionPolicy.lifetime)))
        _ = try await f.store.pruneRollbackBackups(now: transaction.createdAt.addingTimeInterval(BackupRetentionPolicy.lifetime))
        let versions = f.saved.deletingLastPathComponent().appendingPathComponent("versions")
        #expect(try FileManager.default.contentsOfDirectory(atPath: versions.path).isEmpty)
        await #expect(throws: (any Error).self) {
            _ = try await TransactionalSyncExecutor().undo(transactionID: transaction.id, store: f.store)
        }
        #expect(try String(contentsOf: f.saved.appendingPathComponent("guide.md"), encoding: .utf8) == "version two")
    }

    @Test("Unfinished recovery data is protected while ordinary old backup payloads expire")
    func protectsRecoveryAndRejectsUntrustedPaths() {
        let root = URL(fileURLWithPath: "/tmp/retention-test")
        let now = Date()
        let old = now.addingTimeInterval(-BackupRetentionPolicy.lifetime - 1)
        let backup = TransactionBackup(destinationPath: "/tmp/target", backupRelativePath: "backups/0-demo",
                                       beforeFingerprint: "old", afterFingerprint: "new", actionKind: .update)
        let running = SyncTransaction(createdAt: old, status: .running, actions: [], backups: [backup])
        let obsolete = SyncTransaction(createdAt: old, status: .succeeded, actions: [], backups: [backup])
        let hostile = SyncTransaction(createdAt: old, status: .succeeded, actions: [], backups: [.init(
            destinationPath: "/tmp/other", backupRelativePath: "../../original", beforeFingerprint: "old",
            afterFingerprint: "new", actionKind: .update
        )])
        let plan = BackupRetentionPolicy.plan(snapshot: .init(transactions: [obsolete, running, hostile]), root: root, now: now)
        #expect(plan.retainedPaths == [root.appendingPathComponent("Transactions/\(running.id)/backups/0-demo").path])
        #expect(plan.removablePaths == [root.appendingPathComponent("Transactions/\(obsolete.id)/backups/0-demo").path])
        #expect(!plan.expiredTransactionIDs.contains(running.id))
    }

    @Test("A missing restore payload is rejected before any installed destination is removed")
    func missingPayloadCannotDeleteCurrentInstallation() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        try f.edit("version two")
        let candidate = try #require(try await LocalFolderSourceProvider().preview(locator: f.source.path).first)
        let result = try await SkillUpdateCoordinator().updateAndDeploy(skillID: f.record.id, candidate: candidate, store: f.store)
        let transaction = try #require(result.transaction)
        let relative = try #require(transaction.backups.first?.backupRelativePath)
        let payload = await f.store.transactionsDirectory.appendingPathComponent("\(transaction.id)/\(relative)")
        try FileManager.default.removeItem(at: payload)
        await #expect(throws: (any Error).self) {
            _ = try await TransactionalSyncExecutor().undo(transactionID: transaction.id, store: f.store)
        }
        #expect(try String(contentsOf: f.installed.appendingPathComponent("guide.md"), encoding: .utf8) == "version two")
        #expect(try String(contentsOf: f.saved.appendingPathComponent("guide.md"), encoding: .utf8) == "version two")
    }

    @Test("A retained combined update still restores the saved and installed copies")
    func latestUndoStillWorks() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        try f.edit("version two")
        let candidate = try #require(try await LocalFolderSourceProvider().preview(locator: f.source.path).first)
        let result = try await SkillUpdateCoordinator().updateAndDeploy(skillID: f.record.id, candidate: candidate, store: f.store)
        _ = try await TransactionalSyncExecutor().undo(transactionID: try #require(result.transaction?.id), store: f.store)
        #expect(try String(contentsOf: f.installed.appendingPathComponent("guide.md"), encoding: .utf8) == "original runtime")
        #expect(try String(contentsOf: f.saved.appendingPathComponent("guide.md"), encoding: .utf8) == "original runtime")
    }

    private func update(_ fixture: RefreshFixture, text: String) async throws -> SyncTransaction {
        try fixture.edit(text)
        let candidate = try #require(try await LocalFolderSourceProvider().preview(locator: fixture.source.path).first)
        return try #require(try await SkillUpdateCoordinator().updateCentralOnly(
            skillID: fixture.record.id, candidate: candidate, store: fixture.store
        ).transaction)
    }
}
