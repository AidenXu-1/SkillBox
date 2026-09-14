import Foundation
import Testing
@testable import SkillBoxCore
@testable import SkillBoxApp

@Suite("Recovery presentation follows stored state")
struct BackupRecoveryPresentationTests {
    @Test("Central-only update offers a confirmable saved version and cancel preserves it")
    @MainActor func centralOnlyPreviewCanConfirm() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        try "new version".write(to: f.source.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        let candidate = try #require(try await LocalFolderSourceProvider().preview(locator: f.source.path).first)
        let result = try await SkillUpdateCoordinator().updateCentralOnly(skillID: f.record.id, candidate: candidate, store: f.store)
        let transaction = try #require(result.transaction)
        let model = f.model()
        await model.reload()
        #expect(model.prepareUndoPreview(transaction))
        let content = UndoPreviewContent(transaction: try #require(model.pendingUndoTransaction))
        #expect(content.installationActions.isEmpty)
        #expect(content.savedVersion?.id == f.record.id)
        #expect(content.canConfirm)
        model.cancelUndoPreview()
        #expect(model.pendingUndoTransaction == nil)
        #expect(try String(contentsOf: f.saved.appendingPathComponent("guide.md"), encoding: .utf8) == "new version")
        #expect(model.prepareUndoPreview(transaction))
        await model.confirmPendingUndo()
        #expect(model.pendingUndoTransaction == nil)
        #expect(try String(contentsOf: f.saved.appendingPathComponent("guide.md"), encoding: .utf8) == "original runtime")
        #expect(try String(contentsOf: f.source.appendingPathComponent("guide.md"), encoding: .utf8) == "new version")
        #expect(try String(contentsOf: f.installed.appendingPathComponent("guide.md"), encoding: .utf8) == "original runtime")
        let restored = try #require(model.snapshot.transactions.first { $0.id == transaction.id })
        #expect(!UndoPreviewContent(transaction: restored).canConfirm)
    }

    @Test("A failed cleanup refreshes already expired recovery records")
    @MainActor func failedCleanupRefreshesRecoveryState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupRecoveryPresentation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = TransactionBackup(destinationPath: root.appendingPathComponent("Agent/demo").path,
                                       backupRelativePath: "backups/0-demo", beforeFingerprint: "old",
                                       afterFingerprint: "new", actionKind: .update)
        let old = SyncTransaction(createdAt: Date().addingTimeInterval(-120), status: .succeeded, actions: [], backups: [backup])
        let latest = SyncTransaction(createdAt: Date().addingTimeInterval(-60), status: .succeeded, actions: [], backups: [backup])
        for transaction in [old, latest] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Transactions/\(transaction.id)/backups/0-demo"),
                                                    withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(PersistedEnvelope(value: [latest, old])).write(to: root.appendingPathComponent("transactions.json"))
        let store = try LibraryStore(root: root, fileManager: DeniedRecoveryBackupRemoval())
        let suite = "BackupRecoveryPresentation-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(libraryRoot: root, store: store, homeDirectory: root.appendingPathComponent("home"),
                             userDefaults: defaults, startBootstrap: false)
        await model.reload()
        #expect(model.snapshot.transactions.first { $0.id == old.id }?.canRestore() == true)
        await model.cleanRollbackBackups()
        #expect(model.backupCheckResult?.hasPrefix("检查未全部完成") == true)
        #expect(await store.currentSnapshot().transactions.first { $0.id == old.id }?.canRestore() == false)
        let displayed = try #require(model.snapshot.transactions.first { $0.id == old.id })
        #expect(!displayed.canRestore())
        #expect(!model.prepareUndoPreview(displayed))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Transactions/\(old.id)/backups/0-demo").path))
    }
}

private final class DeniedRecoveryBackupRemoval: FileManager, @unchecked Sendable {
    override func removeItem(at url: URL) throws {
        if url.lastPathComponent == "0-demo" { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}
