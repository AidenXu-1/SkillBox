import Foundation

public enum GitHubAutomaticCheckPolicy {
    public static let interval: TimeInterval = 24 * 60 * 60

    public static func isDue(lastCheckedAt: Date?, now: Date = Date()) -> Bool {
        guard let lastCheckedAt else { return true }
        return lastCheckedAt <= now.addingTimeInterval(-interval)
    }
}

public struct GitHubUpdateProgress: Sendable {
    public var completedRepositories: Int
    public var totalRepositories: Int

    public init(completedRepositories: Int, totalRepositories: Int) {
        self.completedRepositories = completedRepositories
        self.totalRepositories = totalRepositories
    }
}

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
        guard let state = snapshot.sourceStates.first(where: { $0.skillID == skillID }) else { return nil }
        guard state.checkingEnabled else { return state }
        return try await checkAll(skillIDs: [skillID]).first ?? state
    }

    public func resumeChecksAfterConnectingGitHub() async throws {
        let snapshot = await store.currentSnapshot()
        var states = snapshot.sourceStates
        var changed = false
        for index in states.indices where states[index].lastCheckIssue == .rateLimited {
            let isKnownAnonymous = states[index].rateLimitScope == .anonymous
            let isLegacyKnownPublic = states[index].rateLimitScope == nil && states[index].repositoryIsPrivate == false
            guard isKnownAnonymous || isLegacyKnownPublic else {
                continue
            }
            states[index].lastCheckIssue = nil
            states[index].retryAfter = nil
            states[index].rateLimitScope = nil
            changed = true
        }
        if changed {
            try await store.replaceSourceStates(states)
        }
    }

    public func migrateLegacyAnonymousRateLimitPauses() async throws {
        let snapshot = await store.currentSnapshot()
        var states = snapshot.sourceStates
        var changed = false
        for index in states.indices where
            states[index].lastCheckIssue == .rateLimited &&
            states[index].rateLimitScope == nil &&
            states[index].repositoryIsPrivate == false
        {
            states[index].lastCheckIssue = nil
            states[index].retryAfter = nil
            changed = true
        }
        if changed {
            try await store.replaceSourceStates(states)
        }
    }

    @discardableResult
    public func checkAll(
        skillIDs: Set<UUID>? = nil,
        progress: (@Sendable (GitHubUpdateProgress) async -> Void)? = nil
    ) async throws -> [GitHubSourceState] {
        let snapshot = await store.currentSnapshot()
        let requested = snapshot.sourceStates.filter { state in
            state.checkingEnabled && (skillIDs == nil || skillIDs?.contains(state.skillID) == true)
        }
        guard !requested.isEmpty else { return [] }
        if requested.contains(where: {
            $0.lastCheckIssue == .rateLimited && ($0.retryAfter ?? .distantPast) > now()
        }) {
            return requested
        }

        var groups: [RepositoryCheckKey: [GitHubSourceState]] = [:]
        var order: [RepositoryCheckKey] = []
        for state in requested {
            let key = RepositoryCheckKey(state: state)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(state)
        }
        order.sort { left, right in
            let leftDate = groups[left]?.map { $0.lastCheckedAt ?? .distantPast }.min() ?? .distantPast
            let rightDate = groups[right]?.map { $0.lastCheckedAt ?? .distantPast }.min() ?? .distantPast
            if leftDate != rightDate { return leftDate < rightDate }
            return left.repositoryFullName < right.repositoryFullName
        }

        var allStates = snapshot.sourceStates
        var completed = 0
        for key in order {
            try Task.checkCancellation()
            guard let group = groups[key] else { continue }
            do {
                let batch = try await checker.checkRemoteVersions(states: group)
                for original in group {
                    let updated: GitHubSourceState
                    if batch.isNotModified {
                        updated = notModifiedState(original, eTag: batch.eTag)
                    } else if let remote = batch.versions[original.skillID] {
                        updated = checkedState(original, remote: remote, eTag: batch.eTag)
                    } else {
                        updated = issueState(original, error: GitHubSourceError.requestFailed(500))
                    }
                    replace(updated, in: &allStates)
                }
            } catch GitHubSourceError.rateLimited(let retryAt, let scope) {
                for index in allStates.indices where allStates[index].checkingEnabled {
                    allStates[index].status = restoredVersionStatus(allStates[index])
                    allStates[index].lastCheckIssue = .rateLimited
                    allStates[index].retryAfter = retryAt
                    allStates[index].rateLimitScope = scope
                }
                try await store.replaceSourceStates(allStates)
                completed += 1
                await progress?(.init(completedRepositories: completed, totalRepositories: order.count))
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                for original in group {
                    replace(issueState(original, error: error), in: &allStates)
                }
            }
            try await store.replaceSourceStates(allStates)
            completed += 1
            await progress?(.init(completedRepositories: completed, totalRepositories: order.count))
        }

        let requestedIDs = Set(requested.map(\.skillID))
        return allStates.filter { requestedIDs.contains($0.skillID) }
    }

    private func checkedState(
        _ original: GitHubSourceState,
        remote: GitHubRemoteVersion,
        eTag: String?
    ) -> GitHubSourceState {
        var state = original
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
        state.versionETag = eTag ?? state.versionETag
        state.lastCheckedAt = now()
        state.lastCheckIssue = nil
        state.retryAfter = nil
        state.rateLimitScope = nil
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
        return state
    }

    private func notModifiedState(_ original: GitHubSourceState, eTag: String?) -> GitHubSourceState {
        var state = original
        state.status = restoredVersionStatus(state)
        state.versionETag = eTag ?? state.versionETag
        state.lastCheckedAt = now()
        state.lastCheckIssue = nil
        state.retryAfter = nil
        state.rateLimitScope = nil
        return state
    }

    private func issueState(_ original: GitHubSourceState, error: Error) -> GitHubSourceState {
        var state = original
        state.status = restoredVersionStatus(state)
        state.retryAfter = nil
        state.rateLimitScope = nil
        switch error {
        case GitHubSourceError.authenticationRequired:
            state.lastCheckIssue = state.repositoryIsPrivate == true ? .authenticationRequired : .temporarilyUnavailable
        case GitHubSourceError.repositoryUnavailableOrUnauthorized:
            state.lastCheckIssue = state.repositoryIsPrivate == true ? .authenticationRequired : .repositoryMissing
        case GitHubSourceError.repositoryPermissionRequired:
            state.lastCheckIssue = state.repositoryIsPrivate == true ? .repositoryPermissionRequired : .repositoryMissing
        default:
            state.lastCheckIssue = .temporarilyUnavailable
        }
        return state
    }

    private func replace(_ state: GitHubSourceState, in states: inout [GitHubSourceState]) {
        guard let index = states.firstIndex(where: { $0.skillID == state.skillID }) else {
            states.append(state)
            return
        }
        states[index] = state
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
        state.rateLimitScope = nil
        try await store.updateSourceState(state)
    }
}

private struct RepositoryCheckKey: Hashable {
    var repositoryFullName: String
    var trackingMode: GitHubTrackingMode

    init(state: GitHubSourceState) {
        repositoryFullName = state.repositoryFullName.lowercased()
        trackingMode = state.trackingMode
    }
}
