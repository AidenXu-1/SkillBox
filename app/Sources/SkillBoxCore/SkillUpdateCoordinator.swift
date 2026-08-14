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

    public func updateCentralOnly(skillID: UUID, candidate: SkillCandidate, store: LibraryStore) async throws -> SkillUpdateResult {
        let record = try await store.updateSkill(id: skillID, with: candidate)
        return .init(record: record, transaction: nil, blockedActions: [])
    }

    public func updateAndDeploy(skillID: UUID, candidate: SkillCandidate, store: LibraryStore) async throws -> SkillUpdateResult {
        let before = await store.currentSnapshot()
        guard let previous = before.skills.first(where: { $0.id == skillID }) else { throw LibraryStoreError.skillNotFound }
        let managedDestinations = Set(before.installations.filter { $0.skillID == skillID }.map(\.destinationPath))
        let updated = try await store.updateSkill(id: skillID, with: candidate)
        do {
            let fullPlan = try planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: store.root)
            let relevant = fullPlan.actions.filter {
                $0.skillID == skillID &&
                managedDestinations.contains($0.destinationPath) &&
                $0.kind != .remove
            }
            guard relevant.contains(where: { $0.kind == .update }) else {
                return .init(record: updated, transaction: nil, blockedActions: relevant.filter { $0.kind == .blocked })
            }
            var transaction = try await executor.execute(plan: .init(actions: relevant), store: store)
            transaction.libraryUpdate = .init(previousRecord: previous, updatedFingerprint: updated.fingerprint)
            try await store.recordTransaction(transaction)
            return .init(record: updated, transaction: transaction, blockedActions: relevant.filter { $0.kind == .blocked })
        } catch {
            _ = try await store.restoreSkillVersion(.init(previousRecord: previous, updatedFingerprint: updated.fingerprint))
            throw error
        }
    }
}
