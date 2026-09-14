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
        authorizingHighRisk: Bool = false,
        nextLocalSourceState: LocalSourceState? = nil,
        nextGitHubSourceState: GitHubSourceState? = nil
    ) async throws -> SkillUpdateResult {
        try await update(skillID: skillID, candidate: candidate, store: store,
                         authorizingHighRisk: authorizingHighRisk, deployToExisting: false,
                         nextLocalSourceState: nextLocalSourceState, nextGitHubSourceState: nextGitHubSourceState)
    }

    public func updateAndDeploy(
        skillID: UUID,
        candidate: SkillCandidate,
        store: LibraryStore,
        authorizingHighRisk: Bool = false,
        nextLocalSourceState: LocalSourceState? = nil,
        nextGitHubSourceState: GitHubSourceState? = nil
    ) async throws -> SkillUpdateResult {
        try await update(skillID: skillID, candidate: candidate, store: store,
                         authorizingHighRisk: authorizingHighRisk, deployToExisting: true,
                         nextLocalSourceState: nextLocalSourceState, nextGitHubSourceState: nextGitHubSourceState)
    }

    private func update(
        skillID: UUID,
        candidate: SkillCandidate,
        store: LibraryStore,
        authorizingHighRisk: Bool,
        deployToExisting: Bool,
        nextLocalSourceState: LocalSourceState?,
        nextGitHubSourceState: GitHubSourceState?
    ) async throws -> SkillUpdateResult {
        let before = await store.currentSnapshot()
        guard let previous = before.skills.first(where: { $0.id == skillID }) else { throw LibraryStoreError.skillNotFound }
        guard nextLocalSourceState == nil || nextGitHubSourceState == nil,
              nextLocalSourceState.map({ $0.skillID == skillID && $0.currentPackageFingerprint == candidate.fingerprint }) ?? true,
              nextGitHubSourceState.map({ $0.skillID == skillID && $0.currentVersionIdentifier != nil }) ?? true
        else { throw LibraryStoreError.candidateChanged }
        let managedDestinations = Set(before.installations.filter { $0.skillID == skillID }.map(\.destinationPath))
        var transaction = SyncTransaction(
            status: .running,
            actions: [],
            libraryUpdate: .init(
                previousRecord: previous,
                updatedFingerprint: candidate.fingerprint,
                previousSourceState: nextGitHubSourceState == nil ? nil : before.sourceStates.first { $0.skillID == skillID },
                updatedSourceVersionIdentifier: nextGitHubSourceState?.currentVersionIdentifier,
                previousLocalSourceState: nextLocalSourceState == nil ? nil : before.localSourceStates.first { $0.skillID == skillID },
                updatedLocalSourceFingerprint: nextLocalSourceState?.currentPackageFingerprint
            )
        )
        // Save both source versions before the first content mutation, so a
        // restart can restore the same complete update as an ordinary failure.
        try await store.recordTransaction(transaction)
        do {
            let updatedRecord = try await store.updateSkill(
                id: skillID,
                with: candidate,
                authorizingHighRisk: authorizingHighRisk
            )
            transaction.libraryUpdate?.updatedFingerprint = updatedRecord.fingerprint
            if let nextLocalSourceState {
                try await store.recordLocalSourceUpdate(nextLocalSourceState, transactionID: transaction.id)
            }
            if let nextGitHubSourceState {
                try await store.recordGitHubSourceUpdate(nextGitHubSourceState, transactionID: transaction.id)
            }
            var relevant: [SyncAction] = []
            if deployToExisting {
                let fullPlan = try planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: store.root)
                relevant = fullPlan.actions.filter {
                    $0.skillID == skillID && managedDestinations.contains($0.destinationPath) && $0.kind != .remove
                }
            }

            transaction.actions = relevant
            if relevant.contains(where: { $0.kind == .update }) {
                transaction = try await executor.execute(plan: .init(actions: relevant), store: store, transaction: transaction)
            } else {
                transaction.completedAt = Date()
                transaction.status = .succeeded
                try await store.recordTransaction(transaction)
            }
            return .init(record: updatedRecord, transaction: transaction, blockedActions: relevant.filter { $0.kind == .blocked })
        } catch {
            let latest = await store.currentSnapshot().transactions.first { $0.id == transaction.id }
            if latest?.status == .running {
                _ = try await executor.rollback(transactionID: transaction.id, store: store, reason: error.localizedDescription)
            }
            // The executor already owns deployment failure and its rescue
            // journal. Never independently rewind just the central copy again.
            throw error
        }
    }
}
