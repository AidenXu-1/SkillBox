import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Discovery request policy", .serialized)
struct DiscoveryRequestPolicyTests {
    func session() -> URLSession {
        BudgetCountingProtocol.log.reset()
        BudgetCountingProtocol.rawFails = false
        BudgetCountingProtocol.holdRequests = false
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BudgetCountingProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("Public documents avoid metadata API and duplicate resolver traffic")
    func duplicateResolversShareRequests() async throws {
        let session = session()
        let gate = GitHubDiscoveryRateLimitGate()
        let context = DiscoveryRequestContext(gate: gate)
        let provider = DiscoverySearchCoordinator(providers: [
            SkillsShDiscoveryProvider(session: session, rateLimitGate: gate),
            SkillsShDiscoveryProvider(session: session, rateLimitGate: gate),
        ])
        let result = try await DiscoveryNetworkResponseLoader.$context.withValue(context) {
            try await provider.search(queries: ["writing"], limitPerQuery: 64)
        }
        let urls = BudgetCountingProtocol.log.snapshot()
        #expect(result.candidates.filter(\.evidence.skillContentVerified).count == 12)
        #expect(urls.filter { $0.host == "api.github.com" }.isEmpty)
        #expect(urls.filter { $0.host == "raw.githubusercontent.com" }.count == 12)
        #expect(urls.count == 25)
        #expect(await context.usage().reusedRequests > 0)
        await context.finish()
    }

    @Test("Concurrent fallback calls share one operation API budget")
    func concurrentBudgetIsAtomic() async throws {
        let session = session()
        BudgetCountingProtocol.rawFails = true
        let gate = GitHubDiscoveryRateLimitGate()
        let context = DiscoveryRequestContext(gate: gate, maximumGitHubRequests: 3)
        let provider = DiscoverySearchCoordinator(providers: [
            SkillsShDiscoveryProvider(session: session, rateLimitGate: gate),
            SkillsShDiscoveryProvider(session: session, rateLimitGate: gate),
        ])
        _ = try await DiscoveryNetworkResponseLoader.$context.withValue(context) {
            try await provider.search(queries: ["writing"], limitPerQuery: 64)
        }
        #expect(BudgetCountingProtocol.log.snapshot().filter { $0.host == "api.github.com" }.count == 3)
        #expect(await context.usage().githubAPIRequests == 3)
        #expect(await context.usage().budgetBlockedRequests > 0)
        await context.finish()
    }

    @Test("Discovery preserves known anonymous headroom and has an hourly cap")
    func anonymousReserveAndHourlyCap() async {
        let gate = GitHubDiscoveryRateLimitGate()
        let now = Date()
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com/repos/example/skill")!, statusCode: 200,
            httpVersion: nil, headerFields: ["X-RateLimit-Remaining": "13", "X-RateLimit-Reset": String(Int(now.addingTimeInterval(100).timeIntervalSince1970))])!
        await gate.observeDiscoveryResponse(response, anonymous: true)
        #expect(await gate.reserveDiscoveryRequest(authenticated: false))
        #expect(await gate.reserveDiscoveryRequest(authenticated: false) == false)
        #expect(await gate.activeRetryDate() == nil)
        let fresh = GitHubDiscoveryRateLimitGate()
        for _ in 0..<36 { #expect(await fresh.reserveDiscoveryRequest(authenticated: false, now: now)) }
        #expect(await fresh.reserveDiscoveryRequest(authenticated: false, now: now) == false)
        #expect(await fresh.reserveDiscoveryRequest(authenticated: false, now: now.addingTimeInterval(3601)))
    }

    @Test("GitHub redirects consume the same budget instead of bypassing it")
    func redirectsAlsoConsumeBudget() async throws {
        let context = DiscoveryRequestContext(gate: GitHubDiscoveryRateLimitGate(), maximumGitHubRequests: 1)
        let url = URL(string: "https://api.github.com/repos/old/name")!
        let response = HTTPURLResponse(url: url, statusCode: 301, httpVersion: nil, headerFields: nil)!
        let request = URLRequest(url: URL(string: "https://api.github.com/repos/new/name")!)
        #expect(await context.redirect(from: response, to: request) != nil)
        #expect(await context.redirect(from: response, to: request) == nil)
        #expect(await context.usage().githubAPIRequests == 1)
        #expect(await context.usage().budgetBlockedRequests == 1)
        await context.finish()
    }

    @Test("Anonymous code search does not send an unusable request")
    func anonymousCodeSearchHasNoRequest() async {
        let session = session()
        let provider = GitHubSkillDiscoveryProvider(session: session)
        do { _ = try await provider.search(queries: ["writing"], limitPerQuery: 64) } catch {}
        #expect(BudgetCountingProtocol.log.snapshot().isEmpty)
    }

    @Test("Fallback only passes unresolved identities to the next source")
    func fallbackPassesOnlyMissingNames() async throws {
        let first = BudgetResolverSpy(name: "alpha")
        let second = BudgetResolverSpy(name: "beta")
        let last = BudgetResolverSpy(name: "gamma")
        let resolver = DiscoveryFallbackResolver(providers: [first, second, last])
        let result = try await resolver.search(queries: ["alpha", "beta"], limitPerQuery: 64)
        #expect(Set(result.candidates.map(\.name)) == ["alpha", "beta"])
        #expect(await first.queries == [["alpha", "beta"]])
        #expect(await second.queries == [["beta"]])
        #expect(await last.queries.isEmpty)
    }

    @Test("A failed fallback source still allows later sources to resolve the identity")
    func failedSourceStillFallsBack() async throws {
        let next = BudgetResolverSpy(name: "alpha")
        let result = try await DiscoveryFallbackResolver(providers: [BudgetFailureProvider(), next])
            .search(queries: ["alpha"], limitPerQuery: 64)
        #expect(result.candidates.map(\.name) == ["alpha"])
        #expect(result.failedSourceCount == 1)
    }

    @Test("The actual application composition shares metadata and keeps media evidence")
    func actualCompositionUsesOneBudget() async throws {
        let session = session()
        let provider = DefaultSkillDiscovery.make(tokenProvider: AnonymousGitHubAccessTokenProvider(), session: session,
            mediaSources: [BudgetMediaSource()], catalogEntries: [])
        let result = try await provider.search(plan: .init(intent: .init(goal: "Rewrite text"), queries: ["writing"]), limitPerQuery: 64)
        #expect(result.batch.candidates.filter(\.evidence.skillContentVerified).count == 12)
        #expect(result.batch.candidates.contains { !$0.evidence.communityMentions.isEmpty })
        #expect(result.batch.requestUsage?.githubAPIRequests == 0)
        let urls = BudgetCountingProtocol.log.snapshot()
        #expect(urls.filter { $0.host == "api.github.com" }.isEmpty)
        #expect(urls.filter { $0.host == "raw.githubusercontent.com" }.count == 12)
        #expect((result.batch.requestUsage?.reusedRequests ?? 0) >= 12)
    }

    @Test("Budget state survives history without claiming GitHub imposed a limit")
    func budgetHistoryIsHonest() throws {
        var usage = DiscoveryRequestUsage()
        usage.githubAPIRequests = 12
        usage.budgetBlockedRequests = 1
        var batch = DiscoveryBatchSearchResult(candidates: [], originalQueryCandidateIDs: [])
        batch.requestUsage = usage
        #expect(!batch.isExhaustive)
        #expect(DiscoverySearchFeedback.incompleteNotice(for: batch)?.contains("查询预算") == true)
        #expect(batch.rateLimitedUntil == nil)
        var run = DiscoverySearchRun(queries: ["writing"])
        run.requestUsage = usage
        let decoded = try JSONDecoder().decode(DiscoverySearchRun.self, from: JSONEncoder().encode(run))
        #expect(decoded.requestUsage == usage)
        let old = try JSONDecoder().decode(DiscoverySearchRun.self, from: Data("{}".utf8))
        #expect(old.requestUsage == nil)
    }

    @Test("A finished operation cannot issue late fallback requests")
    func finishedOperationStopsLateWork() async throws {
        let session = session()
        let context = DiscoveryRequestContext(gate: GitHubDiscoveryRateLimitGate())
        await context.finish()
        do {
            _ = try await DiscoveryNetworkResponseLoader.$context.withValue(context) {
                try await SkillsShDiscoveryProvider(session: session).search(queries: ["writing"], limitPerQuery: 64)
            }
            Issue.record("Finished operation should reject new requests")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(BudgetCountingProtocol.log.snapshot().isEmpty)
    }

    @Test("Cancelling the actual lookup cancels its network work and the next run is usable")
    func cancellationStopsRequestsAndAllowsNextRun() async throws {
        let session = session()
        BudgetCountingProtocol.holdRequests = true
        let provider = DefaultSkillDiscovery.make(tokenProvider: AnonymousGitHubAccessTokenProvider(), session: session,
            mediaSources: [], catalogEntries: [])
        let plan = DiscoveryIntentPlanner.fallback(message: "https://github.com/probe-0/repo", previous: nil)
        let task = Task { try await provider.search(plan: plan, limitPerQuery: 64) }
        for _ in 0..<100 where BudgetCountingProtocol.log.snapshot().isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(BudgetCountingProtocol.log.snapshot().count == 1)
        task.cancel()
        do { _ = try await task.value; Issue.record("Lookup did not cancel") } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        for _ in 0..<100 where BudgetCountingProtocol.log.stopCount() == 0 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(BudgetCountingProtocol.log.stopCount() > 0)
        BudgetCountingProtocol.holdRequests = false
        let next = try await provider.search(plan: plan, limitPerQuery: 64)
        #expect(next.batch.candidates.count == 1)
        #expect(next.batch.requestUsage?.networkRequests == 1)
        #expect(next.batch.requestUsage?.githubAPIRequests == 0)
    }
}

private actor BudgetResolverSpy: SkillDiscoveryProvider {
    let name: String
    var queries: [[String]] = []
    init(name: String) { self.name = name }
    func search(query: String, limit: Int) async throws -> DiscoverySearchResult { .init(candidates: []) }
    func search(queries: [String], limitPerQuery: Int) async throws -> DiscoveryBatchSearchResult {
        self.queries.append(queries)
        let candidate = DiscoveryCandidate(id: name, name: name, repositoryFullName: "example/\(name)", evidence: .init(skillContentVerified: true))
        return .init(candidates: [candidate], originalQueryCandidateIDs: [name])
    }
}

private struct BudgetFailureProvider: SkillDiscoveryProvider {
    func search(query: String, limit: Int) async throws -> DiscoverySearchResult { throw SkillDiscoveryError.requestFailed(503) }
}

private struct BudgetMediaSource: CommunityMediaSearchSource {
    let platform = DiscoveryCommunityPlatform.youtube
    func search(query: String, limit: Int) async throws -> [CommunityMediaSearchItem] {
        [.init(id: "media-one", platform: .youtube, author: "Reviewer", title: "probe-0 Skill",
               summary: "https://github.com/probe-0/repo", url: URL(string: "https://www.youtube.com/watch?v=example")!)]
    }
}

final class BudgetRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var stops = 0
    func recordStop() { lock.lock(); defer { lock.unlock() }; stops += 1 }
    func stopCount() -> Int { lock.lock(); defer { lock.unlock() }; return stops }
    func append(_ url: URL) { lock.lock(); defer { lock.unlock() }; urls.append(url) }
    func reset() { lock.lock(); defer { lock.unlock() }; urls = []; stops = 0 }
    func snapshot() -> [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

final class BudgetCountingProtocol: URLProtocol, @unchecked Sendable {
    static let log = BudgetRequestLog()
    nonisolated(unsafe) static var rawFails = false
    nonisolated(unsafe) static var holdRequests = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.log.append(url)
        if Self.holdRequests { return }
        let body: Data
        if url.host == "skills.sh", url.path == "/api/search" {
            let rows = (0..<12).map { index -> [String: Any] in
                let name = "probe-\(index)"
                return ["id": "\(name)/repo/\(name)", "name": name, "source": "\(name)/repo", "installs": 1000 + index]
            }
            body = try! JSONSerialization.data(withJSONObject: ["skills": rows])
        } else if url.host == "hn.algolia.com" {
            body = Data("{\"hits\":[],\"nbPages\":1,\"page\":0}".utf8)
        } else if url.path == "/search/code" {
            body = Data("{\"total_count\":0,\"items\":[]}".utf8)
        } else if url.host == "api.github.com" {
            let parts = url.pathComponents.filter { $0 != "/" }
            body = try! JSONSerialization.data(withJSONObject: [
                "full_name": "\(parts[1])/\(parts[2])", "description": "Writing tools", "stargazers_count": 100,
                "updated_at": "2026-09-01T08:00:00Z", "default_branch": "main", "archived": false, "private": false,
            ])
        } else if url.host == "raw.githubusercontent.com" {
            let name = url.pathComponents[1]
            body = Data("---\nname: \(name)\ndescription: Rewrite text for a clear result.\n---\n# Usage\nRead and rewrite the input.\n".utf8)
        } else {
            body = Data("<html></html>".utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: Self.rawFails && url.host == "raw.githubusercontent.com" ? 404 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.log.recordStop() }
}
