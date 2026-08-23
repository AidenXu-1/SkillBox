import Foundation

public struct SkillUpdateResult: Sendable {
    public var record: SkillRecord
    public var transaction: SyncTransaction?
    public var blockedActions: [SyncAction]

    public init(record: SkillRecord, transaction: SyncTransaction?, blockedActions: [SyncAction]) {
        self.record = record
        self.transaction = transaction
        self.blockedActions = blockedActions
    }
}

public actor SkillUpdateCoordinator {
    private let planner: any SyncPlanner
    private let executor: any SyncExecutor

    public init(
        planner: any SyncPlanner = DefaultSyncPlanner(),
        executor: any SyncExecutor = TransactionalSyncExecutor()
    ) {
        self.planner = planner
        self.executor = executor
    }

    public func updateCentralOnly(
        skillID: UUID,
        candidate: SkillCandidate,
        store: LibraryStore,
        authorizingHighRisk: Bool = false
    ) async throws -> SkillUpdateResult {
        let before = await store.currentSnapshot()
        guard let previous = before.skills.first(where: { $0.id == skillID }) else { throw LibraryStoreError.skillNotFound }
        var transaction = SyncTransaction(
            status: .running,
            actions: [],
            libraryUpdate: .init(previousRecord: previous, updatedFingerprint: candidate.fingerprint)
        )
        try await store.recordTransaction(transaction)
        do {
            let record = try await store.updateSkill(
                id: skillID,
                with: candidate,
                authorizingHighRisk: authorizingHighRisk
            )
            transaction.libraryUpdate?.updatedFingerprint = record.fingerprint
            transaction.completedAt = Date()
            transaction.status = .succeeded
            try await store.recordTransaction(transaction)
            return .init(record: record, transaction: transaction, blockedActions: [])
        } catch {
            transaction.completedAt = Date()
            transaction.status = .rolledBack
            transaction.errors.append(error.localizedDescription)
            try? await store.recordTransaction(transaction)
            throw error
        }
    }

    public func updateAndDeploy(
        skillID: UUID,
        candidate: SkillCandidate,
        store: LibraryStore,
        authorizingHighRisk: Bool = false
    ) async throws -> SkillUpdateResult {
        let before = await store.currentSnapshot()
        guard let previous = before.skills.first(where: { $0.id == skillID }) else { throw LibraryStoreError.skillNotFound }
        let managedDestinations = Set(before.installations.filter { $0.skillID == skillID }.map(\.destinationPath))
        var transaction = SyncTransaction(
            status: .running,
            actions: [],
            libraryUpdate: .init(previousRecord: previous, updatedFingerprint: candidate.fingerprint)
        )
        try await store.recordTransaction(transaction)
        var updated: SkillRecord?
        do {
            let updatedRecord = try await store.updateSkill(
                id: skillID,
                with: candidate,
                authorizingHighRisk: authorizingHighRisk
            )
            updated = updatedRecord
            transaction.libraryUpdate?.updatedFingerprint = updatedRecord.fingerprint
            try await store.recordTransaction(transaction)
            let fullPlan = try planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: store.root)
            let relevant = fullPlan.actions.filter {
                $0.skillID == skillID &&
                managedDestinations.contains($0.destinationPath) &&
                $0.kind != .remove
            }
            guard relevant.contains(where: { $0.kind == .update }) else {
                transaction.completedAt = Date()
                transaction.status = .succeeded
                transaction.actions = relevant
                try await store.recordTransaction(transaction)
                return .init(record: updatedRecord, transaction: transaction, blockedActions: relevant.filter { $0.kind == .blocked })
            }
            transaction.actions = relevant
            transaction = try await executor.execute(
                plan: .init(actions: relevant),
                store: store,
                transaction: transaction
            )
            return .init(record: updatedRecord, transaction: transaction, blockedActions: relevant.filter { $0.kind == .blocked })
        } catch {
            if let updated {
                _ = try await store.restoreSkillVersion(.init(
                    previousRecord: previous,
                    updatedFingerprint: updated.fingerprint
                ))
            }
            let latest = await store.currentSnapshot().transactions.first { $0.id == transaction.id }
            if let latest { transaction = latest }
            if transaction.status == .running { transaction.status = .rolledBack }
            transaction.completedAt = transaction.completedAt ?? Date()
            transaction.errors.append(error.localizedDescription)
            try? await store.recordTransaction(transaction)
            throw error
        }
    }
}
