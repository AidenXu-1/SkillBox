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
        if state.lastCheckIssue == .rateLimited,
           let retryAfter = state.retryAfter,
           retryAfter > now()
        {
            return state
        }
        do {
            let remote = try await checker.checkRemoteVersion(
                repositoryFullName: state.repositoryFullName,
                skillPath: state.skillPath,
                trackingMode: state.trackingMode
            )
            state.repositoryID = remote.repositoryID
            state.repositoryIsPrivate = remote.isPrivate
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
            state.lastCheckIssue = nil
            state.retryAfter = nil
            if legacySourceArchiveRecordIsCurrent(state: state, remote: remote) {
                state.currentReleaseID = remote.releaseID
                state.currentVersionIdentifier = remote.versionIdentifier
            }
            if state.currentTreeSHA == nil {
                state.status = .needsInitialCheck
            } else if isCurrent(state: state, remote: remote) {
                state.status = .current
            } else if state.ignoredVersionIdentifier == remote.versionIdentifier {
                state.status = .ignored
            } else if sameReleaseHasNewInstallPackage(state: state, remote: remote) {
                state.status = .releasePackageAvailable
            } else {
                state.status = .updateAvailable
            }
            try await store.updateSourceState(state)
            return state
        } catch GitHubSourceError.rateLimited(let retryAt) {
            let checkedAt = now()
            var states = snapshot.sourceStates
            for index in states.indices where states[index].checkingEnabled {
                states[index].status = restoredVersionStatus(states[index])
                states[index].lastCheckIssue = .rateLimited
                states[index].retryAfter = retryAt
                states[index].lastCheckedAt = checkedAt
            }
            try await store.replaceSourceStates(states)
            return states.first(where: { $0.skillID == skillID })
        } catch GitHubSourceError.authenticationRequired {
            state.status = restoredVersionStatus(state)
            state.lastCheckIssue = state.repositoryIsPrivate == true ? .authenticationRequired : .temporarilyUnavailable
            state.retryAfter = nil
            state.lastCheckedAt = now()
            try await store.updateSourceState(state)
            return state
        } catch GitHubSourceError.repositoryUnavailableOrUnauthorized {
            state.status = restoredVersionStatus(state)
            state.lastCheckIssue = state.repositoryIsPrivate == true ? .authenticationRequired : .repositoryMissing
            state.retryAfter = nil
            state.lastCheckedAt = now()
            try await store.updateSourceState(state)
            return state
        } catch GitHubSourceError.repositoryPermissionRequired {
            state.status = restoredVersionStatus(state)
            state.lastCheckIssue = state.repositoryIsPrivate == true ? .repositoryPermissionRequired : .repositoryMissing
            state.retryAfter = nil
            state.lastCheckedAt = now()
            try await store.updateSourceState(state)
            return state
        } catch {
            state.status = restoredVersionStatus(state)
            state.lastCheckIssue = .temporarilyUnavailable
            state.retryAfter = nil
            state.lastCheckedAt = now()
            try await store.updateSourceState(state)
            return state
        }
    }

    private func restoredVersionStatus(_ state: GitHubSourceState) -> GitHubSourceStatus {
        guard state.status == .authenticationRequired || state.status == .unavailable else { return state.status }
        guard state.checkingEnabled else { return .checkingStopped }
        guard state.currentTreeSHA != nil else { return .needsInitialCheck }
        if state.ignoredVersionIdentifier == state.availableVersionIdentifier,
           state.availableVersionIdentifier != nil
        {
            return .ignored
        }
        if state.availableVersionIdentifier != nil,
           state.availableVersionIdentifier != state.currentVersionIdentifier
        {
            return .updateAvailable
        }
        return .current
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

    private func legacySourceArchiveRecordIsCurrent(state: GitHubSourceState, remote: GitHubRemoteVersion) -> Bool {
        guard remote.trackingMode == .latestStableRelease,
              remote.usesSourceArchiveFallback,
              let remoteReleaseID = remote.releaseID
        else { return false }
        return state.currentReleaseID == nil
            && state.currentAssetID == nil
            && state.currentVersionIdentifier == "release:\(remoteReleaseID)"
            && state.currentCommitSHA == remote.commitSHA
            && state.currentTreeSHA == remote.treeSHA
    }

    private func sameReleaseHasNewInstallPackage(state: GitHubSourceState, remote: GitHubRemoteVersion) -> Bool {
        guard remote.trackingMode == .latestStableRelease,
              !remote.usesSourceArchiveFallback,
              let remoteReleaseID = remote.releaseID,
              remote.selectedReleaseAsset != nil
        else { return false }
        return state.currentReleaseID == nil
            && state.currentAssetID == nil
            && state.currentVersionIdentifier == "release:\(remoteReleaseID)"
            && state.currentCommitSHA == remote.commitSHA
            && state.currentTreeSHA == remote.treeSHA
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
        state.lastCheckIssue = nil
        state.retryAfter = nil
        try await store.updateSourceState(state)
    }
}
