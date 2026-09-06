import Foundation
import Testing
@testable import SkillBoxCore
@testable import SkillBoxApp

@Suite("Exact Skill names", .serialized)
struct DiscoveryExactNameTests {
    @Test("Natural name positions preserve the whole identity", arguments: [
        ("wechat-layout-publisher找一下这个skill", "wechat-layout-publisher"),
        ("帮我找一个叫Agent-Team-Skill的开发Skill。", "Agent-Team-Skill"),
        ("human-writing", "human-writing"),
        ("帮我找一下 human-writing", "human-writing"),
        ("帮我找 Agent Team Skill", "Agent Team"),
        ("找一个名为 Humanizer 的 Skill", "Humanizer"),
    ])
    func naturalNames(_ input: (String, String)) {
        let plan = DiscoveryIntentPlanner.fallback(message: input.0, previous: nil)
        #expect(plan.intent.route == .exact)
        #expect(plan.intent.targets == [.init(kind: .skillName, value: input.1)])
        #expect(plan.queries == [input.1])
    }

    @Test("Capabilities and authors keep their original search routes", arguments: [
        ("帮我找一个去文案AI味的skill", DiscoverySearchRoute.scenario),
        ("帮我找一个 PPT/Excel 的 Skill", .scenario),
        ("帮我找卡兹克的写作Skill", .hybrid),
        ("帮我找 AI-powered 写作工具", .scenario),
        ("帮我找一个做图文的小黑元素的Skill", .scenario),
    ])
    func otherRequests(_ input: (String, DiscoverySearchRoute)) {
        #expect(DiscoveryRequestRouter.classify(message: input.0, previousIntent: nil).route == input.1)
    }

    @Test("An unindexed name is discovered by bounded anonymous repository lookup")
    func publicRepositoryLookup() async throws {
        ExactNameProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExactNameProtocol.self]
        let provider = DefaultSkillDiscovery.make(tokenProvider: AnonymousGitHubAccessTokenProvider(), session: URLSession(configuration: config), mediaSources: [], catalogEntries: [])
        let plan = DiscoveryIntentPlanner.fallback(message: "帮我找一个叫Agent-Team-Skill的开发Skill。", previous: nil)
        let result = try await provider.search(plan: plan, limitPerQuery: 64)
        #expect(result.outcome == .exactFound)
        #expect(result.batch.candidates.map(\.name) == ["agent-team"])
        #expect(result.batch.candidates.first?.repositoryFullName == "example/agent-team-skill")
        let urls = ExactNameProtocol.requests()
        #expect(urls.filter { $0.host == "api.github.com" }.count == 1)
        #expect(!urls.contains { $0.path.hasPrefix("/unrelated/") })
        #expect(!urls.contains { $0.path.contains("/search/code") })
        #expect(result.batch.requestUsage?.networkRequests == 3)
    }

    @Test("The application shows the verified named object as its final result", arguments: [
        ("帮我找一个叫Agent-Team-Skill的开发Skill。", "agent-team", "example/agent-team-skill"),
        ("我找一下vibe-project-foundation-skill这个skill", "vibe-project-foundation", "example/vibe-project-foundation-skill"),
    ])
    @MainActor
    func applicationExactResult(_ input: (String, String, String)) async throws {
        ExactNameProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxExactTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExactNameProtocol.self]
        let provider = DefaultSkillDiscovery.make(tokenProvider: AnonymousGitHubAccessTokenProvider(), session: URLSession(configuration: config), mediaSources: [], catalogEntries: [])
        let suite = "SkillBoxExactTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(libraryRoot: root, homeDirectory: root, routedDiscoveryProvider: provider, userDefaults: defaults, startBootstrap: false)
        model.discoveryDraft = input.0
        model.startDiscoverySearch()
        for _ in 0..<300 where model.isDiscoverySearching { try await Task.sleep(for: .milliseconds(10)) }
        let session = try #require(model.selectedDiscoverySession)
        #expect(session.recommendedCandidates.map(\.name) == [input.1])
        #expect(model.selectedDiscoveryCandidate?.repositoryFullName == input.2)
        #expect(session.runs.last?.route == .exact)
        #expect(session.runs.last?.diagnostics.isEmpty == true)
    }

    @Test("Ambiguous names spend no search requests and a complete reply resumes exact lookup")
    @MainActor
    func applicationClarification() async throws {
        ExactNameProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxNameClarification-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExactNameProtocol.self]
        let provider = DefaultSkillDiscovery.make(tokenProvider: AnonymousGitHubAccessTokenProvider(), session: URLSession(configuration: config), mediaSources: [], catalogEntries: [])
        let suite = "SkillBoxNameClarification.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(libraryRoot: root, homeDirectory: root, routedDiscoveryProvider: provider, userDefaults: defaults, startBootstrap: false)
        for input in ["alpha-tools这个skill和beta-tools这个skill", "第一个"] {
            model.discoveryDraft = input
            model.startDiscoverySearch()
            for _ in 0..<300 where model.isDiscoverySearching { try await Task.sleep(for: .milliseconds(10)) }
            let session = try #require(model.selectedDiscoverySession)
            #expect(session.pendingClarification != nil)
            #expect(session.runs.last?.queries.isEmpty == true)
            #expect(session.runs.last?.diagnostics.isEmpty == true)
            #expect(ExactNameProtocol.requests().isEmpty)
        }
        model.discoveryDraft = "vibe-project-foundation-skill"
        model.startDiscoverySearch()
        for _ in 0..<300 where model.isDiscoverySearching { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.selectedDiscoverySession?.pendingClarification == nil)
        #expect(model.selectedDiscoveryCandidate?.name == "vibe-project-foundation")
    }

    @Test("A collection's child does not inherit the repository name")
    func repositoryAliasIsRootOnly() async throws {
        let stub = ExactIdentityFixture()
        let provider = RoutedSkillDiscoveryProvider(exactProvider: stub, scenarioProvider: stub, hybridProvider: stub)
        let plan = DiscoveryIntentPlanner.fallback(message: "agent-team-skill", previous: nil)
        let result = try await provider.search(plan: plan, limitPerQuery: 64)
        #expect(result.batch.candidates.map(\.id) == ["root"])
    }
}

private struct ExactIdentityFixture: SkillDiscoveryProvider {
    func search(query: String, limit: Int) async throws -> DiscoverySearchResult {
        .init(candidates: [], hasMoreResults: false)
    }
    func search(queries: [String], limitPerQuery: Int) async throws -> DiscoveryBatchSearchResult {
        let root = DiscoveryCandidate(id: "root", name: "agent-team", summary: "Team", repositoryFullName: "first/agent-team-skill", evidence: .init(skillContentVerified: true))
        let child = DiscoveryCandidate(id: "child", name: "unrelated", summary: "Other", repositoryFullName: "second/agent-team-skill", skillPath: "skills/unrelated", evidence: .init(skillContentVerified: true))
        return .init(candidates: [root, child], originalQueryCandidateIDs: ["root", "child"])
    }
}

private final class ExactNameProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var urls: [URL] = []
    static func reset() { lock.withLock { urls = [] } }
    static func requests() -> [URL] { lock.withLock { urls } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.withLock { Self.urls.append(url) }
        var status = 200
        let body: String
        if url.host == "skills.sh" {
            body = #"{"skills":[{"id":"unrelated/skills/team","name":"team","source":"unrelated/skills","installs":10000}]}"#
        } else if url.path == "/search/repositories" {
            if url.query?.contains("vibe-project-foundation-skill") == true {
                body = #"{"total_count":1,"items":[{"full_name":"example/vibe-project-foundation-skill","stargazers_count":1,"archived":false,"disabled":false,"private":false}]}"#
            } else {
                body = #"{"total_count":2,"items":[{"full_name":"unrelated/agent-team-skills","stargazers_count":99999,"archived":false,"disabled":false,"private":false},{"full_name":"example/agent-team-skill","stargazers_count":1,"archived":false,"disabled":false,"private":false}]}"#
            }
        } else if url.host == "raw.githubusercontent.com", url.path == "/example/vibe-project-foundation-skill/HEAD/SKILL.md" {
            body = "---\nname: vibe-project-foundation\ndescription: Establish a project foundation.\n---\n"
        } else if url.host == "raw.githubusercontent.com", url.path == "/example/agent-team-skill/HEAD/SKILL.md" {
            body = "---\nname: agent-team\ndescription: Coordinate a development team.\n---\n"
        } else { status = 404; body = "{}" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
