import Foundation
import Testing
@testable import SkillBoxCore

@Suite("GitHub update state")
struct GitHubUpdateCheckerTests {
    @Test("Rate limiting keeps the known version state and never asks for private repository access")
    func rateLimitIsRecordedSeparatelyFromVersionState() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let skill = try await fixture.importSkill(into: store)
        let retryAt = Date(timeIntervalSince1970: 1_786_809_641)
        let checker = GitHubUpdateChecker(checker: RateLimitedChecker(retryAt: retryAt), store: store)
        try await store.updateSourceState(fixture.state(skillID: skill.id))

        let state = try await checker.check(skillID: skill.id)

        #expect(state?.status == .current)
        #expect(state?.lastCheckIssue == .rateLimited)
        #expect(state?.retryAfter == retryAt)
    }

    @Test("A GitHub limit does not pretend that a version check succeeded")
    func rateLimitKeepsLastSuccessfulCheckTime() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let skill = try await fixture.importSkill(into: store)
        let lastSuccess = Date(timeIntervalSince1970: 100)
        var state = fixture.state(skillID: skill.id)
        state.lastCheckedAt = lastSuccess
        try await store.updateSourceState(state)
        let checker = GitHubUpdateChecker(
            checker: RateLimitedChecker(retryAt: Date(timeIntervalSince1970: 2_000)),
            store: store,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let checked = try await checker.check(skillID: skill.id)

        #expect(checked?.lastCheckedAt == lastSuccess)
    }

    @Test("A failed request does not postpone the next automatic check")
    func temporaryFailureKeepsLastSuccessfulCheckTime() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let skill = try await fixture.importSkill(into: store)
        let lastSuccess = Date(timeIntervalSince1970: 100)
        var state = fixture.state(skillID: skill.id)
        state.lastCheckedAt = lastSuccess
        try await store.updateSourceState(state)
        let checker = GitHubUpdateChecker(
            checker: AuthenticationRequiredChecker(),
            store: store,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let checked = try await checker.check(skillID: skill.id)

        #expect(checked?.lastCheckedAt == lastSuccess)
    }

    @Test("Repeated checks wait until GitHub's retry time instead of sending more requests")
    func rateLimitStopsRepeatedRequests() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let skill = try await fixture.importSkill(into: store)
        let retryAt = Date(timeIntervalSince1970: 2_000)
        let remote = CountingRateLimitedChecker(retryAt: retryAt)
        let checker = GitHubUpdateChecker(checker: remote, store: store, now: { Date(timeIntervalSince1970: 1_000) })
        try await store.updateSourceState(fixture.state(skillID: skill.id))

        _ = try await checker.check(skillID: skill.id)
        _ = try await checker.check(skillID: skill.id)

        #expect(await remote.calls == 1)
    }

    @Test("One GitHub rate limit pauses the remaining repository checks")
    func rateLimitPausesAllTrackedSources() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await fixture.importSkill(named: "first", into: store)
        let second = try await fixture.importSkill(named: "second", into: store)
        let retryAt = Date(timeIntervalSince1970: 2_000)
        let remote = CountingRateLimitedChecker(retryAt: retryAt)
        let checker = GitHubUpdateChecker(checker: remote, store: store, now: { Date(timeIntervalSince1970: 1_000) })
        try await store.updateSourceState(fixture.state(skillID: first.id))
        try await store.updateSourceState(fixture.state(skillID: second.id))

        _ = try await checker.check(skillID: first.id)
        _ = try await checker.check(skillID: second.id)

        #expect(await remote.calls == 1)
        let states = await store.currentSnapshot().sourceStates
        #expect(states.allSatisfy { $0.lastCheckIssue == .rateLimited && $0.retryAfter == retryAt })
    }

    @Test("A batch checks one repository once and updates every Skill in it")
    func sameRepositoryIsCheckedOnce() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await fixture.importSkill(named: "first", into: store)
        let second = try await fixture.importSkill(named: "second", into: store)
        try await store.updateSourceState(fixture.state(skillID: first.id))
        try await store.updateSourceState(fixture.state(skillID: second.id))
        let remote = BatchCountingChecker(version: fixture.remote(identifier: "release:42", tree: "tree-2"))
        let checker = GitHubUpdateChecker(checker: remote, store: store)

        let checked = try await checker.checkAll()

        #expect(await remote.batchCalls == 1)
        #expect(await remote.singleCalls == 0)
        #expect(checked.count == 2)
        #expect(checked.allSatisfy { $0.status == .updateAvailable && $0.versionETag == #""release-v2""# })
    }

    @Test("Not-modified keeps the known version and only refreshes check metadata")
    func notModifiedPreservesKnownState() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let skill = try await fixture.importSkill(into: store)
        var original = fixture.state(skillID: skill.id)
        original.availableVersionIdentifier = "release:42"
        original.status = .updateAvailable
        original.lastCheckIssue = .temporarilyUnavailable
        original.versionETag = #""release-v1""#
        try await store.updateSourceState(original)
        let now = Date(timeIntervalSince1970: 4_000)
        let checker = GitHubUpdateChecker(
            checker: NotModifiedBatchChecker(eTag: #""release-v1""#),
            store: store,
            now: { now }
        )

        let checked = try await checker.checkAll()
        let state = try #require(checked.first)

        #expect(state.status == .updateAvailable)
        #expect(state.availableVersionIdentifier == "release:42")
        #expect(state.lastCheckIssue == nil)
        #expect(state.lastCheckedAt == now)
        #expect(state.versionETag == #""release-v1""#)
    }

    @Test("Automatic checks wait twenty-four hours")
    func automaticCheckIntervalIsOneDay() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(!GitHubAutomaticCheckPolicy.isDue(lastCheckedAt: now.addingTimeInterval(-(23 * 60 * 60)), now: now))
        #expect(GitHubAutomaticCheckPolicy.isDue(lastCheckedAt: now.addingTimeInterval(-(24 * 60 * 60 + 1)), now: now))
        #expect(GitHubAutomaticCheckPolicy.isDue(lastCheckedAt: nil, now: now))
    }

    @Test("Large libraries check the oldest repositories first")
    func oldestRepositoriesAreCheckedFirst() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let recentSkill = try await fixture.importSkill(named: "recent", into: store)
        let oldSkill = try await fixture.importSkill(named: "old", into: store)
        var recent = fixture.state(skillID: recentSkill.id)
        recent.repositoryFullName = "example/recent"
        recent.lastCheckedAt = Date(timeIntervalSince1970: 900)
        var old = fixture.state(skillID: oldSkill.id)
        old.repositoryFullName = "example/old"
        old.lastCheckedAt = Date(timeIntervalSince1970: 100)
        try await store.updateSourceState(recent)
        try await store.updateSourceState(old)
        let remote = RepositoryOrderChecker()
        let checker = GitHubUpdateChecker(checker: remote, store: store)

        _ = try await checker.checkAll()

        #expect(await remote.repositories == ["example/old", "example/recent"])
    }

    @Test("Ignored versions stay quiet but the next version appears")
    func ignoreOnlyOneVersion() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let skill = try await fixture.importSkill(into: store)
        let remote = MockVersionChecker(version: fixture.remote(identifier: "release:42", tree: "tree-2"))
        let checker = GitHubUpdateChecker(checker: remote, store: store)
        try await store.updateSourceState(fixture.state(skillID: skill.id, ignored: "release:42"))
        #expect(try await checker.check(skillID: skill.id)?.status == .ignored)

        await remote.setVersion(fixture.remote(identifier: "release:43", tree: "tree-3"))
        #expect(try await checker.check(skillID: skill.id)?.status == .updateAvailable)
    }

    @Test("Stopped sources do not make a remote request")
    func stoppedDoesNotCheck() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let skill = try await fixture.importSkill(into: store)
        let remote = MockVersionChecker(version: fixture.remote(identifier: "release:42", tree: "tree-2"))
        let checker = GitHubUpdateChecker(checker: remote, store: store)
        var state = fixture.state(skillID: skill.id)
        state.checkingEnabled = false
        state.status = .checkingStopped
        try await store.updateSourceState(state)

        _ = try await checker.check(skillID: skill.id)
        #expect(await remote.calls == 0)
    }

    @Test("Revoked GitHub access pauses checking without removing the local Skill")
    func revokedAccessPausesSafely() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let skill = try await fixture.importSkill(into: store)
        let checker = GitHubUpdateChecker(checker: AuthenticationRequiredChecker(), store: store)
        var sourceState = fixture.state(skillID: skill.id)
        sourceState.repositoryIsPrivate = true
        try await store.updateSourceState(sourceState)

        let state = try await checker.check(skillID: skill.id)
        #expect(state?.status == .current)
        #expect(state?.lastCheckIssue == .authenticationRequired)
        #expect(await store.currentSnapshot().skills.contains { $0.id == skill.id })
    }

    @Test("A public repository never asks the user to connect private GitHub")
    func publicRepositoryAuthenticationFailureUsesNeutralIssue() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let skill = try await fixture.importSkill(into: store)
        let checker = GitHubUpdateChecker(checker: AuthenticationRequiredChecker(), store: store)
        var sourceState = fixture.state(skillID: skill.id)
        sourceState.repositoryIsPrivate = false
        try await store.updateSourceState(sourceState)

        let state = try await checker.check(skillID: skill.id)

        #expect(state?.status == .current)
        #expect(state?.lastCheckIssue == .temporarilyUnavailable)
    }

    @Test("A disconnected private repository asks to reconnect, not to change repository permissions")
    func disconnectedPrivateRepositoryAsksToReconnect() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let skill = try await fixture.importSkill(into: store)
        let checker = GitHubUpdateChecker(checker: RepositoryUnavailableChecker(), store: store)
        var sourceState = fixture.state(skillID: skill.id)
        sourceState.repositoryIsPrivate = true
        try await store.updateSourceState(sourceState)

        let state = try await checker.check(skillID: skill.id)

        #expect(state?.lastCheckIssue == .authenticationRequired)
    }

    @Test("A connected private repository outside the allowed list asks for repository permission")
    func connectedPrivateRepositoryAsksForPermission() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let skill = try await fixture.importSkill(into: store)
        let checker = GitHubUpdateChecker(checker: RepositoryPermissionChecker(), store: store)
        var sourceState = fixture.state(skillID: skill.id)
        sourceState.repositoryIsPrivate = true
        try await store.updateSourceState(sourceState)

        let state = try await checker.check(skillID: skill.id)

        #expect(state?.lastCheckIssue == .repositoryPermissionRequired)
    }

    @Test("Replacing a Release asset is detected even when the repository tree is unchanged")
    func replacedReleaseAssetIsAnUpdate() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let skill = try await fixture.importSkill(into: store)
        var state = fixture.state(skillID: skill.id)
        state.currentReleaseID = 42
        state.currentAssetID = 101
        state.currentAssetName = "demo-pure.zip"
        state.currentAssetDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        state.currentVersionIdentifier = "release:42:asset:101:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        state.currentTreeSHA = "tree-1"
        try await store.updateSourceState(state)

        let asset = GitHubReleaseAsset(
            id: 101,
            name: "demo-pure.zip",
            size: 1_024,
            digest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            browserDownloadURL: URL(string: "https://github.com/example/skills/releases/download/v1.4.0/demo-pure.zip")!
        )
        let remote = GitHubRemoteVersion(
            repositoryID: 7,
            repositoryFullName: "example/skills",
            isPrivate: false,
            trackingMode: .latestStableRelease,
            defaultBranch: "main",
            versionIdentifier: "release:42:asset:101:sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            versionName: "v1.4.0",
            revision: "v1.4.0",
            commitSHA: "commit-1",
            treeSHA: "tree-1",
            archiveURL: asset.browserDownloadURL,
            releaseID: 42,
            releaseAssets: [asset],
            selectedReleaseAssetID: 101
        )

        let result = try await GitHubUpdateChecker(checker: MockVersionChecker(version: remote), store: store).check(skillID: skill.id)
        #expect(result?.status == .updateAvailable)
    }

    @Test("An unchanged asset stays current when GitHub omits its digest")
    func sameReleaseAssetWithoutRemoteDigestStaysCurrent() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let skill = try await fixture.importSkill(into: store)
        var state = fixture.state(skillID: skill.id)
        state.currentReleaseID = 42
        state.currentAssetID = 101
        state.currentAssetName = "demo-pure.zip"
        state.currentAssetDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        state.currentTreeSHA = "tree-1"
        try await store.updateSourceState(state)

        let asset = GitHubReleaseAsset(
            id: 101,
            name: "demo-pure.zip",
            size: 1_024,
            digest: nil,
            browserDownloadURL: URL(string: "https://github.com/example/skills/releases/download/v1.4.0/demo-pure.zip")!
        )
        let remote = GitHubRemoteVersion(
            repositoryID: 7,
            repositoryFullName: "example/skills",
            isPrivate: false,
            trackingMode: .latestStableRelease,
            defaultBranch: "main",
            versionIdentifier: "release:42:asset:101:digest:unavailable",
            versionName: "v1.4.0",
            revision: "v1.4.0",
            commitSHA: "commit-1",
            treeSHA: "tree-1",
            archiveURL: asset.browserDownloadURL,
            releaseID: 42,
            releaseAssets: [asset],
            selectedReleaseAssetID: 101
        )

        let result = try await GitHubUpdateChecker(checker: MockVersionChecker(version: remote), store: store).check(skillID: skill.id)
        #expect(result?.status == .current)
    }

    @Test("Legacy source archive records stay current when the same Release source has not changed")
    func legacySourceArchiveRecordStaysCurrent() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let skill = try await fixture.importSkill(into: store)
        var state = fixture.state(skillID: skill.id)
        state.currentVersionIdentifier = "release:42"
        state.currentVersionName = "v1.4.0"
        state.currentCommitSHA = "commit-1"
        state.currentTreeSHA = "tree-1"
        state.currentReleaseID = nil
        state.currentAssetID = nil
        try await store.updateSourceState(state)

        let remote = GitHubRemoteVersion(
            repositoryID: 7,
            repositoryFullName: "example/skills",
            isPrivate: false,
            trackingMode: .latestStableRelease,
            defaultBranch: "main",
            versionIdentifier: "release:42:source:commit-1",
            versionName: "v1.4.0",
            revision: "v1.4.0",
            commitSHA: "commit-1",
            treeSHA: "tree-1",
            archiveURL: URL(string: "https://api.github.com/archive.zip")!,
            releaseID: 42,
            usesSourceArchiveFallback: true
        )

        let result = try await GitHubUpdateChecker(checker: MockVersionChecker(version: remote), store: store).check(skillID: skill.id)
        #expect(result?.status == .current)

        let persisted = try #require(await store.currentSnapshot().sourceStates.first)
        #expect(persisted.currentReleaseID == 42)
        #expect(persisted.currentVersionIdentifier == "release:42:source:commit-1")
    }

    @Test("Same Release with a newly available install package is not called a new version")
    func sameReleaseInstallPackageAvailabilityHasDedicatedStatus() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let skill = try await fixture.importSkill(into: store)
        var state = fixture.state(skillID: skill.id)
        state.currentVersionIdentifier = "release:42"
        state.currentVersionName = "v1.4.0"
        state.currentCommitSHA = "commit-1"
        state.currentTreeSHA = "tree-1"
        state.currentReleaseID = nil
        state.currentAssetID = nil
        try await store.updateSourceState(state)

        let asset = GitHubReleaseAsset(
            id: 101,
            name: "demo-pure.zip",
            size: 1_024,
            digest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            browserDownloadURL: URL(string: "https://github.com/example/skills/releases/download/v1.4.0/demo-pure.zip")!
        )
        let remote = GitHubRemoteVersion(
            repositoryID: 7,
            repositoryFullName: "example/skills",
            isPrivate: false,
            trackingMode: .latestStableRelease,
            defaultBranch: "main",
            versionIdentifier: "release:42:asset:101:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            versionName: "v1.4.0",
            revision: "v1.4.0",
            commitSHA: "commit-1",
            treeSHA: "tree-1",
            archiveURL: asset.browserDownloadURL,
            releaseID: 42,
            releaseAssets: [asset],
            selectedReleaseAssetID: 101
        )

        let result = try await GitHubUpdateChecker(checker: MockVersionChecker(version: remote), store: store).check(skillID: skill.id)
        #expect(result?.status == .releasePackageAvailable)
    }
}

private struct AuthenticationRequiredChecker: GitHubRemoteVersionChecking {
    func checkRemoteVersion(repositoryFullName: String, skillPath: String?, trackingMode: GitHubTrackingMode) async throws -> GitHubRemoteVersion {
        throw GitHubSourceError.authenticationRequired
    }
}

private struct RepositoryUnavailableChecker: GitHubRemoteVersionChecking {
    func checkRemoteVersion(repositoryFullName: String, skillPath: String?, trackingMode: GitHubTrackingMode) async throws -> GitHubRemoteVersion {
        throw GitHubSourceError.repositoryUnavailableOrUnauthorized
    }
}

private struct RepositoryPermissionChecker: GitHubRemoteVersionChecking {
    func checkRemoteVersion(repositoryFullName: String, skillPath: String?, trackingMode: GitHubTrackingMode) async throws -> GitHubRemoteVersion {
        throw GitHubSourceError.repositoryPermissionRequired
    }
}

private struct RateLimitedChecker: GitHubRemoteVersionChecking {
    let retryAt: Date

    func checkRemoteVersion(repositoryFullName: String, skillPath: String?, trackingMode: GitHubTrackingMode) async throws -> GitHubRemoteVersion {
        throw GitHubSourceError.rateLimited(retryAt: retryAt)
    }
}

private actor CountingRateLimitedChecker: GitHubRemoteVersionChecking {
    let retryAt: Date
    var calls = 0

    init(retryAt: Date) {
        self.retryAt = retryAt
    }

    func checkRemoteVersion(repositoryFullName: String, skillPath: String?, trackingMode: GitHubTrackingMode) async throws -> GitHubRemoteVersion {
        calls += 1
        throw GitHubSourceError.rateLimited(retryAt: retryAt)
    }
}

private actor MockVersionChecker: GitHubRemoteVersionChecking {
    var version: GitHubRemoteVersion
    var calls = 0
    init(version: GitHubRemoteVersion) { self.version = version }
    func setVersion(_ version: GitHubRemoteVersion) { self.version = version }
    func checkRemoteVersion(repositoryFullName: String, skillPath: String?, trackingMode: GitHubTrackingMode) async throws -> GitHubRemoteVersion {
        calls += 1
        return version
    }
}

private actor BatchCountingChecker: GitHubRemoteVersionChecking {
    let version: GitHubRemoteVersion
    var batchCalls = 0
    var singleCalls = 0

    init(version: GitHubRemoteVersion) {
        self.version = version
    }

    func checkRemoteVersion(repositoryFullName: String, skillPath: String?, trackingMode: GitHubTrackingMode) async throws -> GitHubRemoteVersion {
        singleCalls += 1
        return version
    }

    func checkRemoteVersions(states: [GitHubSourceState]) async throws -> GitHubRemoteCheckBatch {
        batchCalls += 1
        return GitHubRemoteCheckBatch(
            versions: Dictionary(uniqueKeysWithValues: states.map { ($0.skillID, version) }),
            eTag: #""release-v2""#
        )
    }
}

private struct NotModifiedBatchChecker: GitHubRemoteVersionChecking {
    let eTag: String

    func checkRemoteVersion(repositoryFullName: String, skillPath: String?, trackingMode: GitHubTrackingMode) async throws -> GitHubRemoteVersion {
        throw GitHubSourceError.requestFailed(500)
    }

    func checkRemoteVersions(states: [GitHubSourceState]) async throws -> GitHubRemoteCheckBatch {
        GitHubRemoteCheckBatch(versions: [:], eTag: eTag, isNotModified: true)
    }
}

private actor RepositoryOrderChecker: GitHubRemoteVersionChecking {
    var repositories: [String] = []

    func checkRemoteVersion(
        repositoryFullName: String,
        skillPath: String?,
        trackingMode: GitHubTrackingMode
    ) async throws -> GitHubRemoteVersion {
        fatalError("Batch API expected")
    }

    func checkRemoteVersions(states: [GitHubSourceState]) async throws -> GitHubRemoteCheckBatch {
        let repository = states[0].repositoryFullName
        repositories.append(repository)
        let versions = Dictionary(uniqueKeysWithValues: states.map { state in
            let version = GitHubRemoteVersion(
                repositoryID: state.repositoryID ?? 7,
                repositoryFullName: repository,
                isPrivate: state.repositoryIsPrivate ?? false,
                trackingMode: state.trackingMode,
                defaultBranch: state.defaultBranch ?? "main",
                versionIdentifier: state.currentVersionIdentifier ?? "release:41",
                versionName: state.currentVersionName ?? "v1.0.0",
                revision: "v1.0.0",
                commitSHA: state.currentCommitSHA ?? "commit",
                treeSHA: state.currentTreeSHA ?? "tree",
                archiveURL: URL(string: "https://api.github.com/archive.zip")!
            )
            return (state.skillID, version)
        })
        return GitHubRemoteCheckBatch(versions: versions)
    }
}

private struct UpdateFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxUpdateTests-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func store() throws -> LibraryStore { try LibraryStore(root: root.appendingPathComponent("store")) }
    func importSkill(into store: LibraryStore) async throws -> SkillRecord {
        try await importSkill(named: "demo", into: store)
    }
    func importSkill(named name: String, into store: LibraryStore) async throws -> SkillRecord {
        let source = root.appendingPathComponent("source/\(name)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: Demo\n---\n".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let candidate = SkillCandidate(
            sourceURL: source,
            directoryName: name,
            canonicalName: name,
            displayName: name,
            description: "Demo",
            fingerprint: try SHA256SkillFingerprinter().fingerprint(directory: source),
            source: .init(kind: .github, displayName: "example/skills", locator: "https://github.com/example/skills", repository: "example/skills", revision: "old", skillPath: "skills/demo"),
            riskReport: try StaticRiskAnalyzer().analyze(skillDirectory: source)
        )
        return try await store.importCandidate(candidate)
    }
    func state(skillID: UUID, ignored: String? = nil) -> GitHubSourceState {
        .init(skillID: skillID, repositoryFullName: "example/skills", skillPath: "skills/demo", trackingMode: .latestStableRelease, currentVersionIdentifier: "release:41", currentVersionName: "v1.3.0", currentCommitSHA: "commit-1", currentTreeSHA: "tree-1", ignoredVersionIdentifier: ignored, status: .current)
    }
    func remote(identifier: String, tree: String) -> GitHubRemoteVersion {
        .init(repositoryID: 7, repositoryFullName: "example/skills", isPrivate: false, trackingMode: .latestStableRelease, defaultBranch: "main", versionIdentifier: identifier, versionName: identifier.replacingOccurrences(of: "release:", with: "v"), revision: "tag", commitSHA: "commit", treeSHA: tree, archiveURL: URL(string: "https://api.github.com/archive.zip")!)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
