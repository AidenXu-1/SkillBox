import Foundation
import Testing
@testable import SkillBoxCore
@testable import SkillBoxApp

@Suite("Source-backed name aliases", .serialized)
struct DiscoveryNameAliasTests {
    @Test("The application verifies the original file and rejects a missing or renamed document", arguments: ["valid", "renamed", "missing"])
    @MainActor
    func actualAliasLookup(_ response: String) async throws {
        AliasProtocol.reset(response)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxAlias-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AliasProtocol.self]
        let provider = DefaultSkillDiscovery.make(tokenProvider: AnonymousGitHubAccessTokenProvider(), session: URLSession(configuration: config), mediaSources: [], catalogEntries: [])
        let suite = "SkillBoxAlias.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(libraryRoot: root, homeDirectory: root, routedDiscoveryProvider: provider, userDefaults: defaults, startBootstrap: false)
        model.discoveryDraft = "我要找一个小黑配图的skill。"
        model.startDiscoverySearch()
        for _ in 0..<500 where model.isDiscoverySearching { try await Task.sleep(for: .milliseconds(10)) }
        let session = try #require(model.selectedDiscoverySession)
        #expect(!model.isDiscoverySearching)
        #expect(session.runs.last?.route == .exact)
        if response == "valid" {
            #expect(session.recommendedCandidates.map(\.name) == ["ian-xiaohei-illustrations"])
            #expect(model.selectedDiscoveryCandidate?.repositoryFullName == "helloianneo/ian-xiaohei-illustrations")
            #expect(model.selectedDiscoveryCandidate?.evidence.skillContentVerified == true)
        } else {
            #expect(session.recommendedCandidates.isEmpty)
        }
        let urls = AliasProtocol.requests()
        #expect(urls.contains { $0.host == "raw.githubusercontent.com" && $0.path == "/helloianneo/ian-xiaohei-illustrations/main/ian-xiaohei-illustrations/SKILL.md" })
        #expect(!urls.contains { $0.path.hasPrefix("/search/") || $0.host == "skills.sh" })
        #expect(urls.count <= 4)
    }

    @Test("Capability terms, unsourced aliases and conflicting identities never become an exact target")
    func aliasEvidenceBoundary() {
        var entry = TrustedSkillCatalogEntry(repository: "author/example", path: "SKILL.md", name: "example", description: "Example", trust: .curated)
        entry.searchAliases = ["去文案AI味"]
        #expect(DiscoverySkillNameAliases.targets(entries: [entry]).isEmpty)
        entry.nameAliases = ["某个中文名"]
        #expect(DiscoverySkillNameAliases.targets(entries: [entry]).isEmpty)
        entry.nameAliasSource = URL(string: "https://github.com/another/example/blob/main/SKILL.md")
        #expect(DiscoverySkillNameAliases.targets(entries: [entry]).isEmpty)
        entry.nameAliasSource = URL(string: "https://github.com/author/example/blob/main/SKILL.md")
        #expect(DiscoverySkillNameAliases.targets(entries: [entry]).count == 1)
        var conflicting = entry
        conflicting.repository = "another/example"
        conflicting.nameAliasSource = URL(string: "https://github.com/another/example/blob/main/SKILL.md")
        #expect(DiscoverySkillNameAliases.targets(entries: [entry, conflicting]).isEmpty)
    }
}

private final class AliasProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = "valid"
    nonisolated(unsafe) private static var urls: [URL] = []
    static func reset(_ value: String) { lock.withLock { response = value; urls = [] } }
    static func requests() -> [URL] { lock.withLock { urls } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let response = Self.lock.withLock { Self.urls.append(url); return Self.response }
        var status = 404
        var body = "{}"
        if url.host == "raw.githubusercontent.com", response != "missing" {
            status = 200
            let name = response == "valid" ? "ian-xiaohei-illustrations" : "unrelated-tool"
            body = "---\nname: \(name)\ndescription: Ian 小黑怪诞正文配图。\n---\n# Ian 小黑怪诞正文配图\n"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
