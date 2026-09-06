import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Scenario discovery coverage", .serialized)
struct DiscoveryScenarioCoverageTests {
    @Test("Directory stars are separate from installs and preserve rounded source values")
    func directoryStars() throws {
        let html = "<span>Installs</span><div>99K</div><span>GitHub Stars</span><div><svg><path /></svg>7.3K</div><span>First Seen</span><div>2026</div>"
        #expect(SkillsShDiscoveryProvider.directoryStars(in: html) == "7.3K")
        #expect(SkillsShDiscoveryProvider.directoryStars(in: "<span>Installs</span><div>99K</div>") == nil)
        #expect(SkillsShDiscoveryProvider.directoryStars(in: "<span>GitHub Stars</span><div>Unavailable</div><span>First Seen</span><div>2026</div>") == nil)
        var candidate = DiscoveryCandidate(id: "stars", name: "stars", repositoryFullName: "author/stars", installCount: 99000)
        candidate.repositoryStarsText = "7.3K"
        let restored = try JSONDecoder().decode(DiscoveryCandidate.self, from: JSONEncoder().encode(candidate))
        #expect(DiscoveryPopularityPresentation(candidate: restored).repositoryStarsValue == "7.3K Stars")
    }
    @Test("Humanizing requests resolve curated task aliases before spending verification budget")
    func taskAliases() {
        let plan = DiscoveryIntentPlanner.fallback(message: "推荐去文案AI味的skill。", previous: nil)
        #expect(plan.intent.route == .scenario)
        for name in ["humanizer", "no-ai-slop", "human-writing", "khazix-writer"] {
            #expect(plan.queries.contains(name), "Missing task alias: \(name)")
        }
        #expect(plan.queries.count <= 8)
        #expect(plan.queries.first == "推荐去文案AI味的skill。")
        let exact = DiscoveryIntentPlanner.fallback(message: "我找一下vibe-project-foundation-skill这个skill", previous: nil)
        #expect(exact.queries == ["vibe-project-foundation-skill"])
    }

    @Test("Verified body capability is usable without inventing relevance from a name")
    func bodyCapability() {
        var candidate = DiscoveryCandidate(id: "author/voice", name: "voice", summary: "公众号长文写作。", repositoryFullName: "author/voice", installCount: 2000)
        candidate.evidence.skillContentVerified = true
        candidate.evidence.skillSummary = candidate.summary
        candidate.evidence.skillDocumentExcerpt = "# 写作\n讲人话，像个活人。AI时代最稀缺的是活人感。保留亲身经历、真实感受。"
        let result = DiscoveryCandidateRanker.rank([candidate], intent: .init(goal: "推荐去文案AI味的skill。"), originalQueryCandidateIDs: [])
        #expect(result.recommended.map(\.id) == [candidate.id])
        candidate.evidence.skillSummary = "Does not rewrite or humanize text."
        #expect(DiscoveryCandidateRanker.rank([candidate], intent: .init(goal: "去AI味"), originalQueryCandidateIDs: []).recommended.isEmpty)
    }

    @Test("API document examples do not establish a writing capability")
    func incidentalBodyExamples() {
        let candidate = DiscoveryCandidate(id: "api", name: "claude-api", summary: "Reference for an API SDK: model ids, streaming, agents, tools and migration.", repositoryFullName: "official/sdk", installCount: 20000,
            evidence: .init(skillDocumentExcerpt: "# API examples\nAsk the model to rewrite prose and humanize writing.\n", skillContentVerified: true))
        #expect(DiscoveryCandidateRanker.rank([candidate], intent: .init(goal: "去文案AI味"), originalQueryCandidateIDs: []).recommended.isEmpty)
    }

    @Test("Recommendations have no fixed five-result cap")
    func noFiveCap() {
        let candidates = (0..<9).map { index in
            DiscoveryCandidate(id: "fixture/\(index)", name: "tool-\(index)", summary: "Rewrite prose to remove AI writing patterns.", repositoryFullName: "fixture/tool-\(index)", installCount: 1000,
                evidence: .init(skillContentVerified: true))
        }
        #expect(DiscoveryCandidateRanker.rank(candidates, intent: .init(goal: "去AI味"), originalQueryCandidateIDs: []).recommended.count == 9)
    }

    @Test("Editing plus optional detection is not misclassified as detection-only")
    func dualPurposeEditing() {
        let summary = "Edit drafts into sharper, more human writing while preserving the writer's personal voice, or detect AI-slop patterns without rewriting. Use when a draft should be less AI-sounding."
        let candidate = DiscoveryCandidate(id: "dual", name: "dual-editor", summary: summary, repositoryFullName: "author/dual", installCount: 1000, evidence: .init(skillContentVerified: true))
        #expect(DiscoveryCandidateRanker.rank([candidate], intent: .init(goal: "去文案AI味"), originalQueryCandidateIDs: []).recommended.count == 1)
    }

    @Test("Korean-only descriptions do not become general Chinese rewrite recommendations")
    func nativeLanguageScope() {
        let candidate = DiscoveryCandidate(id: "korean", name: "humanizer", summary: "AI가 생성한 한국어 텍스트를 자연스럽게 변환합니다.", repositoryFullName: "example/korean", installCount: 4000,
            evidence: .init(skillDocumentExcerpt: "Humanize writing and remove AI writing patterns.", skillContentVerified: true))
        #expect(DiscoveryCandidateRanker.rank([candidate], intent: .init(goal: "去文案AI味"), originalQueryCandidateIDs: []).recommended.isEmpty)
        #expect(DiscoveryCandidateRanker.rank([candidate], intent: .init(goal: "去韩语文案AI味"), originalQueryCandidateIDs: []).recommended.count == 1)
    }

    @Test("Rounded directory installs cannot invent precision or cross the quality threshold")
    func roundedInstallThreshold() throws {
        var candidate = DiscoveryCandidate(id: "rounded", name: "humanizer", summary: "Rewrite prose to remove AI writing patterns.", repositoryFullName: "fixture/humanizer", evidence: .init(skillContentVerified: true))
        candidate.installCountText = "0.5K"
        #expect(candidate.verifiedInstallCountLowerBound == 450)
        #expect(DiscoveryCandidateRanker.rank([candidate], intent: .init(goal: "去AI味"), originalQueryCandidateIDs: []).recommended.isEmpty)
        candidate.installCountText = "5.8K"
        let restored = try JSONDecoder().decode(DiscoveryCandidate.self, from: JSONEncoder().encode(candidate))
        #expect(restored.installCount == nil)
        #expect(restored.verifiedInstallCountLowerBound == 5750)
        #expect(DiscoveryPopularityPresentation(candidate: restored).skillUsageValue == "5.8K 次安装")
        #expect(DiscoveryCandidateRanker.rank([restored], intent: .init(goal: "去AI味"), originalQueryCandidateIDs: []).recommended.count == 1)
        candidate.installCountText = "unknown"
        #expect(candidate.verifiedInstallCountLowerBound == 0)
    }

    @Test("Known task Skills remain recommendable when directory search is unavailable")
    func directorySearchOutage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectorySearchOutageProtocol.self]
        var entry = TrustedSkillCatalogEntry(repository: "fixture/humanizer", revision: "HEAD", path: "SKILL.md", name: "humanizer", description: "Rewrite prose to remove AI writing patterns.", trust: .curated)
        entry.searchAliases = ["AI味"]
        let provider = DefaultSkillDiscovery.make(tokenProvider: AnonymousGitHubAccessTokenProvider(), session: URLSession(configuration: configuration), mediaSources: [], catalogEntries: [entry])
        let plan = DiscoveryIntentPlanner.fallback(message: "推荐去文案AI味的skill。", previous: nil)
        let result = try await provider.search(plan: plan, limitPerQuery: 64)
        let ranked = DiscoveryCandidateRanker.rank(result.batch.candidates, intent: plan.intent, originalQueryCandidateIDs: [])
        let candidate = try #require(ranked.recommended.first)
        #expect(candidate.repositoryFullName == "fixture/humanizer")
        #expect(candidate.evidence.skillContentVerified)
        #expect(DiscoveryPopularityPresentation(candidate: candidate).skillUsageValue == "5.8K 次安装")
        #expect(DiscoveryPopularityPresentation(candidate: candidate).repositoryStarsValue == "7.3K Stars")
        #expect(result.batch.failedSourceCount > 0 || result.batch.failedQueryCount > 0)
    }

    @Test("Directory enrichment preserves multiline author descriptions and reads stars without GitHub API")
    func multilineSourceAndStars() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScenarioDocumentProtocol.self]
        let provider = SkillsShDiscoveryProvider(session: URLSession(configuration: configuration), repositoryTokenProvider: AnonymousGitHubAccessTokenProvider())
        let batch = try await provider.search(queries: ["voice-editor"], limitPerQuery: 64)
        let candidate = try #require(batch.candidates.first)
        #expect(candidate.evidence.skillContentVerified)
        #expect(candidate.userFacingSummary?.contains("Rewrite prose") == true)
        #expect(candidate.userFacingSummary != "|")
        #expect(candidate.repositoryStarsText == "7.3K")
    }
}

private final class ScenarioDocumentProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let body: String
        if url.path == "/api/search" {
            body = #"{"skills":[{"name":"voice-editor","source":"fixture/voice-editor","installs":1000}]}"#
        } else if url.host == "raw.githubusercontent.com" {
            body = "---\nname: voice-editor\ndescription: |\n  Rewrite prose so it sounds human.\n  Keep the author's meaning.\n---\n# Guide\n"
        } else {
            #expect(url.host != "api.github.com")
            body = "<script type=\"application/ld+json\">{\"@type\":\"SoftwareApplication\",\"description\":\"Unverified directory description\"}</script><span>GitHub Stars</span><div>7.3K</div>"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class DirectorySearchOutageProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let body: String
        let status: Int
        if url.host == "raw.githubusercontent.com", url.path == "/fixture/humanizer/HEAD/SKILL.md" {
            status = 200
            body = "---\nname: humanizer\ndescription: Rewrite prose to remove AI writing patterns.\n---\n# Guide\n"
        } else if url.host?.hasSuffix("skills.sh") == true, url.path == "/fixture/humanizer/humanizer" {
            status = 200
            body = "<span>Installs</span><div>5.8K</div><span>GitHub Stars</span><div>7.3K</div>"
        } else { status = 503; body = "Unavailable" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
