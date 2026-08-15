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
            state.availableReleaseID = remote.releaseID
            state.availableAssetID = remote.selectedReleaseAsset?.id
            state.availableAssetName = remote.selectedReleaseAsset?.name
            state.availableAssetDigest = remote.selectedReleaseAsset?.digest
            state.lastCheckedAt = now()
            if state.currentTreeSHA == nil {
                state.status = .needsInitialCheck
            } else if isCurrent(state: state, remote: remote) {
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

    private func isCurrent(state: GitHubSourceState, remote: GitHubRemoteVersion) -> Bool {
        guard remote.trackingMode == .latestStableRelease else {
            return state.currentTreeSHA == remote.treeSHA
        }

        guard let remoteReleaseID = remote.releaseID else {
            return state.currentTreeSHA == remote.treeSHA
        }

        guard state.currentReleaseID == remoteReleaseID else { return false }

        if remote.usesSourceArchiveFallback {
            return state.currentAssetID == nil && state.currentCommitSHA == remote.commitSHA
        }

        guard let currentAssetID = state.currentAssetID,
              let remoteAsset = remote.selectedReleaseAsset
                ?? remote.releaseAssets.first(where: { $0.id == currentAssetID }),
              currentAssetID == remoteAsset.id
        else { return false }

        guard let remoteDigest = normalizedDigest(remoteAsset.digest) else { return true }
        return normalizedDigest(state.currentAssetDigest) == remoteDigest
    }

    private func normalizedDigest(_ digest: String?) -> String? {
        digest?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
