import Foundation
import Testing
@testable import SkillBoxCore

@Suite("GitHub source provider", .serialized)
struct SourceProviderTests {
    @Test("Release checks resolve the selected Skill tree without downloading an archive")
    func releaseMetadataCheck() async throws {
        let session = RemoteVersionFixture.session()
        let provider = GitHubSourceProvider(session: session)
        let version = try await provider.checkRemoteVersion(
            repositoryFullName: "example/skills",
            skillPath: "skills/demo",
            trackingMode: .latestStableRelease
        )

        #expect(version.versionIdentifier == "release:42")
        #expect(version.versionName == "v1.4.0")
        #expect(version.revision == "v1.4.0")
        #expect(version.commitSHA == "commit-release")
        #expect(version.treeSHA == "demo-tree")
        #expect(RemoteVersionMockURLProtocol.archiveRequestCount == 0)
    }

    @Test("Default-branch checks use the Skill subtree instead of unrelated repository changes")
    func defaultBranchMetadataCheck() async throws {
        let provider = GitHubSourceProvider(session: RemoteVersionFixture.session())
        let version = try await provider.checkRemoteVersion(
            repositoryFullName: "example/skills",
            skillPath: "skills/demo",
            trackingMode: .defaultBranch
        )
        #expect(version.versionIdentifier == "commit:commit-main")
        #expect(version.treeSHA == "demo-tree")
        #expect(version.archiveURL.absoluteString.hasSuffix("/zipball/commit-main"))
    }

    @Test("Confirmed updates download a complete immutable snapshot")
    func completeSnapshotDownload() async throws {
        let fixture = try GitHubArchiveFixture()
        defer { fixture.remove() }
        let provider = GitHubSourceProvider(session: fixture.session())
        let version = GitHubRemoteVersion(
            repositoryID: 7,
            repositoryFullName: "example/skills",
            isPrivate: false,
            trackingMode: .defaultBranch,
            defaultBranch: "main",
            versionIdentifier: "commit:abc123",
            versionName: "main",
            revision: "main",
            commitSHA: "abc123",
            treeSHA: "demo-tree",
            archiveURL: URL(string: "https://codeload.github.com/example/skills/zip/abc123")!
        )

        let snapshot = try await provider.downloadSnapshot(
            version: version,
            skillPath: "skills/demo",
            locator: "https://github.com/example/skills/tree/main/skills/demo"
        )
        let candidate = try #require(snapshot.candidates.first)
        #expect(snapshot.version.commitSHA == "abc123")
        #expect(FileManager.default.fileExists(atPath: candidate.sourceURL.appendingPathComponent("SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: candidate.sourceURL.appendingPathComponent("README.md").path))
        removeRetainedGitHubTemporaryDirectory(for: candidate.sourceURL)
    }

    @Test("Public repository archives are previewed without executing content")
    func githubPreview() async throws {
        let fixture = try GitHubArchiveFixture()
        defer { fixture.remove() }
        let session = fixture.session()
        let provider = GitHubSourceProvider(session: session)
        let candidates = try await provider.preview(locator: "https://github.com/example/skills/tree/main/skills/demo")
        let candidate = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(candidate.canonicalName == "demo")
        #expect(candidate.source.kind == .github)
        #expect(candidate.source.repository == "example/skills")
        #expect(candidate.source.revision == "main")
        #expect(candidate.riskReport.findings.contains { $0.category == .network && $0.severity == .info })
        removeRetainedGitHubTemporaryDirectory(for: candidate.sourceURL)
    }

    @Test("Archive file-count limits stop imports")
    func fileLimit() async throws {
        let fixture = try GitHubArchiveFixture()
        defer { fixture.remove() }
        let provider = GitHubSourceProvider(
            session: fixture.session(),
            limits: .init(maximumDownloadBytes: 10 * 1024 * 1024, maximumExpandedBytes: 25 * 1024 * 1024, maximumFileCount: 1)
        )
        await #expect(throws: GitHubSourceError.self) {
            try await provider.preview(locator: "example/skills")
        }
    }

    @Test("Expanded-size limits stop imports before extraction")
    func expandedSizeLimit() async throws {
        let fixture = try GitHubArchiveFixture()
        defer { fixture.remove() }
        let provider = GitHubSourceProvider(
            session: fixture.session(),
            limits: .init(maximumDownloadBytes: 10 * 1024 * 1024, maximumExpandedBytes: 1, maximumFileCount: 1_000)
        )
        await #expect(throws: GitHubSourceError.self) {
            try await provider.preview(locator: "example/skills")
        }
    }

    @Test("Archive symlinks are rejected before extraction")
    func symlinkArchive() async throws {
        let fixture = try GitHubArchiveFixture(includeSymlink: true)
        defer { fixture.remove() }
        let provider = GitHubSourceProvider(session: fixture.session())
        await #expect(throws: GitHubSourceError.self) {
            try await provider.preview(locator: "example/skills")
        }
    }
}

private func removeRetainedGitHubTemporaryDirectory(for sourceURL: URL) {
    let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
    var temporary = sourceURL.resolvingSymlinksInPath().standardizedFileURL
    while temporary.path.hasPrefix(temporaryRoot), temporary.path != temporaryRoot {
        if temporary.lastPathComponent.hasPrefix("SkillBoxGitHub-") {
            try? FileManager.default.removeItem(at: temporary)
            break
        }
        temporary.deleteLastPathComponent()
    }
}

private final class RemoteVersionMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var archiveRequestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let payload: String
        switch path {
        case "/repos/example/skills":
            payload = #"{"id":7,"full_name":"example/skills","default_branch":"main","private":false}"#
        case "/repos/example/skills/releases/latest":
            payload = #"{"id":42,"tag_name":"v1.4.0","name":"Version 1.4","published_at":"2026-08-15T00:00:00Z","zipball_url":"https://api.github.com/repos/example/skills/zipball/v1.4.0"}"#
        case "/repos/example/skills/commits/v1.4.0":
            payload = #"{"sha":"commit-release","commit":{"tree":{"sha":"root-tree"}}}"#
        case "/repos/example/skills/commits/main":
            payload = #"{"sha":"commit-main","commit":{"tree":{"sha":"root-tree-new"}}}"#
        case "/repos/example/skills/git/trees/root-tree", "/repos/example/skills/git/trees/root-tree-new":
            payload = #"{"tree":[{"path":"README.md","type":"blob","sha":"readme-new"},{"path":"skills","type":"tree","sha":"skills-tree"}]}"#
        case "/repos/example/skills/git/trees/skills-tree":
            payload = #"{"tree":[{"path":"demo","type":"tree","sha":"demo-tree"},{"path":"other","type":"tree","sha":"other-tree"}]}"#
        default:
            Self.archiveRequestCount += 1
            payload = "{}"
        }
        let data = Data(payload.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private enum RemoteVersionFixture {
    static func session() -> URLSession {
        RemoteVersionMockURLProtocol.archiveRequestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteVersionMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockGitHubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var archiveData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isAPI = request.url?.host == "api.github.com"
        let data = isAPI ? Data(#"{"default_branch":"main"}"#.utf8) : Self.archiveData
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": isAPI ? "application/json" : "application/zip"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct GitHubArchiveFixture {
    let root: URL
    let archive: URL

    init(includeSymlink: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxGitHubTests-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("skills-main/skills/demo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n\nRun curl https://example.com manually.\n".write(to: repo.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "reference".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        if includeSymlink {
            try FileManager.default.createSymbolicLink(
                at: repo.appendingPathComponent("outside-link"),
                withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
            )
        }
        archive = root.appendingPathComponent("source.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", root.appendingPathComponent("skills-main").path, archive.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        MockGitHubURLProtocol.archiveData = try Data(contentsOf: archive)
    }

    func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGitHubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
