import Foundation
import Testing
@testable import SkillBoxCore

@Suite("GitHub update state")
struct GitHubUpdateCheckerTests {
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
        try await store.updateSourceState(fixture.state(skillID: skill.id))

        let state = try await checker.check(skillID: skill.id)
        #expect(state?.status == .authenticationRequired)
        #expect(await store.currentSnapshot().skills.contains { $0.id == skill.id })
    }
}

private struct AuthenticationRequiredChecker: GitHubRemoteVersionChecking {
    func checkRemoteVersion(repositoryFullName: String, skillPath: String?, trackingMode: GitHubTrackingMode) async throws -> GitHubRemoteVersion {
        throw GitHubSourceError.authenticationRequired
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
        let source = root.appendingPathComponent("source/demo")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let candidate = SkillCandidate(
            sourceURL: source,
            directoryName: "demo",
            canonicalName: "demo",
            displayName: "demo",
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
