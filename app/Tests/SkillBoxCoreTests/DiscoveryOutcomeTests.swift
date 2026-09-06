import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Discovery user outcomes", .serialized)
struct DiscoveryOutcomeTests {
    @Test("A root SKILL.md link retains its exact path")
    func rootDocumentRetainsIdentity() {
        let decision = DiscoveryRequestRouter.classify(
            message: "https://github.com/op7418/Humanizer-zh/blob/main/SKILL.md",
            previousIntent: nil
        )
        #expect(decision.targets.first?.skillPath == "")
        #expect(decision.targets.first?.revision == "main")
    }

    @Test("Tool alternatives in a sentence are not repository identities")
    func slashSeparatedToolsStayScenario() {
        for text in ["帮我找一个 PPT/Excel 的 Skill", "想找 PDF/Word 转换的 Skill"] {
            #expect(DiscoveryRequestRouter.classify(message: text, previousIntent: nil).route == .scenario)
        }
        #expect(DiscoveryRequestRouter.classify(message: "op7418/Humanizer-zh", previousIntent: nil).route == .exact)
        #expect(DiscoveryRequestRouter.classify(message: "帮我找 GitHub 仓库 op7418/Humanizer-zh", previousIntent: nil).route == .exact)
    }

    @Test("Local refinements preserve the task and accumulate user constraints")
    func refinementPreservesTask() {
        let first = DiscoveryIntentPlanner.fallback(message: "帮我找能做公众号排版的 Skill", previous: nil)
        let second = DiscoveryIntentPlanner.fallback(message: "最好支持中文", previous: first.intent)
        let third = DiscoveryIntentPlanner.fallback(message: "不要收费", previous: second.intent)
        #expect(second.intent.goal == first.intent.goal)
        #expect(third.intent.goal == first.intent.goal)
        #expect(third.intent.preferences.contains("最好支持中文"))
        #expect(third.intent.mustHaves.contains("不要收费"))
        #expect(third.queries.contains(where: { $0.contains("公众号") }))
        let changed = DiscoveryIntentPlanner.fallback(message: "改成找视频剪辑的 Skill", previous: third.intent)
        #expect(changed.intent.goal.contains("视频剪辑"))
        #expect(!changed.intent.goal.contains("公众号"))
        let newTask = DiscoveryIntentPlanner.fallback(message: "帮我找免费的 PDF 转换工具", previous: third.intent)
        #expect(newTask.intent.goal.contains("PDF"))
        #expect(!newTask.intent.goal.contains("公众号"))
        #expect(newTask.intent.preferences.isEmpty)
        let model = DiscoveryPlan(intent: .init(goal: "被模型改写的目标"), queries: ["writing"])
        let reconciled = DiscoveryIntentPlanner.reconcile(modelPlan: model, deterministicPlan: third)
        #expect(reconciled.intent.goal == first.intent.goal)
        #expect(reconciled.intent.mustHaves.contains("不要收费"))
    }

    @Test("Unavailable exact verification is not displayed as a confirmed miss")
    func incompleteExactSearchIsHonest() throws {
        let run = DiscoverySearchRun(
            queries: ["repo:owner/repo"], route: .exact, outcome: .exactNotFound,
            fallbackReason: "有候选未完成核验", state: .partiallyCompleted,
            failedCandidateVerificationCount: 1
        )
        let session = DiscoverySession(title: "repo", storageFolderName: "review", runs: [run])
        let presentation = try #require(DiscoveryResultPresentation(session: session))
        #expect(presentation.title == "暂时无法完成核验")
        #expect(!presentation.explanation.contains("并非同一个"))
    }

    @Test("A known repository uses the direct verifier before generic search")
    func repositoryUsesDirectVerifier() async throws {
        let generic = OutcomeSearchSpy()
        let direct = OutcomeDirectSpy()
        let provider = RoutedSkillDiscoveryProvider(
            exactProvider: generic, scenarioProvider: generic, hybridProvider: generic,
            exactTargetProvider: direct
        )
        let plan = DiscoveryIntentPlanner.fallback(message: "https://github.com/op7418/Humanizer-zh", previous: nil)
        _ = try await provider.search(plan: plan, limitPerQuery: 64)
        #expect(await direct.calls == 1)
        #expect(await generic.calls == 0)
    }

    @Test("Verified candidates have app-owned steps without generated capability claims")
    func usageHasActionableNextSteps() {
        let candidate = DiscoveryCandidate(id: "one", name: "humanizer-zh", summary: "作者提供的作用", repositoryFullName: "owner/repo")
        let guide = DiscoveryCandidateUsage.guide(for: candidate)
        #expect(guide.purpose == "作者提供的作用")
        #expect(guide.experienceSteps.count == 3)
        #expect(guide.starterPrompt?.contains("humanizer-zh") == true)
        #expect(guide.origin != .aiAssisted)
    }

    @Test("Raw public evidence works when all GitHub API requests are limited")
    func exactRepositoryWorksWithoutSearchQuota() async throws {
        RawOutcomeProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RawOutcomeProtocol.self]
        let credentials = OutcomeCredentialSpy()
        let provider = GitHubSkillDiscoveryProvider(session: URLSession(configuration: configuration), tokenProvider: credentials)
        let batch = try await provider.searchExact(targets: [
            .init(kind: .repository, value: "known/humanizer", repositoryFullName: "known/humanizer", skillPath: "", revision: "v1"),
        ], limit: 64)
        let candidate = try #require(batch.candidates.first)
        #expect(candidate.userFacingSummary == "改写中文文章。 保留原意。")
        #expect(candidate.evidence.skillContentVerified)
        #expect(RawOutcomeProtocol.requests.map { $0.url!.host! } == ["raw.githubusercontent.com"])
        #expect(RawOutcomeProtocol.requests.first?.url?.path == "/known/humanizer/v1/SKILL.md")
        #expect(RawOutcomeProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(await credentials.calls == 0)
    }
}

private actor OutcomeCredentialSpy: GitHubAccessTokenProvider {
    var calls = 0
    func accessToken() async throws -> String? { calls += 1; return nil }
}

private final class RawOutcomeProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let isRaw = request.url?.host == "raw.githubusercontent.com"
        let body = isRaw ? "---\nname: humanizer\ndescription: >\n  改写中文文章。\n  保留原意。\n---\n" : "{}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: isRaw ? 200 : 429, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor OutcomeSearchSpy: SkillDiscoveryProvider {
    var calls = 0
    func search(query: String, limit: Int) async throws -> DiscoverySearchResult {
        calls += 1
        return .init(candidates: [])
    }
}

private actor OutcomeDirectSpy: ExactTargetSkillDiscoveryProvider {
    var calls = 0
    func searchExact(targets: [DiscoveryTarget], limit: Int) async throws -> DiscoveryBatchSearchResult {
        calls += 1
        return .init(candidates: [], originalQueryCandidateIDs: [])
    }
}
