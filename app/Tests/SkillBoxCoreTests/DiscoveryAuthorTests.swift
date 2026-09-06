import Foundation
import Testing
@testable import SkillBoxCore
@testable import SkillBoxApp

@Suite("Author scoped discovery", .serialized)
struct DiscoveryAuthorTests {
    @Test("Colloquial author requests keep the author identity", arguments: ["帮我找到卡兹克那个写作的Skill。", "帮我找卡兹克的写作 Skill", "帮我找 KKKKhazix 的写作 Skill", "帮我找卡兹克写作的skill。", "我记得卡兹克有两个写作skill啊。"])
    func authorRouting(_ message: String) {
        let plan = DiscoveryIntentPlanner.fallback(message: message, previous: nil)
        #expect(plan.intent.route == .hybrid)
        #expect(plan.intent.targets.contains { $0.kind == .author })
    }

    @Test("Author identity does not establish capability or admit another author")
    func rankingRequiresAuthorAndCapability() {
        let intent = DiscoveryIntent(goal: "帮我找到卡兹克那个写作的Skill。", route: .hybrid, targets: [.init(kind: .author, value: "卡兹克")])
        let values = [
            candidate("khazix-writer", "kkkkhazix/khazix-skills", "数字生命卡兹克的公众号长文写作 Skill。用于写文章和改稿。"),
            candidate("human-writing", "KKKKhazix/human-writing", "通用中文创作与改稿，写作之前核准材料，清除 AI 味。"),
            candidate("hv-analysis", "kkkkhazix/khazix-skills", "卡兹克的横纵分析，研究产品并生成 PDF 报告。不要用于公众号写作（那个用 khazix-writer）。"),
            candidate("human-writing", "copycat/skills", "中文写作与改稿。"),
        ]
        let ranked = DiscoveryCandidateRanker.rank(values, intent: intent, originalQueryCandidateIDs: Set(values.map(\.id)))
        #expect(Set(ranked.recommended.map(\.name)) == ["khazix-writer", "human-writing"])
        #expect(ranked.recommended.allSatisfy { $0.repositoryFullName.lowercased().hasPrefix("kkkkhazix/") })
    }

    @Test("Production lookup queries the author across repositories before spending verification slots")
    func authorAcrossRepositories() async throws {
        AuthorProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthorProtocol.self]
        let provider = DefaultSkillDiscovery.make(tokenProvider: AnonymousGitHubAccessTokenProvider(), session: URLSession(configuration: config), mediaSources: [], catalogEntries: [])
        let plan = DiscoveryIntentPlanner.fallback(message: "帮我找到卡兹克那个写作的Skill。", previous: nil)
        let result = try await provider.search(plan: plan, limitPerQuery: 64)
        let ranked = DiscoveryCandidateRanker.rank(result.batch.candidates, intent: plan.intent, originalQueryCandidateIDs: result.batch.originalQueryCandidateIDs)
        #expect(Set(ranked.recommended.map(\.name)) == ["khazix-writer", "human-writing"])
        let requests = AuthorProtocol.requests()
        #expect(requests.contains { $0.host == "skills.sh" && URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value == "KKKKhazix" })
        #expect(!requests.contains { $0.host == "raw.githubusercontent.com" && $0.path.hasPrefix("/copycat/") })
        #expect(result.batch.requestUsage?.githubAPIRequests == 0)
    }

    @Test("The application delivers both author repositories in its final visible list")
    @MainActor
    func applicationShowsBoth() async throws {
        AuthorProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxAuthorTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthorProtocol.self]
        let provider = DefaultSkillDiscovery.make(tokenProvider: AnonymousGitHubAccessTokenProvider(), session: URLSession(configuration: config), mediaSources: [], catalogEntries: [])
        let suite = "SkillBoxAuthorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(libraryRoot: root, homeDirectory: root, routedDiscoveryProvider: provider, userDefaults: defaults, startBootstrap: false)
        model.discoveryDraft = "帮我找卡兹克写作的skill。"
        model.startDiscoverySearch()
        for _ in 0..<200 where !model.discoveryDraft.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<200 where model.isDiscoverySearching { try await Task.sleep(for: .milliseconds(10)) }
        let session = try #require(model.selectedDiscoverySession)
        #expect(Set(session.recommendedCandidates.map(\.name)) == ["khazix-writer", "human-writing"])
        #expect(session.intent?.targets == [.init(kind: .author, value: "卡兹克")])
        #expect(model.selectedDiscoveryCandidate != nil)

        for message in ["我记得卡兹克有两个写作skill啊。", "有个human writing的skill。"] {
            model.discoveryDraft = message
            model.startDiscoverySearch()
            for _ in 0..<300 where model.isDiscoverySearching { try await Task.sleep(for: .milliseconds(10)) }
            let followup = try #require(model.selectedDiscoverySession)
            #expect(followup.intent?.goal == session.intent?.goal)
            #expect(followup.intent?.targets.contains(.init(kind: .author, value: "卡兹克")) == true)
            #expect(!followup.messages.contains { $0.text.hasPrefix("上一任务的结果") })
        }
        let final = try #require(model.selectedDiscoverySession)
        #expect(final.runs.last?.route == .exact)
        #expect(final.recommendedCandidates.map(\.name) == ["human-writing"])
        #expect(final.recommendedCandidates.map { $0.repositoryFullName.lowercased() } == ["kkkkhazix/human-writing"])
    }

    @Test("Popularity does not discard a name within the specified author")
    func namedAuthorPopularity() async throws {
        AuthorProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthorProtocol.self]
        let provider = DefaultSkillDiscovery.make(tokenProvider: AnonymousGitHubAccessTokenProvider(), session: URLSession(configuration: config), mediaSources: [], catalogEntries: [])
        let plan = DiscoveryIntentPlanner.fallback(message: "帮我找卡兹克的 human-writing Skill，热门吗", previous: nil)
        #expect(plan.intent.route == .hybrid)
        let result = try await provider.search(plan: plan, limitPerQuery: 64)
        #expect(result.batch.candidates.map(\.name) == ["human-writing"])
    }

    private func candidate(_ name: String, _ repo: String, _ summary: String) -> DiscoveryCandidate {
        var value = DiscoveryCandidate(id: repo + "/" + name, name: name, summary: summary, repositoryFullName: repo, installCount: 1000)
        value.evidence.skillContentVerified = true
        value.evidence.skillSummary = summary
        value.evidence.repositoryIsPrivate = false
        return value
    }
}

private final class AuthorProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var urls: [URL] = []
    static func reset() { lock.lock(); defer { lock.unlock() }; urls = [] }
    static func requests() -> [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock(); Self.urls.append(url); Self.lock.unlock()
        var body = "{}"
        var status = 200
        if url.host == "skills.sh", url.path == "/api/search" {
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value
            var entries: [[String: Any]] = (0..<16).map { ["id": "copycat/skills/noise-\($0)", "name": "noise-\($0)", "source": "copycat/skills", "installs": 10000] }
            entries.append(["id":"kkkkhazix/khazix-skills/khazix-writer", "name":"khazix-writer", "source":"kkkkhazix/khazix-skills", "installs":2986])
            if ["KKKKhazix", "human writing", "human-writing"].contains(q ?? "") { entries.append(["id":"kkkkhazix/human-writing/human-writing", "name":"human-writing", "source":"kkkkhazix/human-writing", "installs":502]) }
            if q == "human writing" { entries.append(["id":"copycat/human-writing/human-writing", "name":"human-writing", "source":"copycat/human-writing", "installs":10000]) }
            body = String(data: try! JSONSerialization.data(withJSONObject: ["skills": entries]), encoding: .utf8)!
        } else if url.host == "raw.githubusercontent.com" {
            let name = url.path.contains("human-writing") ? "human-writing" : "khazix-writer"
            body = "---\nname: \(name)\ndescription: 中文写作与文章改稿，去除 AI 味。\n---\n# 写作\n核准材料再撰写文章。"
        } else if url.host == "api.github.com" { status = 503 }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
