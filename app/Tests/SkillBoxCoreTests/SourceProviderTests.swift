import Foundation
import Testing
@testable import SkillBoxCore

@Suite("GitHub source provider", .serialized)
struct SourceProviderTests {
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
        let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        var temporary = candidate.sourceURL.resolvingSymlinksInPath().standardizedFileURL
        while temporary.path.hasPrefix(temporaryRoot), temporary.path != temporaryRoot {
            if temporary.lastPathComponent.hasPrefix("SkillBoxGitHub-") {
                try? FileManager.default.removeItem(at: temporary)
                break
            }
            temporary.deleteLastPathComponent()
        }
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
