import Foundation

public actor GitHubUpdateChecker {
    private let checker: any GitHubRemoteVersionChecking
    private let store: LibraryStore
    private let now: @Sendable () -> Date

    public init(
        checker: any GitHubRemoteVersionChecking,
        store: LibraryStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.checker = checker
        self.store = store
        self.now = now
    }

    @discardableResult
    public func check(skillID: UUID) async throws -> GitHubSourceState? {
        let snapshot = await store.currentSnapshot()
        guard var state = snapshot.sourceStates.first(where: { $0.skillID == skillID }) else { return nil }
        guard state.checkingEnabled else { return state }
        do {
            let remote = try await checker.checkRemoteVersion(
                repositoryFullName: state.repositoryFullName,
                skillPath: state.skillPath,
                trackingMode: state.trackingMode
            )
            state.repositoryID = remote.repositoryID
            state.defaultBranch = remote.defaultBranch
            state.availableVersionIdentifier = remote.versionIdentifier
            state.availableVersionName = remote.versionName
            state.availableCommitSHA = remote.commitSHA
            state.availableTreeSHA = remote.treeSHA
            state.lastCheckedAt = now()
            if state.currentTreeSHA == nil {
                state.status = .needsInitialCheck
            } else if state.currentTreeSHA == remote.treeSHA {
                state.status = .current
            } else if state.ignoredVersionIdentifier == remote.versionIdentifier {
                state.status = .ignored
            } else {
                state.status = .updateAvailable
            }
            try await store.updateSourceState(state)
            return state
        } catch GitHubSourceError.authenticationRequired,
                GitHubSourceError.repositoryUnavailableOrUnauthorized {
            state.status = .authenticationRequired
            state.lastCheckedAt = now()
            try await store.updateSourceState(state)
            return state
        } catch {
            state.status = .unavailable
            state.lastCheckedAt = now()
            try await store.updateSourceState(state)
            throw error
        }
    }

    public func ignoreAvailableVersion(skillID: UUID) async throws {
        let snapshot = await store.currentSnapshot()
        guard var state = snapshot.sourceStates.first(where: { $0.skillID == skillID }),
              let version = state.availableVersionIdentifier
        else { return }
        state.ignoredVersionIdentifier = version
        state.status = .ignored
        try await store.updateSourceState(state)
    }

    public func setCheckingEnabled(_ enabled: Bool, skillID: UUID) async throws {
        let snapshot = await store.currentSnapshot()
        guard var state = snapshot.sourceStates.first(where: { $0.skillID == skillID }) else { return }
        state.checkingEnabled = enabled
        state.status = enabled ? .needsInitialCheck : .checkingStopped
        try await store.updateSourceState(state)
    }
}
