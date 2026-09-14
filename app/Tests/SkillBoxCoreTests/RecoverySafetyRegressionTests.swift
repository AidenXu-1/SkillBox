import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Recovery preserves current content")
struct RecoverySafetyRegressionTests {
    @Test("Startup rejects missing and corrupt backups before restoring any destination", arguments: [false, true])
    func startupPreflightsAllBackups(corrupt: Bool) async throws {
        let f = try RecoverySafetyFixture()
        defer { f.remove() }
        let first = try f.destination("first", text: "first current")
        let second = try f.destination("second", text: "second current")
        let transaction = try await f.transaction(destinations: [first, second], status: .running)
        let invalid = f.payload(transaction, index: 0)
        if corrupt { try "corrupt".write(to: invalid.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8) }
        else { try FileManager.default.removeItem(at: invalid) }

        let recovered = try await TransactionalSyncExecutor().recoverInterruptedTransactions(store: f.store)

        #expect(recovered.first?.status == .failed)
        #expect(try f.text(first) == "first current")
        #expect(try f.text(second) == "second current")
    }

    @Test("Startup leaves an already restored destination intact even if its backup disappeared")
    func alreadyRestoredDestinationNeedsNoCopy() async throws {
        let f = try RecoverySafetyFixture()
        defer { f.remove() }
        let destination = try f.destination("demo", text: "original")
        var transaction = try await f.transaction(destinations: [destination], status: .running)
        transaction.backups[0].beforeFingerprint = transaction.backups[0].afterFingerprint
        try await f.store.recordTransaction(transaction)
        try FileManager.default.removeItem(at: f.payload(transaction, index: 0))

        _ = try await TransactionalSyncExecutor().recoverInterruptedTransactions(store: f.store)

        #expect(try f.text(destination) == "original")
    }

    @Test("A failed restore copy preserves the current installation")
    func copyFailurePreservesCurrent() async throws {
        let f = try RecoverySafetyFixture()
        defer { f.remove() }
        let destination = try f.destination("demo", text: "current")
        _ = try await f.transaction(destinations: [destination], status: .running)

        let recovered = try await TransactionalSyncExecutor(fileManager: RecoveryCopyFailingFileManager())
            .recoverInterruptedTransactions(store: f.store)

        #expect(recovered.first?.status == .failed)
        #expect(try f.text(destination) == "current")
    }

    @Test("A destination edit immediately before restore replacement remains untouched")
    func replacementRacePreservesExternalEdit() async throws {
        let f = try RecoverySafetyFixture()
        defer { f.remove() }
        let destination = try f.destination("demo", text: "current")
        _ = try await f.transaction(destinations: [destination], status: .running)
        let executor = TransactionalSyncExecutor(shouldInjectFailure: { _ in false }, beforeDestinationMutation: { url in
            try? "external edit".write(to: url.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        })

        let recovered = try await executor.recoverInterruptedTransactions(store: f.store)

        #expect(recovered.first?.status == .failed)
        #expect(try f.text(destination) == "external edit")
    }

    @Test("A refused atomic replacement preserves the current installation")
    func replacementFailurePreservesCurrent() async throws {
        let f = try RecoverySafetyFixture()
        defer { f.remove() }
        let destination = try f.destination("demo", text: "current")
        let parent = destination.deletingLastPathComponent()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        _ = try await f.transaction(destinations: [destination], status: .running)
        let executor = TransactionalSyncExecutor(shouldInjectFailure: { _ in false }, beforeDestinationMutation: { _ in
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        })

        let recovered = try await executor.recoverInterruptedTransactions(store: f.store)

        #expect(recovered.first?.status == .failed)
        #expect(try f.text(destination) == "current")
    }

    @Test("A later destination copy failure leaves every installation at its original current version")
    func laterCopyFailureCompensatesEarlierDestination() async throws {
        let f = try RecoverySafetyFixture()
        defer { f.remove() }
        let first = try f.destination("first", text: "first current")
        let second = try f.destination("second", text: "second current")
        let transaction = try await f.transaction(destinations: [first, second], status: .succeeded)
        await #expect(throws: (any Error).self) {
            _ = try await TransactionalSyncExecutor(fileManager: RestorationFaultFileManager(fault: .laterCopy))
                .undo(transactionID: transaction.id, store: f.store)
        }
        #expect(try f.text(first) == "first current")
        #expect(try f.text(second) == "second current")
        #expect(await f.store.currentSnapshot().transactions.first { $0.id == transaction.id }?.status == .succeeded)
    }

    @Test("A later destination replacement failure compensates earlier replacements")
    func laterReplacementFailureCompensatesEarlierDestination() async throws {
        let f = try RecoverySafetyFixture()
        defer { f.remove() }
        let first = try f.destination("first", text: "first current")
        let second = try f.destination("second", text: "second current")
        let transaction = try await f.transaction(destinations: [first, second], status: .succeeded)
        let executor = TransactionalSyncExecutor(shouldInjectFailure: { _ in false }, beforeDestinationMutation: { url in
            guard url.path == first.path else { return }
            for staged in (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [] {
                if staged.lastPathComponent.hasPrefix(".skillbox-restore-"),
                   (try? String(contentsOf: staged.appendingPathComponent("guide.md"), encoding: .utf8)) == "previous 0" {
                    try? FileManager.default.removeItem(at: staged)
                }
            }
        })
        await #expect(throws: (any Error).self) { _ = try await executor.undo(transactionID: transaction.id, store: f.store) }
        #expect(try f.text(first) == "first current")
        #expect(try f.text(second) == "second current")
    }

    @Test("A central restore copy failure leaves installed copies and records at the current version", arguments: [false, true])
    func centralFailureCompensatesInstalledCopies(replacement: Bool) async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        try f.edit("version two")
        let candidate = try #require(try await LocalFolderSourceProvider().preview(locator: f.source.path).first)
        let result = try await SkillUpdateCoordinator().updateAndDeploy(skillID: f.record.id, candidate: candidate, store: f.store)
        let transaction = try #require(result.transaction)
        let root = await f.store.root
        let store = try LibraryStore(root: root, fileManager: RestorationFaultFileManager(fault: replacement ? .centralReplacement : .centralCopy))
        let before = await store.currentSnapshot()
        await #expect(throws: (any Error).self) { _ = try await TransactionalSyncExecutor().undo(transactionID: transaction.id, store: store) }
        #expect(try String(contentsOf: f.installed.appendingPathComponent("guide.md"), encoding: .utf8) == "version two")
        #expect(try String(contentsOf: f.saved.appendingPathComponent("guide.md"), encoding: .utf8) == "version two")
        #expect(await store.currentSnapshot().installations == before.installations)
        #expect(await store.currentSnapshot().skills == before.skills)
    }

    @Test("A failure to clean exchanged contents does not fail a completed restoration")
    func cleanupFailureIsMaintenanceIssue() async throws {
        let f = try RecoverySafetyFixture()
        defer { f.remove() }
        let destination = try f.destination("demo", text: "current")
        let transaction = try await f.transaction(destinations: [destination], status: .succeeded)
        let root = await f.store.root
        let store = try LibraryStore(root: root, fileManager: RestorationFaultFileManager(fault: .cleanup))
        let result = try await TransactionalSyncExecutor(fileManager: RestorationFaultFileManager(fault: .cleanup)).undo(transactionID: transaction.id, store: store)
        #expect(result.status == .undone)
        #expect(try f.text(destination) == "previous 0")
        #expect(await store.currentBackupMaintenanceIssue() != nil)
        let completedRescue = try #require(await store.currentSnapshot().transactions.first { $0.restorationContext != nil })
        let rescueDirectory = root.appendingPathComponent("Transactions/\(completedRescue.id)")
        let unknown = rescueDirectory.appendingPathComponent("unregistered.txt")
        try "preserve unknown content".write(to: unknown, atomically: true, encoding: .utf8)
        let reopened = try LibraryStore(root: root)
        await #expect(throws: (any Error).self) { _ = try await reopened.pruneRollbackBackups() }
        #expect(try String(contentsOf: unknown, encoding: .utf8) == "preserve unknown content")
        #expect(await reopened.currentSnapshot().transactions.contains { $0.id == completedRescue.id })
        try FileManager.default.removeItem(at: unknown)
        _ = try await reopened.pruneRollbackBackups()
        #expect(await reopened.currentBackupMaintenanceIssue() == nil)
        #expect(!FileManager.default.fileExists(atPath: rescueDirectory.path))
    }

    @Test("Restart compensates a partial restoration before considering its original transaction", arguments: [false, true])
    func restartResumesCompensationWithoutRepeatingOriginal(originalWasRunning: Bool) async throws {
        let f = try RecoverySafetyFixture()
        defer { f.remove() }
        let first = try f.destination("first", text: "first current")
        let second = try f.destination("second", text: "second current")
        let original = try await f.transaction(destinations: [first, second], status: originalWasRunning ? .running : .succeeded)
        let owned = original.backups.map { backup in
            ManagedInstallation(skillID: UUID(), targetID: UUID(), destinationPath: backup.destinationPath,
                                deployedFingerprint: backup.afterFingerprint!, transactionID: original.id, deployedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }
        try await f.store.replaceInstallations(owned)
        var rescue = SyncTransaction(status: .running, actions: [])
        let stagedPaths = [first, second].map { $0.deletingLastPathComponent().appendingPathComponent(".skillbox-restore-\(UUID())").path }
        rescue.restorationContext = .init(originalTransactionID: original.id, originalStatus: original.status,
            originalCompletedAt: original.completedAt, originalErrors: [], originalBackupsExpiredAt: nil,
            installations: owned, assignments: [], stagedPaths: stagedPaths)
        let root = await f.store.root
        for (index, backup) in original.backups.enumerated() {
            let relative = "backups/\(index)-current"
            let copy = root.appendingPathComponent("Transactions/\(rescue.id)/\(relative)")
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: backup.destinationPath), to: copy)
            rescue.backups.append(.init(destinationPath: backup.destinationPath, backupRelativePath: relative,
                beforeFingerprint: backup.afterFingerprint, afterFingerprint: backup.beforeFingerprint,
                actionKind: .update, previousInstallation: owned[index]))
        }
        try await f.store.recordTransaction(rescue)
        // Simulate the process stopping immediately after the first swap.
        let staged = URL(fileURLWithPath: stagedPaths[1])
        try FileManager.default.moveItem(at: second, to: staged)
        try FileManager.default.copyItem(at: f.payload(original, index: 1), to: second)
        let reopened = try LibraryStore(root: root)
        let recovered = try await TransactionalSyncExecutor().recoverInterruptedTransactions(store: reopened)
        let snapshot = await reopened.currentSnapshot()

        #expect(try f.text(first) == (originalWasRunning ? "previous 0" : "first current"))
        #expect(try f.text(second) == (originalWasRunning ? "previous 1" : "second current"))
        #expect(snapshot.installations == (originalWasRunning ? [] : owned))
        #expect(recovered.count == 1)
        #expect(snapshot.transactions.first { $0.id == original.id }?.status == (originalWasRunning ? .rolledBack : .succeeded))
        #expect(snapshot.transactions.allSatisfy { $0.restorationContext == nil })
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Transactions/\(rescue.id)").path))
        #expect(await reopened.currentBackupMaintenanceIssue() == nil)
    }

    @Test("A central edit during restore preparation is preserved and installed copies are compensated")
    func centralEditDuringPreparationIsNeverOverwritten() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        try f.edit("version two")
        let candidate = try #require(try await LocalFolderSourceProvider().preview(locator: f.source.path).first)
        let result = try await SkillUpdateCoordinator().updateAndDeploy(skillID: f.record.id, candidate: candidate, store: f.store)
        let transaction = try #require(result.transaction)
        let root = await f.store.root
        let store = try LibraryStore(root: root, fileManager: CentralRestoreEditingFileManager(content: f.saved))
        await #expect(throws: (any Error).self) { _ = try await TransactionalSyncExecutor().undo(transactionID: transaction.id, store: store) }
        #expect(try String(contentsOf: f.saved.appendingPathComponent("guide.md"), encoding: .utf8) == "external edit during restore")
        #expect(try String(contentsOf: f.installed.appendingPathComponent("guide.md"), encoding: .utf8) == "version two")
        #expect(await store.currentSnapshot().transactions.first { $0.id == transaction.id }?.status == .failed)
    }

    @Test("Combined undo checks actual central content before changing installed copies")
    func combinedUndoRejectsCentralEditBeforeAnyMutation() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        try f.edit("version two")
        let candidate = try #require(try await LocalFolderSourceProvider().preview(locator: f.source.path).first)
        let result = try await SkillUpdateCoordinator().updateAndDeploy(skillID: f.record.id, candidate: candidate, store: f.store)
        let transaction = try #require(result.transaction)
        try "external central edit".write(to: f.saved.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        let before = await f.store.currentSnapshot()

        await #expect(throws: (any Error).self) {
            _ = try await TransactionalSyncExecutor().undo(transactionID: transaction.id, store: f.store)
        }

        #expect(try String(contentsOf: f.saved.appendingPathComponent("guide.md"), encoding: .utf8) == "external central edit")
        #expect(try String(contentsOf: f.installed.appendingPathComponent("guide.md"), encoding: .utf8) == "version two")
        #expect(await f.store.currentSnapshot().installations == before.installations)
    }

    @Test("Startup checks the central archive before reverting installed copies")
    func combinedStartupRejectsMissingCentralArchiveBeforeAnyMutation() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        try f.edit("version two")
        let candidate = try #require(try await LocalFolderSourceProvider().preview(locator: f.source.path).first)
        let result = try await SkillUpdateCoordinator().updateAndDeploy(skillID: f.record.id, candidate: candidate, store: f.store)
        var transaction = try #require(result.transaction)
        transaction.status = .running
        try await f.store.recordTransaction(transaction)
        let previous = try #require(transaction.libraryUpdate).previousRecord
        let archive = f.saved.deletingLastPathComponent().appendingPathComponent("versions/\(previous.fingerprint)")
        try FileManager.default.removeItem(at: archive)

        let recovered = try await TransactionalSyncExecutor().recoverInterruptedTransactions(store: f.store)

        #expect(recovered.first?.status == .failed)
        #expect(try String(contentsOf: f.saved.appendingPathComponent("guide.md"), encoding: .utf8) == "version two")
        #expect(try String(contentsOf: f.installed.appendingPathComponent("guide.md"), encoding: .utf8) == "version two")
    }
}

private final class RecoveryCopyFailingFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private struct RecoverySafetyFixture {
    let root: URL
    let store: LibraryStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxRecoverySafety-\(UUID())")
        store = try LibraryStore(root: root.appendingPathComponent("Store"))
    }

    func destination(_ name: String, text: String) throws -> URL {
        let url = root.appendingPathComponent("Agent/\(name)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try text.write(to: url.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        return url
    }

    func transaction(destinations: [URL], status: TransactionStatus) async throws -> SyncTransaction {
        var transaction = SyncTransaction(status: status, actions: [])
        let fp = SHA256SkillFingerprinter()
        for (index, destination) in destinations.enumerated() {
            let backup = payload(transaction, index: index)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try "previous \(index)".write(to: backup.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
            transaction.backups.append(.init(destinationPath: destination.path, backupRelativePath: "backups/\(index)-demo",
                                             beforeFingerprint: try fp.fingerprint(directory: backup),
                                             afterFingerprint: try fp.fingerprint(directory: destination), actionKind: .update))
        }
        try await store.recordTransaction(transaction)
        return transaction
    }

    func payload(_ transaction: SyncTransaction, index: Int) -> URL {
        root.appendingPathComponent("Store/Transactions/\(transaction.id)/backups/\(index)-demo")
    }

    func text(_ url: URL) throws -> String { try String(contentsOf: url.appendingPathComponent("guide.md"), encoding: .utf8) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class RestorationFaultFileManager: FileManager, @unchecked Sendable {
    enum Fault { case laterCopy, laterReplacement, centralCopy, centralReplacement, cleanup }
    let fault: Fault
    init(fault: Fault) { self.fault = fault; super.init() }
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if fault == .laterCopy && srcURL.lastPathComponent == "0-demo" && srcURL.deletingLastPathComponent().lastPathComponent == "backups" {
            throw CocoaError(.fileWriteNoPermission)
        }
        if fault == .centralCopy && dstURL.lastPathComponent.hasPrefix(".restore-") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.copyItem(at: srcURL, to: dstURL)
        if fault == .centralReplacement && dstURL.lastPathComponent.hasPrefix(".restore-") {
            try super.removeItem(at: dstURL)
        }
    }
    override func removeItem(at URL: URL) throws {
        if fault == .cleanup && URL.lastPathComponent.hasPrefix(".skillbox-restore-") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}

private final class CentralRestoreEditingFileManager: FileManager, @unchecked Sendable {
    let content: URL
    init(content: URL) { self.content = content; super.init() }
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try super.copyItem(at: srcURL, to: dstURL)
        if dstURL.lastPathComponent.hasPrefix(".restore-") {
            try "external edit during restore".write(to: content.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        }
    }
}
