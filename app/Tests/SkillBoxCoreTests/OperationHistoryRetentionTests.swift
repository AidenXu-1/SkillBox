import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Seven day operation history")
struct OperationHistoryRetentionTests {
    private func deletionFixture() async throws -> (URL, LibraryStore, SkillRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Test\n---\nHello\n".write(
            to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let candidate = try #require(try await LocalFolderSourceProvider().preview(locator: source.path).first)
        let store = try LibraryStore(root: root.appendingPathComponent("store"))
        return (root, store, try await store.importCandidate(candidate))
    }

    @Test("Seven day boundary removes history durably without touching installed or central content")
    func expiryAndPersistence() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        let before = await f.store.currentSnapshot()
        let transaction = SyncTransaction(createdAt: Date().addingTimeInterval(-3600), completedAt: Date(),
                                          status: .succeeded, actions: [])
        try await f.store.recordTransaction(transaction)
        let expiry = transaction.retentionStartedAt.addingTimeInterval(BackupRetentionPolicy.lifetime)
        _ = try await f.store.pruneRollbackBackups(now: expiry.addingTimeInterval(-1))
        #expect(await f.store.currentSnapshot().transactions.contains { $0.id == transaction.id })
        _ = try await f.store.pruneRollbackBackups(now: expiry)
        #expect(await f.store.currentSnapshot().transactions.isEmpty)
        let inMemory = await f.store.currentSnapshot()
        #expect(inMemory.skills == before.skills)
        #expect(inMemory.installations == before.installations)
        let reopened = try LibraryStore(root: await f.store.root)
        let after = await reopened.currentSnapshot()
        #expect(after.transactions.isEmpty)
        #expect(after.skills.map(\.fingerprint) == before.skills.map(\.fingerprint))
        #expect(after.installations.map(\.deployedFingerprint) == before.installations.map(\.deployedFingerprint))
        #expect(after.assignments == before.assignments)
        #expect(try String(contentsOf: f.installed.appendingPathComponent("guide.md"), encoding: .utf8) == "original runtime")
        #expect(try String(contentsOf: f.saved.appendingPathComponent("guide.md"), encoding: .utf8) == "original runtime")
        _ = try await reopened.pruneRollbackBackups(now: expiry)
    }

    @Test("Legacy records without completion time expire on the next successful operation")
    func legacyAutomaticCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let old = SyncTransaction(createdAt: Date().addingTimeInterval(-8 * 86400), status: .undone, actions: [])
        try await store.recordTransaction(old)
        #expect(await store.currentSnapshot().transactions.isEmpty)
    }

    @Test("Failed rescue protects its original operation and original backup beyond expiry")
    func protectsRecoveryDependencies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let original = SyncTransaction(status: .succeeded, actions: [], backups: [.init(
            destinationPath: "/unused/target", backupRelativePath: "backups/0-demo", beforeFingerprint: "old",
            afterFingerprint: "new", actionKind: .update)])
        let payload = root.appendingPathComponent("Transactions/\(original.id)/backups/0-demo")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try "restore me".write(to: payload.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try await store.recordTransaction(original)
        let rescue = SyncTransaction(status: .failed, actions: [], restorationContext: .init(
            originalTransactionID: original.id, originalStatus: .succeeded, originalCompletedAt: nil,
            originalErrors: [], originalBackupsExpiredAt: nil, installations: [], assignments: [], stagedPaths: []))
        try await store.recordTransaction(rescue)
        _ = try await store.pruneRollbackBackups(now: Date().addingTimeInterval(8 * 86400))
        #expect(await store.currentSnapshot().transactions.count == 2)
        #expect(FileManager.default.fileExists(atPath: payload.path))
        #expect(await store.currentSnapshot().transactions.first { $0.id == original.id }?.backupsExpiredAt == nil)
    }

    @Test("Deletion compensation leftovers are retried, expired history disappears, Trash is preserved")
    func deletionRetention() async throws {
        let (root, store, record) = try await deletionFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let deletion = try await store.deleteSkill(id: record.id)
        let transaction = try #require(await store.currentSnapshot().transactions.first { $0.libraryDeletion != nil })
        let trash = try #require(deletion.archivedURL)
        let recovery = root.appendingPathComponent("store/Transactions/\(transaction.id)/deletion-recovery")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try "leftover".write(to: recovery.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        let expiry = transaction.retentionStartedAt.addingTimeInterval(BackupRetentionPolicy.lifetime)
        #expect(transaction.canRestore(at: expiry.addingTimeInterval(-1)))
        #expect(!transaction.canRestore(at: expiry))
        _ = try await store.pruneRollbackBackups(now: expiry)
        #expect(!FileManager.default.fileExists(atPath: recovery.path))
        #expect(FileManager.default.fileExists(atPath: trash.path))
        #expect(await store.currentSnapshot().transactions.isEmpty)
        await #expect(throws: SyncExecutorError.self) { _ = try await store.restoreDeletedSkill(deletion) }
    }

    @Test("A symlink cleanup failure keeps the record, preserves outside files and succeeds on retry")
    func cleanupFailureRetry() async throws {
        let (root, store, record) = try await deletionFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let deletion = try await store.deleteSkill(id: record.id)
        let transaction = try #require(await store.currentSnapshot().transactions.first { $0.libraryDeletion != nil })
        let trash = try #require(deletion.archivedURL)
        let recovery = root.appendingPathComponent("store/Transactions/\(transaction.id)/deletion-recovery")
        try FileManager.default.createDirectory(at: recovery.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: recovery, withDestinationURL: trash)
        let expiry = transaction.retentionStartedAt.addingTimeInterval(BackupRetentionPolicy.lifetime)
        await #expect(throws: (any Error).self) { _ = try await store.pruneRollbackBackups(now: expiry) }
        #expect(await store.currentSnapshot().transactions.count == 1)
        #expect(FileManager.default.fileExists(atPath: trash.path))
        try FileManager.default.removeItem(at: recovery)
        _ = try await store.pruneRollbackBackups(now: expiry)
        #expect(await store.currentSnapshot().transactions.isEmpty)
        #expect(await store.currentBackupMaintenanceIssue() == nil)
    }

    @Test("Unknown transaction contents preserve their journal and are never recursively deleted")
    func unknownContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let transaction = SyncTransaction(status: .succeeded, actions: [])
        try await store.recordTransaction(transaction)
        let directory = root.appendingPathComponent("Transactions/\(transaction.id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unknown = directory.appendingPathComponent("unknown")
        try "keep".write(to: unknown, atomically: true, encoding: .utf8)
        let future = Date().addingTimeInterval(8 * 86400)
        _ = try await store.pruneRollbackBackups(now: future)
        #expect(await store.currentSnapshot().transactions.count == 1)
        #expect(try String(contentsOf: unknown, encoding: .utf8) == "keep")
        try FileManager.default.removeItem(at: unknown)
        _ = try await store.pruneRollbackBackups(now: future)
        #expect(await store.currentSnapshot().transactions.isEmpty)
    }
}
