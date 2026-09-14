import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Update recovery and completion")
struct UpdateRecoveryCommitTests {
    @Test("Direct central update preserves old content when saving fails and copying cannot recover it")
    func directUpdateFailureKeepsCompleteContent() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        let candidate = try await candidate(f)
        let storeRoot = f.root.appendingPathComponent("Store")
        let faultState = UpdateCommitFaultState()
        let store = try LibraryStore(root: storeRoot, fileManager: UpdateCommitFaultFileManager(
            root: storeRoot, content: f.saved, fault: .centralCommit, state: faultState, rejectRecoveryCopies: true))
        faultState.armed = true

        await #expect(throws: (any Error).self) { _ = try await store.updateSkill(id: f.record.id, with: candidate) }

        #expect(faultState.didFail)
        #expect(try content(f.saved) == "original runtime")
        #expect(await store.currentSnapshot().skills.first?.fingerprint == f.record.fingerprint)
        let reopened = try LibraryStore(root: storeRoot)
        #expect(await reopened.currentSnapshot().skills.first?.fingerprint == f.record.fingerprint)
    }

    @Test("Failed central persistence plus unavailable recovery copies cannot erase content during cleanup or restart")
    func failedUpdateSurvivesCleanupAndRestart() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        let candidate = try await candidate(f)
        let storeRoot = f.root.appendingPathComponent("Store")
        let faultState = UpdateCommitFaultState()
        let store = try LibraryStore(root: storeRoot, fileManager: UpdateCommitFaultFileManager(
            root: storeRoot, content: f.saved, fault: .centralCommit, state: faultState, rejectRecoveryCopies: true))
        faultState.armed = true

        await #expect(throws: (any Error).self) {
            _ = try await SkillUpdateCoordinator().updateCentralOnly(skillID: f.record.id, candidate: candidate, store: store)
        }

        #expect(faultState.didFail)
        #expect(try content(f.saved) == "original runtime")
        _ = try await store.pruneRollbackBackups()
        let reopened = try LibraryStore(root: storeRoot)
        _ = try await TransactionalSyncExecutor().recoverInterruptedTransactions(store: reopened)
        #expect(try content(f.saved) == "original runtime")
        #expect(await reopened.currentSnapshot().skills.first?.fingerprint == f.record.fingerprint)
    }

    @Test("Failure of the final success record restores central and deployed content before claiming rollback", arguments: [false, true])
    func finalCompletionFailureRestoresOldVersion(deploy: Bool) async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        let candidate = try await candidate(f)
        let storeRoot = f.root.appendingPathComponent("Store")
        let faultState = UpdateCommitFaultState()
        let store = try LibraryStore(root: storeRoot, fileManager: UpdateCommitFaultFileManager(
            root: storeRoot, content: f.saved, fault: .completionCommit, state: faultState))
        faultState.armed = true

        await #expect(throws: (any Error).self) {
            if deploy {
                _ = try await SkillUpdateCoordinator().updateAndDeploy(skillID: f.record.id, candidate: candidate, store: store)
            } else {
                _ = try await SkillUpdateCoordinator().updateCentralOnly(skillID: f.record.id, candidate: candidate, store: store)
            }
        }

        #expect(faultState.didFail)
        #expect(try content(f.saved) == "original runtime")
        #expect(try content(f.installed) == "original runtime")
        let transaction = try #require(await store.currentSnapshot().transactions.first { $0.libraryUpdate != nil && $0.restorationContext == nil })
        #expect(transaction.status == .rolledBack)
        _ = try await store.pruneRollbackBackups()
        let reopened = try LibraryStore(root: storeRoot)
        _ = try await TransactionalSyncExecutor().recoverInterruptedTransactions(store: reopened)
        #expect(try content(f.saved) == "original runtime")
        #expect(await reopened.currentSnapshot().skills.first?.fingerprint == f.record.fingerprint)
    }

    @Test("An unsuccessful recovery retains complete current content and the previous archive through cleanup and restart")
    func recoveryFailureCannotBecomeDisposableHistory() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        let candidate = try await candidate(f)
        let storeRoot = f.root.appendingPathComponent("Store")
        let faultState = UpdateCommitFaultState()
        let store = try LibraryStore(root: storeRoot, fileManager: UpdateCommitFaultFileManager(
            root: storeRoot, content: f.saved, fault: .completionCommit, state: faultState, rejectRecoveryCopies: true))
        faultState.armed = true

        await #expect(throws: (any Error).self) {
            _ = try await SkillUpdateCoordinator().updateCentralOnly(skillID: f.record.id, candidate: candidate, store: store)
        }

        #expect(faultState.didFail)
        #expect(try content(f.saved) == "version two")
        let transaction = try #require(await store.currentSnapshot().transactions.first { $0.libraryUpdate != nil && $0.restorationContext == nil })
        #expect(transaction.status == .failed)
        _ = try await store.pruneRollbackBackups()
        let previousArchive = f.saved.deletingLastPathComponent().appendingPathComponent("versions/\(f.record.fingerprint)")
        #expect(try content(previousArchive) == "original runtime")
        let reopened = try LibraryStore(root: storeRoot)
        _ = try await TransactionalSyncExecutor().recoverInterruptedTransactions(store: reopened)
        _ = try await reopened.pruneRollbackBackups()
        #expect(try content(f.saved) == "version two")
        #expect(try content(previousArchive) == "original runtime")
        #expect(await reopened.currentSnapshot().transactions.first { $0.id == transaction.id }?.status == .failed)
    }

    @Test("A failed source commit restores the old complete update and a retry retains its real undo", arguments: [false, true])
    func sourceCommitFailureThenRetry(deploy: Bool) async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        let candidate = try await candidate(f)
        let storeRoot = f.root.appendingPathComponent("Store")
        let faultState = UpdateCommitFaultState()
        let store = try LibraryStore(root: storeRoot, fileManager: UpdateCommitFaultFileManager(
            root: storeRoot, content: f.saved, fault: .sourceCommit, state: faultState))
        var next = try #require(await store.currentSnapshot().localSourceStates.first)
        next.currentPackageFingerprint = candidate.fingerprint
        next.availablePackageFingerprint = nil
        next.status = .current
        let nextState = next
        faultState.armed = true

        await #expect(throws: (any Error).self) {
            if deploy {
                _ = try await SkillUpdateCoordinator().updateAndDeploy(skillID: f.record.id, candidate: candidate,
                    store: store, nextLocalSourceState: nextState)
            } else {
                _ = try await SkillUpdateCoordinator().updateCentralOnly(skillID: f.record.id, candidate: candidate,
                    store: store, nextLocalSourceState: nextState)
            }
        }

        #expect(faultState.didFail)
        #expect(try content(f.saved) == "original runtime")
        #expect(try content(f.installed) == "original runtime")
        _ = try await store.pruneRollbackBackups()
        let reopened = try LibraryStore(root: storeRoot)
        _ = try await TransactionalSyncExecutor().recoverInterruptedTransactions(store: reopened)
        #expect(await reopened.currentSnapshot().localSourceStates.first?.currentPackageFingerprint == f.record.fingerprint)
        let result: SkillUpdateResult
        if deploy {
            result = try await SkillUpdateCoordinator().updateAndDeploy(skillID: f.record.id, candidate: candidate,
                store: reopened, nextLocalSourceState: nextState)
        } else {
            result = try await SkillUpdateCoordinator().updateCentralOnly(skillID: f.record.id, candidate: candidate,
                store: reopened, nextLocalSourceState: nextState)
        }
        #expect(await reopened.currentSnapshot().localSourceStates.first?.currentPackageFingerprint == candidate.fingerprint)
        let transaction = try #require(result.transaction)
        #expect(transaction.libraryUpdate?.previousRecord.fingerprint == f.record.fingerprint)
        _ = try await TransactionalSyncExecutor().undo(transactionID: transaction.id, store: reopened)
        #expect(try content(f.saved) == "original runtime")
        #expect(try content(f.installed) == "original runtime")
        #expect(await reopened.currentSnapshot().localSourceStates.first?.currentPackageFingerprint == f.record.fingerprint)
    }

    @Test("Startup restores the previous source when interruption follows the running source commit")
    func startupRestoresRunningSourceCommit() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        let candidate = try await candidate(f)
        let previousState = try #require(await f.store.currentSnapshot().localSourceStates.first)
        var nextState = previousState
        nextState.currentPackageFingerprint = candidate.fingerprint
        let transaction = SyncTransaction(status: .running, actions: [], libraryUpdate: .init(
            previousRecord: f.record, updatedFingerprint: candidate.fingerprint,
            previousLocalSourceState: previousState, updatedLocalSourceFingerprint: candidate.fingerprint))
        try await f.store.recordTransaction(transaction)
        _ = try await f.store.updateSkill(id: f.record.id, with: candidate)
        try await f.store.recordLocalSourceUpdate(nextState, transactionID: transaction.id)

        let reopened = try LibraryStore(root: f.root.appendingPathComponent("Store"))
        let recovered = try await TransactionalSyncExecutor().recoverInterruptedTransactions(store: reopened)

        #expect(recovered.first { $0.id == transaction.id }?.status == .rolledBack)
        #expect(try content(f.saved) == "original runtime")
        #expect(await reopened.currentSnapshot().localSourceStates.first?.currentPackageFingerprint == previousState.currentPackageFingerprint)
    }

    @Test("An unsaved transaction never replaces the last persisted in-memory transaction")
    func failedTransactionSaveRestoresMemory() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        let storeRoot = f.root.appendingPathComponent("Store")
        let faultState = UpdateCommitFaultState()
        let store = try LibraryStore(root: storeRoot, fileManager: UpdateCommitFaultFileManager(
            root: storeRoot, content: f.saved, fault: .nextWrite, state: faultState))
        let before = await store.currentSnapshot()
        faultState.armed = true
        await #expect(throws: (any Error).self) { try await store.recordTransaction(.init(status: .succeeded, actions: [])) }
        #expect(await store.currentSnapshot().transactions == before.transactions)
    }

    @Test("An unsaved installation change never replaces the current in-memory ownership")
    func failedInstallationsSaveRestoresMemory() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        let storeRoot = f.root.appendingPathComponent("Store")
        let faultState = UpdateCommitFaultState()
        let store = try LibraryStore(root: storeRoot, fileManager: UpdateCommitFaultFileManager(
            root: storeRoot, content: f.saved, fault: .nextWrite, state: faultState))
        let before = await store.currentSnapshot()
        faultState.armed = true
        await #expect(throws: (any Error).self) { try await store.replaceInstallations([]) }
        #expect(await store.currentSnapshot().installations == before.installations)
    }

    private func candidate(_ f: RefreshFixture) async throws -> SkillCandidate {
        try f.edit("version two")
        return try #require(try await LocalFolderSourceProvider().preview(locator: f.source.path).first)
    }

    private func content(_ url: URL) throws -> String {
        try String(contentsOf: url.appendingPathComponent("guide.md"), encoding: .utf8)
    }
}

private final class UpdateCommitFaultFileManager: FileManager, @unchecked Sendable {
    enum Fault { case nextWrite, centralCommit, completionCommit, sourceCommit }
    let storeRoot: URL
    let contentURL: URL
    let fault: Fault
    let rejectRecoveryCopies: Bool
    let state: UpdateCommitFaultState

    init(root: URL, content: URL, fault: Fault, state: UpdateCommitFaultState, rejectRecoveryCopies: Bool = false) {
        storeRoot = root.standardizedFileURL
        contentURL = content
        self.fault = fault
        self.state = state
        self.rejectRecoveryCopies = rejectRecoveryCopies
        super.init()
    }

    override func createDirectory(at url: URL, withIntermediateDirectories: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if state.armed && !state.didFail && url.standardizedFileURL == storeRoot {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let transactions = try? decoder.decode(PersistedEnvelope<[SyncTransaction]>.self,
                from: Data(contentsOf: storeRoot.appendingPathComponent("transactions.json")))
            let shouldFail: Bool
            switch fault {
            case .nextWrite: shouldFail = true
            case .centralCommit:
                shouldFail = (try? String(contentsOf: contentURL.appendingPathComponent("guide.md"), encoding: .utf8)) == "version two"
            case .completionCommit:
                shouldFail = transactions?.value.contains { $0.libraryUpdate != nil && $0.status == .succeeded } == true
            case .sourceCommit:
                let mirror = try? decoder.decode(PersistedEnvelope<[LocalSourceState]>.self,
                    from: Data(contentsOf: storeRoot.appendingPathComponent("local-source-state.json")))
                let committed = try? decoder.decode(PersistedEnvelope<LibrarySnapshot>.self,
                    from: Data(contentsOf: storeRoot.appendingPathComponent("library-state.json")))
                shouldFail = mirror?.value.first?.currentPackageFingerprint == committed?.value.skills.first?.fingerprint &&
                    mirror?.value.first?.currentPackageFingerprint != committed?.value.localSourceStates.first?.currentPackageFingerprint
            }
            if shouldFail {
                state.didFail = true
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        try super.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories, attributes: attributes)
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if state.didFail && rejectRecoveryCopies { throw CocoaError(.fileWriteOutOfSpace) }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

private final class UpdateCommitFaultState: @unchecked Sendable {
    private let lock = NSLock()
    private var isArmed = false
    private var hasFailed = false
    var armed: Bool {
        get { lock.withLock { isArmed } }
        set { lock.withLock { isArmed = newValue } }
    }
    var didFail: Bool {
        get { lock.withLock { hasFailed } }
        set { lock.withLock { hasFailed = newValue } }
    }
}
