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
